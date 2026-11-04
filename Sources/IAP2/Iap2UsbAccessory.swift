import Foundation

// USB iAP2 配件端：lockdown 开出 carkit 流（Iap2Usbmuxd.swift），通芯交给 Iap2AccessoryCore。
// 与蓝牙版同一套协议核心——识别、MFi、会话消息全部一致，只是传输换成了 usbmuxd。

package final class Iap2UsbAccessory: Iap2AccessoryForwarding, @unchecked Sendable {
    package let core: Iap2AccessoryCore
    package let device: Usbmuxd.Device
    private let stream: any Usbmuxd.MuxByteStream
    private var started = false

    package init(device: Usbmuxd.Device, identity: Iap2MfiIdentity,
                 info: Iap2AccessoryCore.Info = Iap2AccessoryCore.Info(), stopAfterAuth: Bool,
                 log: @escaping (String) -> Void) throws {
        self.device = device
        let carkit = try Lockdown.openCarkit(device: device, log: log)
        self.stream = carkit.stream
        var wiredInfo = info
        wiredInfo.transport = .wired
        self.core = Iap2AccessoryCore(identity: identity, info: wiredInfo, stopAfterAuth: stopAfterAuth)
        core.transportTeardown = { [weak self] _ in self?.stream.close() }
        core.onDrain = { [weak self] bytes in self?.stream.send(bytes) }
    }

    // 回调转发面（onLog/onPhase/onMessage/onArtwork/onFinished/phase/finished）在 Iap2AccessoryForwarding

    /// 停止：关掉 carkit 流，让手机看到正常断开（不留"配件还在会话里"的残留）。
    package func close() { core.finish(0) }

    /// 开跑：接流、发 marker。字节来了跳主线程喂核心，回包从 takeOutput 拿走发回去。
    package func start() {
        guard !started else { return }
        started = true
        stream.onBytes = { [weak self] bytes in
            DispatchQueue.main.async { self?.core.feed(bytes) }
        }
        stream.onClosed = { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                self.core.onLog?("carkit 流关闭")
                self.core.finish(self.core.phase == .authenticated ? 0 : 4)
            }
        }
        core.onLog?("carkit 流已打开（USB）")
        stream.startReading()
        core.start()
        core.onLog?("开始：marker＋SYNC 已发，等 iPhone")
    }

}
