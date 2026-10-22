import Foundation

// iAP2-over-CarPlay 隧道的配件端：传输是无线会话里的流 130（手机→配件）＋事件通道 iAPSendMessage
// （配件→手机），协议核心仍是 Iap2AccessoryCore——识别、MFi、Now Playing 等与蓝牙／USB 版一致。
// 这层对传输一无所知：收到的原始 iAP2 字节由上层 feed 进来，要发的字节经 send 闭包交回去。
// 照 MacPlay livi_sock.rs run_tunnel：隧道上重新跑一遍完整 bring-up（marker → SYNC → 识别 → 认证），
// 链路参数 zero-ack／出窗 4／控制会话 v2（Iap2Link.Synchronization.local 已是这组）。

package final class Iap2TunnelAccessory: @unchecked Sendable {
    package let core: Iap2AccessoryCore
    private let sendBytes: ([UInt8]) -> Void
    private var started = false

    /// - send: 配件→手机的原始 iAP2 字节（上层包成 iAPSendMessage 发事件通道）；在主线程被叫。
    package init(identity: Iap2MfiIdentity, info: Iap2AccessoryCore.Info = Iap2AccessoryCore.Info(),
                 stopAfterAuth: Bool = false, send: @escaping ([UInt8]) -> Void) {
        var tunnelInfo = info
        tunnelInfo.transport = .wireless
        self.sendBytes = send
        self.core = Iap2AccessoryCore(identity: identity, info: tunnelInfo, stopAfterAuth: stopAfterAuth)
        core.onDrain = { [weak self] bytes in self?.sendBytes(bytes) }
    }

    // 转发：调用方（Wireless）和蓝牙／USB 版同一套接口
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

    /// 开跑（主线程）：发 marker＋SYNC，之后 250ms 心跳驱动重发。手机还没连上数据口也先发——
    /// MacPlay 在 RECORD 时就起链路，由手机来连；SYNC 每 500ms 重发直到被 ACK。
    package func start() {
        guard !started else { return }
        started = true
        core.start()
        core.onLog?("开始：marker＋SYNC 经事件通道发出，等 iPhone 连流 130")
    }

    /// 隧道送来的原始 iAP2 字节（主线程）。
    package func feed(_ bytes: [UInt8]) { core.feed(bytes) }

    /// 数据口断开／流被拆：认证后算正常结束（0），否则 4（与 USB 版 carkit 流关闭同码）。
    package func transportClosed() {
        core.finish(core.phase == .authenticated ? 0 : 4)
    }

    /// 主动停止。
    package func close() { core.finish(0) }
}
