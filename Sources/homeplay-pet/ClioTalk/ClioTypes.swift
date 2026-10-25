// ClioTalk 的共用型別：對話紀錄（transcript）、串流事件、錯誤、價目、路由、修剪、確認詞。
// 這裡全是純邏輯，--selftest 直接測（ClioSelftest.swift）；網路與 UI 在別的檔案。
// 原則照 AI System 6：ClioTalk 不替你發聲（會改資料的工具先念給你聽、等你說「好」）；回答是暫時的，按「留下」才存。

import Foundation

// MARK: - 供應商與模型

enum ClioProviderID: String, CaseIterable, Codable {
    case anthropic, deepseek, lmStudio, onDevice   // 2.0: lmStudio＝這台 Mac 上的 LM Studio（不用金鑰）

    /// 預設模型（2026-10-24 查證，見 byok.md）：快＝每一輪，深＝需要時升級
    var defaultFast: String {
        switch self {
        case .anthropic: return "claude-haiku-5-5"
        case .deepseek: return "deepseek-flash"
        case .lmStudio: return ClioModels.lmStudio
        case .onDevice: return ClioModels.onDevice
        }
    }
    var defaultDeep: String {
        switch self {
        case .anthropic: return "claude-opus-5-5"
        case .deepseek: return "deepseek-v4-pro"
        case .lmStudio: return ClioModels.lmStudio
        case .onDevice: return ClioModels.onDevice
        }
    }
    var fastChoices: [String] {
        switch self {
        case .anthropic: return ["claude-haiku-5-5", "claude-sonnet-5-5"]
        case .deepseek: return ["deepseek-flash"]
        case .lmStudio: return [ClioModels.lmStudio]
        case .onDevice: return [ClioModels.onDevice]
        }
    }
    var deepChoices: [String] {
        switch self {
        case .anthropic: return ["claude-opus-5-5", "claude-fable-5-1", "claude-sonnet-5-5"]
        case .deepseek: return ["deepseek-v4-pro"]
        case .lmStudio: return [ClioModels.lmStudio]
        case .onDevice: return [ClioModels.onDevice]
        }
    }
    var needsKey: Bool { self != .onDevice && self != .lmStudio }
}

enum ClioModels {
    static let onDevice = "apple-on-device"
    /// 2.0: LM Studio 沒有固定的模型名——用使用者載入的那個，真名在請求時才知道（ClioEvent.info 回報）
    static let lmStudio = "lmstudio-loaded"
    /// 卡片底下、設定裡顯示的名字（產品名，不翻譯）
    static func displayName(_ id: String) -> String {
        switch id {
        case "claude-haiku-5-5": return "Claude Haiku 5.5"
        case "claude-sonnet-5-5": return "Claude Sonnet 5.5"
        case "claude-opus-5-5": return "Claude Opus 5.5"
        case "claude-fable-5-1": return "Claude Fable 5.1"
        case "deepseek-flash": return "DeepSeek Flash"
        case "deepseek-v4-pro": return "DeepSeek V4 Pro"
        case onDevice: return "Apple Intelligence"
        case lmStudio: return "LM Studio"
        default: return id
        }
    }
}

// MARK: - 對話紀錄

/// 一則訊息裡的一塊。中性格式：Anthropic 幾乎照搬；DeepSeek（OpenAI 格式）在送出前轉換。
enum ClioBlock: Codable, Equatable {
    case text(String)
    case toolUse(id: String, name: String, input: String)          // input＝JSON 物件字串
    case toolResult(id: String, content: String, isError: Bool)
    /// 模型的思考（Anthropic thinking 區塊帶簽章、DeepSeek reasoning_content）。帶工具的多輪對話要原樣送回去，否則 400。
    case thinking(text: String, signature: String)
    case redactedThinking(data: String)
    case reasoning(String)
}

struct ClioMessage: Codable, Equatable {
    enum Role: String, Codable { case user, assistant }
    var role: Role
    var blocks: [ClioBlock]
    var at = Date()

    static func user(_ s: String) -> ClioMessage { ClioMessage(role: .user, blocks: [.text(s)]) }

    var text: String {
        blocks.compactMap { if case .text(let t) = $0 { return t }; return nil }.joined()
    }
    var toolUses: [(id: String, name: String, input: String)] {
        blocks.compactMap { if case let .toolUse(id, name, input) = $0 { return (id, name, input) }; return nil }
    }
    /// 使用者「開口說話」的那一則（不是只裝工具結果的那種 user 訊息）：修剪只能從這裡切
    var isUserUtterance: Bool {
        role == .user && blocks.contains { if case .text = $0 { return true }; return false }
            && !blocks.contains { if case .toolResult = $0 { return true }; return false }
    }
    /// 估算長度用的字數
    var charCount: Int {
        blocks.reduce(0) { n, b in
            switch b {
            case .text(let t), .reasoning(let t): return n + t.count
            case let .toolUse(_, name, input): return n + name.count + input.count + 20
            case let .toolResult(_, content, _): return n + content.count + 20
            case let .thinking(text, sig): return n + text.count + sig.count / 4
            case .redactedThinking(let d): return n + d.count / 4
            }
        }
    }
}

