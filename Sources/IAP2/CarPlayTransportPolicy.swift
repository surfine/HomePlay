// CarPlay 传输策略的纯规则：不碰 usbmuxd / IOBluetooth / 网络，离线测试可直接验。
// 决定三件事：USB 链路上 0x4300 来了回哪种 0x4301；拔线时会话怎么处理；另一台手机插线时要不要顶掉。
// 真机依据（2026-10-22 receiver.log）：经 USB iAP2 送无线版 0x4301，iPhone 235 ms 内从 Wi-Fi 回连；
// 而「关 USB 等蓝牙接管」插着线时多半被拒。所以无线优先，12 秒没回连才退回有线 NCM。
import Foundation

package enum CarPlayTransport: Equatable, Sendable {
    case wifi
    case usbNCM
}

package enum CarPlayTransportPolicy {
    package enum StartReply: Equatable, Sendable {
        case wireless                    // 回无线版 0x4301
        case pushWiFiConfigThenWireless  // 先送 0x5703 Wi-Fi 配置，再回无线版 0x4301
        case wired                       // 回有线版 0x4301（NCM 链路本地）
        case waitNCM                     // 有线可用但 NCM 未就绪：由调用方排程重查
        case none                        // 没有可用传输
    }

    /// 0x4300（CarPlay 可用性）到来时该回哪种 0x4301。
    /// wirelessTried = 已经回过无线版、12 秒内手机没连回控制口（退回有线）。
    package static func startReply(wiredAvailable: Bool, wirelessAvailable: Bool,
                                   wifiReady: Bool, wifiConfigSent: Bool, ncmReady: Bool,
                                   wirelessTried: Bool) -> StartReply {
        if wirelessAvailable, wifiReady, !wirelessTried {
            return wifiConfigSent ? .wireless : .pushWiFiConfigThenWireless
        }
        if wiredAvailable { return ncmReady ? .wired : .waitNCM }
        if wirelessAvailable, wifiReady { return .wireless }   // 没有有线可退，只能再试无线
        return .none
    }

    package enum CableGoneAction: Equatable, Sendable {
        case freezeFrame, resumeBluetooth, keepSession, expectReconnect
    }

    /// 拔线（连续两次轮询没看到装置）时该做什么；顺序固定。
    package static func onCableGone(live: Bool, transport: CarPlayTransport?) -> [CableGoneAction] {
        guard live else { return [.resumeBluetooth] }
        switch transport {
        case .wifi: return [.freezeFrame, .resumeBluetooth, .keepSession]
        case .usbNCM, nil: return [.freezeFrame, .resumeBluetooth, .expectReconnect]
        }
    }

    package enum BluetoothAfterDisable: Equatable, Sendable {
        case keep            // 藍牙是唯一的 iAP2 路徑：留著，斷了也走快速重連
        case tunnelCarries   // 流 130 隧道已接手（或正在接）：藍牙照舊慢速保活
    }

    /// 手機送 disableBluetooth 之後藍牙 iAP2 留不留。手機要先 SETUP 流 130 才有隧道；
    /// 舊機型（真機 iPhone8,4，2026-10-22 log 13 次）從不 SETUP 130，這時關藍牙就沒有
    /// 通話狀態與正在播放了，所以只要沒 SETUP 130 就留藍牙。
    package static func bluetoothAfterDisable(tunnelSetUp: Bool) -> BluetoothAfterDisable {
        tunnelSetUp ? .tunnelCarries : .keep
    }

    /// 會話進行中藍牙 iAP2 斷線後要不要走慢速保活（60 s）。藍牙是唯一路徑時不能慢。
    package static func bluetoothRetryIsSlow(live: Bool, keepBluetooth: Bool) -> Bool {
        live && !keepBluetooth
    }

    package enum NewPhoneAction: Equatable, Sendable { case switchPhone, ignore }

    /// 新的 USB 手机（蓝牙地址或 USB 序号）出现时，是否要结束目前会话换成它。
    package static func onNewUSBPhone(liveOwner: String?, newPhone: String) -> NewPhoneAction {
        guard let liveOwner else { return .ignore }
        return PairingRules.normalize(liveOwner) == PairingRules.normalize(newPhone) ? .ignore : .switchPhone
    }

    /// 由控制连接的对端地址判断会话走的是 Wi-Fi 还是 USB NCM。
    /// Wi-Fi 也可能给 fe80 链路本地地址，所以只看 `%` 后面的网口名是不是这台手机的 NCM 网口。
    package static func transport(forPeer host: String, ncmInterfaces: [String]) -> CarPlayTransport {
        guard let percent = host.lastIndex(of: "%") else { return .wifi }
        let iface = String(host[host.index(after: percent)...])
        return ncmInterfaces.contains(iface) ? .usbNCM : .wifi
    }
}

/// 拔线去抖：usbmuxd 的 ListDevices 偶尔丢错会被当成空清单，一次抖动不算拔线。
package struct CableDebounce: Sendable, Equatable {
    private let misses: Int
    private var missed = 0
    private var present = false

    package init(misses: Int = 2) {
        precondition(misses >= 1)
        self.misses = misses
    }

    /// 回传「目前是否视为有线插着」。present=true 立刻视为插着并归零；
    /// present=false 要连续 misses 次才翻成拔线，之前维持上一个状态。
    package mutating func observe(present seen: Bool) -> Bool {
        if seen {
            missed = 0
            present = true
            return true
        }
        missed += 1
        if missed >= misses { present = false }
        return present
    }
}
