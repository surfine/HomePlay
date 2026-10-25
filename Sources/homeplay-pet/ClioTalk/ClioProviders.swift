// 供應商層：Anthropic Messages API、DeepSeek（OpenAI 相容）、Apple 裝置端 Foundation Models。
// 不用第三方套件：URLSession.bytes + async/await。請求內文由純函式組出來（selftest 驗形狀）；串流解析在 ClioStreaming.swift。
// 金鑰只在組 URLRequest 的那一刻從參數拿到，不進日誌、不進錯誤訊息。

import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// 一次請求要送的東西：穩定前綴（system＋工具）在前、對話紀錄在後
struct ClioTranscript {
    var system: String
    var messages: [ClioMessage]
}

protocol ClioProvider {
    func stream(_ transcript: ClioTranscript, tools: [ClioToolSpec], model: String) -> AsyncThrowingStream<ClioEvent, Error>
}

/// 供應商專屬的串流解碼器（每個請求一份）
protocol ClioStreamDecoder {
    mutating func consume(event: String?, data: String) -> [ClioEvent]
    /// 連線正常結束時：補吐剩下的事件；串流被截斷就回 error
    mutating func end() -> [ClioEvent]
}

extension AnthropicStreamParser: ClioStreamDecoder {
    mutating func end() -> [ClioEvent] { finished ? [] : [.error(.network("stream ended early"))] }
}
extension DeepSeekStreamParser: ClioStreamDecoder {
    mutating func consume(event: String?, data: String) -> [ClioEvent] { consume(data: data) }
    mutating func end() -> [ClioEvent] { finish() }
}

enum ClioHTTP {
    /// 送出請求、處理重試（429／503／529，守 Retry-After，只在還沒收到任何內容前重試），把 SSE 解成事件
    static func stream<D: ClioStreamDecoder>(_ request: URLRequest, decoder: D, session: URLSession = .shared) -> AsyncThrowingStream<ClioEvent, Error> {
        AsyncThrowingStream { cont in
            let task = Task {
                var attempt = 0
                do {
                    while true {
                        let (bytes, resp) = try await session.bytes(for: request)
                        let http = resp as? HTTPURLResponse
                        let status = http?.statusCode ?? 0
                        guard status == 200 else {
                            var body = Data()
                            for try await b in bytes { body.append(b); if body.count > 65_536 { break } }
                            let ra = http?.value(forHTTPHeaderField: "retry-after").flatMap { Double($0.trimmingCharacters(in: .whitespaces)) }
                            if ClioRetry.shouldRetry(status: status), let d = ClioRetry.delay(attempt: attempt, retryAfter: ra) {
                                log("ClioTalk: HTTP \(status)，\(String(format: "%.1f", d)) 秒後重試（第 \(attempt + 1) 次）")
                                attempt += 1
                                try await Task.sleep(nanoseconds: UInt64(d * 1e9))
                                continue
                            }
                            log("ClioTalk: HTTP \(status)")
                            throw ClioError.from(status: status, body: body, retryAfter: ra)
                        }
                        var sse = SSELineParser()
                        var dec = decoder
                        for try await line in bytes.lines {
                            guard let (ev, data) = sse.feed(line) else { continue }
                            for e in dec.consume(event: ev, data: data) {
                                if case .error(let err) = e { throw err }
                                cont.yield(e)
                            }
                        }
                        for e in dec.end() {
                            if case .error(let err) = e { throw err }
                            cont.yield(e)
                        }
                        cont.finish()
                        return
                    }
                } catch let e as ClioError {
                    cont.finish(throwing: e)
                } catch is CancellationError {
                    cont.finish(throwing: ClioError.cancelled)
                } catch let e as URLError {
                    cont.finish(throwing: e.code == .cancelled ? ClioError.cancelled : ClioError.network("\(e.code.rawValue)"))
                } catch {
                    cont.finish(throwing: ClioError.network("\(type(of: error))"))
                }
            }
            cont.onTermination = { _ in task.cancel() }
        }
    }

    static func json(_ o: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys])) ?? Data()   // 排序鍵：同一份前綴每次位元組一樣，快取才命中
    }
    static func object(_ s: String) -> Any {
        (try? JSONSerialization.jsonObject(with: Data(s.utf8))) ?? [String: Any]()
    }
}

// MARK: - Anthropic

struct AnthropicProvider: ClioProvider {
    let key: String
    var base = URL(string: "https://api.anthropic.com")!
    static let version = "2023-06-01"
    static let webSearchType = "web_search_20260209"

