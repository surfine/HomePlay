// SSE 與兩家的串流解析器（純狀態機，餵一行吐事件；--selftest 用手寫的樣本測）。
// 注意：URLSession.bytes.lines 會吞掉空行，所以不能靠「空行＝事件結束」：兩家的 data: 都是單行 JSON，
// 每收到一行 data: 就當一個完整事件處理；event: 只記下名字；「:」開頭是註解（DeepSeek 的 : keep-alive）。

import Foundation

struct SSELineParser {
    private var eventName: String?

    /// 一行 → (事件名, data)；不是 data 行回 nil
    mutating func feed(_ rawLine: String) -> (event: String?, data: String)? {
        let line = rawLine.hasSuffix("\r") ? String(rawLine.dropLast()) : rawLine
        if line.isEmpty { eventName = nil; return nil }
        if line.hasPrefix(":") { return nil }
        if line.hasPrefix("event:") {
            eventName = line.dropFirst(6).trimmingCharacters(in: .whitespaces)
            return nil
        }
        guard line.hasPrefix("data:") else { return nil }
        var d = line.dropFirst(5)
        if d.first == " " { d = d.dropFirst() }
        let out = (eventName, String(d))
        eventName = nil
        return out
    }
}

private func jsonObject(_ s: String) -> [String: Any]? {
    (try? JSONSerialization.jsonObject(with: Data(s.utf8))) as? [String: Any]
}
private func int(_ v: Any?) -> Int { (v as? NSNumber)?.intValue ?? 0 }

// MARK: - Anthropic Messages API

/// message_start → content_block_start/delta/stop … → message_delta → message_stop；中間穿插 ping；error 可在 200 之後出現。
/// 未知事件一律忽略（官方說會新增）。
struct AnthropicStreamParser {
    private struct Block { var type: String; var id = ""; var name = ""; var json = ""; var text = ""; var signature = ""; var data = "" }
    private var blocks: [Int: Block] = [:]
    private var usage = ClioUsage()
    private var stopReason: String?
    private(set) var finished = false

    mutating func consume(event: String?, data: String) -> [ClioEvent] {
        guard let o = jsonObject(data) else { return [] }
        let type = (o["type"] as? String) ?? event ?? ""
        switch type {
        case "message_start":
            if let u = (o["message"] as? [String: Any])?["usage"] as? [String: Any] { absorb(u) }
            return []
        case "content_block_start":
            let i = int(o["index"])
            let cb = o["content_block"] as? [String: Any] ?? [:]
            var b = Block(type: cb["type"] as? String ?? "")
            b.id = cb["id"] as? String ?? ""
            b.name = cb["name"] as? String ?? ""
            b.data = cb["data"] as? String ?? ""
            b.signature = cb["signature"] as? String ?? ""
            var out: [ClioEvent] = []
            if b.type == "text", let t = cb["text"] as? String, !t.isEmpty { out.append(.textDelta(t)) }
            blocks[i] = b
            return out
        case "content_block_delta":
            let i = int(o["index"])
            let d = o["delta"] as? [String: Any] ?? [:]
            switch d["type"] as? String {
            case "text_delta":
                let t = d["text"] as? String ?? ""
                return t.isEmpty ? [] : [.textDelta(t)]
            case "input_json_delta": blocks[i]?.json += d["partial_json"] as? String ?? ""
            case "thinking_delta": blocks[i]?.text += d["thinking"] as? String ?? ""
            case "signature_delta": blocks[i]?.signature += d["signature"] as? String ?? ""
            default: break
            }
            return []
        case "content_block_stop":
            let i = int(o["index"])
            guard let b = blocks.removeValue(forKey: i) else { return [] }
            switch b.type {
            case "tool_use":
                let json = b.json.trimmingCharacters(in: .whitespaces).isEmpty ? "{}" : b.json
                return [.toolCall(id: b.id, name: b.name, json: json)]
            case "thinking": return [.reasoning(.thinking(text: b.text, signature: b.signature))]
            case "redacted_thinking": return [.reasoning(.redactedThinking(data: b.data))]
            default: return []   // text、server_tool_use、web_search_tool_result：文字已經串出去了
            }
        case "message_delta":
            if let r = (o["delta"] as? [String: Any])?["stop_reason"] as? String { stopReason = r }
            if let u = o["usage"] as? [String: Any] { absorb(u) }
            return []
        case "message_stop":
            finished = true
            return [.usage(usage), .done(stopReason: stopReason)]
        case "error":
            let e = o["error"] as? [String: Any] ?? [:]
            finished = true
            return [.error(ClioError.fromStreamType(e["type"] as? String ?? "", message: e["message"] as? String ?? ""))]
        default:
            return []   // ping 與未來的新事件
        }
    }

