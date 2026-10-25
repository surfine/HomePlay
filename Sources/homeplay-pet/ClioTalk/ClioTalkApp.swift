// 2.0: ClioTalk 接進外殼：主畫面的 ClioTalk 圖示、頂端中間往下拉都打開 ClioTalk 這一層（ClioTalkPanel 那張卡），
// 不是一個 App 畫面；在想、在回答時頂端藥丸是「ClioTalk 回答中」。
// 另外放訊息 App 的「建議回覆」：一次快模型、不帶工具、只送最後幾則，沒有金鑰或沒開「信息」同意就用固定的三個。

import AppKit

final class ClioTalkApp: PetApp {
    static let shared = ClioTalkApp()
    let id = "cliotalk"
    var title: String { "ClioTalk" }
    let icon = AppIcon(color: srgb(0x1c1c22), symbol: "waveform", glyph: srgb(0xc58cff))

    func render(into g: CGContext, face: Face, rect: CGRect, now: Double) {
        g.setFillColor(NSColor.white.cgColor); g.fill(rect)   // 只在打開的過場裡看得到一下：跟卡片同一個白
    }

    /// 打開＝蓋上 ClioTalk 這一層（外殼不切到 App 畫面）
    func launch(face: Face) -> Bool {
        (NSApp.delegate as? AppDelegate)?.view?.shellNavigate(.openClioTalk)
        return true
    }

    /// 快照：--live-activity cliotalk
    nonisolated(unsafe) static var demoActivity = false

    /// 卡片收起來了、這一輪還在想或在回答：頂端藥丸接手
    func liveActivity(face: Face, now: Double) -> LiveActivity? {
        let p = ClioTalkController.shared.snapshot.phase
        guard Self.demoActivity || !ClioTalkController.shared.isOpen && (p == .thinking || p == .streaming) else { return nil }
        return LiveActivity(kind: .assistant, title: "ClioTalk", detail: L("clio.activity.answering", "ClioTalk 回答中"),
                            accent: srgb(0xc58cff), progress: nil, appID: id, symbol: "waveform")
    }
}

/// 訊息的建議回覆
enum ClioReplySuggest {
    static var fixed: [String] { [L("msg.demo.chip1", "好啊"), L("msg.demo.chip2", "晚点回你"), L("msg.demo.chip3", "在路上了")] }

    /// 能不能叫模型：有金鑰（不是只用這台 Mac）、開了「信息」同意、主人在、沒超過每月上限
    static var eligible: Bool {
        let p = ClioSettings.provider
        return p.needsKey && ClioSettings.toolOn(.messages) && PersonalGate.allowed && ClioKeychain.load(p) != nil
            && !ClioLedger().overCap(ClioSettings.monthlyCap)
    }

    static let system = """
    You suggest quick replies for a text message conversation. Reply with exactly three short replies the user could send next, \
    one per line, no numbering, no quotes, no emoji, each under 16 characters, in the same language and script as the conversation.
    """

    /// 模型回的文字 → 最多三個、去掉編號與引號、太長的丟掉
    static func parse(_ s: String) -> [String] {
        let junk = CharacterSet(charactersIn: "-•*·0123456789.)、\"“”「」『』 ")
        let lines = s.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: junk) }.filter { !$0.isEmpty && $0.count <= 24 }
        var out: [String] = []
        for l in lines where !out.contains(l) { out.append(l) }
        return Array(out.prefix(3))
    }

    /// 背景叫一次快模型；拿不到就回 nil（呼叫端維持固定的三個）。completion 在主執行緒
    static func request(last: [(fromMe: Bool, text: String)], completion: @escaping ([String]?) -> Void) {
        guard eligible, !last.isEmpty else { completion(nil); return }
        let p = ClioSettings.provider, model = ClioSettings.fastModel(p)
        let convo = last.suffix(6).map { ($0.fromMe ? "Me: " : "Them: ") + $0.text }.joined(separator: "\n")
        Task.detached {
            var text = "", usage = ClioUsage()
            do {
                let provider = try ClioEngine.liveProvider(p)
                let t = ClioTranscript(system: system, messages: [ClioMessage(role: .user, blocks: [.text(convo)])])
                for try await ev in provider.stream(t, tools: [], model: model) {
                    switch ev {
                    case .textDelta(let d): text += d
                    case .usage(let u): usage = u
                    case .error(let e): throw e
                    default: break
                    }
                }
            } catch {
                log("messages: suggest failed \(type(of: error))")
            }
            ClioLedger().add(usd: ClioPrice.of(model).cost(usage), turn: false)
            let chips = parse(text)
            DispatchQueue.main.async { completion(chips.count >= 2 ? chips : nil) }
        }
    }
}