    static func headers(key: String) -> [String: String] {
        ["x-api-key": key, "anthropic-version": version, "content-type": "application/json"]
    }

    /// 快模型 effort low（Haiku 再把思考關掉）；深模型 effort medium、思考照預設（adaptive）
    static func body(_ t: ClioTranscript, tools: [ClioToolSpec], model: String) -> [String: Any] {
        let fast = model.contains("haiku") || model.contains("sonnet")
        var b: [String: Any] = [
            "model": model,
            "max_tokens": fast ? 2048 : 8192,
            "stream": true,
            // 系統說明是穩定前綴：tools → system 的整段用 1 小時快取（cache_control 放在 system 最後一塊）
            "system": [["type": "text", "text": t.system, "cache_control": ["type": "ephemeral", "ttl": "1h"]]],
            "messages": messages(t.messages),
            "output_config": ["effort": fast ? "low" : "medium"],
        ]
        if model.contains("haiku") { b["thinking"] = ["type": "disabled"] }
        if !tools.isEmpty {
            b["tools"] = tools.map { s -> [String: Any] in
                if let type = s.serverType { return ["type": type, "name": s.name, "max_uses": 3] }
                return ["name": s.name, "description": s.description, "input_schema": s.schemaObject]
            }
        }
        return b
    }

    static func messages(_ ms: [ClioMessage]) -> [[String: Any]] {
        ms.compactMap { m in
            let content: [[String: Any]] = m.blocks.compactMap { b in
                switch b {
                case .text(let s): return s.isEmpty ? nil : ["type": "text", "text": s]
                case let .toolUse(id, name, input): return ["type": "tool_use", "id": id, "name": name, "input": ClioHTTP.object(input)]
                case let .toolResult(id, content, isError):
                    var r: [String: Any] = ["type": "tool_result", "tool_use_id": id, "content": content]
                    if isError { r["is_error"] = true }
                    return r
                case let .thinking(text, sig): return ["type": "thinking", "thinking": text, "signature": sig]
                case .redactedThinking(let d): return ["type": "redacted_thinking", "data": d]
                case .reasoning: return nil   // DeepSeek 的思考不送給 Anthropic
                }
            }
            return content.isEmpty ? nil : ["role": m.role.rawValue, "content": content]
        }
    }

    func stream(_ transcript: ClioTranscript, tools: [ClioToolSpec], model: String) -> AsyncThrowingStream<ClioEvent, Error> {
        var req = URLRequest(url: base.appendingPathComponent("v1/messages"))
        req.httpMethod = "POST"
        req.timeoutInterval = 60
        for (k, v) in Self.headers(key: key) { req.setValue(v, forHTTPHeaderField: k) }
        req.httpBody = ClioHTTP.json(Self.body(transcript, tools: tools, model: model))
        return ClioHTTP.stream(req, decoder: AnthropicStreamParser())
    }
}

// MARK: - DeepSeek

struct DeepSeekProvider: ClioProvider {
    let key: String
    var base = URL(string: "https://api.deepseek.com")!

    /// 快模型（deepseek-flash）明確關掉思考（預設是開的，語音會等很久）；深模型開思考、effort high。
    /// 伺服端工具（網頁搜尋）DeepSeek 沒有：直接略過。
    static func body(_ t: ClioTranscript, tools: [ClioToolSpec], model: String) -> [String: Any] {
        let fast = model == "deepseek-flash"
        var b: [String: Any] = [
            "model": model,
            "stream": true,
            "stream_options": ["include_usage": true],
            "max_tokens": fast ? 2048 : 8192,
            "thinking": ["type": fast ? "disabled" : "enabled"],
            "messages": [["role": "system", "content": t.system]] + messages(t.messages),
        ]
        if !fast { b["reasoning_effort"] = "high" }
        let fns = tools.filter { $0.serverType == nil }
        if !fns.isEmpty {
            b["tools"] = fns.map { ["type": "function", "function": ["name": $0.name, "description": $0.description, "parameters": $0.schemaObject]] }
        }
        return b
    }

