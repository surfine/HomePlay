import Foundation
import IOBluetooth

// 蓝牙 iAP2 配件端：对 iPhone 打开 iAP2 RFCOMM 通道，通芯交给 Iap2AccessoryCore。
// 可变状态只在主队列读写，IOBluetooth 回调一律跳主队列再碰状态。
// locateAuto 自动匹配：已配对设备里谁带 iAP2 服务（iPhone 的签名）就连谁，当前已连接的优先。

package final class Iap2BluetoothAccessory: NSObject, IOBluetoothRFCOMMChannelDelegate, @unchecked Sendable {
    package let core: Iap2AccessoryCore
    /// RFCOMM 打开超时（秒）；0 关闭。照 MacPlay 的 15s。
    /// 手机愿意回时都在 1 秒内（2026-10-22 真机）；15 秒（MacPlay 值）只是在拉长每次被忽略的代价。
    package var openTimeout: TimeInterval = 6
    private var channel: IOBluetoothRFCOMMChannel?
    private var openTimer: DispatchSourceTimer?
    /// 打开完成时刻与是否收到过字节：用来识别「开了立刻被手机关闭」——
    /// 那通常意味着 SDP 缓存里的 iAP2 通道过期（真机样本 2026-10-19 23:09–23:26：
    /// 每轮 open 后 10–30ms 被关闭、零字节交互）。上层收到 11 就刷新 SDP 再重连。
    private var openedAt = Date.distantPast
    private var receivedAny = false

    package init(identity: Iap2MfiIdentity, info: Iap2AccessoryCore.Info = Iap2AccessoryCore.Info(), stopAfterAuth: Bool) {
        self.core = Iap2AccessoryCore(identity: identity, info: info, stopAfterAuth: stopAfterAuth)
        super.init()
        core.transportTeardown = { [weak self] _ in self?.close() }
        core.onDrain = { [weak self] bytes in self?.write(bytes) }
    }

    // 转发：调用方（Wireless/探针）像以前一样挂在配件上
    package var onLog: ((String) -> Void)? {
        get { core.onLog } set { core.onLog = newValue }
    }
    package var onPhase: ((Iap2AccessoryCore.Phase) -> Void)? {
        get { core.onPhase } set { core.onPhase = newValue }
    }
    package var onMessage: ((Iap2Csm.Frame) -> [Iap2Csm.Frame])? {
        get { core.onMessage } set { core.onMessage = newValue }
    }
    package var onArtwork: ((UInt8, Data) -> Void)? {
        get { core.onArtwork } set { core.onArtwork = newValue }
    }
    package var onFinished: ((Int) -> Void)? {
        get { core.onFinished } set { core.onFinished = newValue }
    }
    package var phase: Iap2AccessoryCore.Phase { core.phase }
    package var finished: Bool { core.finished }

    // MARK: 找设备

    // 使用者按下「忘记 iPhone」后，系统配对记录可能仍删不掉（macOS 不提供公开 unpair）；
    // 这里维护应用层黑名单，让 HomePlay 不再尝试这台手机。地址统一成冒号大写。
    private static let ignoredLock = NSLock()
    private static nonisolated(unsafe) var _ignored: Set<String> = []

    package static var ignoredAddresses: Set<String> {
        get { ignoredLock.lock(); defer { ignoredLock.unlock() }; return _ignored }
        set {
            ignoredLock.lock()
            _ignored = Set(newValue.map { PairingRules.normalize($0) })
            ignoredLock.unlock()
        }
    }
    package static func isIgnored(_ address: String) -> Bool {
        ignoredLock.lock(); defer { ignoredLock.unlock() }
        return _ignored.contains(PairingRules.normalize(address))
    }

    /// 尽力尝试删除系统配对；部分 macOS 版本对隐藏的 CarPlay 配对会拒绝，应用层黑名单仍然生效。
    @discardableResult
    package static func unpair(address: String) -> Bool {
        let normalized = address.replacingOccurrences(of: ":", with: "-").lowercased()
        guard let device = IOBluetoothDevice(addressString: normalized) else { return false }
        _ = device.perform(Selector(("forceRemove")))
        return true
    }
    package static var iap2ServiceUUID: IOBluetoothSDPUUID { IOBluetoothSDPUUID(data: Data([
        0x00, 0x00, 0x00, 0x00, 0xde, 0xca, 0xfa, 0xde,
        0xde, 0xca, 0xde, 0xaf, 0xde, 0xca, 0xca, 0xfe])) }

    package static func pairedDevices() -> [(address: String, name: String)] {
        ((IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []).compactMap { device in
            let address = (device.addressString ?? "").uppercased().replacingOccurrences(of: "-", with: ":")
            guard !isIgnored(address) else { return nil }
            return (address, device.name ?? "")
        }
    }

    /// 已配对设备里看起来是手机的。**不靠名字**——iPhone 可以被命名成任意字符串
    /// （真机教训 2026-10-19：设备叫 "Aaron's Phone"，名字规则漏掉了它）。用设备自身的属性：
    /// 1) CoD 主类 = Phone（配对/查询即可拿到）；
    /// 2) 设备带 iAP2 服务记录（Apple 设备的签名）。
    /// 刚配对、两者暂时都拿不到的设备不会出现在这个列表里；出站连接不依赖它
    /// （locate(address:) 直接查已配对设备），第一次连接/SDP 后列表就会自动补上。
    package static func pairedPhones() -> [(address: String, name: String)] {
        var seen = Set<String>()
        return ((IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []).compactMap { device in
            let name = device.name ?? ""
            let phone = device.deviceClassMajor == kBluetoothDeviceClassMajorPhone
                || device.getServiceRecord(for: iap2ServiceUUID) != nil
            guard phone, !isIgnored(device.addressString ?? ""),
                  let raw = device.addressString,
                  seen.insert(raw.uppercased().replacingOccurrences(of: "-", with: ":")).inserted else { return nil }
            let address = raw.uppercased().replacingOccurrences(of: "-", with: ":")
            return (address, name)
        }
    }

    /// 本机蓝牙名（iPhone 的蓝牙列表里看到的名字，也是配对弹窗上的名字）。
    package static var localBluetoothName: String {
        if let name = IOBluetoothHostController.default()?.nameAsString(), !name.isEmpty { return name }
        return Host.current().localizedName ?? "Mac"
    }

    /// 系统配对列表里有没有这台设备（不要求 iAP2 服务记录）。USB CarPlay 期间
    /// 手机常会临时关蓝牙/清 SDP，locate 会失败；这时不能把它当成“没配对”再弹一次配对。
    package static func isSystemPaired(_ address: String) -> Bool {
        guard !isIgnored(address) else { return false }
        let normalized = address.uppercased().replacingOccurrences(of: "-", with: ":")
        return ((IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []).contains {
            ($0.addressString ?? "").uppercased().replacingOccurrences(of: "-", with: ":") == normalized
        }
    }

    /// 已配对设备 + 它的 iAP2 RFCOMM 通道号；失败时给一句能照着做的原因
    package static func locate(address: String) -> Result<(IOBluetoothDevice, BluetoothRFCOMMChannelID), LocateError> {
        guard !isIgnored(address) else { return .failure(.notPaired) }
        let normalized = address.replacingOccurrences(of: ":", with: "-").lowercased()
        guard let devices = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice],
              let device = devices.first(where: { ($0.addressString ?? "").lowercased() == normalized }) else {
            return .failure(.notPaired)
        }
        guard let record = device.getServiceRecord(for: iap2ServiceUUID) else { return .failure(.noService) }
        var channelID: BluetoothRFCOMMChannelID = 0
        guard record.getRFCOMMChannelID(&channelID) == kIOReturnSuccess else { return .failure(.noChannel) }
        return .success((device, channelID))
    }

    /// 自动匹配：扫已配对设备的缓存 SDP，谁有 iAP2 服务就连谁（当前已连接的排前面）。
    /// 返回找到的地址供上层记住（下次优先直连）。缓存都没有时返回 .noService——上层会刷新 SDP 再来。
    package static func locateAuto() -> Result<(IOBluetoothDevice, BluetoothRFCOMMChannelID, String), LocateError> {
        guard let devices = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice], !devices.isEmpty else {
            return .failure(.notPaired)
        }
        let ranked = devices
            .filter { !isIgnored($0.addressString ?? "") }
            .sorted { $0.isConnected() && !$1.isConnected() }
        for device in ranked {
            guard let record = device.getServiceRecord(for: iap2ServiceUUID) else { continue }
            var channelID: BluetoothRFCOMMChannelID = 0
            guard record.getRFCOMMChannelID(&channelID) == kIOReturnSuccess,
                  let address = device.addressString?.uppercased().replacingOccurrences(of: "-", with: ":") else { continue }
            return .success((device, channelID, address))
        }
        return .failure(.noService)
    }

    package enum LocateError: Error, CustomStringConvertible {
        case notPaired, noService, noChannel
        package var description: String {
            switch self {
            case .notPaired: return "没有已配对的蓝牙设备（先在系统设置里配对 iPhone）"
            case .noService: return "已配对设备里没有 iAP2 服务（iPhone 没解锁亮屏，或缓存里没有服务记录）"
            case .noChannel: return "读不到 iAP2 的 RFCOMM 通道号"
            }
        }
    }

    package static var localBluetoothAddress: String { Iap2AccessoryCore.localBluetoothAddress }

    package func start(device: IOBluetoothDevice, channelID: BluetoothRFCOMMChannelID) -> Bool {
        core.onLog?("RFCOMM 用通道 \(channelID) 打开（来自 SDP 缓存）")
        var pointer: IOBluetoothRFCOMMChannel?
        let status = device.openRFCOMMChannelAsync(&pointer, withChannelID: channelID, delegate: self)
        guard status == kIOReturnSuccess, let pointer else {
            core.onLog?("RFCOMM 打开失败（0x\(String(status, radix: 16))）")
            return false
        }
        channel = pointer
        peerDevice = device
        armOpenTimeout()
        return true
    }

    /// iPhone 主动连进来（我们发布了 iAP2 / CarPlay SDP 服务）：直接接管已打开的通道。
    /// 返回 false 表示已有通道或会话已结束，调用方负责关掉这条新通道。
    package func adopt(channel newChannel: IOBluetoothRFCOMMChannel) -> Bool {
        guard channel == nil, !core.finished else { return false }
        channel = newChannel
        peerDevice = newChannel.getDevice()
        newChannel.setDelegate(self)
        openTimer?.cancel(); openTimer = nil
        DispatchQueue.main.async {
            self.core.onLog?("接受 iPhone 发起的 RFCOMM 连接")
            self.core.start()
        }
        return true
    }

    package func close() {
        openTimer?.cancel(); openTimer = nil
        channel?.close(); channel = nil
    }

    private var peerDevice: IOBluetoothDevice?
    /// 把到这台手机的基带（ACL）连接也断掉。手机「通道开了立刻关」时多半是它那边还留着上一条
    /// 链路的状态；重开 RFCOMM 之前先断 ACL，让下一次是干净的新连接（MacPlay 在 disableBluetooth 后也这么做）。
    package func dropBaseband() -> Bool {
        guard let device = peerDevice, device.isConnected() else { return false }
        return device.closeConnection() == kIOReturnSuccess
    }

    /// 照 MacPlay：15s 打不开就关了重来（上层退避重连会刷新 SDP）
    private func armOpenTimeout() {
        guard openTimeout > 0 else { return }
        openTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + openTimeout)
        timer.setEventHandler { [weak self] in
            guard let self, let channel = self.channel, !self.core.finished, self.core.phase == .linkDetect else { return }
            self.core.onLog?("RFCOMM 打开超时（\(Int(self.openTimeout))s），断开重试")
            self.close()
            self.core.finish(9)
        }
        openTimer = timer
        timer.resume()
    }

    // MARK: RFCOMM 回调（IOBluetooth 线程）

    package func rfcommChannelOpenComplete(_ sender: IOBluetoothRFCOMMChannel!, status error: IOReturn) {
        guard sender === channel else { sender?.close(); return }   // 迟到的旧通道：关掉，别动现役会话
        guard error == kIOReturnSuccess else {
            DispatchQueue.main.async {
                self.core.onLog?("RFCOMM 打开完成但失败（0x\(String(error, radix: 16))）"); self.core.finish(3)
            }
            return
        }
        DispatchQueue.main.async {
            self.openTimer?.cancel(); self.openTimer = nil
            self.openedAt = Date()
            self.receivedAny = false
            self.core.onLog?("RFCOMM 通道已打开")
            self.core.start()
            self.core.onLog?("开始：marker＋SYNC 已发，等 iPhone")
        }
    }

    package func rfcommChannelData(_ sender: IOBluetoothRFCOMMChannel!, data dataPointer: UnsafeMutableRawPointer!, length dataLength: Int) {
        guard sender === channel else { return }
        let pointer = dataPointer.assumingMemoryBound(to: UInt8.self)
        let bytes = [UInt8](UnsafeBufferPointer(start: pointer, count: dataLength))
        DispatchQueue.main.async {
            self.receivedAny = true
            self.core.feed(bytes)
        }
    }

    package func rfcommChannelClosed(_ sender: IOBluetoothRFCOMMChannel!) {
        guard sender === channel else { return }
        DispatchQueue.main.async {
            let immediate = !self.receivedAny && Date().timeIntervalSince(self.openedAt) < 2
            self.core.onLog?(immediate ? "RFCOMM 通道被立刻关闭（零字节）——可能 SDP 缓存的通道过期" : "RFCOMM 通道关闭")
            if immediate { self.core.finish(11) }
            else { self.core.finish(self.core.phase == .authenticated ? 0 : 4) }
        }
    }

    // MARK: 发送（主线程）

    /// 把链路输出按 RFCOMM MTU 分块写（一次最多 UInt16），写失败就结束而不是悄悄丢字节
    private func write(_ out: [UInt8]) {
        guard !out.isEmpty, let channel else { return }
        let mtu = max(1, Int(channel.getMTU()))
        var offset = 0
        while offset < out.count {
            var chunk = Array(out[offset..<min(out.count, offset + mtu)])
            let st = channel.writeSync(&chunk, length: UInt16(chunk.count))
            if st != kIOReturnSuccess {
                core.onLog?("RFCOMM 写失败（0x\(String(st, radix: 16))）"); core.finish(5); return
            }
            offset += chunk.count
        }
    }
}
