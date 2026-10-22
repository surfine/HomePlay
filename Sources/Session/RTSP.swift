// RTSP / HTTP 风格的控制通道分帧（对应 MacPlay native/Engine/protocol/rtspMessage.ts）。
// 请求行 + 头 + 可选二进制 plist 正文；增量解析，支持粘包、拆包、流水线。
import Foundation

package let plistContentType = "application/x-apple-binary-plist"

package struct RTSPMessage: Equatable {
    package var method: String
    package var path: String
    package var proto: String
    /// 头名一律小写
    package var headers: [String: String]
    package var body: Data

    package init(method: String, path: String, proto: String = "RTSP/1.0", headers: [String: String] = [:], body: Data = Data()) {
        self.method = method; self.path = path; self.proto = proto; self.headers = headers; self.body = body
    }

    /// 事件通道上手机对我们命令的应答也走同一套分帧：`RTSP/1.0 200 OK` 会被解成
    /// method="RTSP/1.0"、path="200"（MacPlay 同样处理）。
    package var isResponse: Bool { method.hasPrefix("RTSP/") || method.hasPrefix("HTTP/") }
    package var statusCode: Int? { isResponse ? Int(path) : nil }
    package var cseq: String? { headers["cseq"] }
}

package struct RTSPResponse {
    package var proto: String?
    package var status: Int
    package var statusText: String?
    /// 保序；CSeq 与 Content-Length 由序列化补上
    package var headers: [(String, String)]
    package var body: Data

    package init(status: Int = 200, statusText: String? = nil, proto: String? = nil,
                 headers: [(String, String)] = [], body: Data = Data()) {
        self.status = status; self.statusText = statusText; self.proto = proto
        self.headers = headers; self.body = body
    }

    package static func plist(_ body: Data) -> RTSPResponse {
        RTSPResponse(headers: [("Content-Type", plistContentType)], body: body)
    }
}

/// 流式缓冲：feed 进字节，吐出已完整的消息，余下的留着等下一块。
package struct RTSPParser {
    private var buffer = Data()
    package init() {}
    package var pendingBytes: Int { buffer.count }

    /// 头最多 16 KiB、正文最多 4 MiB；超过就清空并标记，调用方应断开（输入来自网络，不可信）
    package static let maxHeader = 16 * 1024
    package static let maxBody = 4 * 1024 * 1024
    package private(set) var overflowed = false

    package mutating func feed(_ data: Data) -> [RTSPMessage] {
        if overflowed { return [] }
        buffer.append(data)
        var out: [RTSPMessage] = []
        let sep = Data([13, 10, 13, 10])
        var offset = buffer.startIndex
        while offset < buffer.endIndex {
            guard let r = buffer.range(of: sep, in: offset..<buffer.endIndex) else {
                if buffer.endIndex - offset > Self.maxHeader { overflowed = true; buffer = Data(); return out }
                break
            }
            if r.lowerBound - offset > Self.maxHeader { overflowed = true; buffer = Data(); return out }
            let headText = String(decoding: buffer[offset..<r.lowerBound], as: UTF8.self)
            var lines = headText.components(separatedBy: "\r\n")
            let requestLine = lines.removeFirst()
            let parts = requestLine.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
            var headers: [String: String] = [:]
            for line in lines {
                guard let idx = line.firstIndex(of: ":") else { continue }
                let k = line[..<idx].trimmingCharacters(in: .whitespaces).lowercased()
                headers[k] = line[line.index(after: idx)...].trimmingCharacters(in: .whitespaces)
            }
            let bodyStart = r.upperBound
            let length = max(0, Int(headers["content-length"] ?? "0") ?? 0)
            if length > Self.maxBody { overflowed = true; buffer = Data(); return out }
            let bodyEnd = bodyStart + length
            if bodyEnd > buffer.endIndex { break }   // 正文还没收齐
            out.append(RTSPMessage(method: parts.first ?? "", path: parts.count > 1 ? parts[1] : "",
                                   proto: parts.count > 2 ? parts[2] : "RTSP/1.0",
                                   headers: headers, body: Data(buffer[bodyStart..<bodyEnd])))
            offset = bodyEnd
        }
        buffer = Data(buffer[offset...])
        return out
    }
}

private let statusTexts: [Int: String] = [200: "OK", 400: "Bad Request", 403: "Forbidden", 404: "Not Found", 500: "Internal Server Error"]

/// 序列化应答：回显请求的协议与 CSeq，补 Content-Length。
package func rtspSerialize(_ res: RTSPResponse, for req: RTSPMessage) -> Data {
    let proto = res.proto ?? req.proto
    let text = res.statusText ?? statusTexts[res.status] ?? "OK"
    var headers = res.headers.filter { $0.0 != "CSeq" && $0.0 != "Content-Length" }
    if let c = req.cseq { headers.append(("CSeq", c)) }
    headers.append(("Content-Length", String(res.body.count)))
    var head = "\(proto) \(res.status) \(text)\r\n"
    for (k, v) in headers { head += "\(k): \(v)\r\n" }
    head += "\r\n"
    var d = Data(head.utf8); d.append(res.body)
    return d
}

/// 我们在事件通道上主动发的 `POST /command`（MacPlay `_sendEventCommand`）。头序：Content-Type、Content-Length、CSeq。
package func rtspEventCommand(body: Data, cseq: Int, streamID: Int? = nil) -> Data {
    let sid = streamID.map { "X-Apple-StreamID: \($0)\r\n" } ?? ""
    let head = "POST /command RTSP/1.0\r\n\(sid)Content-Type: \(plistContentType)\r\nContent-Length: \(body.count)\r\nCSeq: \(cseq)\r\n\r\n"
    var d = Data(head.utf8); d.append(body)
    return d
}
