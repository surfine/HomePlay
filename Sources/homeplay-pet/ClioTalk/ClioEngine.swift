// ClioTalk 的對話引擎：transcript（每輪整份重送，前綴穩定以吃快取）、修剪、路由（快 → 深）、工具迴圈、
// 「好」才做的確認閘門、每月花費上限、本機 JSON 紀錄。網路與工具都由外面注入，--selftest 用假的跑完整流程。

import Foundation

enum ClioPersona {
    /// 2.0 第五輪：系統說明搬到 ClioPrompt.swift（段落、回答模式、物件卡、AI System 6 的世界觀）；這裡只轉接
    static var system: String { ClioPrompt.system }
    static var noSearchNote: String { ClioPrompt.noSearchNote }

    /// 這一輪實際的系統說明：同一組工具＝同一段文字，快取照樣吃得到
    static func prompt(for tools: [ClioToolSpec]) -> String {
        tools.contains { $0.name == "web_search" || $0.name == ClioWebSearch.spec.name } ? system : system + noSearchNote
    }

    /// 裝置端模型情境小：只留最基本的
    static var onDeviceInstructions: String { ClioPrompt.onDevice }
}

/// 畫面要畫的狀態（ClioTalkPanel 讀它）
struct ClioSnapshot: Equatable {
    enum Phase: Equatable { case idle, thinking, streaming, confirm, error }
    var phase = Phase.idle
    var question = ""
    var answer = ""
    var previous: String?          // 上一輪縮成一行
    var source: String?            // 「来自日历」
    var model = ""
    var tier = ClioTier.fast
    var confirm: String?           // 等你說「好」的那句
    var error: String?
    var note: String?              // 2.0: 暫時的狀態說明（LM Studio「正在載入模型…」），畫在狀態列取代「正在想…」
    var sources: [String] = []     // 第三輪：網頁來源（第一個畫成晶片，其餘收成「+N」）
    var demoImage = false          // 第三輪：示範用的圖片卡（--cliotalk-demo cyanotype；我們自己畫的藍曬圖）
    // 2.0 第五輪
    var handoff: ClioHandoff?      // 交給 App 的物件（計時器、提醒、行程、場景、訊息草稿、通話）
    var kept = false               // 說了「留下」：這則回答存進 kept.json（不再是暫時的）
    var mode = ClioResponseMode.display
    var spoken: String?            // 語音模式的念稿（<spoken> 區塊關起來才有）
    var spokenBlock = false        // 回答有念稿區塊：朗讀念它，不念畫面上的字
    var citations: [Int] = []      // 回答引用的來源編號
}

// MARK: - 本機紀錄

/// ~/Library/Application Support/HomePlay/ClioTalk/：history.json（對話，超過 24 小時的舊輪次載入時丟掉）、kept.json（按「留下」的回答）
struct ClioHistoryStore {
    var dir: URL
    static var defaultDir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("HomePlay/ClioTalk", isDirectory: true)
    }
    static let maxAge: TimeInterval = 24 * 3600

    private var historyURL: URL { dir.appendingPathComponent("history.json") }
    private var keptURL: URL { dir.appendingPathComponent("kept.json") }

    private func ensureDir() {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
    private static let encoder: JSONEncoder = { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e }()
    private static let decoder: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }()

    func load(now: Date = Date()) -> [ClioMessage] {
        guard let d = try? Data(contentsOf: historyURL), let m = try? Self.decoder.decode([ClioMessage].self, from: d) else { return [] }
        // 回答是暫時的：太舊的輪次不再帶進對話（要留的請按「留下」）
        let fresh = m.drop { now.timeIntervalSince($0.at) > Self.maxAge }
        return ClioTrim.trim(Array(fresh), budget: .max)
    }
    func save(_ m: [ClioMessage]) {
        ensureDir()
        guard let d = try? Self.encoder.encode(m) else { return }
        try? d.write(to: historyURL, options: [.atomic])
    }

    struct Kept: Codable, Equatable { var at: Date; var question: String; var answer: String }
    func kept() -> [Kept] {
        guard let d = try? Data(contentsOf: keptURL) else { return [] }
        return (try? Self.decoder.decode([Kept].self, from: d)) ?? []
    }
    func keep(question: String, answer: String, at: Date = Date()) {
        ensureDir()
        let all = kept() + [Kept(at: at, question: question, answer: answer)]
        if let d = try? Self.encoder.encode(all) { try? d.write(to: keptURL, options: [.atomic]) }
    }
    func clear() {
        try? FileManager.default.removeItem(at: historyURL)
        try? FileManager.default.removeItem(at: keptURL)
    }
}

