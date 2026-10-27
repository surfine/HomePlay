// 照 MacPlay 的蓝牙桥：把 Mac 临时广播成车机 A/V 设备，并发布 iAP2 / CarPlay 的 SDP 服务。
// iPhone 配对后会看到 CarPlay 服务，也可能主动通过 RFCOMM 连进来；这是首次配对成功率的关键。
// 类设备值只维持 120 秒，系统会自动恢复；我们在 60 秒时续一次。SDP 记录标成非持久，进程退出即消失。
import Foundation
import IOBluetooth

final class BluetoothBeacon: NSObject {
    var log: ((String) -> Void)?
    /// 收到 iPhone 主动打开的 RFCOMM 通道。调用方负责接管或关闭，beacon 不再碰它。
    var onIncoming: ((IOBluetoothDevice, IOBluetoothRFCOMMChannel) -> Void)?

    private var records: [IOBluetoothSDPServiceRecord] = []
    private var notifications: [IOBluetoothUserNotification] = []
    private var classTimer: Timer?
    private var serviceTimer: Timer?
    private(set) var iap2Channel: BluetoothRFCOMMChannelID = 0
    private(set) var carPlayChannel: BluetoothRFCOMMChannelID = 0

    /// 车机 A/V 设备类（MacPlay 同款）。服务类包含 Audio，主类 0x04。
    private static let carClass: BluetoothClassOfDevice = 0x200408
    private static let iap2UUIDBytes: [UInt8] = [
        0x00, 0x00, 0x00, 0x00, 0xde, 0xca, 0xfa, 0xde,
        0xde, 0xca, 0xde, 0xaf, 0xde, 0xca, 0xca, 0xff]
    private static let carPlayUUIDBytes: [UInt8] = [
        0xec, 0x88, 0x43, 0x48, 0xcd, 0x41, 0x40, 0xa2,
        0x97, 0x27, 0x57, 0x5d, 0x50, 0xbf, 0x1f, 0xd3]

    override init() {
        self.advertiseClass = true
        super.init()
        start()
    }

    /// 测试/诊断用：advertiseClass=false 只发布 SDP，不改 Mac 的蓝牙设备类。
    /// log 在 start() 之前装好，init 阶段（设备类/SDP 发布结果）的日志才不会丢。
    init(advertiseClass: Bool, log: ((String) -> Void)? = nil) {
        self.advertiseClass = advertiseClass
        self.log = log
        super.init()
        start()
    }

    private let advertiseClass: Bool
    private var hasIAP2 = false
    private var hasCarPlay = false
    private var lastClassResult: IOReturn?
    private var lastPower: UInt32 = 0xFF
    private var servicesLost = false
    private(set) var stopped = false

    /// 停止广播：撤掉 SDP、停掉续期。车机类只维持 120 秒，不再续期后系统自己恢复。
    /// 用于「桌宠没在跑」的后台常驻：不再让 iPhone 把 Mac 认成一台可配对的 CarPlay 车机。
    func stop() {
        guard !stopped else { return }
        stopped = true
        classTimer?.invalidate(); classTimer = nil
        serviceTimer?.invalidate(); serviceTimer = nil
        for note in notifications { note.unregister() }
        notifications.removeAll()
        for record in records { _ = record.remove() }
        records.removeAll()
        hasIAP2 = false
        hasCarPlay = false
        log?("广播已停止（SDP 已移除，车机类 120 秒内自动恢复）")
    }

