// ClioTalk 語音迴圈的純邏輯（--selftest 全部離線測）：
// 音量式的說話偵測（VAD：開口、停頓 0.7 秒算講完）、一輪一輪的狀態機（按住 F5＝按著說、點一下＝免按住、
// 回答完再聽 8 秒、說話打斷朗讀）、插話時分辨是不是自己念的回音、口說的「好／取消」。
// 麥克風與轉寫在 ClioListener.swift，畫面在 ClioVoicePanel.swift，串起來在 ClioTalkPanel.swift 的控制器。

import AVFoundation
import Foundation

// MARK: - 說話偵測（音量）

/// 每段音訊的音量（dBFS）餵進來，回報「開口了」和「講完了（停頓 0.7 秒）」。
/// 噪音底會跟著環境走：一開麥克風先量 0.25 秒當起點，之後安靜時往下追、很慢地往上追。
struct ClioVAD {
    enum Event: Equatable { case onset, endpoint }

    static let onsetTime = 0.15, strictOnsetTime = 0.3
    static let endTime = 0.7
    static let margin: Float = 12, strictMargin: Float = 18
    static let minLevel: Float = -50, strictMinLevel: Float = -38
    static let calibrateTime = 0.25

    var floor: Float = -60
    /// 正在念回答：門檻拉高、要講久一點才算（喇叭的回音不容易誤觸）
    var strict = false
    private(set) var inSpeech = false
    private(set) var heard = false
    private var speechRun = 0.0, silenceRun = 0.0
    private var calibrated = 0.0, calibSum: Float = 0

    /// 新的一輪：忘掉「聽到過」，噪音底保留
    mutating func reset() { inSpeech = false; heard = false; speechRun = 0; silenceRun = 0 }

    func isSpeech(_ db: Float) -> Bool {
        db > max(floor + (strict ? Self.strictMargin : Self.margin), strict ? Self.strictMinLevel : Self.minLevel)
    }

    mutating func feed(db: Float, duration d: Double) -> Event? {
        if calibrated < Self.calibrateTime {   // 剛開麥克風：先量噪音底
            calibSum += db * Float(d); calibrated += d
            if calibrated >= Self.calibrateTime { floor = min(-30, max(-90, calibSum / Float(calibrated))) }
            return nil
        }
        if isSpeech(db) {
            speechRun += d; silenceRun = 0
            // 一直「在說話」超過 4 秒：多半是環境變吵，噪音底慢慢往上追
            if speechRun > 4 { floor = min(-30, floor + Float(d) * 3) }
            if !inSpeech, speechRun >= (strict ? Self.strictOnsetTime : Self.onsetTime) {
                inSpeech = true; heard = true
                return .onset
            }
            return nil
        }
        speechRun = 0
        silenceRun += d
        floor = db < floor ? floor + (db - floor) * 0.3 : min(-30, floor + min(db - floor, Float(d) * 2))
        floor = max(-90, floor)
        if heard, silenceRun >= Self.endTime {
            heard = false; inSpeech = false
            return .endpoint
        }
        return nil
    }

    /// 一段取樣的 RMS（dBFS）
    static func level(_ samples: UnsafeBufferPointer<Float>) -> Float {
        guard !samples.isEmpty else { return -120 }
        var sum: Float = 0
        for s in samples { sum += s * s }
        return 10 * log10(max(1e-12, sum / Float(samples.count)))
    }
    static func level(_ samples: [Float]) -> Float { samples.withUnsafeBufferPointer { level($0) } }
    /// 麥克風的緩衝：取第一聲道
    static func level(_ b: AVAudioPCMBuffer) -> Float {
        let n = Int(b.frameLength)
        if let f = b.floatChannelData { return level(UnsafeBufferPointer(start: f[0], count: n)) }
        if let i = b.int16ChannelData {
            var sum: Float = 0
            for k in 0..<n { let s = Float(i[0][k]) / 32768; sum += s * s }
            return n == 0 ? -120 : 10 * log10(max(1e-12, sum / Float(n)))
        }
        return -120
    }
}

// MARK: - 一輪一輪的狀態機

