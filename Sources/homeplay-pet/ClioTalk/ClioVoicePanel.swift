// ClioTalk 語音的畫面：2.0 R9 照官方影片——錶面模糊轉淺色，👀 膠囊下緣滴出一顆 195 px 的黑色玻璃水滴（送出後縮成 102 px、裡面一圈點轉著），
// 邊聽邊出字，還沒確定的字淡一點；最底下一行「放开 F5 或停顿一下就送出」，第一次用時是模型下載進度。
// 回答完再聽的「还在听…（8 秒）」畫在白卡的狀態列（ClioTalkPanel.swift）。
// 快照：--cliotalk-demo listening（聆聽畫面＋示範字）、--cliotalk-demo followup（白卡＋倒數）。

import AppKit

struct ClioVoiceView {
    enum Screen: Equatable { case card, listening, thinking }
    var screen = Screen.card
    var final = ""
    var volatile = ""
    var download: Double?
    var followUp: Int?
    var notice: String?
    var startedAt = 0.0
    var thinkAt = -1.0
    var note: String?           // 2.0: 「正在載入模型…」
    var handsFree = false       // 2.0 P10：免按住（從頂端滑下來、點彩球）：提示不提 F5
    var swipeIntro = false      // 2.0 P10：第一次從頂端滑下來
}

extension ClioVoiceView {
    /// 聆聽時最底下那一行：第一次從頂端滑下來＝怎麼叫出來；免按住＝停頓就送出；按住 F5＝放開或停頓（2026 與 1988 共用）
    var listenHint: String {
        swipeIntro ? L("clio.voice.swipeIntro", "从顶端往下滑就能叫 ClioTalk · 停顿就送出")
            : handsFree ? L("clio.voice.hintHandsFree", "停顿一下就送出 · 点一下屏幕也行")
            : L("clio.voice.hint", "放开 F5 或停顿一下就送出")
    }
}

extension ClioTalkPanel {
    static func voiceView(_ s: ClioSnapshot, _ now: Double) -> ClioVoiceView {
        var v = ClioVoiceView()
        if let d = demo {
            switch d {
            case "listening":
                v.screen = .listening
                v.final = L("clio.demo.listenFinal", "这周有谁生日？")
                v.volatile = L("clio.demo.listenVolatile", "还有要不要")
                v.startedAt = -10
            case "followup": v.followUp = 8
            default: break
            }
            return v
        }
        let c = ClioTalkController.shared, vs = c.voice
        v.notice = c.voiceNotice
        v.followUp = vs.loop.followUpRemaining(now)
        v.startedAt = vs.listenAt
        v.handsFree = vs.loop.state == .listening(.handsFree)
        v.swipeIntro = c.swipeIntro
        if let at = c.swipeDemoAt {   // 2.0 P10 快照：從頂端滑下來，在聽、還沒聽到字
            v.screen = .listening; v.startedAt = at; v.handsFree = true
            return v
        }
        if vs.loop.listening || (vs.download != nil && vs.loop.micOpen) {
            v.screen = .listening
            v.final = vs.liveFinal; v.volatile = vs.liveVolatile
            v.download = vs.download
        } else if vs.loop.state == .waiting, s.phase == .thinking, s.answer.isEmpty, vs.submittedAt > 0 {
            v.screen = .thinking
            v.final = s.question
            v.thinkAt = vs.submittedAt
            v.note = s.note
        }
        return v
    }
}

extension Face {
    /// 2.0 R9：底（模糊轉淺色的錶面）與水滴由 drawClioTalk 畫好；這裡只畫聽到的字與最底下的提示。top＝水滴下緣
    func drawClioListening(_ g: CGContext, _ now: Double, _ v: ClioVoiceView, top: CGFloat) {
        // 聽到的字：確定的用主文字色，還沒確定的淡一點；太長就留最後四行
        let left: CGFloat = 90, width: CGFloat = 1024 - 2 * left
        let f = FaceType.sf(72, .semibold, mono: false)
        let all = v.final + v.volatile
        var y: CGFloat = max(430, top + 110)
        let y0 = y   // 2.0 depth：VoiceOver 的字框從這裡起算
        if all.isEmpty {
            let placeholder = v.download != nil ? L("clio.voice.preparing", "准备语音输入…") : L("clio.voice.listening", "在听…")
            HPAX.note(g, CGRect(x: left, y: y - 76, width: width, height: 110), .text, placeholder)   // 2.0 depth：VoiceOver
            drawLeft(g, placeholder, font: f, x: left, y: y, color: HPTokens.tertiary)
        } else {
            let lines = Array(Face.clioWrap(all, f, width, maxLines: 100).suffix(4))
            let finalCount = v.final.count
            var cursor = all.startIndex
            for line in lines {
                let r = all.range(of: line, range: cursor..<all.endIndex) ?? (cursor..<cursor)
                let start = all.distance(from: all.startIndex, to: r.lowerBound)
                cursor = r.upperBound
                let solid = max(0, min(line.count, finalCount - start))
                let a = String(line.prefix(solid)), b = String(line.dropFirst(solid))
                if !a.isEmpty { drawLeft(g, a, font: f, x: left, y: y, color: HPTokens.label) }
                if !b.isEmpty {
                    drawLeft(g, b, font: f, x: left + (a.isEmpty ? 0 : Typo.width(a, f)), y: y, color: v.screen == .thinking ? HPTokens.label : HPTokens.tertiary)
                }
                y += 100
            }
            HPAX.note(g, CGRect(x: left, y: y0 - 76, width: width, height: max(110, y - y0 + 10)), .text, all)   // 2.0 depth：VoiceOver——聽到的字
        }

        // 最底下：下載進度，或怎麼送出
        let hf = FaceType.sf(39, .regular, mono: false)
        let hint: String
        if let p = v.download {
            hint = String(format: L("clio.voice.downloading", "正在下载语音模型… %d%%"), Int((p * 100).rounded()))
            let bar = CGRect(x: left, y: 1024 - 150, width: width, height: 12)
            g.setFillColor(HPTokens.fill.cgColor)
            g.addPath(CGPath(roundedRect: bar, cornerWidth: 6, cornerHeight: 6, transform: nil)); g.fillPath()
            let fill = CGRect(x: bar.minX, y: bar.minY, width: max(12, bar.width * CGFloat(min(1, max(0, p)))), height: bar.height)
            g.setFillColor(HPTokens.label.withAlphaComponent(0.8).cgColor)
            g.addPath(CGPath(roundedRect: fill, cornerWidth: 6, cornerHeight: 6, transform: nil)); g.fillPath()
        } else if v.screen == .thinking {
            hint = v.note ?? L("clio.status.thinking", "正在想…")
        } else {
            hint = v.listenHint
        }
        drawLeft(g, hint, font: hf, x: left, y: 1024 - 78, color: HPTokens.secondary)
        HPAX.note(g, CGRect(x: left, y: 1024 - 124, width: width, height: 60), .text, hint)   // 2.0 depth：VoiceOver

        // 在聽的時候整塊螢幕都能點：點一下＝講完了
        ClioTalkPanel.buttons = v.screen == .listening ? [(.listen, CGRect(x: 0, y: 0, width: 1024, height: 1024))] : []
    }
}
