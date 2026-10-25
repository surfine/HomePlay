// 「這台 Mac（LM Studio）」的 --selftest：模型清單解析（v1、v0 兩種形狀的樣本）、評分與挑選、狀態、
// SSE 串流（文字、<think>、工具呼叫分塊、錯誤、截斷）、請求內文、情境預算與修剪。全部離線，不碰網路、不啟動 LM Studio。

import Foundation

enum ClioLMStudioSelftest {
    // 照 LM Studio 0.4 的 /api/v1/models 回應手寫（欄位名照官方文件）
    static let v1 = #"""
    {"models":[
      {"type":"llm","publisher":"mlx-community","key":"qwen3.5-4b-mlx","display_name":"Qwen3.5 4B","architecture":"qwen3_5","format":"safetensors","size_bytes":3061129077,
       "params_string":"4B","max_context_length":262144,
       "loaded_instances":[{"id":"qwen3.5-4b-mlx","config":{"context_length":16384,"eval_batch_size":512}}],
       "capabilities":{"vision":true,"trained_for_tool_use":true}},
      {"type":"embedding","publisher":"nomic-ai","key":"text-embedding-nomic-embed-text-v1.5","display_name":"Nomic Embed Text v1.5","architecture":"nomic-bert",
       "max_context_length":2048,"loaded_instances":[]},
      {"type":"llm","publisher":"unsloth","key":"gemma-4-e4b-it","display_name":"Gemma 4 E4B","max_context_length":131072,"loaded_instances":[],
       "capabilities":{"vision":false,"trained_for_tool_use":false}}
    ]}
    """#
    // /api/v0/models：data 陣列、state 字串、capabilities 是字串陣列、vlm
    static let v0 = #"""
    {"object":"list","data":[
      {"id":"qwen2-vl-7b-instruct","object":"model","type":"vlm","publisher":"mlx-community","arch":"qwen2_vl","quantization":"4bit","state":"not-loaded","max_context_length":32768,"capabilities":["tool_use"]},
      {"id":"meta-llama-3.1-8b-instruct","object":"model","type":"llm","state":"loaded","max_context_length":131072,"loaded_context_length":8192,"capabilities":["tool_use"]},
      {"id":"text-embedding-nomic-embed-text-v1.5","object":"model","type":"embeddings","state":"loaded","max_context_length":2048},
      {"id":"phi-3-mini","object":"model","type":"llm","state":"not-loaded","max_context_length":4096}
    ]}
    """#

    private static func chunk(_ delta: String, finish: String? = nil, extra: String = "") -> String {
        #"{"choices":[{"index":0,"delta":\#(delta),"finish_reason":\#(finish.map { "\"\($0)\"" } ?? "null")}]\#(extra)}"#
    }
    private static func feed(_ lines: [String]) -> [ClioEvent] {
        var p = LMStudioStreamParser(), out: [ClioEvent] = []
        for l in lines { out += p.consume(event: nil, data: l) }
        return out + p.end()
    }

    static func run(_ check: (Bool, String) -> Void) {
        parsing(check); scoring(check); streaming(check); budget(check); requests(check)
    }

    private static func parsing(_ check: (Bool, String) -> Void) {
        let a = LMStudioModels.parse(Data(v1.utf8))
        check(a.map(\.id) == ["qwen3.5-4b-mlx", "text-embedding-nomic-embed-text-v1.5", "gemma-4-e4b-it"], "LM Studio v1：三個模型、依序")
        check(a[0].isChat && a[0].loaded && a[0].loadedContext == 16384 && a[0].maxContext == 262_144 && a[0].toolUse && a[0].vision && a[0].name == "Qwen3.5 4B",
              "LM Studio v1：已載入、情境 16384／最大 262144、會用工具、看得懂圖")   // l10n-ignore
        check(!a[1].isChat && !a[1].loaded, "LM Studio v1：embedding 不算聊天模型")
        check(a[2].isChat && !a[2].loaded && !a[2].toolUse && a[2].maxContext == 131_072, "LM Studio v1：沒載入、不會用工具")

        let b = LMStudioModels.parse(Data(v0.utf8))
        check(b.count == 4 && b[0].vision && b[0].toolUse && !b[0].loaded, "LM Studio v0：vlm＝看得懂圖、capabilities 陣列有 tool_use、not-loaded 不算載入")
        check(b[1].loaded && b[1].loadedContext == 8192 && b[1].toolUse && b[1].maxContext == 131_072, "LM Studio v0：state loaded、loaded_context_length")
        check(!b[2].isChat && b[2].loaded, "LM Studio v0：type embeddings 不算聊天模型")
        check(!b[3].toolUse && !b[3].vision, "LM Studio v0：沒寫能力＝當作不會用工具")

        check(LMStudioModels.parse(Data("[\"a\",\"b\"]".utf8)).map(\.id) == ["a", "b"], "LM Studio：純字串陣列")
        check(LMStudioModels.parse(Data("not json".utf8)).isEmpty && LMStudioModels.parse(Data("{}".utf8)).isEmpty && LMStudioModels.parse(Data(#"{"data":[{"id":""},3]}"#.utf8)).isEmpty, "LM Studio：壞資料回空陣列")
        check(LMStudioModels.parse(Data(#"{"data":[{"id":"x"},{"id":"x"}]}"#.utf8)).count == 1, "LM Studio：同 id 去重")
        let k = LMStudioModels.parse(Data(#"{"data":[{"id":"mlx-community/Qwen3.5-4B-MLX-4bit"}]}"#.utf8))
        check(k.first?.maxContext == 262_144, "LM Studio：沒回報最大情境時用已知模型表")
        let inst = LMStudioModels.parse(Data(#"{"models":[{"key":"m","loaded_instances":[{"id":"m:2","config":{"context_length":4096}}]}]}"#.utf8))
        check(inst.first?.instanceId == "m:2" && inst.first?.loadedContext == 4096, "LM Studio v1：聊天用已載入實例的 id")

        check(LMStudioModels.sameName("Qwen/Qwen3-4B", "qwen3-4b") && LMStudioModels.sameName(" A ", "a") && !LMStudioModels.sameName("a", "b") && !LMStudioModels.sameName("", ""),
              "LM Studio：模型名寬鬆比對")   // l10n-ignore

        // 狀態列
        check(LMStatus.resolve(installed: false, models: nil) == .notInstalled && LMStatus.resolve(installed: true, models: nil) == .serverOff, "LM Studio 狀態：沒裝／沒開")
        check(LMStatus.resolve(installed: true, models: []) == .noModels && LMStatus.resolve(installed: true, models: [a[1]]) == .noModels, "LM Studio 狀態：在跑但沒有聊天模型")
        check(LMStatus.resolve(installed: true, models: [a[2]]) == .idle, "LM Studio 狀態：有模型但沒載入")
        check(LMStatus.resolve(installed: true, models: a) == .ready(name: "Qwen3.5 4B", tools: true), "LM Studio 狀態：已載入（顯示名字與能不能控制家裡）")
        check(LMStudioModels.loadContext(for: a[0]) == 16_384 && LMStudioModels.loadContext(for: LMModel(id: "s", instanceId: "s", name: "s", isChat: true, loaded: false, loadedContext: 0, maxContext: 4096, toolUse: false, vision: false)) == 4096
              && LMStudioModels.loadContext(for: LMModel(id: "u", instanceId: "u", name: "u", isChat: true, loaded: false, loadedContext: 0, maxContext: 0, toolUse: false, vision: false)) == 8192,
              "LM Studio：自己載入時的情境長度（16K 封頂、不超過模型上限、未知用 8192）")   // l10n-ignore
        check(LMReady(a[0]).context == 16384 && LMReady(b[3], fallbackContext: 8192).context == 4096 && LMReady(LMModel(id: "q", instanceId: "q", name: "q", isChat: true, loaded: true, loadedContext: 0, maxContext: 0, toolUse: false, vision: false)).context == 4096,
              "LM Studio：載入長度沒回報時保守估 4096")   // l10n-ignore
    }

    private static func scoring(_ check: (Bool, String) -> Void) {
        func m(_ id: String, loaded: Bool = false, tool: Bool = false, chat: Bool = true) -> LMModel {
            LMModel(id: id, instanceId: id, name: id, isChat: chat, loaded: loaded, loadedContext: 0, maxContext: 0, toolUse: tool, vision: false)
        }
        let p = LMStudioModels.billionParams("qwen3-30b-a3b-instruct")
        check(p.active == 3 && p.total == 30, "評分：A3B／30B 的參數量")
        check(LMStudioModels.billionParams("some-model").total == 99 && LMStudioModels.billionParams("llama-3.1-8b-instruct").active == 8, "評分：沒寫參數量當 99")
        check(LMStudioModels.score(m("anything-70b", loaded: true)) < LMStudioModels.score(m("qwen-4b")), "評分：已載入的永遠優先")
        check(LMStudioModels.score(m("qwen3-8b")) < LMStudioModels.score(m("llama-3-8b")), "評分：Qwen 優先")
        check(LMStudioModels.score(m("llama-3-8b-instruct")) < LMStudioModels.score(m("llama-3-8b")), "評分：instruct 優先")
        check(LMStudioModels.score(m("llama-3-8b-vision")) > LMStudioModels.score(m("llama-3-8b")), "評分：多模態排後面")
        check(LMStudioModels.score(m("llama-3-4b")) < LMStudioModels.score(m("llama-3-14b")), "評分：小的優先")
        check(LMStudioModels.score(m("x-8b", tool: true)) < LMStudioModels.score(m("x-8b")), "評分：會用工具的優先（2.0 加的）")
        // 常見組合：4B Qwen（會用工具）贏過 7B Qwen2-VL 與 8B Llama
        let a = LMStudioModels.parse(Data(v1.utf8)), b = LMStudioModels.parse(Data(v0.utf8))
        check(LMStudioModels.choose(a.map { var x = $0; x.loaded = false; return x })?.id == "qwen3.5-4b-mlx", "挑模型：沒有載入的就照評分挑（會用工具的 Qwen 4B）")
        check(LMStudioModels.choose(b)?.id == "meta-llama-3.1-8b-instruct", "挑模型：有載入的就用載入的")
        check(LMStudioModels.choose([m("text-embedding-x", chat: false)]) == nil && LMStudioModels.choose([]) == nil, "挑模型：只有 embedding 或沒有＝nil")
    }

    private static func streaming(_ check: (Bool, String) -> Void) {
        // 純文字＋usage＋[DONE]
        let t = feed([chunk(#"{"role":"assistant","content":""}"#), chunk(#"{"content":"你"}"#), chunk(#"{"content":"好"}"#), chunk("{}", finish: "stop"),
                      #"{"choices":[],"usage":{"prompt_tokens":120,"completion_tokens":7,"total_tokens":127}}"#, "[DONE]"])
        check(t == [.textDelta("你"), .textDelta("好"), .usage(ClioUsage(input: 120, output: 7)), .done(stopReason: "stop")], "LM Studio 串流：文字、用量、結束")

        // <think> 濾掉，標籤被切開也行；reasoning_content 不外漏
        let th = feed([chunk(#"{"content":"<thi"}"#), chunk(#"{"content":"nk>先想一下"}"#), chunk(#"{"content":"</th"}"#), chunk(#"{"content":"ink>答案是"}"#), chunk(#"{"content":"42"}"#),
                       chunk(#"{"reasoning_content":"內部思考"}"#), chunk("{}", finish: "stop"), "[DONE]"])
        let text = th.compactMap { if case .textDelta(let s) = $0 { return s }; return nil }.joined()
        check(text == "答案是42" && !th.contains { if case .reasoning = $0 { return true }; return false }, "LM Studio 串流：<think> 與 reasoning_content 不進正文")
        var f = ClioThinkFilter()
        check(f.feed("a < b and 1<2") + f.flush() == "a < b and 1<2", "LM Studio 串流：一般的 < 不被吃掉")

        // 工具呼叫：參數分好幾塊、兩個呼叫靠 index 分開
        let tc = feed([
            chunk(#"{"tool_calls":[{"index":0,"id":"call_a","type":"function","function":{"name":"get_weather","arguments":""}}]}"#),
            chunk(#"{"tool_calls":[{"index":0,"function":{"arguments":"{\"city\":"}}]}"#),
            chunk(#"{"tool_calls":[{"index":0,"function":{"arguments":"\"Taipei\"}"}}]}"#),
            chunk(#"{"tool_calls":[{"index":1,"id":"call_b","type":"function","function":{"name":"set_timer","arguments":"{\"minutes\":5}"}}]}"#),
            chunk("{}", finish: "tool_calls"), "[DONE]"])
        check(tc == [.toolCall(id: "call_a", name: "get_weather", json: #"{"city":"Taipei"}"#), .toolCall(id: "call_b", name: "set_timer", json: #"{"minutes":5}"#), .done(stopReason: "tool_calls")],
              "LM Studio 串流：工具呼叫分塊拼回、兩個呼叫分開")   // l10n-ignore
        // 沒有 index：改用 id 分辨；整段一次給；沒有參數
        let tn = feed([
            chunk(#"{"tool_calls":[{"id":"x1","function":{"name":"a","arguments":"{}"}}]}"#),
            chunk(#"{"tool_calls":[{"id":"x2","function":{"name":"b","arguments":"{\"k\":1}"}}]}"#),
            chunk(#"{"tool_calls":[{"id":"x3","function":{"name":"c"}}]}"#), chunk("{}", finish: "tool_calls"), "[DONE]"])
        check(tn.prefix(3).map { $0 } == [.toolCall(id: "x1", name: "a", json: "{}"), .toolCall(id: "x2", name: "b", json: #"{"k":1}"#), .toolCall(id: "x3", name: "c", json: "{}")], "LM Studio 串流：沒有 index 時用 id 分辨呼叫；沒參數＝{}")
        let obj = feed([chunk(#"{"tool_calls":[{"index":0,"id":"o","function":{"name":"f","arguments":{"z":2,"a":1}}}]}"#), "[DONE]"])
        check(obj.first == .toolCall(id: "o", name: "f", json: #"{"a":1,"z":2}"#), "LM Studio 串流：arguments 直接是物件也收")
        let noId = feed([chunk(#"{"tool_calls":[{"index":0,"function":{"name":"f","arguments":"{}"}}]}"#), "[DONE]"])
        check(noId.first == .toolCall(id: "call_0", name: "f", json: "{}"), "LM Studio 串流：沒給 id 就補一個")

        // 錯誤與截斷
        check(feed([#"{"error":"Model unloaded."}"#]) == [.error(.badRequest("Model unloaded."))], "LM Studio 串流：字串錯誤")
        check(feed([#"{"error":{"message":"boom"}}"#]) == [.error(.badRequest("boom"))], "LM Studio 串流：物件錯誤")
        check(feed([chunk(#"{"content":"半截"}"#)]) == [.textDelta("半截"), .error(.network("stream ended early"))], "LM Studio 串流：連線中途斷掉＝錯誤，不當成完整回答")
        check(feed([chunk(#"{"content":"好"}"#), chunk("{}", finish: "stop")]).last == .done(stopReason: "stop"), "LM Studio 串流：沒有 [DONE] 但有 finish_reason 也算完成")
        check(feed(["", "garbage", chunk("{}", finish: "stop"), "[DONE]"]).last == .done(stopReason: "stop"), "LM Studio 串流：壞行忽略")

        // 錯誤分類
        check(LMStudioErrors.needsModelLoad("No models loaded. Please load a model in the developer page.") && LMStudioErrors.needsModelLoad("Model xyz is not loaded") && !LMStudioErrors.needsModelLoad("bad json"), "LM Studio 錯誤：沒載入模型")
        check(LMStudioErrors.isContextOverflow("Trying to keep the first 5000 tokens when context the overflows. context length is only 4096") && LMStudioErrors.isContextOverflow("The number of tokens to keep from the initial prompt is greater than the context length") && !LMStudioErrors.isContextOverflow("model not found"), "LM Studio 錯誤：情境超過")
        let body = Data(#"{"error":"No models loaded. Please load a model."}"#.utf8)
        check(ClioError.from(status: 400, body: body, retryAfter: nil) == .badRequest("No models loaded. Please load a model."), "LM Studio 錯誤：錯誤是字串時也讀得到訊息")
    }

    private static func tool(_ n: String) -> ClioToolSpec { ClioToolSpec(name: n, description: "does " + n, schema: #"{"type":"object","properties":{"q":{"type":"string"}}}"#) }

    private static func budget(_ check: (Bool, String) -> Void) {
        check(ClioLMBudget.tokens("abcdefgh") == 2 && ClioLMBudget.tokens("你好嗎") == 3 && ClioLMBudget.tokens("") == 0, "預算：估 token（漢字一字一個、其他四個字元一個）")

        let u1 = ClioMessage.user("第一句"), u2 = ClioMessage.user("第二句")   // l10n-ignore
        let call = ClioMessage(role: .assistant, blocks: [.text("我查一下"), .toolUse(id: "c1", name: "weather", input: "{}")])   // l10n-ignore
        let res = ClioMessage(role: .user, blocks: [.toolResult(id: "c1", content: "晴", isError: false)])   // l10n-ignore
        let ans = ClioMessage(role: .assistant, blocks: [.reasoning("內心戲"), .text("晴天")])   // l10n-ignore
        let history = [u1, call, res, ans, u2]
        let tools = [tool("weather"), tool("timer")]

        // 會用工具：帶工具、說明不加註、歷史完整
        let on = ClioLMBudget.plan(context: 16_384, toolUse: true, system: "SYS", tools: tools, messages: history)
        check(on.tools.count == 2 && on.system == "SYS" && !on.droppedTools && on.messages == history && on.maxTokens == 1024, "預算：會用工具＝送工具、歷史照舊")
        // 不會用工具：不送工具、說明加註「不能控制家裡」、歷史只剩文字且角色交替
        let off = ClioLMBudget.plan(context: 16_384, toolUse: false, system: "SYS", tools: tools, messages: history)
        check(off.tools.isEmpty && off.droppedTools && off.system.hasPrefix("SYS") && off.system.contains("cannot control the home"), "預算：不會用工具＝不送工具、說明告訴它不能控制家裡")
        check(off.messages.map(\.role) == [.user, .assistant, .user] && off.messages.allSatisfy { m in m.blocks.allSatisfy { if case .text = $0 { return true }; return false } }, "預算：不送工具時歷史只留文字、角色交替")
        // 沒有工具可送（全關）：不加註
        let none = ClioLMBudget.plan(context: 16_384, toolUse: false, system: "SYS", tools: [], messages: history)
        check(none.system == "SYS" && !none.droppedTools, "預算：本來就沒工具＝說明不加註")
        // 伺服器端工具（Anthropic 的）不送
        var server = tool("web_search"); server.serverType = "web_search_20260209"
        check(ClioLMBudget.plan(context: 16_384, toolUse: true, system: "S", tools: [server], messages: [u1]).tools.isEmpty, "預算：伺服端工具不送")
        // 情境很小：工具定義吃掉一大半就放棄工具
        let big = (0..<40).map { ClioToolSpec(name: "t\($0)", description: String(repeating: "describe ", count: 40), schema: #"{"type":"object"}"#) }
        let tiny = ClioLMBudget.plan(context: 4096, toolUse: true, system: "SYS", tools: big, messages: [u1])
        check(tiny.droppedTools && tiny.tools.isEmpty && tiny.maxTokens == 512, "預算：4096 情境塞不下工具定義＝改成只聊天")
        // 修剪：舊的整輪丟掉（工具呼叫與結果不拆開），最後一輪一定留
        let longText = String(repeating: "很長的一句話", count: 200)   // l10n-ignore
        let turns = (0..<10).flatMap { i in [ClioMessage.user("問題\(i)" + longText), ClioMessage(role: .assistant, blocks: [.text("回答\(i)" + longText)])] }   // l10n-ignore
        let p = ClioLMBudget.plan(context: 4096, toolUse: true, system: "SYS", tools: [], messages: turns)
        check(p.messages.count < turns.count && p.messages.first?.isUserUtterance == true && p.messages.last == turns.last
              && p.messages.reduce(0, { $0 + ClioLMBudget.tokens($1) }) <= 4096 - p.maxTokens, "預算：舊的整輪丟掉、從使用者的話開始、最後一輪留著、總量在情境內")   // l10n-ignore
        let withTools = ClioLMBudget.trim([u1, call, res, ans, u2], budget: ClioLMBudget.tokens(u2) + 2)
        check(withTools == [u2], "預算：修剪時工具呼叫與結果跟著那一輪一起丟")
        let huge = ClioLMBudget.trim([ClioMessage.user(String(repeating: "字", count: 50_000))], budget: 100)   // l10n-ignore
        check(huge.count == 1, "預算：只有一輪、自己就超過＝照樣保留")
    }

    private static func requests(_ check: (Bool, String) -> Void) {
        let msgs = [ClioMessage.user("開燈"),   // l10n-ignore
                    ClioMessage(role: .assistant, blocks: [.reasoning("想過了"), .toolUse(id: "c1", name: "home_control", input: #"{"x":1}"#)]),   // l10n-ignore
                    ClioMessage(role: .user, blocks: [.toolResult(id: "c1", content: "ok", isError: false)])]
        let plan = ClioLMBudget.plan(context: 16_384, toolUse: true, system: "SYS", tools: [tool("home_control")], messages: msgs)
        let b = LMStudioProvider.body(model: "qwen3.5-4b-mlx", plan: plan)
        let m = b["messages"] as? [[String: Any]] ?? []
        check(b["model"] as? String == "qwen3.5-4b-mlx" && b["stream"] as? Bool == true && b["max_tokens"] as? Int == 1024, "LM Studio 請求：model、stream、max_tokens")
        check(m.first?["role"] as? String == "system" && m.first?["content"] as? String == "SYS", "LM Studio 請求：第一則是 system")
        check(m.count == 4 && m[2]["role"] as? String == "assistant" && (m[2]["content"] as? String) == "" && (m[2]["tool_calls"] as? [[String: Any]])?.count == 1 && m[3]["role"] as? String == "tool",
              "LM Studio 請求：assistant 只有工具呼叫時 content 是空字串、結果是 role:tool")   // l10n-ignore
        check(m[2]["reasoning_content"] == nil, "LM Studio 請求：思考不送回去")
        let tools = b["tools"] as? [[String: Any]] ?? []
        check(tools.count == 1 && tools[0]["type"] as? String == "function" && (tools[0]["function"] as? [String: Any])?["name"] as? String == "home_control"
              && ((tools[0]["function"] as? [String: Any])?["parameters"] as? [String: Any])?["type"] as? String == "object", "LM Studio 請求：工具用 OpenAI function 格式")   // l10n-ignore
        let off = LMStudioProvider.body(model: "m", plan: ClioLMBudget.plan(context: 8192, toolUse: false, system: "S", tools: [tool("a")], messages: [.user("hi")]))
        check(off["tools"] == nil, "LM Studio 請求：模型不會用工具＝請求裡沒有 tools")
        check(JSONSerialization.isValidJSONObject(b), "LM Studio 請求：是合法 JSON")

        // 供應商與周邊
        check(!ClioProviderID.lmStudio.needsKey && ClioProviderID(rawValue: "lmStudio") == .lmStudio && ClioProviderID.lmStudio.defaultFast == ClioModels.lmStudio, "LM Studio：供應商不需要金鑰")
        check(ClioPrice.of(ClioModels.lmStudio).cost(ClioUsage(input: 1_000_000, output: 1_000_000)) == 0, "LM Studio：花費記 0")
        let all = Set(ClioToolGroup.allCases)
        check(!ClioToolCatalog.specs(all, provider: .lmStudio, includeEscalate: false).isEmpty, "LM Studio：工具清單照常組（模型不會用工具時由供應商拿掉）")
        check(ClioToolCatalog.specs(all, provider: .lmStudio, includeEscalate: false, canSearchWeb: true).contains { $0.name == "search_web" }
              && !ClioToolCatalog.specs(all, provider: .lmStudio, includeEscalate: false, canSearchWeb: false).contains { $0.name == "search_web" }, "LM Studio：有 DeepSeek 金鑰才有 search_web")   // l10n-ignore
        check(ClioError.lmNotInstalled.message != ClioError.lmOffline.message && !ClioError.lmNoModel.message.isEmpty && !ClioError.lmLoadFailed.message.isEmpty, "LM Studio：四種錯誤各有說明")
        check(ClioModels.displayName(ClioModels.lmStudio) == "LM Studio", "LM Studio：預設顯示名")
    }
}