    /// usage 是累計值：有給就覆蓋
    private mutating func absorb(_ u: [String: Any]) {
        if u["input_tokens"] != nil { usage.input = int(u["input_tokens"]) }
        if u["output_tokens"] != nil { usage.output = int(u["output_tokens"]) }
        if u["cache_read_input_tokens"] != nil { usage.cacheRead = int(u["cache_read_input_tokens"]) }
        if u["cache_creation_input_tokens"] != nil { usage.cacheWrite = int(u["cache_creation_input_tokens"]) }
        if let s = u["server_tool_use"] as? [String: Any] { usage.webSearches = int(s["web_search_requests"]) }
    }
}

// MARK: - DeepSeek（OpenAI 相容 chat/completions）

/// 每個 chunk：choices[0].delta.{content, reasoning_content, tool_calls[{index, id, function{name, arguments}}]}、finish_reason；
/// stream_options.include_usage 時最後一個 chunk 帶 usage；以 data: [DONE] 結束。
struct DeepSeekStreamParser {
    private struct Call { var id = ""; var name = ""; var args = "" }
    private var calls: [Int: Call] = [:]
    private var reasoning = ""
    private var stopReason: String?
    private var usage: ClioUsage?
    private(set) var finished = false

    mutating func consume(data: String) -> [ClioEvent] {
        if data.trimmingCharacters(in: .whitespaces) == "[DONE]" { return finish() }
        guard let o = jsonObject(data) else { return [] }
        var out: [ClioEvent] = []
        if let e = o["error"] as? [String: Any] {
            finished = true
            return [.error(.badRequest(e["message"] as? String ?? ""))]
        }
        if let choice = (o["choices"] as? [[String: Any]])?.first {
            let d = choice["delta"] as? [String: Any] ?? [:]
            if let r = d["reasoning_content"] as? String { reasoning += r }
            if let t = d["content"] as? String, !t.isEmpty { out.append(.textDelta(t)) }
            for tc in d["tool_calls"] as? [[String: Any]] ?? [] {
                let i = int(tc["index"])
                var c = calls[i] ?? Call()
                if let id = tc["id"] as? String, !id.isEmpty { c.id = id }
                let f = tc["function"] as? [String: Any] ?? [:]
                if let n = f["name"] as? String { c.name += n }
                if let a = f["arguments"] as? String { c.args += a }
                calls[i] = c
            }
            if let r = choice["finish_reason"] as? String { stopReason = r }
        }
        if let u = o["usage"] as? [String: Any] {
            // prompt_tokens＝命中＋未中；未中的才算全價
            let hit = int(u["prompt_cache_hit_tokens"])
            let miss = u["prompt_cache_miss_tokens"] != nil ? int(u["prompt_cache_miss_tokens"]) : max(0, int(u["prompt_tokens"]) - hit)
            usage = ClioUsage(input: miss, output: int(u["completion_tokens"]), cacheRead: hit, cacheWrite: 0)
        }
        return out
    }

    /// [DONE]（或連線正常結束）：吐出思考、工具呼叫、用量、結束
    mutating func finish() -> [ClioEvent] {
        guard !finished else { return [] }
        finished = true
        var out: [ClioEvent] = []
        if !reasoning.isEmpty { out.append(.reasoning(.reasoning(reasoning))) }
        for i in calls.keys.sorted() {
            let c = calls[i]!
            let args = c.args.trimmingCharacters(in: .whitespaces).isEmpty ? "{}" : c.args
            out.append(.toolCall(id: c.id.isEmpty ? "call_\(i)" : c.id, name: c.name, json: args))
        }
        if let usage { out.append(.usage(usage)) }
        out.append(.done(stopReason: stopReason))
        return out
    }
}
