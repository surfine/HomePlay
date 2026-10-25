// 2.0 第四輪（使用者決定 #1）：回答畫面完全照官方——只有 👀 玻璃珠＋內容，沒有按鈕。
// 「留下」「想深一點」改成用說的；點 👀 珠＝繼續問（追問）。第一次出現回答時，底部淡淡一行提示一次，之後不再出現（存偏好）。
// 確認、出錯、還沒回答時照舊有控制（ClioTalkPanel 的膠囊）。

import Foundation

enum ClioAnswerCommand: Equatable {
    case keep, deeper

    /// 轉寫出來的一句話是不是回答畫面上的語音指令。整句幾乎就是指令才算（「記住這個電話號碼」是新的問題，不算）
    static func classify(_ text: String) -> ClioAnswerCommand? {
        let t = text.lowercased().filter { $0.isLetter || $0.isNumber }
        guard !t.isEmpty else { return nil }
        var cands = [t]
        for tail in ["please", "thanks", "啊", "呀", "吧", "喔", "哦", "啦", "嘛", "了"] where t.count > tail.count && t.hasSuffix(tail) {   // l10n-ignore：比對用詞
            cands.append(String(t.dropLast(tail.count)))
        }
        for head in ["請", "请", "幫我", "帮我", "please"] where t.count > head.count && t.hasPrefix(head) {   // l10n-ignore：比對用詞
            cands += cands.map { $0.hasPrefix(head) ? String($0.dropFirst(head.count)) : $0 }
        }
        let keep: Set<String> = ["留下", "留着", "留著", "留下来", "留下來", "记住这个", "記住這個", "记住", "記住", "保存", "存起来", "存起來", "keep", "keepit", "keepthis", "savethis", "saveit", "rememberthis", "rememberthat"]   // l10n-ignore：比對用詞
        let deeper: Set<String> = ["想深一点", "想深一點", "再想想", "再说详细一点", "再說詳細一點", "详细一点", "詳細一點", "说详细一点", "說詳細一點", "再详细一点", "再詳細一點", "多说一点", "多說一點", "thinkdeeper", "godeeper", "moredetail", "moredetails", "tellmemore"]   // l10n-ignore：比對用詞
        if cands.contains(where: { keep.contains($0) }) { return .keep }
        if cands.contains(where: { deeper.contains($0) }) { return .deeper }
        return nil
    }

    // MARK: 一次性的提示

    static let hintKey = "clio.answerHintShown"
    /// 這一則回答要不要帶提示（第一次見到回答時記下是哪一則，那一則一直帶著，下一則起不再出現）
    nonisolated(unsafe) static var hintAnswer: String?
    static func hint(for answer: String, defaults: UserDefaults = .standard) -> Bool {
        guard !answer.isEmpty else { return false }
        if let h = hintAnswer { return h == answer }
        guard !defaults.bool(forKey: hintKey) else { return false }
        hintAnswer = answer
        defaults.set(true, forKey: hintKey)
        return true
    }
    static var hintText: String { L("clio.hint.voice", "回答是暂时的：说「留下」才存，说「想深一点」再想想，点 👀 继续问") }

    static func selftest(_ check: (Bool, String) -> Void) {
        let keep = ["留下", "留下。", "記住這個", "记住这个吧", "Keep this.", "Save it", "請留下"]   // l10n-ignore：測試樣本
        let deeper = ["想深一點", "想深一点。", "再說詳細一點", "Tell me more", "Think deeper", "多說一點吧"]   // l10n-ignore：測試樣本
        let other = ["記住這個電話號碼", "明天提醒我", "留下來吃飯嗎", "more coffee", ""]   // l10n-ignore：測試樣本
        check(keep.allSatisfy { classify($0) == .keep }, "ClioTalk 語音指令：留下／記住這個（\(keep.filter { classify($0) != .keep })）")
        check(deeper.allSatisfy { classify($0) == .deeper }, "ClioTalk 語音指令：想深一點／再說詳細一點（\(deeper.filter { classify($0) != .deeper })）")
        check(other.allSatisfy { classify($0) == nil }, "ClioTalk 語音指令：帶了別的內容就是新的問題（\(other.filter { classify($0) != nil })）")
        // 提示只出現一次：第一則回答帶著（重畫也帶著），下一則不帶
        let d = UserDefaults(suiteName: "homeplay.selftest.cliohint")!
        d.removePersistentDomain(forName: "homeplay.selftest.cliohint")
        let saved = hintAnswer; hintAnswer = nil
        let first = hint(for: "A", defaults: d), again = hint(for: "A", defaults: d), next = hint(for: "B", defaults: d)
        hintAnswer = nil
        let afterRestart = hint(for: "C", defaults: d)
        hintAnswer = saved
        d.removePersistentDomain(forName: "homeplay.selftest.cliohint")
        check(first && again && !next && !afterRestart, "ClioTalk：回答的提示只出現一次（存偏好）")
    }
}
