// 「這台 Mac（LM Studio）」供應商：ClioTalk 連到本機 LM Studio（127.0.0.1:1234），用使用者載入的模型回答，不需要金鑰。
// 行為照 AI System 6（apps/server/server/lmstudio.js、lib/lmstudio-models.js）移植：
//   列模型先試 /api/v1/models、不行退 /api/v0/models；沒在跑就 `lms server start`；沒載入模型就照評分挑一個載入；
//   對話走 OpenAI 相容 /v1/chat/completions（SSE）。純邏輯（解析、評分、串流、預算）在上半，I/O 在下半。
// 不記錄提示詞與訊息內容；錯誤只帶狀態碼與固定字串。

import Foundation

// MARK: - 模型資料（純邏輯）

struct LMModel: Equatable {
    var id: String            // 列表裡的 key
    var instanceId: String    // 聊天請求的 model 欄位：已載入的實例 id（沒有就用 key）
    var name: String
    var isChat: Bool          // llm／vlm；embeddings 不算
    var loaded: Bool
    var loadedContext: Int    // 已載入時的情境長度（未知＝0）
    var maxContext: Int       // 模型最大情境長度（未知＝0）
    var toolUse: Bool         // 模型自己回報「為工具呼叫訓練過」
    var vision: Bool
}

enum LMStudioModels {
    private static func int(_ v: Any?) -> Int {
        if let n = v as? Int { return max(0, n) }
        if let d = v as? Double, d.isFinite { return max(0, Int(d)) }
        if let s = v as? String, let n = Int(s) { return max(0, n) }
        return 0
    }
    private static func str(_ d: [String: Any], _ keys: [String]) -> String {
        for k in keys { if let s = d[k] as? String, !s.trimmingCharacters(in: .whitespaces).isEmpty { return s.trimmingCharacters(in: .whitespaces) } }
        return ""
    }
    private static func firstPositive(_ vs: [Any?]) -> Int { vs.map(int).first { $0 > 0 } ?? 0 }