// MARK: - 引擎

actor ClioEngine {
    /// 等你說「好」的那個工具呼叫；同一輪其他工具的結果先收著，確認後一起送回去
    struct Pending: Equatable {
        var id: String
        var name: String
        var input: String
        var readback: String
        var otherResults: [ClioBlock]
        var tier: ClioTier
    }

    private(set) var messages: [ClioMessage]
    private(set) var pending: Pending?
    private(set) var snapshot = ClioSnapshot()
    private let store: ClioHistoryStore
    private let runner: ClioToolRunner
    private let ledger: ClioLedger
    private let config: () -> ClioConfig
    private let makeProvider: (ClioProviderID) throws -> ClioProvider
    private let onSnapshot: (ClioSnapshot) -> Void
    private let now: () -> Date
    private let context: (Date, ClioResponseMode) -> ClioContext
    private var mode = ClioResponseMode.display
    static let maxToolRounds = 6

    init(store: ClioHistoryStore, runner: ClioToolRunner, ledger: ClioLedger, config: @escaping () -> ClioConfig,
         makeProvider: @escaping (ClioProviderID) throws -> ClioProvider, now: @escaping () -> Date = Date.init,
         context: @escaping (Date, ClioResponseMode) -> ClioContext = { ClioContext(now: $0, mode: $1) },
         onSnapshot: @escaping (ClioSnapshot) -> Void) {
        self.store = store; self.runner = runner; self.ledger = ledger; self.config = config
        self.makeProvider = makeProvider; self.now = now; self.context = context; self.onSnapshot = onSnapshot
        self.messages = store.load()
    }

    /// 正式用的：金鑰從鑰匙圈拿，沒有就丟 missingKey
    static func liveProvider(_ p: ClioProviderID) throws -> ClioProvider {
        switch p {
        case .anthropic:
            guard let k = ClioKeychain.load(.anthropic) else { throw ClioError.missingKey }
            return AnthropicProvider(key: k)
        case .deepseek:
            guard let k = ClioKeychain.load(.deepseek) else { throw ClioError.missingKey }
            return DeepSeekProvider(key: k)
        case .lmStudio:
            return LMStudioProvider()   // 2.0: 不用金鑰；連不上時由 ensureReady 丟出說得清楚的錯誤
        case .onDevice:
            guard ClioOnDevice.available else { throw ClioError.onDeviceUnavailable }
            return AppleOnDeviceProvider()
        }
    }

    private func publish() { onSnapshot(snapshot) }

    /// 使用者說了一句（打字＝display；用說的＝voice，回答另給一段念稿）
    func send(_ raw: String, mode: ClioResponseMode = .display) async {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        var leading: [ClioBlock] = []
        if let p = pending {
            switch ClioConfirm.classify(text) {
            case .yes: await resolve(yes: true, said: text); return
            case .no: await resolve(yes: false, said: text); return
            case .other:
                // 沒說好：什麼都不做，把新的話一起交給模型
                leading = p.otherResults + [.toolResult(id: p.id, content: "The user did not confirm, so nothing was changed. Their next message follows.", isError: false)]
                pending = nil
            }
        }
        let saved = messages
        if leading.isEmpty { leading = danglingResults() }
        let cfg = config()
        self.mode = mode
        snapshot = ClioSnapshot(phase: .thinking, question: text, answer: "",
                                previous: oneLine(snapshot.answer.isEmpty ? nil : snapshot.answer), source: nil, model: "", tier: .fast)
        snapshot.mode = mode
        publish()
        appendUser(leading + [.text(context(now(), mode).sharing(nameAndCity: cfg.sendsNameAndCity).block + text)])   // 第六輪：名字與城市照設定
        messages = ClioTrim.trim(messages, budget: cfg.historyBudget)
        await run(tier: ClioRouter.tier(for: text), cfg: cfg, saved: saved, round: 0)
    }

    /// 「好」或「取消」（按鈕、或打字被 send 認出來）
    func confirm(_ yes: Bool) async {
        await resolve(yes: yes, said: yes ? L("clio.chip.ok", "好") : L("clio.chip.cancel", "取消"))
    }

    /// 停掉這一輪：由外面取消 Task，串流丟 cancelled，這裡只負責狀態
    func clear() {
        messages = []; pending = nil
        snapshot = ClioSnapshot()
        store.clear()
        publish()
    }

    /// 「留下」：把最近一輪的問與答存進 kept.json
    @discardableResult
    func keepLast() -> Bool {
        guard !snapshot.answer.isEmpty, snapshot.phase == .idle else { return false }
        if !snapshot.kept { store.keep(question: snapshot.question, answer: snapshot.answer, at: now()) }
        snapshot.kept = true
        publish()
        return true
    }

    // MARK: 內部

    private func oneLine(_ s: String?) -> String? {
        guard let s else { return nil }
        let first = s.split(whereSeparator: \.isNewline).first.map(String.init) ?? s
        return first.count > 40 ? String(first.prefix(40)) + "…" : first
    }

    /// 上一則 assistant 有工具呼叫卻沒有結果（例如上次中途失敗）：補「沒執行」，免得 API 回 400
    private func danglingResults() -> [ClioBlock] {
        guard let last = messages.last, last.role == .assistant, !last.toolUses.isEmpty else { return [] }
        return last.toolUses.map { .toolResult(id: $0.id, content: "Not run.", isError: true) }
    }

    /// 連續兩則 user 合成一則（工具結果＋新的話）
    private func appendUser(_ blocks: [ClioBlock]) {
        if let last = messages.last, last.role == .user {
            messages[messages.count - 1].blocks += blocks
        } else {
            messages.append(ClioMessage(role: .user, blocks: blocks, at: now()))
        }
    }

    private func fail(_ e: Error, saved: [ClioMessage]) {
        let err = (e as? ClioError) ?? .network("\(type(of: e))")
        messages = saved          // 這一輪不算：下次重問不會有半截的紀錄
        pending = nil
        if err == .cancelled {
            snapshot.phase = .idle
        } else {
            snapshot.phase = .error
            snapshot.error = err.message
        }
        publish()
    }

    private func resolve(yes: Bool, said: String) async {
        guard let p = pending else { return }
        pending = nil
        let saved = messages
        snapshot.previous = oneLine(p.readback)
        snapshot.question = said
        snapshot.answer = ""
        snapshot.confirm = nil
        snapshot.spoken = nil; snapshot.spokenBlock = false
        snapshot.phase = .thinking
        publish()
        let result: ClioToolResult
        let input = (try? JSONSerialization.jsonObject(with: Data(p.input.utf8))) as? [String: Any] ?? [:]
        if yes {
            var r = await runner.run(name: p.name, input: input)
            if !r.isError { r.content = "The user confirmed. " + r.content }
            result = r
            if let s = r.source { snapshot.source = s.source }
            // 第五輪：做成了才把草稿卡換成「已交給 App」；失敗就不留卡（不假裝做了）
            snapshot.handoff = r.isError ? nil : ClioHandoff.make(tool: p.name, input: input, state: .done)
        } else {
            result = ClioToolResult(content: "The user cancelled. Nothing was changed.", source: ClioToolCatalog.group(of: p.name))
            snapshot.handoff = nil
        }
        appendUser(p.otherResults + [.toolResult(id: p.id, content: result.content, isError: result.isError)])
        await run(tier: p.tier, cfg: config(), saved: saved, round: 1)
    }

    private func run(tier: ClioTier, cfg: ClioConfig, saved: [ClioMessage], round: Int) async {
        let model = tier == .fast ? cfg.fastModel : cfg.deepModel
        snapshot.model = ClioModels.displayName(model)
        snapshot.tier = tier
        // 每月上限：超過就不送新的請求
        if ledger.overCap(cfg.monthlyCap, at: now()) { fail(ClioError.spendCapReached(cap: cfg.monthlyCap), saved: saved); return }
        let provider: ClioProvider
        do { provider = try makeProvider(cfg.provider) } catch { fail(error, saved: saved); return }
        let canEscalate = tier == .fast && cfg.autoEscalate && cfg.provider != .onDevice && cfg.deepModel != cfg.fastModel
        let tools = ClioToolCatalog.specs(cfg.tools, provider: cfg.provider, includeEscalate: canEscalate, canSearchWeb: cfg.canSearchWeb)
        let base = snapshot.answer
        var text = "", thinking: [ClioBlock] = [], calls: [(id: String, name: String, json: String)] = [], usage = ClioUsage()
        do {
            for try await ev in provider.stream(ClioTranscript(system: ClioPersona.prompt(for: tools), messages: messages), tools: tools, model: model) {
                switch ev {
                case .textDelta(let d):
                    text += d
                    snapshot.phase = .streaming
                    snapshot.note = nil
                    // 第五輪：<spoken> 念稿與 [1] 引用拆出來；畫面只放要看的字
                    let reply = ClioReply.parse(text)
                    snapshot.answer = [base, reply.display].filter { !$0.isEmpty }.joined(separator: "\n")
                    snapshot.spoken = reply.hasSpokenBlock ? reply.spoken : nil
                    snapshot.spokenBlock = reply.hasSpokenBlock
                    snapshot.citations = reply.citations
                    publish()
                case let .toolCall(id, name, json): calls.append((id, name, json))
                case .reasoning(let b): thinking.append(b)
                case .usage(let u): usage = u
                case .done: break
                case .error(let e): throw e
                case let .info(note, model):   // 2.0: LM Studio 的進度說明與實際模型名
                    snapshot.note = note
                    if let model { snapshot.model = model }
                    publish()
                }
            }
        } catch {
            snapshot.note = nil
            ledger.add(usd: ClioPrice.of(model).cost(usage), turn: false, at: now())
            fail(error, saved: saved)
            return
        }
        snapshot.note = nil
        ledger.add(usd: ClioPrice.of(model).cost(usage), turn: round == 0, at: now())

        // 快模型說要升級：這一則不留，同一份紀錄交給深模型重答
        if canEscalate, calls.contains(where: { $0.name == ClioRouter.escalateTool }) {
            log("ClioTalk: 升級到深模型")
            snapshot.answer = base
            publish()
            await run(tier: .deep, cfg: cfg, saved: saved, round: round + 1)
            return
        }

        let blocks: [ClioBlock] = thinking + (text.isEmpty ? [] : [.text(text)]) + calls.map { .toolUse(id: $0.id, name: $0.name, input: $0.json) }
        if !blocks.isEmpty { messages.append(ClioMessage(role: .assistant, blocks: blocks, at: now())) }
        guard !calls.isEmpty else { finish(); return }

        var results: [ClioBlock] = []
        var waiting: Pending?
        for c in calls {
            guard ClioToolCatalog.spec(c.name) != nil, let g = ClioToolCatalog.group(of: c.name), cfg.tools.contains(g) else {
                let msg = c.name == ClioRouter.escalateTool ? "You are already the deeper model; answer directly." : "This tool is turned off in HomePlay settings."
                results.append(.toolResult(id: c.id, content: msg, isError: c.name != ClioRouter.escalateTool))
                continue
            }
            let input = (try? JSONSerialization.jsonObject(with: Data(c.json.utf8))) as? [String: Any] ?? [:]
            if ClioToolCatalog.needsConfirmation(name: c.name, input: input) {
                if waiting == nil {
                    let rb = ClioToolCatalog.readback(name: c.name, input: input) ?? c.name
                    waiting = Pending(id: c.id, name: c.name, input: c.json, readback: rb, otherResults: [], tier: tier)
                    snapshot.handoff = ClioHandoff.make(tool: c.name, input: input, state: .pending)   // 草稿卡：等你說「好」
                } else {
                    results.append(.toolResult(id: c.id, content: "Only one change can be confirmed at a time. Ask about this one after the first is settled.", isError: true))
                }
                continue
            }
            let r = await runner.run(name: c.name, input: input)
            if let s = r.source { snapshot.source = s.source }
            if !r.isError, let h = ClioHandoff.make(tool: c.name, input: input, state: .done) { snapshot.handoff = h }   // 不用確認就做的（計時器、場景）
            results.append(.toolResult(id: c.id, content: r.content, isError: r.isError))
        }
        if var w = waiting {
            // 先念給你聽，等「好」：工具還沒執行
            w.otherResults = results
            pending = w
            snapshot.phase = .confirm
            snapshot.confirm = w.readback
            store.save(messages)
            publish()
            return
        }
        appendUser(results)
        guard round + 1 < Self.maxToolRounds else { finish(); return }
        snapshot.phase = .thinking
        publish()
        await run(tier: tier, cfg: cfg, saved: saved, round: round + 1)
    }

    private func finish() {
        snapshot.phase = .idle
        store.save(messages)
        publish()
    }
}