/// 時間由外面給（selftest 用假時鐘）。回傳要做的動作，控制器照做。
struct ClioVoiceLoop: Equatable {
    enum Mode: Equatable { case pushToTalk, handsFree }
    enum State: Equatable {
        case off                        // 麥克風關著
        case listening(Mode)            // 這一輪在聽、在轉寫
        case finishing                  // 講完了，等轉寫收尾
        case waiting                    // 已送出，等模型（不聽）
        case speaking                   // 念回答；只看音量有沒有人插話
        case bargeCheck                 // 念的時候有聲音：先轉寫看看，不是回音才打斷
        case followUp(until: Double)    // 回答完再聽一會兒，開口就是下一輪
    }
    enum Action: Equatable {
        case openMic, closeMic
        case beginTurn, endTurn, cancelTurn
        case interrupt                  // 停止朗讀、停掉還在串流的回答
        case submit                     // 把這輪的字交給引擎
    }

    static let tapThreshold = 0.35      // 按住超過這麼久＝按著說
    static let followUpWindow = 8.0
    static let noSpeechTimeout = 6.0    // 免按住但一直沒開口
    static let maxTurn = 30.0
    static let maxWait = 90.0           // 等模型等太久（沒有新階段）：放掉麥克風

    var state = State.off
    var followUpEnabled = true
    private(set) var pressAt = -1.0
    private(set) var turnAt = -1.0
    private(set) var heard = false
    private(set) var waitAt = -1.0

    var micOpen: Bool { state != .off }
    var listening: Bool { if case .listening = state { return true }; return state == .finishing }

    /// 跟進還剩幾秒（畫「还在听…（8 秒）」）
    func followUpRemaining(_ now: Double) -> Int? {
        guard case .followUp(let until) = state else { return nil }
        return max(1, Int(ceil(until - now)))
    }

    private mutating func begin(_ mode: Mode, now: Double, heard h: Bool = false) {
        state = .listening(mode); turnAt = now; heard = h
    }

    /// F5 按下（或點彩球的按下）
    mutating func press(now: Double) -> [Action] {
        pressAt = now
        switch state {
        case .off: begin(.pushToTalk, now: now); return [.openMic, .beginTurn]
        case .followUp: begin(.pushToTalk, now: now); return [.beginTurn]
        case .speaking, .waiting: begin(.pushToTalk, now: now); return [.interrupt, .beginTurn]
        case .bargeCheck: begin(.pushToTalk, now: now); return [.interrupt, .cancelTurn, .beginTurn]
        case .listening(.handsFree):   // 免按住時再按一下＝我講完了
            pressAt = -1; state = .finishing; return [.endTurn]
        case .listening(.pushToTalk), .finishing: return []
        }
    }

    /// F5 放開：按得短＝點一下，換成免按住；按得久＝這一輪結束
    mutating func release(now: Double) -> [Action] {
        guard pressAt >= 0, case .listening(.pushToTalk) = state else { pressAt = -1; return [] }
        defer { pressAt = -1 }
        if now - pressAt >= Self.tapThreshold { state = .finishing; return [.endTurn] }
        state = .listening(.handsFree); turnAt = now
        return []
    }

    /// 點卡片上的彩球（或從頂端往下拉）：直接免按住
    mutating func tapOrb(now: Double) -> [Action] {
        if case .listening(.pushToTalk) = state { return [] }   // F5 正按著：照按著說
        let a = press(now: now)
        if case .listening(.pushToTalk) = state { state = .listening(.handsFree); pressAt = -1 }
        return a
    }

    /// VAD：開口了
    mutating func onset(now: Double) -> [Action] {
        switch state {
        case .followUp: begin(.handsFree, now: now, heard: true); return [.beginTurn]
        case .speaking: state = .bargeCheck; turnAt = now; heard = true; return [.beginTurn]
        case .listening: heard = true; return []
        default: return []
        }
    }

    /// 念的時候聽到的字：不是回音就打斷朗讀，這一輪繼續聽
    mutating func voiceText(isEcho: Bool) -> [Action] {
        guard state == .bargeCheck, !isEcho else { return [] }
        state = .listening(.handsFree)
        return [.interrupt]
    }

    /// VAD：停頓 0.7 秒
    mutating func endpoint(now: Double) -> [Action] {
        switch state {
        case .listening(.handsFree) where heard: state = .finishing; return [.endTurn]
        case .bargeCheck: state = .speaking; heard = false; return [.cancelTurn]   // 只是回音或雜音
        default: return []
        }
    }

    /// 轉寫收尾回來了：有字就送出，沒字就收麥克風
    mutating func turnDone(text: String, now: Double) -> [Action] {
        guard state == .finishing || listening else { return [] }
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { state = .off; return [.closeMic] }
        state = .waiting; waitAt = now
        return [.submit]
    }

