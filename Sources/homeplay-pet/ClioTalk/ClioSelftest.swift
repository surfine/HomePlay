// ClioTalk 的 --selftest：串流解析（手寫的官方格式樣本）、請求內文形狀、錯誤與重試、修剪、路由、確認閘門、花費上限。
// 全部離線：供應商與工具都是假的，不碰網路、不碰鑰匙圈。

import Foundation

/// 照劇本吐事件的假供應商；記下每次被叫時的模型、對話與工具
final class ClioScriptedProvider: ClioProvider, @unchecked Sendable {
    enum Step { case events([ClioEvent]), fail(ClioError) }
    var steps: [Step]
    private(set) var calls: [(model: String, transcript: ClioTranscript, tools: [ClioToolSpec])] = []
    init(_ steps: [Step]) { self.steps = steps }

    func stream(_ transcript: ClioTranscript, tools: [ClioToolSpec], model: String) -> AsyncThrowingStream<ClioEvent, Error> {
        calls.append((model, transcript, tools))
        let step = steps.isEmpty ? .events([.textDelta("?"), .done(stopReason: "end_turn")]) : steps.removeFirst()
        return AsyncThrowingStream { c in
            switch step {
            case .events(let es): for e in es { c.yield(e) }; c.finish()
            case .fail(let e): c.finish(throwing: e)
            }
        }
    }
}

final class ClioRecordingTools: ClioToolRunner, @unchecked Sendable {
    private(set) var ran: [String] = []
    func run(name: String, input: [String: Any]) async -> ClioToolResult {
        ran.append(name)
        return ClioToolResult(content: "ok:\(name)", source: ClioToolCatalog.group(of: name))
    }
}

enum ClioSelftest {
    /// 在背景跑 async 的東西，主執行緒等它（selftest 是同步的頂層程式）
    private static func wait(_ body: @escaping () async -> Void) {
        let sem = DispatchSemaphore(value: 0)
        Task.detached { await body(); sem.signal() }
        sem.wait()
    }

    static func run(_ check: (Bool, String) -> Void) {
        sse(check); anthropic(check); deepseek(check); bodies(check); errors(check); logic(check); engine(check)
        ClioVoiceSelftest.run(check)   // 語音迴圈（ClioVoiceSelftest.swift）
        ClioReply.selftest(check)        // 2.0 第五輪：念稿／畫面、引用、系統說明的段落（ClioPrompt.swift）
        ClioContext.selftest(check)      // 2.0 第五輪：每輪的裝置狀態（ClioPrompt.swift）
        ClioHandoff.selftest(check)      // 2.0 第五輪：交給 App 的物件卡（ClioHandoff.swift）
        ClioAnswerCommand.selftest(check)   // 2.0 第四輪：回答畫面的語音指令、一次性提示（ClioAnswerCommands.swift）
        ClioLMStudioSelftest.run(check)   // 2.0: 這台 Mac（LM Studio）（ClioLMStudioSelftest.swift）
        ClioHomeSelftest.run(check)    // 2.0: 家庭、搜尋、找訊息、打電話、辨曲（ClioHomeSelftest.swift）
        ClioTimers.selftest(check)     // 2.0 P10：多組計時器（ClioTimers.swift）
        ClioSpeechVoices.selftest(check)   // 2.0 P10：ClioTalk 的聲音與語速（ClioSpeechVoices.swift）
        speechLanguage(check)   // 2.0 depth：朗讀照內容選語言（以前非中文一律 en-US）
    }

    /// 2.0 depth：一句話的朗讀語言（純邏輯；漢字跟介面語言，測的時候固定介面）
    private static func speechLanguage(_ check: (Bool, String) -> Void) {
        let saved = L10n.language
        L10n.language = .zhHant
        check(ClioSpeaker.language(for: "今天天氣如何") == "zh-TW" && ClioSpeaker.language(for: "こんにちは、元気ですか") == "ja-JP",
              "ClioTalk 朗讀：漢字照介面語言（繁中→台灣），假名用日文聲音")   // l10n-ignore：selftest 訊息
        L10n.language = .zhHans
        check(ClioSpeaker.language(for: "今天天气如何") == "zh-CN", "ClioTalk 朗讀：簡中介面用普通話聲音")   // l10n-ignore：selftest 訊息
        L10n.language = saved
        check(ClioSpeaker.language(for: "안녕하세요") == "ko-KR" && ClioSpeaker.language(for: "Привет") == "ru-RU"
              && ClioSpeaker.language(for: "¿Hola, cómo estás?") == "es-ES" && ClioSpeaker.language(for: "Sounds good, see you at seven") == "en-US",
              "ClioTalk 朗讀：韓文、西里爾照文字系統；拉丁字母讓系統認語言（西文不再用英文聲音）")   // l10n-ignore：selftest 訊息
    }

