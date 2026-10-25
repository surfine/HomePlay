// 2.0 P10（HV-NEWS-38）：ClioTalk 念回答用的聲音與語速。HomeView 把 iPhone 上 Siri 的聲音帶過來；我們在 Mac 上讓你挑
// 這台 Mac 已經裝好的系統聲音（AVSpeechSynthesisVoice，含「增強」「高品質」與「個人聲音」），外加語速。
// 只列介面語言那一種（繁中＝台灣的國語、簡中＝普通話、英文＝各地英文）；沒挑＝自動（挑最好的那個，跟以前一樣）。
// 個人聲音：系統要先問過你；只有你在設定裡按了那顆鈕才去問（不會自己跳框）。

import AVFoundation

struct ClioVoiceOption: Equatable, Identifiable {
    var id: String
    var name: String
    var language: String
    /// 0＝一般、1＝增強、2＝高品質（AVSpeechSynthesisVoiceQuality 的 1/2/3 減一）
    var quality: Int
    var personal = false
}

enum ClioSpeechVoices {
    static let rateKey = "ClioTalkSpeechRate"
    static func voiceKey(_ lang: String) -> String { "ClioTalkVoice.\(lang)" }

    /// 語速：AVSpeechUtterance 的 0…1（0.5＝系統預設）。預設快 8%，聽起來比較像在對話
    static let defaultRate = min(AVSpeechUtteranceMaximumSpeechRate, AVSpeechUtteranceDefaultSpeechRate * 1.08)
    static let rateRange: ClosedRange<Float> = 0.35...0.65
    static func clampRate(_ r: Float) -> Float { min(rateRange.upperBound, max(rateRange.lowerBound, r.isFinite ? r : defaultRate)) }

    static var rate: Float {
        get { (UserDefaults.standard.object(forKey: rateKey) as? Double).map { clampRate(Float($0)) } ?? defaultRate }
        set { UserDefaults.standard.set(Double(clampRate(newValue)), forKey: rateKey) }
    }

    /// 設定頁列的那一種語言（跟 ClioSpeaker.language(for:) 念中文時用的同一個）
    static var interfaceLanguage: String {
        switch L10n.language {
        case .zhHans: return "zh-CN"
        case .zhHant: return "zh-TW"
        default: return "en-US"
        }
    }

    /// 同一種語言：英文不分地區（美式、英式、澳洲…都列）；中文照地區（zh-HK 是粵語，不混進國語）
    static func sameFamily(_ voice: String, _ lang: String) -> Bool {
        if lang.hasPrefix("en") { return voice.hasPrefix("en") }
        return voice == lang
    }

    /// 純邏輯：這種語言可以挑的聲音。順序：個人聲音 → 高品質 → 增強 → 一般，同級照名字
    static func options(_ all: [ClioVoiceOption], lang: String) -> [ClioVoiceOption] {
        all.filter { sameFamily($0.language, lang) }.sorted {
            if $0.personal != $1.personal { return $0.personal }
            if $0.quality != $1.quality { return $0.quality > $1.quality }
            if $0.language != $1.language { return $0.language == lang }   // 英文：本地區的先
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    /// 挑過的還裝著就用它；被移除了（或換了語言）＝自動
    static func resolve(_ selected: String?, in opts: [ClioVoiceOption]) -> String? {
        guard let s = selected, opts.contains(where: { $0.id == s }) else { return nil }
        return s
    }

    // MARK: 系統

    static func installed() -> [ClioVoiceOption] {
        AVSpeechSynthesisVoice.speechVoices().filter { !$0.voiceTraits.contains(.isNoveltyVoice) }.map {
            ClioVoiceOption(id: $0.identifier, name: $0.name, language: $0.language,
                            quality: max(0, $0.quality.rawValue - 1), personal: $0.voiceTraits.contains(.isPersonalVoice))
        }
    }

    static func selected(for lang: String) -> String? { UserDefaults.standard.string(forKey: voiceKey(lang)) }
    static func setSelected(_ id: String?, for lang: String) {
        if let id { UserDefaults.standard.set(id, forKey: voiceKey(lang)) } else { UserDefaults.standard.removeObject(forKey: voiceKey(lang)) }
    }

    /// 念這一句用的聲音：這種語言你挑過、而且還裝著 → 它；否則 nil（呼叫端照舊自動挑）
    static func chosen(for lang: String) -> AVSpeechSynthesisVoice? {
        let listLang = interfaceLanguage
        guard sameFamily(lang, listLang), let id = selected(for: listLang) else { return nil }
        return AVSpeechSynthesisVoice(identifier: id)
    }

    /// 個人聲音的權限：nil＝這台 Mac 不支援
    static var personalStatus: AVSpeechSynthesizer.PersonalVoiceAuthorizationStatus? {
        let s = AVSpeechSynthesizer.personalVoiceAuthorizationStatus
        return s == .unsupported ? nil : s
    }
    /// 只在使用者按了「使用個人聲音」才叫
    static func requestPersonal(_ done: @escaping () -> Void) {
        AVSpeechSynthesizer.requestPersonalVoiceAuthorization { _ in DispatchQueue.main.async { done() } }
    }

    static func selftest(_ check: (Bool, String) -> Void) {
        let all = [ClioVoiceOption(id: "a", name: "Samantha", language: "en-US", quality: 0),
                   ClioVoiceOption(id: "b", name: "Zoe", language: "en-US", quality: 2),
                   ClioVoiceOption(id: "c", name: "Daniel", language: "en-GB", quality: 1),
                   ClioVoiceOption(id: "d", name: "Me", language: "en-US", quality: 2, personal: true),
                   ClioVoiceOption(id: "e", name: "Meijia", language: "zh-TW", quality: 1),
                   ClioVoiceOption(id: "f", name: "Sinji", language: "zh-HK", quality: 1),
                   ClioVoiceOption(id: "g", name: "Tingting", language: "zh-CN", quality: 0)]
        check(options(all, lang: "en-US").map(\.id) == ["d", "b", "c", "a"], "ClioTalk 聲音：個人聲音＞高品質＞增強＞一般，英文各地區都列")
        check(options(all, lang: "zh-TW").map(\.id) == ["e"] && options(all, lang: "zh-CN").map(\.id) == ["g"], "ClioTalk 聲音：國語不混粵語、簡繁分開")
        check(resolve("b", in: options(all, lang: "en-US")) == "b" && resolve("e", in: options(all, lang: "en-US")) == nil && resolve(nil, in: all) == nil,
              "ClioTalk 聲音：挑的被移除或不是這種語言＝自動")   // l10n-ignore：selftest 訊息
        check(clampRate(0.1) == rateRange.lowerBound && clampRate(0.9) == rateRange.upperBound && clampRate(.nan) == defaultRate && rateRange.contains(defaultRate),
              "ClioTalk 聲音：語速夾在範圍內")   // l10n-ignore：selftest 訊息
    }
}