/// 給模型看的工具定義。schema 是 JSON Schema 物件的字串（定義固定，前綴才快取得住）。
struct ClioToolSpec: Equatable {
    var name: String
    var description: String
    var schema: String
    /// 會改資料或用你的名義送出：要先念給你聽、等你說「好」
    var needsConfirmation = false
    /// 伺服端工具（Anthropic web_search）：只送定義，模型自己在 Anthropic 那邊用
    var serverType: String? = nil

    var schemaObject: [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(schema.utf8))) as? [String: Any] ?? ["type": "object", "properties": [String: Any]()]
    }
}

// MARK: - 串流事件與錯誤

struct ClioUsage: Equatable {
    var input = 0          // 未快取的輸入
    var output = 0
    var cacheRead = 0
    var cacheWrite = 0
    var webSearches = 0
    static func + (a: ClioUsage, b: ClioUsage) -> ClioUsage {
        ClioUsage(input: a.input + b.input, output: a.output + b.output, cacheRead: a.cacheRead + b.cacheRead,
                  cacheWrite: a.cacheWrite + b.cacheWrite, webSearches: a.webSearches + b.webSearches)
    }
}

enum ClioEvent: Equatable {
    case textDelta(String)
    case toolCall(id: String, name: String, json: String)
    case reasoning(ClioBlock)          // 思考區塊：存進 transcript，下一輪原樣送回
    case usage(ClioUsage)
    case done(stopReason: String?)
    case error(ClioError)
    /// 2.0: 狀態說明（「正在載入模型…」，nil＝清掉）與這一輪實際用的模型名（nil＝不變）
    case info(note: String?, model: String?)
}

enum ClioError: Error, Equatable {
    case missingKey
    case invalidKey
    case billing                       // Anthropic 402／DeepSeek 402 餘額不足
    case permission(String)
    case rateLimited(retryAfter: Double?)
    case overloaded
    case server(Int)
    case badRequest(String)
    case network(String)
    case spendCapReached(cap: Double)
    case onDeviceUnavailable
    // 2.0: LM Studio
    case lmNotInstalled, lmOffline, lmNoModel, lmLoadFailed
    case contextTooLong
    case cancelled

    /// 畫面與朗讀用的一句話
    var message: String {
        switch self {
        case .missingKey: return L("clio.err.missingKey", "还没连接模型。到「设置 › ClioTalk」接上你自己的模型；其他功能照常能用")
        case .invalidKey: return L("clio.err.invalidKey", "API 密钥无效或已过期")
        case .billing: return L("clio.err.billing", "账户余额不足，请到供应商网站充值")
        case .permission: return L("clio.err.permission", "这个密钥没有使用这个模型的权限")
        case .rateLimited: return L("clio.err.rateLimited", "请求太频繁，稍等一下再问")
        case .overloaded: return L("clio.err.overloaded", "模型现在太忙，稍后再试")
        case .server: return L("clio.err.server", "供应商那边出错了，稍后再试")
        case .badRequest: return L("clio.err.badRequest", "请求被拒绝了（设置可能不对）")
        case .network: return L("clio.err.network", "连不上网络")
        case .spendCapReached(let cap): return String(format: L("clio.err.cap", "这个月已经用到上限 US$%.2f，在设置里可以调高"), cap)
        case .onDeviceUnavailable: return L("clio.err.onDevice", "这台 Mac 的 Apple Intelligence 现在不能用")
        case .lmNotInstalled: return L("clio.err.lmNotInstalled", "没有找到 LM Studio：到 lmstudio.ai 下载并安装")
        case .lmOffline: return L("clio.err.lmOffline", "LM Studio 没有启动，也叫不起来：请先打开它")
        case .lmNoModel: return L("clio.err.lmNoModel", "LM Studio 里没有可用的模型：先在里面下载一个")
        case .lmLoadFailed: return L("clio.err.lmLoadFailed", "模型载入失败：可能内存不够，换小一点的模型试试")
        case .contextTooLong: return L("clio.err.context", "对话太长了，清除对话纪录后再问")
        case .cancelled: return L("clio.err.cancelled", "已停止")
        }
    }