    /// 中性格式 → OpenAI 格式：工具結果拆成一則一則 role:tool（要緊跟在 assistant 的 tool_calls 後面），
    /// assistant 的思考放 reasoning_content（帶工具的思考模式每輪都要送回，否則 400）
    static func messages(_ ms: [ClioMessage]) -> [[String: Any]] {
        var out: [[String: Any]] = []
        for m in ms {
            switch m.role {
            case .user:
                for b in m.blocks { if case let .toolResult(id, content, _) = b { out.append(["role": "tool", "tool_call_id": id, "content": content]) } }
                let text = m.text
                if !text.isEmpty { out.append(["role": "user", "content": text]) }
            case .assistant:
                var a: [String: Any] = ["role": "assistant"]
                let calls = m.toolUses.map { ["id": $0.id, "type": "function", "function": ["name": $0.name, "arguments": $0.input]] as [String: Any] }
                let text = m.text
                a["content"] = text.isEmpty && !calls.isEmpty ? NSNull() : text
                if !calls.isEmpty { a["tool_calls"] = calls }
                let r = m.blocks.compactMap { if case .reasoning(let s) = $0 { return s }; return nil }.joined()
                if !r.isEmpty { a["reasoning_content"] = r }
                out.append(a)
            }
        }
        return out
    }

    func stream(_ transcript: ClioTranscript, tools: [ClioToolSpec], model: String) -> AsyncThrowingStream<ClioEvent, Error> {
        var req = URLRequest(url: base.appendingPathComponent("chat/completions"))
        req.httpMethod = "POST"
        req.timeoutInterval = 60
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = ClioHTTP.json(Self.body(transcript, tools: tools, model: model))
        return ClioHTTP.stream(req, decoder: DeepSeekStreamParser())
    }
}

// MARK: - 只用這台 Mac（Apple Foundation Models）

enum ClioOnDevice {
    /// 執行階段才知道：系統要 macOS 26 以上、機器支援、Apple Intelligence 開著、模型下載好了
    static var available: Bool {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) { return SystemLanguageModel.default.availability == .available }
        #endif
        return false
    }
    /// 不能用的原因（設定頁那一行）
    static var status: String {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available: return L("clio.onDevice.ready", "可以用 · 完全在这台 Mac 上运行")
            case .unavailable(.deviceNotEligible): return L("clio.onDevice.notEligible", "这台 Mac 不支持 Apple Intelligence")
            case .unavailable(.appleIntelligenceNotEnabled): return L("clio.onDevice.notEnabled", "先在系统设置里打开 Apple Intelligence")
            case .unavailable(.modelNotReady): return L("clio.onDevice.notReady", "模型还在下载，稍后再试")
            default: return L("clio.onDevice.unavailable", "现在不能用")
            }
        }
        #endif
        return L("clio.onDevice.needsOS", "需要 macOS 26 以上")
    }
}

/// 裝置端模型：情境只有幾千 token，不帶工具，只送最近幾輪的文字
struct AppleOnDeviceProvider: ClioProvider {
    /// 最近幾輪壓成一段提示（裝置端情境小，system 也要短）
    static func prompt(_ ms: [ClioMessage], maxChars: Int = 6000) -> String {
        var lines: [String] = []
        for m in ms {
            let t = m.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty else { continue }
            lines.append((m.role == .user ? "User: " : "Assistant: ") + t)
        }
        var out = lines.joined(separator: "\n")
        if out.count > maxChars { out = String(out.suffix(maxChars)) }
        return out + "\nAssistant:"
    }

    func stream(_ transcript: ClioTranscript, tools: [ClioToolSpec], model: String) -> AsyncThrowingStream<ClioEvent, Error> {
        AsyncThrowingStream { cont in
            #if canImport(FoundationModels)
            if #available(macOS 26.0, *), ClioOnDevice.available {
                let task = Task {
                    do {
                        let session = LanguageModelSession(instructions: ClioPersona.onDeviceInstructions)
                        var sent = ""
                        for try await snap in session.streamResponse(to: Self.prompt(transcript.messages)) {
                            let full = snap.content
                            if full.hasPrefix(sent) {
                                let d = String(full.dropFirst(sent.count))
                                if !d.isEmpty { cont.yield(.textDelta(d)) }
                            }
                            sent = full
                        }
                        cont.yield(.usage(ClioUsage()))
                        cont.yield(.done(stopReason: "end_turn"))
                        cont.finish()
                    } catch is CancellationError {
                        cont.finish(throwing: ClioError.cancelled)
                    } catch {
                        let s = "\(error)"
                        cont.finish(throwing: s.contains("exceededContextWindowSize") || s.contains("contextSize") ? ClioError.contextTooLong : ClioError.onDeviceUnavailable)
                    }
                }
                cont.onTermination = { _ in task.cancel() }
                return
            }
            #endif
            cont.finish(throwing: ClioError.onDeviceUnavailable)
        }
    }
}
