// 事件通道：手机在 SETUP 后连我们的 eventPort，我们在上面推 HID 报告和命令
// （对应 MacPlay cpStack.ts 的 _openEventChannel / _sendEventCommand / sendTouches / sendKnob）。
// 通道从第一个字节起就是加密的；加密由外部（P4 的 ControlCipher）通过 MessageSealer 注入。
import Foundation
import Network

/// 事件／控制通道的帧加密。`open` 吃进目前缓冲的全部密文，吐出整帧能解的明文和剩下的尾巴
/// （和 MacPlay ControlCipher.decrypt 同形）。
package protocol MessageSealer: AnyObject {
    func seal(_ plain: Data) throws -> Data
    func open(_ buffered: Data) throws -> (plain: Data, rest: Data)
}

package final class EventChannel {
    /// 连接建立时取加密器；返回 nil 就按明文走（测试用）
    private let makeSealer: () -> MessageSealer?
    private var listener: NWListener?
    private var conn: NWConnection?
    private var sealer: MessageSealer?
    private var parser = RTSPParser()
    private var cipherBuffer = Data()
    private var cseq = 0
    private let queue = DispatchQueue(label: "session.event")

    /// 手机发来的请求（应答已由本类自动回 200）
    package var onRequest: ((RTSPMessage) -> Void)?
    package var onConnected: (() -> Void)?
    package var onClosed: (() -> Void)?
    package var onError: ((String) -> Void)?

    package init(sealer: @escaping () -> MessageSealer?) { makeSealer = sealer }

    package var isConnected: Bool { queue.sync { conn != nil } }

    package func start(timeout: TimeInterval = 5) throws -> UInt16 {
        let l = try NWListener(using: .tcp)
        l.newConnectionHandler = { [weak self] c in self?.accept(c) }
        let port = try listenAndWait(l, queue: queue, timeout: timeout)
        listener = l
        return port
    }

    package func stop() {
        queue.sync { conn?.cancel(); conn = nil }
        listener?.cancel(); listener = nil
    }

    private func accept(_ c: NWConnection) {
        conn?.cancel()
        conn = c; sealer = makeSealer(); parser = RTSPParser(); cipherBuffer = Data()
        c.start(queue: queue)
        onConnected?()
        receive(c)
    }

    private func receive(_ c: NWConnection) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [weak self] data, _, done, err in
            guard let self, self.conn === c else { return }
            if let data, !data.isEmpty { self.ingest(data, from: c) }
            if done || err != nil { self.conn = nil; c.cancel(); self.onClosed?(); return }
            self.receive(c)
        }
    }

    package func ingest(_ data: Data, from c: NWConnection? = nil) {
        var plain = data
        if let sealer {
            cipherBuffer.append(data)
            do { let r = try sealer.open(cipherBuffer); cipherBuffer = r.rest; plain = r.plain }
            catch { onError?("event channel decrypt failed: \(error)"); return }
        }
        for m in parser.feed(plain) {
            if m.isResponse { continue }   // 手机对我们命令的应答
            onRequest?(m)
            write(rtspSerialize(RTSPResponse(status: 200), for: m))
        }
    }

    private func write(_ plain: Data) {
        guard let c = conn else { return }
        do {
            let out = try sealer?.seal(plain) ?? plain
            c.send(content: out, completion: .contentProcessed { _ in })
        } catch { onError?("event channel seal failed: \(error)") }
    }

    /// 发一条 `POST /command`，正文是 bplist。通道没连上就丢。
    package func sendCommand(_ bplistBody: Data, streamID: Int? = nil) {
        queue.async { [self] in
            guard conn != nil else { return }
            cseq += 1
            write(rtspEventCommand(body: bplistBody, cseq: cseq, streamID: streamID))
        }
    }

    package func sendHIDReport(uuid: UInt32, report: Data) {
        if let b = try? CarPlayPlist.hidSendReport(uuid: uuid, report: report) { sendCommand(b) }
    }

    /// 0..1 的触点，按流像素尺寸换成多点触控报告
    package func sendTouches(_ contacts: [(id: Int, x: Double, y: Double, down: Bool)], streamWidth: Int, streamHeight: Int) {
        sendHIDReport(uuid: HID.touchUID, report: HID.touchReport(normalized: contacts, streamWidth: streamWidth, streamHeight: streamHeight))
    }

    /// 旋钮：按下的状态之后紧跟一个全零的松开（momentary）
    package func sendKnob(_ state: KnobState, momentary: Bool = true) {
        sendHIDReport(uuid: HID.knobUID, report: HID.knobReport(state))
        if momentary { sendHIDReport(uuid: HID.knobUID, report: HID.knobReport(KnobState())) }
    }

    /// 车机 Siri 键：requestSiri buttonDown(2) + buttonUp(3)（MacPlay invokeSiri 同款）
    package func sendSiri() {
        for action in [2, 3] { sendSiri(action: action) }
    }

    /// 單一 Siri 鍵動作：2＝按下（開始聽）、3＝放開（結束）。按住說話時分開送。
    package func sendSiri(action: Int) {
        if let b = try? CarPlayPlist.requestSiri(action: action) { sendCommand(b) }
    }

    package func sendMedia(_ b: HID.MediaButton) {
        sendHIDReport(uuid: HID.mediaUID, report: HID.mediaReport(b.rawValue))
        sendHIDReport(uuid: HID.mediaUID, report: HID.mediaReport(0))
    }

    package func sendTelephony(_ b: HID.TelephonyButton) {
        sendHIDReport(uuid: HID.telephonyUID, report: HID.telephonyReport(b.rawValue))
        sendHIDReport(uuid: HID.telephonyUID, report: HID.telephonyReport(0))
    }

    /// iAP2 隧道（流 130）的反向路径：原始 iAP2 字节包成 `iAPSendMessage` 命令（MacPlay _sendIapMessage 同款）。
    /// 通道没连上返回 false，字节丢弃（链路层靠定时器重发 marker/SYNC）。
    @discardableResult
    package func sendIapMessage(_ data: Data) -> Bool {
        guard isConnected, let b = try? CarPlayPlist.iAPSendMessage(data) else { return false }
        sendCommand(b)
        return true
    }

    package func forceKeyFrame(displayUUID: String = CarPlayPlist.mainDisplayUUID) {
        if let b = try? CarPlayPlist.forceKeyFrame(displayUUID: displayUUID) { sendCommand(b) }
    }
}