    /// HTTP 狀態碼＋錯誤 JSON → 錯誤（兩家共用；DeepSeek 503＝過載）
    static func from(status: Int, body: Data?, retryAfter: Double?) -> ClioError {
        let obj = body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let err = obj?["error"] as? [String: Any]
        let msg = (err?["message"] as? String) ?? (obj?["error"] as? String) ?? ""   // 2.0: LM Studio 的錯誤是字串
        let type = (err?["type"] as? String) ?? ""
        switch status {
        case 401: return .invalidKey
        case 402: return .billing
        case 403: return .permission(msg)
        case 413: return .contextTooLong
        case 429:
            // 月花費上限（Anthropic）沒有 retry-after，重試也沒用：當成帳單問題
            if msg.contains("spend") || ((err?["details"] as? [String: Any])?["error_code"] as? String) == "enforced_spend_limit_reached" { return .billing }
            return .rateLimited(retryAfter: retryAfter)
        case 529, 503: return .overloaded
        case 400, 404, 409, 422:
            if type == "authentication_error" { return .invalidKey }
            return .badRequest(msg)
        default: return status >= 500 ? .server(status) : .badRequest(msg)
        }
    }

    /// 串流中途的 error 事件（Anthropic：{"type":"error","error":{"type":"overloaded_error",...}}）
    static func fromStreamType(_ type: String, message: String) -> ClioError {
        switch type {
        case "overloaded_error": return .overloaded
        case "rate_limit_error": return .rateLimited(retryAfter: nil)
        case "authentication_error": return .invalidKey
        case "permission_error": return .permission(message)
        case "billing_error": return .billing
        case "request_too_large": return .contextTooLong
        case "invalid_request_error": return .badRequest(message)
        default: return .server(500)
        }
    }

    var retryable: Bool {
        switch self { case .rateLimited, .overloaded: return true; default: return false }
    }
}

/// 429／529／503 的重試：守 Retry-After，沒有就 1、2、4 秒；最多重試 2 次（官方 SDK 的預設）
enum ClioRetry {
    static let maxRetries = 2
    static func delay(attempt: Int, retryAfter: Double?) -> Double? {
        guard attempt < maxRetries else { return nil }
        if let r = retryAfter, r >= 0 { return min(r, 20) }
        return min(pow(2, Double(attempt)), 20)
    }
    static func shouldRetry(status: Int) -> Bool { [429, 503, 529].contains(status) }
}

// MARK: - 價目與花費

/// 每百萬 token 的美元價（byok.md 2026-10-24 查證）。DeepSeek 用尖峰價（保守估）。
struct ClioPrice: Equatable {
    var input: Double, output: Double, cacheWrite: Double, cacheRead: Double

    static func of(_ model: String) -> ClioPrice {
        switch model {
        case "claude-haiku-5-5": return ClioPrice(input: 0.10, output: 0.50, cacheWrite: 0.20, cacheRead: 0.01)
        case "claude-sonnet-5-5": return ClioPrice(input: 2, output: 10, cacheWrite: 4, cacheRead: 0.10)
        case "claude-opus-5-5": return ClioPrice(input: 4, output: 20, cacheWrite: 8, cacheRead: 0.20)
        case "claude-fable-5-1": return ClioPrice(input: 10, output: 50, cacheWrite: 20, cacheRead: 0.25)
        case "deepseek-flash": return ClioPrice(input: 0.30, output: 1.2, cacheWrite: 0.30, cacheRead: 0.006)
        case "deepseek-v4-pro": return ClioPrice(input: 1.32, output: 3.96, cacheWrite: 1.32, cacheRead: 0.044)
        case ClioModels.onDevice, ClioModels.lmStudio: return ClioPrice(input: 0, output: 0, cacheWrite: 0, cacheRead: 0)
        default: return ClioPrice(input: 10, output: 50, cacheWrite: 20, cacheRead: 0.25)   // 不認得的模型：照最貴的算，寧可高估
        }
    }
    /// Anthropic 網頁搜尋每次的費用（US$10／1000 次；byok.md 沒寫數字，這是假設值，寧可高估）
    static let webSearch = 0.01

    func cost(_ u: ClioUsage) -> Double {
        (Double(u.input) * input + Double(u.output) * output + Double(u.cacheWrite) * cacheWrite + Double(u.cacheRead) * cacheRead) / 1_000_000
            + Double(u.webSearches) * Self.webSearch
    }
}

/// 這個月用了多少：存在 UserDefaults（只有數字，沒有內容）
struct ClioLedger {
    var defaults: UserDefaults = .standard
    static let key = "ClioTalkLedger"