    private func start() {
        if advertiseClass {
            advertiseCarClass()
            // 60 秒续一次，确保 120 秒的临时类不会在长会话里过期。
            let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in self?.tick() }
            RunLoop.main.add(timer, forMode: .common)
            classTimer = timer
        }
        publishServices()
        if !hasIAP2 || !hasCarPlay {
            // 蓝牙可能是刚在设置里打开的：每 10 秒重试发布，直到两个服务都成功。
            let timer = Timer(timeInterval: 10, repeats: true) { [weak self] timer in
                guard let self else { timer.invalidate(); return }
                if self.advertiseClass { self.advertiseCarClass() }
                self.publishServices()
                if self.hasIAP2 && self.hasCarPlay {
                    self.servicesLost = false
                    timer.invalidate()
                    self.serviceTimer = nil
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            serviceTimer = timer
        }
    }

    private func tick() {
        guard !stopped else { return }
        let power = IOBluetoothHostController.default()?.powerState.rawValue ?? 0xFF
        if lastPower != 0xFF, power != lastPower, power == 0 {
            servicesLost = true   // 蓝牙被关掉：之前的 SDP 记录可能没了
        }
        if lastPower == 0, power == 1 {
            // 重新打开：若服务确实是在关闭前发布过，重发一次（10 秒重试计时器还在时交给它做）。
            if servicesLost, serviceTimer == nil {
                hasIAP2 = false
                hasCarPlay = false
                records.removeAll()
                notifications.removeAll()
                log?("蓝牙重新打开，重新发布 iAP2 / CarPlay 服务")
                publishServices()
            }
            servicesLost = false
        }
        lastPower = power
        if power == 1 { advertiseCarClass() }
        if !hasIAP2 || !hasCarPlay { publishServices() }
    }

    private func advertiseCarClass() {
        guard let host = IOBluetoothHostController.default() else {
            if lastClassResult != kIOReturnNoDevice {
                lastClassResult = kIOReturnNoDevice
                log?("找不到蓝牙控制器")
            }
            return
        }
        let result = host.setClassOfDevice(Self.carClass, forTimeInterval: 120)
        guard result != lastClassResult else { return }
        lastClassResult = result
        if result == kIOReturnSuccess {
            log?("广播为车机 Bluetooth 类 0x\(String(Self.carClass, radix: 16))（120 秒）")
        } else {
            log?("设置 Bluetooth 类失败（0x\(String(result, radix: 16))）——继续用普通电脑类")
        }
    }

    private func publishServices() {
        if !hasIAP2 { publishIAP2() }
        if !hasCarPlay { publishCarPlay() }
    }

    /// 配对引导开始时调用：如果启动时蓝牙还没开、服务发布失败，这里立刻再试一次。
    func retryNow() {
        if advertiseClass { advertiseCarClass() }
        publishServices()
    }

    /// 手机把 iAP2 通道「接受后立刻关闭」（零字节）时，常见是它缓存了旧的配件 SDP 状态。
    /// 移除并重新发布 iAP2/CarPlay SDP、重设车机类，让手机重新发现；
    /// 真机 2026-10-19 验证：接收器重启能恢复该状态，这里是进程内的等价动作。
    func republish() {
        for record in records { _ = record.remove() }
        for note in notifications { note.unregister() }
        records.removeAll()
        notifications.removeAll()
        hasIAP2 = false
        hasCarPlay = false
        servicesLost = false
        if advertiseClass { advertiseCarClass() }
        publishServices()
        log?("已重新发布 iAP2 / CarPlay SDP（恢复手机缓存的旧状态）")
    }

    private func publishIAP2() {
        let iap2UUID = IOBluetoothSDPUUID(data: Data(Self.iap2UUIDBytes))
        let l2cap = IOBluetoothSDPUUID(uuid16: 0x0100)
        let rfcomm = IOBluetoothSDPUUID(uuid16: 0x0003)
        // iAP2 服务：让 iPhone 知道这台 Mac 能讲 iAP2（UUID 结尾 FF）。
        // 通道 18 被占用时换一个，避免整个服务发布失败。
        for requested in [18, 20, 22, 24] {
            let iap2: IOBluetoothSDPServiceRecord? = IOBluetoothSDPServiceRecord.publishedServiceRecord(with: [
                "0001": [iap2UUID],
                "0004": [
                    [l2cap],
                    [rfcomm, ["DataElementType": 1, "DataElementSize": 1, "DataElementValue": requested]],
                ],
                "0100": "HomePlay",
                "LocalAttributes": ["Persistent": false],
            ])
            guard let iap2 else { continue }
            hasIAP2 = true
            records.append(iap2)
            var channel: BluetoothRFCOMMChannelID = 0
            if iap2.getRFCOMMChannelID(&channel) == kIOReturnSuccess {
                iap2Channel = channel
                registerIncoming(channel)
            }
            log?("iAP2 SDP 服务已发布（RFCOMM \(channel)）")
            return
        }
        log?("iAP2 SDP 服务发布失败（18/20/22/24 都被占用？稍后重试）")
    }

    private func publishCarPlay() {
        let carPlayUUID = IOBluetoothSDPUUID(data: Data(Self.carPlayUUIDBytes))
        let l2cap = IOBluetoothSDPUUID(uuid16: 0x0100)
        let rfcomm = IOBluetoothSDPUUID(uuid16: 0x0003)
        let publicBrowse = IOBluetoothSDPUUID(uuid16: 0x1002)
        // CarPlay 服务：iPhone 配对后据此把 Mac 认成车机。
        for requested in [19, 21, 23, 25] {
            let carPlay: IOBluetoothSDPServiceRecord? = IOBluetoothSDPServiceRecord.publishedServiceRecord(with: [
                "0001": [carPlayUUID],
                "0004": [
                    [l2cap],
                    [rfcomm, ["DataElementType": 1, "DataElementSize": 1, "DataElementValue": requested]],
                ],
                "0005": [publicBrowse],
                "0100": "HomePlay CarPlay",
                "LocalAttributes": ["Persistent": false],
            ])
            guard let carPlay else { continue }
            hasCarPlay = true
            records.append(carPlay)
            var channel: BluetoothRFCOMMChannelID = 0
            if carPlay.getRFCOMMChannelID(&channel) == kIOReturnSuccess {
                carPlayChannel = channel
                registerIncoming(channel)
            }
            log?("CarPlay SDP 服务已发布（RFCOMM \(channel)）")
            return
        }
        log?("CarPlay SDP 服务发布失败（19/21/23/25 都被占用？稍后重试）")
    }

    private func registerIncoming(_ channel: BluetoothRFCOMMChannelID) {
        guard channel != 0 else { return }
        if let note = IOBluetoothRFCOMMChannel.register(forChannelOpenNotifications: self,
                                                       selector: #selector(opened(_:channel:)),
                                                       withChannelID: channel,
                                                       direction: IOBluetoothUserNotificationChannelDirection(rawValue: 1)) {
            notifications.append(note)
        } else {
            log?("注册 RFCOMM \(channel) 入站通知失败")
        }
    }

    @objc private func opened(_ note: IOBluetoothUserNotification, channel: IOBluetoothRFCOMMChannel) {
        guard let device = channel.getDevice() else {
            channel.close()
            return
        }
        log?("iPhone 主动连入 RFCOMM（\(device.name ?? "?")）")
        if let onIncoming {
            onIncoming(device, channel)
        } else {
            channel.close()
        }
    }
}
