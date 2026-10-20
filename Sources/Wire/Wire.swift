// wire 编码与 WebSocket 服务器（和 WindowShade WS2CarPlayReceiverWire 对齐）。
import Foundation
import Network
import CoreMedia

// MARK: - wire 编码（和 WS2CarPlayReceiverWire 对齐，全部小端）

package enum Wire {
    // [1][streamType][codec=1][width u32][height u32][avcC...]，记录从偏移 11 起。
    /// codec: 1 = H.264（avcC）、2 = HEVC（自家參數集包：count u8 + 每個 len u16 + NAL）
    package static func videoConfig(width: Int, height: Int, avcC: Data, streamType: UInt8 = 0, codec: UInt8 = 1) -> Data {
        var d = Data([1, streamType, codec])
        d.append(u32(width)); d.append(u32(height)); d.append(avcC)
        return d
    }
    // [2][streamType][flags bit0=keyframe][pts u64][Annex B NAL 序列]
    package static func videoFrame(annexB: Data, keyframe: Bool, ptsMicros: UInt64, streamType: UInt8 = 0) -> Data {
        var d = Data([2, streamType, keyframe ? 1 : 0])
        d.append(u64(ptsMicros)); d.append(annexB)
        return d
    }
    package static func helloJSON(name: String, width: Int, height: Int) -> String {
        #"{"type":"hello","message":"\#(name)","sessionActive":true,"width":\#(width),"height":\#(height)}"#
    }
    package static func u32(_ v: Int) -> Data {
        let x = UInt32(truncatingIfNeeded: v)
        return Data([UInt8(x & 0xff), UInt8((x >> 8) & 0xff), UInt8((x >> 16) & 0xff), UInt8((x >> 24) & 0xff)])
    }
    package static func u64(_ v: UInt64) -> Data {
        var d = Data(); for i in 0..<8 { d.append(UInt8((v >> (8 * i)) & 0xff)) }; return d
    }
}

// AVCC（4 字节大端长度前缀）→ Annex B（00 00 00 01 起始码）。
package func avccToAnnexB(_ avcc: Data) -> Data {
    var out = Data(); var i = 0
    let bytes = [UInt8](avcc)
    while i + 4 <= bytes.count {
        let len = Int(bytes[i]) << 24 | Int(bytes[i+1]) << 16 | Int(bytes[i+2]) << 8 | Int(bytes[i+3])
        i += 4
        guard len > 0, i + len <= bytes.count else { break }
        out.append(contentsOf: [0, 0, 0, 1])
        out.append(contentsOf: bytes[i..<(i+len)])
        i += len
    }
    return out
}

// 从 CMFormatDescription 取出 avcC 原子。
package func avcCRecord(from fmt: CMFormatDescription) -> Data? {
    guard let atoms = CMFormatDescriptionGetExtension(
        fmt, extensionKey: kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms) as? [String: Any],
        let avcC = atoms["avcC"] as? Data else { return nil }
    return avcC
}

// MARK: - WebSocket 服务器（Network.framework，无第三方依赖）

package final class WSServer {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "ws.server")
    private var conns: [NWConnection] = []
    package var onConnect: ((NWConnection) -> Void)?
    package var onText: ((String) -> Void)?

    package init(port: UInt16) throws {
        let params = NWParameters.tcp
        let ws = NWProtocolWebSocket.Options()
        ws.autoReplyPing = true
        params.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)
        listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
    }

    package func start() {
        listener.newConnectionHandler = { [weak self] conn in
            guard let self else { return }
            self.conns.append(conn)
            conn.stateUpdateHandler = { state in
                if case .ready = state { self.onConnect?(conn); self.receive(conn) }
                if case .failed = state { self.drop(conn) }
                if case .cancelled = state { self.drop(conn) }
            }
            conn.start(queue: self.queue)
        }
        listener.start(queue: queue)
    }

    private func drop(_ conn: NWConnection) { conns.removeAll { $0 === conn } }

    private func receive(_ conn: NWConnection) {
        conn.receiveMessage { [weak self] data, ctx, _, error in
            guard let self else { return }
            if let data, !data.isEmpty,
               let md = ctx?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata,
               md.opcode == .text, let s = String(data: data, encoding: .utf8) {
                self.onText?(s)
            }
            if error == nil, conn.state == .ready { self.receive(conn) }
        }
    }

    package func sendText(_ s: String, to conn: NWConnection) {
        let md = NWProtocolWebSocket.Metadata(opcode: .text)
        let ctx = NWConnection.ContentContext(identifier: "text", metadata: [md])
        conn.send(content: s.data(using: .utf8), contentContext: ctx, isComplete: true, completion: .contentProcessed { _ in })
    }

    package func broadcastText(_ s: String) {
        let md = NWProtocolWebSocket.Metadata(opcode: .text)
        let ctx = NWConnection.ContentContext(identifier: "text", metadata: [md])
        for conn in conns where conn.state == .ready {
            conn.send(content: s.data(using: .utf8), contentContext: ctx, isComplete: true, completion: .contentProcessed { _ in })
        }
    }

    package func broadcastBinary(_ data: Data) {
        let md = NWProtocolWebSocket.Metadata(opcode: .binary)
        let ctx = NWConnection.ContentContext(identifier: "bin", metadata: [md])
        for conn in conns where conn.state == .ready {
            conn.send(content: data, contentContext: ctx, isComplete: true, completion: .contentProcessed { _ in })
        }
    }

    package func sendBinary(_ data: Data, to conn: NWConnection) {
        let md = NWProtocolWebSocket.Metadata(opcode: .binary)
        let ctx = NWConnection.ContentContext(identifier: "bin", metadata: [md])
        conn.send(content: data, contentContext: ctx, isComplete: true, completion: .contentProcessed { _ in })
    }

    package var hasClients: Bool { conns.contains { $0.state == .ready } }
}