    /// 開始念回答
    mutating func answerSpeaking() { if state == .waiting { state = .speaking } }

    /// 回答（含朗讀）結束：再聽一會兒，或收麥克風
    mutating func answerDone(now: Double) -> [Action] {
        switch state {
        case .waiting, .speaking:
            if followUpEnabled { state = .followUp(until: now + Self.followUpWindow); heard = false; return [] }
            state = .off; return [.closeMic]
        case .bargeCheck:   // 念完了、人還在講：這就是下一輪
            state = .listening(.handsFree)
            return []
        default: return []
        }
    }

    /// 每幀：跟進時間到、一直沒開口、講太久
    mutating func tick(now: Double) -> [Action] {
        switch state {
        case .followUp(let until) where now >= until: state = .off; return [.closeMic]
        case .listening(.handsFree) where !heard && now - turnAt >= Self.noSpeechTimeout:
            state = .off; return [.cancelTurn, .closeMic]
        case .listening where now - turnAt >= Self.maxTurn: state = .finishing; return [.endTurn]
        case .waiting where now - waitAt >= Self.maxWait: state = .off; return [.closeMic]
        default: return []
        }
    }

    /// Esc、收起卡片、CarPlay 要用麥克風
    mutating func cancel() -> [Action] {
        guard state != .off else { return [] }
        let a: [Action] = [.cancelTurn, .interrupt, .closeMic]
        state = .off; pressAt = -1; heard = false
        return a
    }
}

// MARK: - 回音

/// 念回答時聽到的字是不是自己的回音：聽到的字兩兩一組，一半以上出現在正在念的文字裡就當回音。
/// 太短（不到 2 個字）還看不出來，也當回音，等多一點字再說。
enum ClioEcho {
    static func normalize(_ s: String) -> [Character] {
        Array(s.lowercased().filter { $0.isLetter || $0.isNumber })
    }
    static func isEcho(heard: String, spoken: String) -> Bool {
        let h = normalize(heard)
        guard h.count >= 2 else { return true }
        let sp = normalize(spoken)
        guard sp.count >= 2 else { return false }
        var pairs = Set<String>()
        for i in 0..<(sp.count - 1) { pairs.insert(String(sp[i...i + 1])) }
        var hit = 0
        for i in 0..<(h.count - 1) where pairs.contains(String(h[i...i + 1])) { hit += 1 }
        return Double(hit) / Double(h.count - 1) >= 0.5
    }
}

// MARK: - 口說的「好／取消」

extension ClioConfirm {
    /// 轉寫出來的話：去掉所有標點空白、語尾助詞、重複（「好好好」「好的。」「OK.」「Yes, please」）
    static func classifySpoken(_ text: String) -> Answer {
        let direct = classify(text)
        if direct != .other { return direct }
        let t = text.lowercased().filter { $0.isLetter || $0.isNumber }
        // 原句、去掉一個語尾、疊字縮成一個（好好好 → 好）
        var cands = [t]
        for tail in ["please", "thanks", "thankyou", "啊", "呀", "吧", "喔", "哦", "啦", "嘛", "了"] where t.count > tail.count && t.hasSuffix(tail) {   // l10n-ignore：比對用詞
            cands.append(String(t.dropLast(tail.count)))
        }
        for c in cands { if let f = c.first, c.count > 1, c.allSatisfy({ $0 == f }) { cands.append(String(f)) } }
        let yes: Set<String> = ["好", "好的", "可以", "ok", "okay", "yes", "yeah", "sure", "確定", "确定", "對", "对", "要", "好啊", "沒問題", "没问题"]   // l10n-ignore：比對用詞
        let no: Set<String> = ["取消", "不要", "不用", "算了", "no", "nope", "cancel", "dont", "nothanks", "不", "先不要"]   // l10n-ignore：比對用詞
        if cands.contains(where: { no.contains($0) }) { return .no }
        if cands.contains(where: { yes.contains($0) }) { return .yes }
        return .other
    }
}

// MARK: - 語言

enum ClioSpeechLocale {
    /// 介面語言 → 聽寫語系（繁中用台灣的模型）
    static func identifier(for lang: PetLanguage) -> String {
        switch lang {
        case .zhHant: return "zh_TW"
        case .zhHans: return "zh_CN"
        case .en: return "en_US"
        }
    }
    static var current: Locale { Locale(identifier: identifier(for: L10n.language)) }
}
