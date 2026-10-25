// ClioTalk 語音的 --selftest（離線、不開麥克風）：合成的音訊（安靜／說話／安靜）跑 VAD、口說的「好／取消」、
// 回答完再聽 8 秒的狀態機、說話打斷朗讀、回音判斷、聽寫語系。

import Foundation

enum ClioVoiceSelftest {
    static func run(_ check: (Bool, String) -> Void) {
        vad(check); confirm(check); loop(check); bargeIn(check)
        let ids = [PetLanguage.zhHant, .zhHans, .en].map(ClioSpeechLocale.identifier(for:))
        check(ids == ["zh_TW", "zh_CN", "en_US"], "語音：介面語言對到聽寫語系")
    }

    // MARK: VAD：合成的緩衝

    /// 48 kHz、每段 2048 個取樣；回傳每段的（開始時間, 事件）
    private static func runVAD(_ segments: [(seconds: Double, amp: Float)], strict: Bool = false) -> [(Double, ClioVAD.Event)] {
        var vad = ClioVAD()
        vad.strict = strict
        let rate = 48_000.0, n = 2048
        var seed: UInt32 = 12345
        func noise() -> Float { seed = seed &* 1_664_525 &+ 1_013_904_223; return Float(seed >> 8) / Float(1 << 24) * 2 - 1 }
        var samples: [Float] = []
        var t = 0.0
        for seg in segments {
            for _ in 0..<Int(seg.seconds * rate) {
                // 說話：220 Hz＋音節起伏（每秒 4 次，不會掉到 0）；安靜：很小的雜訊
                let speech = seg.amp * Float(sin(2 * .pi * 220 * t) * (0.6 + 0.4 * sin(2 * .pi * 4 * t)))
                samples.append(speech + 0.0005 * noise())
                t += 1 / rate
            }
        }
        var out: [(Double, ClioVAD.Event)] = []
        var i = 0
        while i + n <= samples.count {
            let db = ClioVAD.level(Array(samples[i..<(i + n)]))
            if let e = vad.feed(db: db, duration: Double(n) / rate) { out.append((Double(i + n) / rate, e)) }
            i += n
        }
        return out
    }

    private static func vad(_ check: (Bool, String) -> Void) {
        // 安靜 1 秒 → 說 0.8 秒 → 停 0.3 秒（換氣）→ 再說 0.6 秒 → 安靜 1.5 秒
        let ev = runVAD([(1.0, 0), (0.8, 0.2), (0.3, 0), (0.6, 0.2), (1.5, 0)])
        let onsets = ev.filter { $0.1 == .onset }, ends = ev.filter { $0.1 == .endpoint }
        check(onsets.count == 1 && (1.1...1.35).contains(onsets[0].0), "VAD：開口 0.15 秒內報一次（\(onsets.map(\.0))）")
        let speechEnd = 2.7
        check(ends.count == 1 && (speechEnd + 0.65...speechEnd + 0.85).contains(ends[0].0), "VAD：換氣不算講完，停頓 0.7 秒才算（\(ends.map(\.0))）")
        check(runVAD([(3, 0)]).isEmpty, "VAD：一直安靜什麼都不報")
        // 一直都有的吵雜（風扇）：開麥克風時量進噪音底，不算開口
        check(runVAD([(3, 0.02)]).isEmpty, "VAD：穩定的環境聲不算說話")
        // 念回答時：小聲（像喇叭回音）不算，大聲才算
        check(runVAD([(1, 0), (1, 0.01)], strict: true).isEmpty && !runVAD([(1, 0), (1, 0.01)]).isEmpty, "VAD：念回答時門檻拉高，小聲回音不觸發")
        check(runVAD([(1, 0), (1, 0.2)], strict: true).first?.1 == .onset, "VAD：念回答時大聲說話仍然觸發")
    }

    // MARK: 口說的「好／取消」

    private static func confirm(_ check: (Bool, String) -> Void) {
        let yes = ["好", "好的。", "可以", "OK.", "Okay", "yes", "Yes, please.", "好好好", "好啊", "確定", "Sure"]   // l10n-ignore：測試樣本
        let no = ["取消", "不要。", "不要了", "No.", "no thanks", "算了吧", "Cancel", "先不要"]   // l10n-ignore：測試樣本
        let other = ["好，改到中午", "明天提醒我買花", "OK Google", "不好意思"]   // l10n-ignore：測試樣本
        let badYes = yes.filter { ClioConfirm.classifySpoken($0) != .yes }
        let badNo = no.filter { ClioConfirm.classifySpoken($0) != .no }
        let badOther = other.filter { ClioConfirm.classifySpoken($0) != .other }
        check(badYes.isEmpty, "語音確認：好／好的／可以／OK／yes（\(badYes)）")
        check(badNo.isEmpty, "語音確認：取消／不要／no（\(badNo)）")
        check(badOther.isEmpty, "語音確認：帶了別的內容就不算（\(badOther)）")
    }

    // MARK: 一輪一輪、跟進 8 秒