    /// 手動維護的最大情境（SDK 有時回報不準）：lmstudio-models.js 的 knownModelMaxContext
    static func knownMaxContext(_ model: String) -> Int {
        let v = model
        if matches(v, #"(^|[/\s_-])qwen3\.5[-_\s]?4b($|[/\s_-])"#) { return 262_144 }
        if matches(v, #"gemma[-_/ ]?4"#), matches(v, #"26b"#), matches(v, #"a4b"#) { return 262_144 }
        if matches(v, #"gemma[-_/ ]?4"#), matches(v, #"e4b"#) { return 131_072 }
        return 0
    }

    fileprivate static func matches(_ s: String, _ pattern: String) -> Bool {
        s.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// /api/v1/models（{"models":[…]}，key／display_name／loaded_instances／capabilities{}）與
    /// /api/v0/models（{"data":[…]}，id／type／state／capabilities[]）兩種形狀都吃；也吃純陣列與純字串。
    static func parse(_ data: Data) -> [LMModel] {
        guard let root = try? JSONSerialization.jsonObject(with: data) else { return [] }
        var raw: [Any] = []
        if let o = root as? [String: Any] { raw = (o["data"] as? [Any]) ?? (o["models"] as? [Any]) ?? [] }
        else if let a = root as? [Any] { raw = a }
        var seen = Set<String>(), out: [LMModel] = []
        for item in raw {
            let d: [String: Any]
            if let s = item as? String { d = ["id": s] } else if let x = item as? [String: Any] { d = x } else { continue }
            let id = str(d, ["id", "model", "modelKey", "model_key", "key", "name", "path"])
            guard !id.isEmpty, !seen.contains(id) else { continue }
            seen.insert(id)
            let name = { () -> String in let n = str(d, ["displayName", "display_name", "name"]); return n.isEmpty ? id : n }()

            // 種類：type／kind／架構裡有 embed 就不是聊天模型
            let meta = d["metadata"] as? [String: Any] ?? [:]
            let kindText = [id, name, str(d, ["type"]), str(d, ["kind"]), str(d, ["architecture"]), str(meta, ["type"]), str(meta, ["kind"])].joined(separator: " ")
            let isChat = !matches(kindText, "embed")
            let type = str(d, ["type", "kind"]).lowercased()

            // 載入狀態：state 字串 → loaded_instances → loaded 布林
            let instances = d["loaded_instances"] as? [[String: Any]]
            var loaded = false
            let state = str(d, ["state", "status", "load_state"]).lowercased()
            if !state.isEmpty {
                loaded = matches(state, #"(^|[-_\s])loaded($|[-_\s])"#) && !matches(state, #"not[-_\s]?loaded|unloaded"#)
            } else if let inst = instances {
                loaded = !inst.isEmpty
            } else if let b = d["loaded"] as? Bool {
                loaded = b
            }
            let inst0 = instances?.first
            let instanceId = { () -> String in let s = inst0.map { str($0, ["id", "identifier"]) } ?? ""; return s.isEmpty ? id : s }()

            let cfg = d["config"] as? [String: Any] ?? [:], load = d["load_config"] as? [String: Any] ?? [:]
            let instCfg = inst0?["config"] as? [String: Any] ?? [:]
            let loadedCtx = loaded ? firstPositive([instCfg["context_length"], d["loaded_context_length"], load["context_length"], cfg["context_length"], d["context_length"]]) : 0
            let detectedMax = firstPositive([d["max_context_length"], d["maxContextLength"], d["max_context"], d["context_length_max"], d["trained_context_length"],
                                             d["context_length"], d["n_ctx"], cfg["max_context_length"], cfg["context_length"], load["max_context_length"], load["context_length"]])
            let maxCtx = detectedMax > 0 ? detectedMax : max(knownMaxContext(id), knownMaxContext(name))

            // 能力：v1 是物件（trained_for_tool_use／vision），v0 是字串陣列（"tool_use"），lms CLI 是頂層布林
            var tool = false, vision = false
            if let caps = d["capabilities"] as? [String: Any] {
                tool = (caps["trained_for_tool_use"] as? Bool) ?? (caps["tool_use"] as? Bool) ?? false
                vision = (caps["vision"] as? Bool) ?? (caps["image_input"] as? Bool) ?? false
            } else if let caps = d["capabilities"] as? [String] {
                let l = caps.map { $0.lowercased() }
                tool = l.contains("tool_use") || l.contains("tools")
                vision = l.contains("vision") || l.contains("image_input")
            } else {
                tool = d["trainedForToolUse"] as? Bool ?? false
                vision = d["vision"] as? Bool ?? false
            }
            if type == "vlm" { vision = true }

            out.append(LMModel(id: id, instanceId: instanceId, name: name, isChat: isChat, loaded: loaded,
                               loadedContext: loadedCtx, maxContext: maxCtx, toolUse: tool, vision: vision))
        }
        return out
    }

    /// 名字寬鬆比對：大小寫、前後空白、或一邊是另一邊加 "命名空間/"
    static func sameName(_ a: String, _ b: String) -> Bool {
        let l = a.trimmingCharacters(in: .whitespaces).lowercased(), r = b.trimmingCharacters(in: .whitespaces).lowercased()
        if l.isEmpty || r.isEmpty { return false }
        return l == r || l.hasSuffix("/" + r) || r.hasSuffix("/" + l)
    }

    /// 標籤裡的參數量（十億）：沒寫就當 99，排到最後
    static func billionParams(_ label: String) -> (active: Double, total: Double) {
        func first(_ pattern: String) -> Double? {
            guard let re = try? NSRegularExpression(pattern: pattern),
                  let m = re.firstMatch(in: label, range: NSRange(label.startIndex..., in: label)),
                  m.numberOfRanges > 1, let r = Range(m.range(at: 1), in: label) else { return nil }
            return Double(label[r])
        }
        let active = first(#"a(\d+(?:\.\d+)?)b\b"#), total = first(#"(?:^|[^a-z0-9])(\d+(?:\.\d+)?)b\b"#)
        return (active ?? total ?? 99, total ?? active ?? 99)
    }

    /// 自動載入的評分，越低越優先（autoLoadModelScore 原樣：已載入 −1000、Qwen −20、instruct／chat −8、
    /// 多模態／rerank +35、mlx／gguf／4bit −2、再依參數量加分）。
    /// 2.0 加的一條：模型自己回報會用工具的 −25——ClioTalk 要控制家裡，有工具的優先；不到會蓋過大小差距。
    static func score(_ m: LMModel) -> Double {
        let label = "\(m.id) \(m.name)".lowercased()
        let p = billionParams(label)
        var s = 0.0
        if m.loaded { s -= 1000 }
        if matches(label, "qwen") { s -= 20 }
        if matches(label, "instruct|chat") { s -= 8 }
        if matches(label, "vl|vision|image|audio|rerank") { s += 35 }
        if matches(label, "mlx|gguf|q4|int4|4bit") { s -= 2 }
        if m.toolUse { s -= 25 }
        s += p.active * 10
        s += p.total * 0.8
        return s
    }

    /// 從聊天模型裡挑一個：分數最低的（同分取列表裡先出現的）
    static func choose(_ models: [LMModel]) -> LMModel? {
        var best: LMModel?
        for m in models where m.isChat { if best == nil || score(m) < score(best!) { best = m } }
        return best
    }

    /// 自己載入模型時要的情境長度：ClioTalk 的前綴（說明＋工具）就要三、四千 token，預設的 4096 不夠；
    /// 取 16K 但不超過模型上限，下限 1024（照 AI System 6 的 minContextLength）
    static func loadContext(for m: LMModel) -> Int {
        guard m.maxContext > 0 else { return 8192 }
        return max(1024, min(m.maxContext, 16_384))
    }
}

/// 設定頁那一行的狀態
enum LMStatus: Equatable {
    case notInstalled
    case serverOff
    case noModels
    case idle                                    // 在跑，有聊天模型，但都還沒載入
    case ready(name: String, tools: Bool)

    static func resolve(installed: Bool, models: [LMModel]?) -> LMStatus {
        guard let models else { return installed ? .serverOff : .notInstalled }
        let chat = models.filter(\.isChat)
        if chat.isEmpty { return .noModels }
        if let m = chat.filter(\.loaded).min(by: { LMStudioModels.score($0) < LMStudioModels.score($1) }) { return .ready(name: m.name, tools: m.toolUse) }
        return .idle
    }
}

/// 一次對話用的模型：已經載入、可以送請求
struct LMReady: Equatable {
    var instanceId: String
    var name: String
    var context: Int
    var toolUse: Bool

    init(_ m: LMModel, fallbackContext: Int = 4096) {
        instanceId = m.instanceId; name = m.name; toolUse = m.toolUse
        // 載入時的長度沒回報：LM Studio 預設 4096，保守估
        context = m.loadedContext > 0 ? m.loadedContext : (m.maxContext > 0 ? min(m.maxContext, fallbackContext) : fallbackContext)
    }
}

// MARK: - 情境預算（純邏輯）

enum ClioLMBudget {
    /// 估 token：漢字約一字一 token，其他 4 個字元一個（寧可高估）
    static func tokens(_ s: String) -> Int {
        var cjk = 0, other = 0
        for u in s.unicodeScalars {
            switch u.value {
            case 0x2E80...0x9FFF, 0xAC00...0xD7AF, 0xF900...0xFAFF, 0xFF00...0xFFEF, 0x3000...0x303F: cjk += 1
            default: other += 1
            }
        }
        return cjk + (other + 3) / 4
    }
    static func tokens(_ m: ClioMessage) -> Int {
        m.blocks.reduce(4) { n, b in
            switch b {
            case .text(let t): return n + tokens(t)
            case let .toolUse(_, name, input): return n + tokens(name) + tokens(input) + 12
            case let .toolResult(_, content, _): return n + tokens(content) + 8
            case .thinking, .redactedThinking, .reasoning: return n   // 不送給 LM Studio
            }
        }
    }
    static func tokens(_ tools: [ClioToolSpec]) -> Int {
        tools.reduce(0) { $0 + tokens($1.name) + tokens($1.description) + tokens($1.schema) + 12 }
    }

    struct Plan: Equatable {
        var system: String
        var messages: [ClioMessage]
        var tools: [ClioToolSpec]
        var maxTokens: Int
        var droppedTools: Bool       // 原本有工具，這次不送
    }

    static let noToolsNote = """

    Important: the model running you in this session is a local model that cannot call tools. \
    So right now you cannot control the home, read or change the calendar, reminders or messages, set timers, make calls or play music, and you cannot search the web. \
    If the user asks for any of that, say so in one short sentence and never pretend you did it. Everything else (conversation, general knowledge, maths, conversions) you can still answer.
    """

    /// 模型沒有工具能力（或前綴太大塞不進去）→ 不送工具、說明加一段、歷史只留文字；
    /// 然後照真實情境長度修剪歷史（整輪整輪丟，最後一輪一定留），並算 max_tokens。
    static func plan(context: Int, toolUse: Bool, system: String, tools: [ClioToolSpec], messages: [ClioMessage]) -> Plan {
        let reserve = min(1024, max(256, context / 8))            // 留給回答
        let available = max(256, context - reserve - 64)
        var sys = system
        var sent = tools.filter { $0.serverType == nil }
        var dropped = false
        if !sent.isEmpty, !toolUse || tokens(sent) + tokens(sys) > available * 6 / 10 {
            sent = []; dropped = true
        }
        if dropped { sys += noToolsNote }
        var history = dropped ? textOnly(messages) : messages
        let fixed = tokens(sys) + tokens(sent)
        history = trim(history, budget: max(0, available - fixed))
        return Plan(system: sys, messages: history, tools: sent, maxTokens: reserve, droppedTools: dropped)
    }

    /// 只留文字；相鄰同角色的合成一則（嚴格的聊天範本不接受連續兩個 user）
    static func textOnly(_ ms: [ClioMessage]) -> [ClioMessage] {
        var out: [ClioMessage] = []
        for m in ms {
            let t = m.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty else { continue }
            if let last = out.last, last.role == m.role {
                out[out.count - 1].blocks = [.text(last.text + "\n" + t)]
            } else {
                out.append(ClioMessage(role: m.role, blocks: [.text(t)], at: m.at))
            }
        }
        return out
    }

    /// 從最舊的開始丟，一次丟一整輪（到下一句使用者的話為止，工具呼叫與結果不拆開），最後一輪永遠保留
    static func trim(_ messages: [ClioMessage], budget: Int) -> [ClioMessage] {
        var m = messages
        func total() -> Int { m.reduce(0) { $0 + tokens($1) } }
        while total() > budget {
            guard let next = m.indices.dropFirst().first(where: { m[$0].isUserUtterance }) else { break }
            m.removeSubrange(0..<next)
        }
        if let first = m.firstIndex(where: { $0.isUserUtterance }), first > 0 { m.removeSubrange(0..<first) }
        return m
    }
}

// MARK: - 串流解碼（OpenAI chat.completion.chunk）

/// 把 `<think>…</think>` 從正文裡濾掉（有些模型把思考寫在 content 裡）；標籤被切在兩個 chunk 之間也處理。
/// 限制：只認「有開頭」的 <think>；範本把開頭塞在提示詞裡、輸出只有 </think> 的模型，思考會漏進正文（LM Studio 通常已分到 reasoning_content）。
struct ClioThinkFilter {
    private var inside = false
    private var held = ""
    private static let open = "<think>", close = "</think>"

    mutating func feed(_ s: String) -> String {
        var buf = held + s
        held = ""
        var out = ""
        while !buf.isEmpty {
            let tag = inside ? Self.close : Self.open
            if let r = buf.range(of: tag) {
                if !inside { out += buf[buf.startIndex..<r.lowerBound] }
                buf = String(buf[r.upperBound...])
                inside.toggle()
                continue
            }
            // 結尾可能是標籤的前半：留到下一塊
            var keep = 0
            for n in stride(from: min(tag.count - 1, buf.count), to: 0, by: -1) where buf.hasSuffix(String(tag.prefix(n))) { keep = n; break }
            let emit = buf.dropLast(keep)
            if !inside { out += emit }
            held = String(buf.suffix(keep))
            break
        }
        // 單獨出現的 </think>（沒開頭）只去掉標籤
        if !inside, out.contains(Self.close) { out = out.replacingOccurrences(of: Self.close, with: "") }
        return out
    }
    /// 串流結束時：沒配成標籤的殘餘照原樣吐出（不在思考中才有意義）
    mutating func flush() -> String { defer { held = "" }; return inside ? "" : held }
}

/// LM Studio 的 SSE：choices[0].delta.{content, reasoning_content, tool_calls[{index?, id?, function{name, arguments}}]}、finish_reason；
/// 最後一個 chunk 可能帶 usage；以 data: [DONE] 結束。與 DeepSeek 的差別：工具呼叫可能沒有 index（改用 id 分辨）、
/// arguments 可能直接是物件、錯誤是字串、思考不存進紀錄（不送回）、被截斷的串流算錯誤。
struct LMStudioStreamParser: ClioStreamDecoder {
    private struct Call { var id = ""; var name = ""; var args = "" }
    private var calls: [Call] = []
    private var slotByIndex: [Int: Int] = [:]
    private var think = ClioThinkFilter()
    private var stopReason: String?
    private var usage: ClioUsage?
    private var sawDone = false
    private(set) var finished = false

    private static func int(_ v: Any?) -> Int { (v as? Int) ?? (v as? Double).map { Int($0) } ?? 0 }

    mutating func consume(event: String?, data: String) -> [ClioEvent] {
        if data.trimmingCharacters(in: .whitespaces) == "[DONE]" { sawDone = true; return finish() }
        guard !finished, let d = data.data(using: .utf8), let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { return [] }
        if let e = o["error"] {
            finished = true
            let msg = (e as? String) ?? (e as? [String: Any])?["message"] as? String ?? ""
            return [.error(.badRequest(msg))]
        }
        var out: [ClioEvent] = []
        if let choice = (o["choices"] as? [[String: Any]])?.first {
            let delta = choice["delta"] as? [String: Any] ?? [:]
            if let t = delta["content"] as? String, !t.isEmpty {
                let shown = think.feed(t)
                if !shown.isEmpty { out.append(.textDelta(shown)) }
            }
            for tc in delta["tool_calls"] as? [[String: Any]] ?? [] {
                let id = (tc["id"] as? String) ?? ""
                var slot: Int
                if let idx = tc["index"] as? Int {
                    if let s = slotByIndex[idx] { slot = s } else { calls.append(Call()); slot = calls.count - 1; slotByIndex[idx] = slot }
                } else if calls.isEmpty || (!id.isEmpty && !calls[calls.count - 1].id.isEmpty && id != calls[calls.count - 1].id) {
                    calls.append(Call()); slot = calls.count - 1
                } else {
                    slot = calls.count - 1
                }
                if !id.isEmpty { calls[slot].id = id }
                let f = tc["function"] as? [String: Any] ?? [:]
                if let n = f["name"] as? String, !n.isEmpty {
                    if calls[slot].name.isEmpty { calls[slot].name = n } else if n != calls[slot].name { calls[slot].name += n }
                }
                if let a = f["arguments"] as? String { calls[slot].args += a }
                else if let a = f["arguments"] as? [String: Any], let j = try? JSONSerialization.data(withJSONObject: a, options: [.sortedKeys]) {
                    calls[slot].args = String(decoding: j, as: UTF8.self)
                }
            }
            if let r = choice["finish_reason"] as? String { stopReason = r }
        }
        if let u = o["usage"] as? [String: Any] {
            usage = ClioUsage(input: Self.int(u["prompt_tokens"]), output: Self.int(u["completion_tokens"]), cacheRead: 0, cacheWrite: 0)
        }
        return out
    }

    /// [DONE]（或連線正常結束）：吐出殘餘文字、工具呼叫、用量、結束
    mutating func finish() -> [ClioEvent] {
        guard !finished else { return [] }
        finished = true
        var out: [ClioEvent] = []
        let rest = think.flush()
        if !rest.isEmpty { out.append(.textDelta(rest)) }
        for (i, c) in calls.enumerated() where !c.name.isEmpty {
            let args = c.args.trimmingCharacters(in: .whitespaces).isEmpty ? "{}" : c.args
            out.append(.toolCall(id: c.id.isEmpty ? "call_\(i)" : c.id, name: c.name, json: args))
        }
        if let usage { out.append(.usage(usage)) }
        out.append(.done(stopReason: stopReason))
        return out
    }

    /// 連線結束：有 [DONE] 或 finish_reason 才算正常；本機服務中途被關掉就是錯誤，不把半截回答當完整的存起來
    mutating func end() -> [ClioEvent] {
        if finished { return [] }
        return sawDone || stopReason != nil ? finish() : [.error(.network("stream ended early"))]
    }
}

// MARK: - 錯誤分類（純邏輯）

enum LMStudioErrors {
    /// 聊天被拒是因為沒有載入模型 → 載入後重試一次（lmStudioChatNeedsModelLoad）
    static func needsModelLoad(_ text: String) -> Bool {
        LMStudioModels.matches(text, #"no models? loaded|model .*not loaded|please load a model"#)
    }
    /// 提示太長（classifyLmStudioProxyError 的 context 那一條）
    static func isContextOverflow(_ text: String) -> Bool {
        LMStudioModels.matches(text, #"context length|tokens to keep|too many tokens|prompt.*too long|input.*too long|shorter input|larger context|context size"#)
    }
}

// MARK: - 連線與啟動（I/O）

enum LMStudio {
    static let base = URL(string: "http://127.0.0.1:1234")!

    static var appInstalled: Bool {
        let fm = FileManager.default
        return ["/Applications/LM Studio.app", NSHomeDirectory() + "/Applications/LM Studio.app"].contains { fm.fileExists(atPath: $0) }
    }

    /// lms 命令列：~/.lmstudio/bin/lms，再找 PATH 與常見位置
    static func lmsPath() -> String? {
        let fm = FileManager.default
        var dirs = [NSHomeDirectory() + "/.lmstudio/bin"]
        dirs += (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        dirs += ["/usr/local/bin", "/opt/homebrew/bin"]
        for d in dirs { let p = d + "/lms"; if fm.isExecutableFile(atPath: p) { return p } }
        return nil
    }
    static var installed: Bool { appInstalled || lmsPath() != nil }

    /// 列模型：先 v1 再 v0。連不上＝nil；連得上但沒有模型＝[]
    static func fetchModels(base: URL = LMStudio.base, timeout: TimeInterval = 3, session: URLSession = .shared) async -> [LMModel]? {
        var reachable = false
        for path in ["api/v1/models", "api/v0/models"] {
            var r = URLRequest(url: base.appendingPathComponent(path))
            r.timeoutInterval = timeout
            guard let (data, resp) = try? await session.data(for: r), let http = resp as? HTTPURLResponse else { continue }
            reachable = true
            guard http.statusCode == 200 else { continue }
            let models = LMStudioModels.parse(data)
            if !models.isEmpty { return models }
        }
        return reachable ? [] : nil
    }

    /// 設定頁用：只讀，不啟動、不載入
    static func status() async -> LMStatus {
        LMStatus.resolve(installed: installed, models: await fetchModels())
    }

    private final class Once: @unchecked Sendable {
        private let lock = NSLock(); private var done = false
        func run(_ f: () -> Void) { lock.lock(); defer { lock.unlock() }; if !done { done = true; f() } }
    }

    /// 跑 lms；逾時就結束它。回傳是否以 0 結束
    static func runLms(_ args: [String], timeout: TimeInterval) async -> Bool {
        guard let path = lmsPath() else { return false }
        return await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            let p = Process(), once = Once()
            p.executableURL = URL(fileURLWithPath: path)
            p.arguments = args
            p.standardInput = FileHandle.nullDevice; p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
            p.terminationHandler = { pr in once.run { cont.resume(returning: pr.terminationStatus == 0) } }
            do { try p.run() } catch { once.run { cont.resume(returning: false) }; return }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                if p.isRunning { p.terminate() }
                once.run { cont.resume(returning: false) }
            }
        }
    }

    /// 載入模型：REST /api/v1/models/load；端點不存在（舊版）才退回 `lms load`。載入可能很久（讀幾 GB），逾時放寬
    static func loadModel(_ id: String, contextLength: Int, base: URL = LMStudio.base, session: URLSession = .shared) async -> Bool {
        var r = URLRequest(url: base.appendingPathComponent("api/v1/models/load"))
        r.httpMethod = "POST"
        r.timeoutInterval = 600
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = ClioHTTP.json(["model": id, "echo_load_config": true, "context_length": contextLength])
        var missing = false
        do {
            let (_, resp) = try await session.data(for: r)
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if (200..<300).contains(status) { return true }
            missing = status == 404 || status == 405
            log("ClioTalk: LM Studio load HTTP \(status)")
        } catch {
            if error is CancellationError || (error as? URLError)?.code == .cancelled { return false }
            missing = true
        }
        guard missing else { return false }
        return await runLms(["load", id, "--yes", "--context-length", "\(contextLength)"], timeout: 600)
    }

    private static func waitForServer(base: URL, seconds: Int) async -> [LMModel]? {
        for _ in 0..<seconds {
            if let m = await fetchModels(base: base, timeout: 2) { return m }
            if Task.isCancelled { return nil }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        return nil
    }

    /// 確保能聊：沒在跑 → `lms server start` 再等；沒載入聊天模型 → 照評分挑一個載入。
    /// info 回報進度（「正在启动…」「正在载入模型…」），nil＝回到平常的狀態。
    static func ensureReady(base: URL = LMStudio.base, info: @Sendable (String?) -> Void) async throws -> LMReady {
        var models = await fetchModels(base: base)
        if models == nil {
            guard installed else { throw ClioError.lmNotInstalled }
            info(L("clio.lm.starting", "正在启动 LM Studio…"))
            _ = await runLms(["server", "start", "--port", "1234", "--bind", "127.0.0.1"], timeout: 60)
            models = await waitForServer(base: base, seconds: 30)
            try Task.checkCancellation()
            guard models != nil else { throw ClioError.lmOffline }
        }
        let chat = (models ?? []).filter(\.isChat)
        guard !chat.isEmpty else { throw ClioError.lmNoModel }
        if let m = chat.filter(\.loaded).min(by: { LMStudioModels.score($0) < LMStudioModels.score($1) }) {
            info(nil)
            return LMReady(m)
        }
        guard let pick = LMStudioModels.choose(chat) else { throw ClioError.lmNoModel }
        info(String(format: L("clio.lm.loading", "正在载入模型 %@…"), pick.name))
        let ctx = LMStudioModels.loadContext(for: pick)
        guard await loadModel(pick.id, contextLength: ctx, base: base) else {
            try Task.checkCancellation()
            throw ClioError.lmLoadFailed
        }
        try Task.checkCancellation()
        info(nil)
        // 載入後再讀一次，拿實際的實例 id 與情境長度；讀不到就用我們要求的
        if let after = await fetchModels(base: base), let m = after.first(where: { $0.isChat && $0.loaded && LMStudioModels.sameName($0.id, pick.id) }) {
            return LMReady(m, fallbackContext: ctx)
        }
        var m = pick
        m.loaded = true; m.loadedContext = ctx
        return LMReady(m, fallbackContext: ctx)
    }
}

// MARK: - 供應商

struct LMStudioProvider: ClioProvider {
    var base = LMStudio.base

    /// 中性紀錄 → OpenAI 格式。思考不送回（本機模型的範本不認 reasoning_content）；工具呼叫只有 assistant 沒文字時 content 給空字串（null 有的範本會壞）
    static func messages(_ ms: [ClioMessage]) -> [[String: Any]] {
        let stripped = ms.map { m -> ClioMessage in
            var c = m
            c.blocks.removeAll { if case .reasoning = $0 { return true }; if case .thinking = $0 { return true }; if case .redactedThinking = $0 { return true }; return false }
            return c
        }
        return DeepSeekProvider.messages(stripped).map { m in
            var o = m
            if o["content"] is NSNull { o["content"] = "" }
            return o
        }
    }

    static func body(model: String, plan: ClioLMBudget.Plan) -> [String: Any] {
        var b: [String: Any] = [
            "model": model,
            "stream": true,
            "stream_options": ["include_usage": true],
            "max_tokens": plan.maxTokens,
            "messages": [["role": "system", "content": plan.system]] + messages(plan.messages),
        ]
        if !plan.tools.isEmpty {
            b["tools"] = plan.tools.map { ["type": "function", "function": ["name": $0.name, "description": $0.description, "parameters": $0.schemaObject]] as [String: Any] }
        }
        return b
    }

    func stream(_ transcript: ClioTranscript, tools: [ClioToolSpec], model: String) -> AsyncThrowingStream<ClioEvent, Error> {
        AsyncThrowingStream { cont in
            let task = Task {
                do {
                    var attempt = 0
                    while true {
                        let ready = try await LMStudio.ensureReady(base: base) { cont.yield(.info(note: $0, model: nil)) }
                        cont.yield(.info(note: nil, model: ready.name))
                        let plan = ClioLMBudget.plan(context: ready.context, toolUse: ready.toolUse, system: transcript.system, tools: tools, messages: transcript.messages)
                        var req = URLRequest(url: base.appendingPathComponent("v1/chat/completions"))
                        req.httpMethod = "POST"
                        req.timeoutInterval = 300      // 本機模型第一個字可能要等很久（讀進記憶體、處理長提示）
                        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                        req.httpBody = ClioHTTP.json(Self.body(model: ready.instanceId, plan: plan))
                        var yielded = false
                        do {
                            for try await e in ClioHTTP.stream(req, decoder: LMStudioStreamParser()) { yielded = true; cont.yield(e) }
                            cont.finish()
                            return
                        } catch ClioError.badRequest(let msg) {
                            // 模型被卸載了：載入後重試一次；情境超過：說清楚
                            if !yielded, attempt == 0, LMStudioErrors.needsModelLoad(msg) { attempt += 1; continue }
                            throw LMStudioErrors.isContextOverflow(msg) ? ClioError.contextTooLong : ClioError.badRequest(msg)
                        }
                    }
                } catch let e as ClioError {
                    cont.finish(throwing: e)
                } catch is CancellationError {
                    cont.finish(throwing: ClioError.cancelled)
                } catch {
                    cont.finish(throwing: ClioError.network("\(type(of: error))"))
                }
            }
            cont.onTermination = { _ in task.cancel() }
        }
    }
}