    // MARK: 串流

    private static func feed<D: ClioStreamDecoder>(_ lines: [String], _ d: inout D) -> [ClioEvent] {
        var sse = SSELineParser(), out: [ClioEvent] = []
        for l in lines { if let (e, data) = sse.feed(l) { out += d.consume(event: e, data: data) } }
        return out + d.end()
    }

    private static func sse(_ check: (Bool, String) -> Void) {
        var p = SSELineParser()
        check(p.feed("event: ping") == nil, "SSE：event 行只記名字")
        let r = p.feed("data: {\"type\":\"ping\"}\r")
        check(r?.event == "ping" && r?.data == "{\"type\":\"ping\"}", "SSE：data 行帶上前一行的事件名、去掉 \\r")
        check(p.feed(": keep-alive") == nil && p.feed("") == nil, "SSE：註解與空行忽略")
        check(p.feed("data:[DONE]")?.data == "[DONE]" && p.feed("data: x")?.event == nil, "SSE：沒空格的 data、事件名只用一次")
    }

    private static func anthropic(_ check: (Bool, String) -> Void) {
        // 照 platform.claude.com/docs/en/build-with-claude/streaming 的格式手寫
        let lines = [
            "event: message_start",
            #"data: {"type":"message_start","message":{"id":"msg_1","type":"message","role":"assistant","content":[],"model":"claude-haiku-5-5","stop_reason":null,"usage":{"input_tokens":512,"cache_creation_input_tokens":0,"cache_read_input_tokens":3000,"output_tokens":1}}}"#,
            "",
            "event: content_block_start",
            #"data: {"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":"","signature":""}}"#,
            "event: content_block_delta",
            #"data: {"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"Let me check."}}"#,
            #"data: {"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"EqQBCg=="}}"#,
            #"data: {"type":"content_block_stop","index":0}"#,
            #"data: {"type":"content_block_start","index":1,"content_block":{"type":"text","text":""}}"#,
            "event: ping",
            #"data: {"type": "ping"}"#,
            #"data: {"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"Starting a "}}"#,
            #"data: {"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"timer."}}"#,
            #"data: {"type":"content_block_stop","index":1}"#,
            #"data: {"type":"content_block_start","index":2,"content_block":{"type":"tool_use","id":"toolu_01","name":"timer_set","input":{}}}"#,
            #"data: {"type":"content_block_delta","index":2,"delta":{"type":"input_json_delta","partial_json":""}}"#,
            #"data: {"type":"content_block_delta","index":2,"delta":{"type":"input_json_delta","partial_json":"{\"seco"}}"#,
            #"data: {"type":"content_block_delta","index":2,"delta":{"type":"input_json_delta","partial_json":"nds\": 300}"}}"#,
            #"data: {"type":"content_block_stop","index":2}"#,
            #"data: {"type":"some_future_event","foo":1}"#,
            "event: message_delta",
            #"data: {"type":"message_delta","delta":{"stop_reason":"tool_use","stop_sequence":null},"usage":{"output_tokens":89,"server_tool_use":{"web_search_requests":1}}}"#,
            "event: message_stop",
            #"data: {"type":"message_stop"}"#,
        ]
        var d = AnthropicStreamParser()
        let ev = feed(lines, &d)
        check(ev.first == .reasoning(.thinking(text: "Let me check.", signature: "EqQBCg==")), "Anthropic：thinking 區塊含簽章")
        check(ev.dropFirst().prefix(2).elementsEqual([.textDelta("Starting a "), .textDelta("timer.")]), "Anthropic：text_delta 逐段")
        check(ev.contains(.toolCall(id: "toolu_01", name: "timer_set", json: #"{"seconds": 300}"#)), "Anthropic：input_json_delta 拼成完整參數")
        check(ev.contains(.usage(ClioUsage(input: 512, output: 89, cacheRead: 3000, cacheWrite: 0, webSearches: 1))), "Anthropic：usage 累計（含快取讀取、網頁搜尋次數）")
        check(ev.last == .done(stopReason: "tool_use"), "Anthropic：message_stop → done(tool_use)")

        var e = AnthropicStreamParser()
        let err = feed([#"data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}"#,
                        "event: error", #"data: {"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#], &e)
        check(err == [.error(.overloaded)], "Anthropic：200 之後的 error 事件 → overloaded")
        var cut = AnthropicStreamParser()
        let cutEv = feed([#"data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hi"}}"#], &cut)
        check(cutEv.last.map { if case .error(.network) = $0 { return true }; return false } == true, "Anthropic：沒有 message_stop 就斷線＝錯誤")
    }

    private static func deepseek(_ check: (Bool, String) -> Void) {
        // 照 api-docs.deepseek.com 的 chat/completions 串流格式手寫（含 : keep-alive）
        let lines = [
            ": keep-alive",
            #"data: {"id":"c1","object":"chat.completion.chunk","choices":[{"index":0,"delta":{"role":"assistant","content":""},"finish_reason":null}]}"#,
            #"data: {"id":"c1","choices":[{"index":0,"delta":{"content":"Checking"},"finish_reason":null}]}"#,
            #"data: {"id":"c1","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"call_0","type":"function","function":{"name":"get_weather","arguments":""}}]},"finish_reason":null}]}"#,
            #"data: {"id":"c1","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{}"}}]},"finish_reason":null}]}"#,
            #"data: {"id":"c1","choices":[{"index":0,"delta":{"tool_calls":[{"index":1,"id":"call_1","type":"function","function":{"name":"timer_set","arguments":"{\"seconds\""}}]},"finish_reason":null}]}"#,
            #"data: {"id":"c1","choices":[{"index":0,"delta":{"tool_calls":[{"index":1,"function":{"arguments":":60}"}}]},"finish_reason":"tool_calls"}]}"#,
            #"data: {"id":"c1","choices":[],"usage":{"prompt_tokens":3500,"completion_tokens":42,"prompt_cache_hit_tokens":3000,"prompt_cache_miss_tokens":500,"total_tokens":3542}}"#,
            "data: [DONE]",
        ]
        var d = DeepSeekStreamParser()
        let ev = feed(lines, &d)
        check(ev.first == .textDelta("Checking"), "DeepSeek：content 逐段、空字串略過")
        check(ev.contains(.toolCall(id: "call_0", name: "get_weather", json: "{}")) && ev.contains(.toolCall(id: "call_1", name: "timer_set", json: #"{"seconds":60}"#)),
              "DeepSeek：tool_calls 依 index 拼起來")   // l10n-ignore：測試樣本
        check(ev.contains(.usage(ClioUsage(input: 500, output: 42, cacheRead: 3000, cacheWrite: 0))), "DeepSeek：usage 拆成命中／未中")
        check(ev.last == .done(stopReason: "tool_calls") && ev.filter { if case .done = $0 { return true }; return false }.count == 1, "DeepSeek：[DONE] 只結束一次")
        var r = DeepSeekStreamParser()
        let rev = feed([#"data: {"choices":[{"index":0,"delta":{"reasoning_content":"hmm"},"finish_reason":null}]}"#,
                        #"data: {"choices":[{"index":0,"delta":{"content":"Yes."},"finish_reason":"stop"}]}"#], &r)
        check(rev.contains(.reasoning(.reasoning("hmm"))) && rev.last == .done(stopReason: "stop"), "DeepSeek：reasoning_content 留著送回；沒 [DONE] 也正常結束")
    }

    private static func bodies(_ check: (Bool, String) -> Void) {
        let msgs = [ClioMessage.user("[t]\nhi"),
                    ClioMessage(role: .assistant, blocks: [.text("ok"), .toolUse(id: "t1", name: "timer_set", input: #"{"seconds":5}"#)]),
                    ClioMessage(role: .user, blocks: [.toolResult(id: "t1", content: "done", isError: false), .text("thanks")])]
        let t = ClioTranscript(system: "SYS", messages: msgs)
        let tools = ClioToolCatalog.specs([.weatherTime, .webSearch], provider: .anthropic, includeEscalate: true)
        let a = AnthropicProvider.body(t, tools: tools, model: "claude-haiku-5-5")
        let sys = (a["system"] as? [[String: Any]])?.first
        check((sys?["cache_control"] as? [String: String]) == ["type": "ephemeral", "ttl": "1h"], "Anthropic 內文：system 帶 1 小時快取")
        check((a["thinking"] as? [String: String])?["type"] == "disabled" && (a["output_config"] as? [String: String])?["effort"] == "low", "Anthropic 內文：Haiku 關思考、effort low")
        let at = a["tools"] as? [[String: Any]] ?? []
        check(at.contains { $0["type"] as? String == AnthropicProvider.webSearchType } && at.contains { $0["name"] as? String == "escalate" }, "Anthropic 內文：有網頁搜尋與 escalate")
        let am = a["messages"] as? [[String: Any]] ?? []
        let tr = ((am.last?["content"] as? [[String: Any]])?.first)
        check(am.count == 3 && tr?["type"] as? String == "tool_result" && tr?["tool_use_id"] as? String == "t1", "Anthropic 內文：tool_result 接在 user 訊息")
        let deep = AnthropicProvider.body(t, tools: [], model: "claude-opus-5-5")
        check(deep["thinking"] == nil && (deep["output_config"] as? [String: String])?["effort"] == "medium" && deep["tools"] == nil, "Anthropic 內文：Opus 不關思考、effort medium")

        let dsTools = ClioToolCatalog.specs([.weatherTime, .webSearch], provider: .deepseek, includeEscalate: false)
        check(!dsTools.contains { $0.serverType != nil } && !dsTools.contains { $0.name == "escalate" }, "DeepSeek：沒有網頁搜尋、沒要求就沒有 escalate")
        let d = DeepSeekProvider.body(t, tools: dsTools, model: "deepseek-flash")
        check((d["thinking"] as? [String: String])?["type"] == "disabled" && d["reasoning_effort"] == nil, "DeepSeek 內文：flash 關思考")
        let dm = d["messages"] as? [[String: Any]] ?? []
        check(dm.map { $0["role"] as? String ?? "" } == ["system", "user", "assistant", "tool", "user"], "DeepSeek 內文：role 順序 system/user/assistant/tool/user")
        check(((dm[2]["tool_calls"] as? [[String: Any]])?.first?["function"] as? [String: Any])?["arguments"] as? String == #"{"seconds":5}"#, "DeepSeek 內文：tool_calls 參數原樣")
        let pro = DeepSeekProvider.body(t, tools: [], model: "deepseek-v4-pro")
        check((pro["thinking"] as? [String: String])?["type"] == "enabled" && pro["reasoning_effort"] as? String == "high", "DeepSeek 內文：v4-pro 開思考 effort high")
        check(ClioToolCatalog.specs(Set(ClioToolGroup.allCases), provider: .onDevice, includeEscalate: true).isEmpty, "裝置端：不帶工具")
        check(!ClioToolCatalog.specs([.music], provider: .anthropic, includeEscalate: false).contains { $0.name == "calendar_events" }, "工具：關掉的組不送")
    }

    private static func errors(_ check: (Bool, String) -> Void) {
        check(ClioError.from(status: 429, body: nil, retryAfter: 2) == .rateLimited(retryAfter: 2), "錯誤：429 → rateLimited")
        check(ClioError.from(status: 529, body: nil, retryAfter: nil) == .overloaded && ClioError.from(status: 503, body: nil, retryAfter: nil) == .overloaded, "錯誤：529／503 → overloaded")
        check(ClioError.from(status: 401, body: nil, retryAfter: nil) == .invalidKey && ClioError.from(status: 402, body: nil, retryAfter: nil) == .billing, "錯誤：401／402")
        let spend = Data(#"{"type":"error","error":{"type":"rate_limit_error","message":"x","details":{"error_code":"enforced_spend_limit_reached"}}}"#.utf8)
        check(ClioError.from(status: 429, body: spend, retryAfter: nil) == .billing, "錯誤：月花費上限的 429 不重試")
        check(ClioRetry.delay(attempt: 0, retryAfter: 3) == 3 && ClioRetry.delay(attempt: 1, retryAfter: nil) == 2 && ClioRetry.delay(attempt: 2, retryAfter: 1) == nil, "重試：守 Retry-After、指數退避、最多 2 次")
        check(ClioRetry.shouldRetry(status: 529) && !ClioRetry.shouldRetry(status: 400), "重試：只有 429／503／529")
        check(!ClioError.missingKey.message.isEmpty && ClioError.spendCapReached(cap: 5).message.contains("5.00"), "錯誤：有給人看的訊息")
        check(ClioKeyChecker.interpret(.deepseek, status: 200, body: Data(#"{"is_available":true,"balance_infos":[{"currency":"USD","total_balance":"10.00"}]}"#.utf8)) == .ok(detail: "USD 10.00"), "金鑰檢查：DeepSeek 餘額")
        check(ClioKeyChecker.interpret(.anthropic, status: 401, body: Data()) == .invalid && ClioKeyChecker.interpret(.anthropic, status: 200, body: Data()) == .ok(detail: nil), "金鑰檢查：Anthropic 200／401")
        check(ClioKeyChecker.request(.anthropic, key: "k")?.url?.absoluteString == "https://api.anthropic.com/v1/models?limit=1"
              && ClioKeyChecker.request(.deepseek, key: "k")?.url?.path == "/user/balance", "金鑰檢查：打便宜的唯讀端點")   // l10n-ignore：測試樣本
    }

    private static func logic(_ check: (Bool, String) -> Void) {
        check(ClioRouter.wantsDeep("這題想深一點") && ClioRouter.wantsDeep("Please THINK HARDER") && !ClioRouter.wantsDeep("hello"), "路由：想深一點／think harder")
        check(ClioConfirm.classify("好") == .yes && ClioConfirm.classify(" OK! ") == .yes && ClioConfirm.classify("取消。") == .no, "確認：好／OK／取消")
        check(ClioConfirm.classify("好，改到中午") == .other && ClioConfirm.classify("") == .other, "確認：帶條件的不算單純的好")
        let haiku = ClioPrice.of("claude-haiku-5-5").cost(ClioUsage(input: 500, output: 300, cacheRead: 3000))
        check(abs(haiku - 0.00023) < 1e-9, "花費：Haiku 一輪約 US$0.0002（\(haiku)）")
        check(ClioPrice.of("unknown-model").output >= 50, "花費：不認得的模型照最貴的算")

        // 修剪：10 輪，每輪 user → assistant(tool_use) → user(tool_result) → assistant
        var ms: [ClioMessage] = []
        for i in 0..<10 {
            ms.append(.user(String(repeating: "q\(i) ", count: 100)))
            ms.append(ClioMessage(role: .assistant, blocks: [.toolUse(id: "t\(i)", name: "get_time", input: "{}")]))
            ms.append(ClioMessage(role: .user, blocks: [.toolResult(id: "t\(i)", content: String(repeating: "r", count: 200), isError: false)]))
            ms.append(ClioMessage(role: .assistant, blocks: [.text(String(repeating: "a", count: 200))]))
        }
        let trimmed = ClioTrim.trim(ms, budget: 600)
        check(ClioTrim.tokens(trimmed) <= 600 && trimmed.first?.isUserUtterance == true, "修剪：在預算內、開頭是使用者的話")
        check(trimmed.count % 4 == 0 && trimmed.last == ms.last, "修剪：整輪丟、工具呼叫與結果不拆開、最新一輪保留")
        check(ClioTrim.trim(Array(ms.suffix(4)), budget: 1).count == 4, "修剪：只剩一輪就不再丟")

        var sp = ClioSentenceSplitter()
        let a = sp.feed("今天晴。明天"), b = sp.feed("下雨！Price is 3.5 today. Done")   // l10n-ignore：測試樣本
        check(a == ["今天晴。"] && b == ["明天下雨！", "Price is 3.5 today."] && sp.flush() == "Done", "朗讀：串流文字逐句切（3.5 不切）")

        var f5 = ClioF5Router()
        check(!f5.route(down: true, carPlayLive: true, clioEnabled: true) && !f5.route(down: false, carPlayLive: false, clioEnabled: true), "F5：直播中給 iPhone，放開跟著同一邊")
        check(f5.route(down: true, carPlayLive: false, clioEnabled: true) && f5.route(down: false, carPlayLive: true, clioEnabled: true), "F5：沒直播給 ClioTalk，放開也歸 ClioTalk")
        check(!f5.route(down: true, carPlayLive: false, clioEnabled: false), "F5：設定關掉就照舊")

        let d = ClioDates.parse("2026-10-27T18:30")
        let c = d.map { Calendar.current.dateComponents([.month, .day, .hour, .minute], from: $0) }
        check(c?.month == 10 && c?.day == 27 && c?.hour == 18 && c?.minute == 30 && ClioDates.parse("2026-10-27") != nil && ClioDates.parse("soon") == nil, "日期：模型給的本地時間")
        let rb = ClioToolCatalog.readback(name: "reminders_add", input: ["title": "Buy gift", "due": "2026-10-29T18:00"]) ?? ""
        let rbTime = ClioDates.parse("2026-10-29T18:00").map(ClioDates.clock) ?? ""   // 時制照系統（「下午 6:00」「6:00 PM」「18:00」）
        check(rb.contains("Buy gift") && rbTime.contains(Face.uses12Hour ? "6:00" : "18:00") && rb.contains(rbTime), "確認：念給你聽的那句有內容和時間")
        check(ClioToolCatalog.readback(name: "timer_set", input: [:]) == nil, "確認：計時器不用確認")
        check(Face.splitDetail("Tue Oct 27: A's birthday") == ("Tue Oct 27", "A's birthday") && Face.splitDetail("plain line").0 == nil, "卡片：資料卡拆成標籤＋內容")
    }

    // MARK: 引擎（假供應商＋假工具＋暫存資料夾）

    private static func engine(_ check: (Bool, String) -> Void) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("clio-selftest-\(UUID().uuidString)")
        let suite = "clio.selftest.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { try? FileManager.default.removeItem(at: dir); defaults.removePersistentDomain(forName: suite) }
        let ledger = ClioLedger(defaults: defaults)
        let store = ClioHistoryStore(dir: dir)
        let cfg = ClioConfig(provider: .anthropic, fastModel: "claude-haiku-5-5", deepModel: "claude-opus-5-5", autoEscalate: true,
                             tools: Set(ClioToolGroup.allCases), monthlyCap: 1)
        func make(_ p: ClioScriptedProvider, _ tools: ClioToolRunner = ClioRecordingTools()) -> ClioEngine {
            ClioEngine(store: store, runner: tools, ledger: ledger, config: { cfg }, makeProvider: { _ in p }, onSnapshot: { _ in })
        }
        let usage = ClioEvent.usage(ClioUsage(input: 100, output: 50))

        // 1. 一般回答：存檔、記帳
        let p1 = ClioScriptedProvider([.events([.textDelta("Hi "), .textDelta("there."), usage, .done(stopReason: "end_turn")])])
        let e1 = make(p1)
        var snap = ClioSnapshot(), count = 0
        wait { await e1.send("hello"); snap = await e1.snapshot; count = await e1.messages.count }
        check(snap.phase == .idle && snap.answer == "Hi there." && count == 2, "引擎：一般回答")
        check(p1.calls.first?.model == "claude-haiku-5-5" && p1.calls.first?.transcript.messages.first?.text.hasPrefix("[Context]\ntime: ") == true, "引擎：先用快模型、每句前面帶時間（[Context]）")
        check(p1.calls.first?.tools.contains { $0.name == "escalate" } == true, "引擎：快模型拿得到 escalate")
        check(store.load().count == 2 && ledger.turns() == 1 && ledger.spent() > 0, "引擎：紀錄存檔、這個月多一輪")
        var reloaded = 0
        wait { reloaded = await make(p1).messages.count }
        check(reloaded == 2 && store.load().first?.text.contains("hello") == true, "引擎：重開後讀回紀錄")

        // 2. 快模型叫 escalate → 同一份紀錄交給深模型，escalate 那則不留
        store.clear()
        let p2 = ClioScriptedProvider([.events([.toolCall(id: "e1", name: "escalate", json: #"{"reason":"hard"}"#), usage, .done(stopReason: "tool_use")]),
                                       .events([.textDelta("Deep answer."), usage, .done(stopReason: "end_turn")])])
        let e2 = make(p2)
        var msgs: [ClioMessage] = []
        wait { await e2.send("plan my week"); snap = await e2.snapshot; msgs = await e2.messages }
        check(p2.calls.map(\.model) == ["claude-haiku-5-5", "claude-opus-5-5"], "路由：escalate 升級到深模型")
        check(snap.answer == "Deep answer." && snap.tier == .deep && !msgs.contains { !$0.toolUses.isEmpty }, "路由：升級後的回答、紀錄裡沒有 escalate")
        check(p2.calls.last?.tools.contains { $0.name == "escalate" } == false, "路由：深模型不再拿到 escalate")

        // 3. 使用者說想深一點：直接用深模型
        let p3 = ClioScriptedProvider([.events([.textDelta("ok"), .done(stopReason: "end_turn")])])
        wait { await make(p3).send("想深一點：這週怎麼排") }   // l10n-ignore：測試樣本
        check(p3.calls.first?.model == "claude-opus-5-5", "路由：「想深一點」直接用深模型")

        // 4. 確認閘門：加提醒先停下來，不執行；說「好」才執行，結果送回模型
        store.clear()
        let tools = ClioRecordingTools()
        let p4 = ClioScriptedProvider([
            .events([.toolCall(id: "w1", name: "get_weather", json: "{}"),
                     .toolCall(id: "r1", name: "reminders_add", json: #"{"title":"Buy gift","due":"2026-10-29T18:00"}"#), usage, .done(stopReason: "tool_use")]),
            .events([.textDelta("Added."), usage, .done(stopReason: "end_turn")]),
            .events([.toolCall(id: "r2", name: "reminders_add", json: #"{"title":"Call mom"}"#), .done(stopReason: "tool_use")]),
            .events([.textDelta("OK, not added."), .done(stopReason: "end_turn")]),
        ])
        let e4 = make(p4, tools)
        var pending: ClioEngine.Pending?
        wait { await e4.send("remind me to buy a gift"); snap = await e4.snapshot; pending = await e4.pending }
        check(snap.phase == .confirm && pending?.name == "reminders_add" && snap.confirm?.contains("Buy gift") == true, "確認：會改資料的工具先念出來等「好」")
        check(tools.ran == ["get_weather"], "確認：還沒說好就不執行（只跑了唯讀的天氣）")
        check(snap.handoff?.kind == .reminder && snap.handoff?.state == .pending && snap.handoff?.title == "Buy gift", "物件卡：等「好」時是提醒草稿")
        wait { await e4.send("好"); snap = await e4.snapshot; pending = await e4.pending }   // l10n-ignore：測試樣本
        check(tools.ran == ["get_weather", "reminders_add"] && pending == nil && snap.answer == "Added.", "確認：說「好」才執行")
        check(snap.handoff?.state == .done && snap.handoff?.kind == .reminder, "物件卡：說「好」做完後交給「提醒事項」")
        let context0 = p4.calls[0].transcript.messages.first?.text ?? ""
        check(context0.hasPrefix("[Context]\ntime: ") && context0.contains("response_mode: display") && context0.hasSuffix("remind me to buy a gift"), "引擎：每句話前面帶 [Context]")
        let sent = p4.calls[1].transcript.messages.last?.blocks ?? []
        check(sent.contains(.toolResult(id: "w1", content: "ok:get_weather", isError: false))
              && sent.contains(.toolResult(id: "r1", content: "The user confirmed. ok:reminders_add", isError: false)), "確認：兩個工具結果一起送回模型")   // l10n-ignore：測試樣本
        wait { await e4.send("also remind me to call mom"); await e4.confirm(false); snap = await e4.snapshot }
        check(tools.ran.count == 2 && snap.answer == "OK, not added.", "確認：取消就不執行")
        check(snap.handoff == nil, "物件卡：取消就不留卡")
        check(p4.calls[3].transcript.messages.last?.blocks.contains { if case let .toolResult(_, c, _) = $0 { return c.contains("cancelled") }; return false } == true, "確認：取消也告訴模型")

        // 5. 錯誤：這一輪不留在紀錄裡
        let p5 = ClioScriptedProvider([.fail(.overloaded)])
        let e5 = make(p5)
        var before = 0, after = 0
        wait { before = await e5.messages.count; await e5.send("hi"); after = await e5.messages.count; snap = await e5.snapshot }
        check(before == after && snap.phase == .error && snap.error == ClioError.overloaded.message, "引擎：失敗的那輪回滾、顯示錯誤")

        // 6. 每月上限：超過就不送
        ledger.add(usd: 5, turn: false)
        let p6 = ClioScriptedProvider([])
        let e6 = make(p6)
        wait { await e6.send("hello"); snap = await e6.snapshot }
        check(p6.calls.isEmpty && snap.error == ClioError.spendCapReached(cap: 1).message, "花費：超過每月上限就不送新請求")

        // 7. 清除紀錄
        wait { await e6.clear() }
        check(store.load().isEmpty && !FileManager.default.fileExists(atPath: dir.appendingPathComponent("history.json").path), "引擎：清除對話紀錄")
        store.keep(question: "q", answer: "a")
        check(store.kept().count == 1, "引擎：「留下」存進 kept.json")
    }
}