    private static func loop(_ check: (Bool, String) -> Void) {
        var l = ClioVoiceLoop()
        check(l.press(now: 0) == [.openMic, .beginTurn] && l.state == .listening(.pushToTalk), "語音：F5 按下開麥克風、開始這一輪")
        check(l.release(now: 0.1) == [] && l.state == .listening(.handsFree), "語音：點一下＝免按住")
        check(l.endpoint(now: 1) == [] && l.state == .listening(.handsFree), "語音：還沒開口不會因為安靜就送出")
        _ = l.onset(now: 1.2)
        check(l.endpoint(now: 2.5) == [.endTurn] && l.state == .finishing, "語音：開口後停頓＝講完")
        check(l.turnDone(text: "这周有谁生日", now: 2.8) == [.submit] && l.state == .waiting, "語音：有字就送出")   // l10n-ignore：測試樣本
        l.answerSpeaking()
        check(l.state == .speaking, "語音：開始念回答")
        check(l.answerDone(now: 5) == [] && l.state == .followUp(until: 13), "語音：念完再聽 8 秒")
        check(l.followUpRemaining(5.2) == 8 && l.followUpRemaining(12.5) == 1, "語音：倒數 8 → 1 秒")
        check(l.tick(now: 12.9) == [] && l.micOpen, "語音：8 秒內麥克風開著")
        check(l.tick(now: 13.01) == [.closeMic] && l.state == .off, "語音：8 秒到了收麥克風")

        var f = ClioVoiceLoop()
        _ = f.press(now: 0); _ = f.release(now: 0.1); _ = f.onset(now: 0.5); _ = f.endpoint(now: 2); _ = f.turnDone(text: "x", now: 2.2)
        _ = f.answerDone(now: 4)
        check(f.onset(now: 6) == [.beginTurn] && f.state == .listening(.handsFree) && f.heard, "語音：跟進時一開口就是下一輪（不用按 F5）")
        var g = ClioVoiceLoop()
        g.followUpEnabled = false
        _ = g.press(now: 0); _ = g.release(now: 2); _ = g.turnDone(text: "x", now: 2.2)
        check(g.answerDone(now: 4) == [.closeMic] && g.state == .off, "語音：設定關掉跟進就直接收麥克風")

        var h = ClioVoiceLoop()
        _ = h.press(now: 0)
        check(h.release(now: 1.0) == [.endTurn] && h.state == .finishing, "語音：按住說話，放開就結束這一輪")
        check(h.turnDone(text: " ", now: 1.2) == [.closeMic] && h.state == .off, "語音：沒聽到字就收麥克風、不送出")
        var k = ClioVoiceLoop()
        _ = k.tapOrb(now: 0)
        check(k.state == .listening(.handsFree), "語音：點彩球＝免按住")
        check(k.tick(now: 6.1) == [.cancelTurn, .closeMic] && k.state == .off, "語音：免按住 6 秒沒開口就放掉麥克風")
        var m = ClioVoiceLoop()
        _ = m.tapOrb(now: 0); _ = m.onset(now: 0.3)
        check(m.press(now: 2) == [.endTurn] && m.state == .finishing, "語音：免按住時再按 F5＝講完了")
        check(m.cancel() == [.cancelTurn, .interrupt, .closeMic] && m.state == .off && m.cancel().isEmpty, "語音：Esc／CarPlay 放掉一切，再取消不重複")
    }

    // MARK: 說話打斷朗讀

    private static func bargeIn(_ check: (Bool, String) -> Void) {
        var l = ClioVoiceLoop()
        _ = l.press(now: 0); _ = l.release(now: 1); _ = l.turnDone(text: "x", now: 1.2)
        l.answerSpeaking()
        check(l.onset(now: 2) == [.beginTurn] && l.state == .bargeCheck, "插話：念的時候有聲音，先轉寫看看")
        check(l.voiceText(isEcho: true) == [] && l.state == .bargeCheck, "插話：聽到的是自己念的字，不停")
        check(l.endpoint(now: 3) == [.cancelTurn] && l.state == .speaking, "插話：只是回音，丟掉這輪繼續念")
        _ = l.onset(now: 4)
        check(l.voiceText(isEcho: false) == [.interrupt] && l.state == .listening(.handsFree), "插話：真的有人說話，立刻停止朗讀")
        check(l.endpoint(now: 5) == [.endTurn], "插話：說完就送出這一輪")

        var p = ClioVoiceLoop()
        _ = p.press(now: 0); _ = p.release(now: 1); _ = p.turnDone(text: "x", now: 1.2); p.answerSpeaking()
        check(p.press(now: 3) == [.interrupt, .beginTurn] && p.state == .listening(.pushToTalk), "插話：念的時候按 F5 立刻停")
        var q = ClioVoiceLoop()
        _ = q.press(now: 0); _ = q.release(now: 1); _ = q.turnDone(text: "x", now: 1.2); q.answerSpeaking(); _ = q.onset(now: 2)
        check(q.answerDone(now: 2.5) == [] && q.state == .listening(.handsFree), "插話：念完時人還在講，就接成下一輪")

        let spoken = "这周有两个生日：周二 10月27日：朋友 A 生日"   // l10n-ignore：測試樣本
        check(ClioEcho.isEcho(heard: "这周有两个生日", spoken: spoken) && ClioEcho.isEcho(heard: "周", spoken: spoken), "回音：跟念的字一樣（或太短）當回音")   // l10n-ignore：測試樣本
        check(!ClioEcho.isEcho(heard: "等一下先停", spoken: spoken) && !ClioEcho.isEcho(heard: "wait stop", spoken: "It is sunny today."), "回音：不一樣的話就是插話")   // l10n-ignore：測試樣本
    }
}