    static func monthKey(_ d: Date = Date()) -> String {
        let c = Calendar(identifier: .gregorian).dateComponents([.year, .month], from: d)
        return String(format: "%04d-%02d", c.year ?? 0, c.month ?? 0)
    }
    private var table: [String: [String: Double]] {
        get { defaults.dictionary(forKey: Self.key) as? [String: [String: Double]] ?? [:] }
        nonmutating set { defaults.set(newValue, forKey: Self.key) }
    }
    func spent(_ d: Date = Date()) -> Double { table[Self.monthKey(d)]?["usd"] ?? 0 }
    func turns(_ d: Date = Date()) -> Int { Int(table[Self.monthKey(d)]?["turns"] ?? 0) }
    func add(usd: Double, turn: Bool, at d: Date = Date()) {
        var t = table, k = Self.monthKey(d)
        var m = t[k] ?? [:]
        m["usd", default: 0] += usd
        if turn { m["turns", default: 0] += 1 }
        t[k] = m
        // 只留最近 13 個月
        if t.count > 13 { for old in t.keys.sorted().dropLast(13) { t[old] = nil } }
        table = t
    }
    /// 上限 0＝不限
    func overCap(_ cap: Double, at d: Date = Date()) -> Bool { cap > 0 && spent(d) >= cap }
}

// MARK: - 路由

enum ClioTier: String, Codable { case fast, deep }

enum ClioRouter {
    /// 使用者明說要想深一點：直接用深模型
    static let deepPhrases = ["想深一点", "想深一點", "仔细想", "仔細想", "认真想", "認真想", "深入想", "想清楚一点", "想清楚一點",   // l10n-ignore：比對用詞
                              "think harder", "think deeper", "think carefully", "think it through"]
    static func wantsDeep(_ text: String) -> Bool {
        let t = text.lowercased()
        return deepPhrases.contains { t.contains($0) }
    }
    static func tier(for text: String) -> ClioTier { wantsDeep(text) ? .deep : .fast }
    static let escalateTool = "escalate"
}

// MARK: - 確認（「好」才做）

enum ClioConfirm {
    enum Answer: Equatable { case yes, no, other }
    private static let yes = ["好", "好的", "好啊", "好喔", "好哦", "可以", "确定", "確定", "对", "對", "是", "嗯", "行", "没问题", "沒問題", "加吧", "送出",   // l10n-ignore：比對用詞
                              "ok", "okay", "yes", "yep", "sure", "do it", "confirm"]
    private static let no = ["取消", "不要", "不用", "算了", "不", "别", "別", "先不要", "no", "nope", "cancel", "stop", "don't"]   // l10n-ignore：比對用詞
    /// 只看整句（去掉標點與空白）：「好，改到中午」不算單純的「好」
    static func classify(_ text: String) -> Answer {
        let t = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "。．.!！?？,，~～ "))
        if t.isEmpty { return .other }
        if yes.contains(t) { return .yes }
        if no.contains(t) { return .no }
        return .other
    }
}

// MARK: - 修剪（超過 token 預算就丟最舊的整輪）

enum ClioTrim {
    /// 估 token：4 個字元一個（中文其實更多 token；預算本身留了餘裕）
    static func tokens(_ messages: [ClioMessage]) -> Int { messages.reduce(0) { $0 + $1.charCount } / 4 }

    /// 從最舊的開始丟，一次丟一整輪（到下一句使用者的話為止），工具呼叫與結果不拆開。
    /// 最後一輪永遠保留，就算它自己就超過預算。
    static func trim(_ messages: [ClioMessage], budget: Int) -> [ClioMessage] {
        var m = messages
        while tokens(m) > budget {
            guard let next = m.indices.dropFirst().first(where: { m[$0].isUserUtterance }) else { break }
            m.removeSubrange(0..<next)
        }
        // 開頭一定要是使用者說的話
        if let first = m.firstIndex(where: { $0.isUserUtterance }), first > 0 { m.removeSubrange(0..<first) }
        return m
    }
}

// MARK: - 朗讀：串流文字切成句子

struct ClioSentenceSplitter {
    private var buffer = ""
    private static let enders: Set<Character> = ["。", "！", "？", "!", "?", "；", ";", "\n"]

    /// 餵進新文字，回傳已經完整的句子
    mutating func feed(_ s: String) -> [String] {
        buffer += s
        var out: [String] = []
        var cur = ""
        let chars = Array(buffer)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            cur.append(c)
            // 英文句點：後面要是空白才算句尾（3.5、e.g. 不切）
            let isEnd = Self.enders.contains(c) || (c == "." && i + 1 < chars.count && chars[i + 1] == " ")
            if isEnd {
                let t = cur.trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty { out.append(t) }
                cur = ""
            }
            i += 1
        }
        buffer = cur
        return out
    }
    /// 串流結束：剩下的也念
    mutating func flush() -> String? {
        let t = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        buffer = ""
        return t.isEmpty ? nil : t
    }
}
