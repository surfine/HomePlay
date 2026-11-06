// 跟唱：全螢幕的跟唱歌詞。目前那句放大置中、唱到哪裡就從左往右掃亮；上一句、下兩句小一號淡在上下。
// 歌詞與正在播放都沿用既有來源：NowPlayingPage（Mac／iPhone 的正在播放）與 LyricsStore（同一條歌詞來源鏈、同一份快取），
// 不另外找歌詞。逐字時間：歌詞行裡帶 <mm:ss.xx> 逐字標籤就照標籤；沒有就按行內字數平均推估（中日韓字一字一拍，英文按字母）。
// 人聲減弱：Mac 上沒有公開的人聲分離 API，不做，畫面上也不放這顆按鈕。
// 快照旗標：--demo-sing [lyrics|word|plain|none|loading|idle]（自己寫的示範歌詞，不連網、不讀真的正在播放）

import AppKit

extension HPTokens {
    /// 跟唱（8-pt 網格）：目前那句 SF Pro bold 80、列高 104；上下句 48、列高 64；左緣對內容邊線
    enum Sing {
        static let x: CGFloat = HPTokens.Space.margin
        static var width: CGFloat { 1024 - 2 * x }
        static let currentSize: CGFloat = 80
        static let currentLine: CGFloat = 104
        static let sideSize: CGFloat = 48
        static let sideLine: CGFloat = 64
        /// 句與句之間
        static let gap: CGFloat = 48
        /// 目前那句的垂直中心（略高於畫面中心，底下留給歌名）
        static let centerY: CGFloat = 480
        /// 還沒唱到的字、上下句的透明度（增加對比時提高）
        static var restAlpha: CGFloat { HPAccessibility.increaseContrast ? 0.6 : 0.4 }
        static var sideAlpha: CGFloat { HPAccessibility.increaseContrast ? 0.7 : 0.45 }
        static let captionBaseline: CGFloat = 968
        static let captionSize: CGFloat = 32
        /// 掃色每秒最多重畫 30 次（字在動，但不必滿幀）
        static let frameInterval = 1.0 / 30
    }
}

/// 一行歌詞的逐字時間（純邏輯，selftest 直接驗）
struct SingLine: Equatable {
    var text: String                       // 拿掉逐字標籤之後要顯示的字
    var start: Double
    /// 關鍵點：(第幾個字之前, 秒)；第一個是 (0, start)、最後一個是 (字數, 唱完)。兩點之間照字的權重平均分
    var keys: [(index: Int, time: Double)]
    static func == (a: Self, b: Self) -> Bool {
        a.text == b.text && a.start == b.start && a.keys.map(\.index) == b.keys.map(\.index) && a.keys.map(\.time) == b.keys.map(\.time)
    }
}

enum SingTiming {
    /// 一個字唱多久（推估用）：中日韓字一拍、英文字母約四分之一拍、空白和標點幾乎不佔時間
    static func weight(_ c: Character) -> Double {
        if c.isWhitespace { return 0.15 }
        if c.isPunctuation || c.isSymbol { return 0.1 }
        if let u = c.unicodeScalars.first?.value, u >= 0x2E80 { return 1 }
        return 0.25
    }
    /// 一拍幾秒（推估：一般流行歌每個中文字約 0.4 秒）
    static let beat = 0.42

    /// 拿掉 <mm:ss.xx> 逐字標籤；回傳 (字, 每個標籤落在第幾個字之前與它的秒數)
    static func stripTags(_ s: String) -> (text: String, tags: [(index: Int, time: Double)]) {
        var out = "", tags: [(Int, Double)] = []
        var rest = Substring(s)
        while let open = rest.firstIndex(of: "<") {
            out += rest[..<open]
            guard let close = rest[open...].firstIndex(of: ">"), let t = LRC.time(rest[rest.index(after: open)..<close]) else {
                out += rest[open...open]; rest = rest[rest.index(after: open)...]; continue
            }
            tags.append((out.count, t))
            rest = rest[rest.index(after: close)...]
        }
        out += rest
        let text = out.trimmingCharacters(in: .whitespaces)
        let lead = out.prefix { $0 == " " }.count
        return (text, tags.map { (index: max(0, min(text.count, $0.0 - lead)), time: $0.1) })
    }

    /// 第 i 行的逐字時間；next＝下一行開始（沒有就 songEnd，再沒有就 +4 秒）
    static func line(_ lines: [Lyrics.Line], _ i: Int, songEnd: Double) -> SingLine? {
        guard lines.indices.contains(i) else { return nil }
        let l = lines[i]
        let (text, tags) = stripTags(l.text)
        let next = i + 1 < lines.count ? lines[i + 1].time : (songEnd > l.time ? songEnd : l.time + 4)
        let span = max(0.3, next - l.time)
        let n = text.count
        if tags.count >= 2 {   // 逐字標籤：照標籤（最後一個標籤之後的字唱到下一行前）
            var keys = [(index: 0, time: l.time)]
            for t in tags where t.index > keys.last!.index && t.time >= keys.last!.time { keys.append((t.index, t.time)) }
            if keys.last!.index < n { keys.append((n, max(keys.last!.time + 0.2, min(next, keys.last!.time + Double(n - keys.last!.index) * beat)))) }
            return SingLine(text: text, start: l.time, keys: keys)
        }
        // 推估：照字的權重算要唱多久；下一行離得不遠就唱滿（留 5%），離得很遠（間奏）就照推估再寬一點
        let est = text.reduce(0) { $0 + weight($1) } * beat
        let sung = span <= est * 2 ? span * 0.95 : max(1, est * 1.3)
        return SingLine(text: text, start: l.time, keys: [(0, l.time), (n, l.time + max(0.3, sung))])
    }

    /// t 秒時唱到第幾個字（可以是小數：那個字唱了一部分）
    static func position(_ s: SingLine, at t: Double) -> Double {
        let chars = Array(s.text)
        guard let first = s.keys.first, let last = s.keys.last, !chars.isEmpty else { return 0 }
        if t <= first.time { return 0 }
        if t >= last.time { return Double(chars.count) }
        for (a, b) in zip(s.keys, s.keys.dropFirst()) where t < b.time {
            let f = (t - a.time) / max(0.001, b.time - a.time)
            // a…b 之間照權重分
            let ws = chars[a.index..<b.index].map(weight)
            let total = ws.reduce(0, +)
            guard total > 0 else { return Double(a.index) + f * Double(b.index - a.index) }
            var want = f * total, i = a.index
            for w in ws {
                if want < w { return Double(i) + want / w }
                want -= w; i += 1
            }
            return Double(b.index)
        }
        return Double(chars.count)
    }
}

final class SingApp: PetApp {
    static let shared = SingApp()
    let id = "sing"
    var title: String { L("app.sing", "跟唱") }
    let icon = AppIcon(color: srgb(0xFF2D55), symbol: "music.mic")
    typealias T = HPTokens.Sing

    private weak var face: Face?
    /// 示範：nil＝真的；其他見檔頭
    private var demo: String?
    private var shownIndex = Int.min
    private var shift = Anim(0, spring: HPTokens.Lyrics.scrollSpring, name: "sing.shift")
    private var shiftStep: CGFloat = 0
    private var lastFrame = 0.0
    private var openButton = CGRect.zero
    private var blurKey: ObjectIdentifier?
    private var blurImage: CGImage?

    var showsClock: Bool { false }

    func didOpen(now: Double) { shownIndex = Int.min; shift.set(0, now: now) }

    // MARK: 資料

    private func current(_ face: Face) -> (info: NowPlayingInfo, source: NowPlayingPage.Source)? {
        // 快照隱私：沒有給示範資料就當作沒在播（不讀真的正在播放）
        if SnapshotPrivacy.active, NowPlayingPage.shared.demo == nil { return nil }
        if demo == "idle" { return nil }
        return NowPlayingPage.shared.state(face: face)
    }
    private func lyricsState(_ i: NowPlayingInfo) -> LyricsStore.State {
        if demo == "loading" { return .loading }
        if let d = NowPlayingPage.shared.demo { return d.lyrics.map { .ready($0) } ?? .notFound }
        return LyricsStore.shared.state(title: i.title, artist: i.artist, duration: i.duration)
    }
    private func position(_ i: NowPlayingInfo, now: Double) -> Double {
        NowPlayingLogic.progress(i, now: now).map { $0 * i.duration } ?? i.position
    }

    func tick(_ now: Double) -> Bool {
        if HPComponents.needsFrame(now) { return true }
        guard let face, let s = current(face) else { return false }
        if !shift.done(now) { return true }
        // 播放中掃色：30 fps；暫停或沒有同步歌詞：每秒一次就夠（讀取中→讀到歌詞的切換）
        let fast = s.info.playing && !s.info.fixed
        let interval = fast ? T.frameInterval : 1
        if now - lastFrame >= interval { lastFrame = now; return true }
        return false
    }

    // MARK: 畫

    func render(into g: CGContext, face: Face, rect: CGRect, now: Double) {
        self.face = face
        openButton = .zero
        guard let s = current(face) else { drawBackdrop(g, face, info: nil); drawIdle(g, face); return }
        let i = s.info
        drawBackdrop(g, face, info: i)
        let st = lyricsState(i)
        guard case .ready(let l) = st, !l.instrumental, !l.synced.isEmpty else {
            let msg: String
            switch st {
            case .loading: msg = L("lyrics.loading", "正在载入歌词…")
            case .ready(let l) where l.instrumental: msg = L("lyrics.instrumental", "纯音乐，没有歌词")
            case .ready(let l) where !l.plain.isEmpty: msg = L("sing.plainOnly", "这首歌的歌词没有时间轴，没法跟唱")
            case .off: msg = L("lyrics.off", "歌词已在设置里关闭")
            case .failed: msg = L("lyrics.failed", "暂时读不到歌词")
            default: msg = L("lyrics.none", "这首歌没有歌词")
            }
            drawMessage(g, face, symbol: st == .loading ? "ellipsis" : "music.mic", title: msg, body: nil)
            drawCaption(g, face, i)
            return
        }
        drawLyrics(g, face, l, at: position(i, now: now), songEnd: i.duration, now: now)
        drawCaption(g, face, i)
    }

    /// 封面糊掉當底（減少透明度：不用糊的封面，換成封面的兩色漸層）；再壓暗，白字才讀得清楚
    private func drawBackdrop(_ g: CGContext, _ face: Face, info: NowPlayingInfo?) {
        let full = MediaUI.full
        let art = info == nil ? nil : NowPlayingPage.shared.artwork(face: face)
        if let a = art, !HPAccessibility.reduceTransparency {
            if blurKey != ObjectIdentifier(a) { blurKey = ObjectIdentifier(a); blurImage = MediaUI.blurred(a) }
            if let b = blurImage { MediaUI.drawCover(g, face: face, b, in: full) }
        } else if let info {
            let (a, b) = MediaUI.gradient(for: info.title + info.artist); MediaUI.fillGradient(g, full, a, b)
        } else {
            g.setFillColor(srgb(0x1c1c1e).cgColor); g.fill(full)
        }
        g.setFillColor(NSColor(white: 0, alpha: HPAccessibility.increaseContrast ? 0.55 : 0.38).cgColor); g.fill(full)
    }

    private var curFont: NSFont { HPType.sf(T.currentSize, .bold) }
    private var sideFont: NSFont { HPType.sf(T.sideSize, .bold) }

    /// 一句折成幾列，每列從第幾個字開始（掃色要對回原文的字）
    private func rows(_ text: String, _ font: NSFont) -> [(text: String, start: Int)] {
        let shown = text.isEmpty ? HPTokens.Lyrics.gapMark : text
        let wrapped = MediaUI.wrap(shown, font, T.width, maxLines: 3)
        let chars = Array(shown)
        var out: [(String, Int)] = [], cursor = 0
        for w in wrapped {
            let wc = Array(w)
            var at = cursor
            while at < chars.count, chars[at] == " " { at += 1 }
            if at + wc.count <= chars.count, Array(chars[at..<(at + wc.count)]) == wc { out.append((w, at)); cursor = at + wc.count }
            else { out.append((w, cursor)); cursor += wc.count }   // 尾巴縮成「…」的那列：照順序接上
        }
        return out
    }

    private func drawLyrics(_ g: CGContext, _ face: Face, _ l: Lyrics, at pos: Double, songEnd: Double, now: Double) {
        let lines = l.synced
        let idx = LRC.index(lines, at: pos + HPTokens.Lyrics.lead)
        let curRows = idx >= 0 ? rows(SingTiming.stripTags(lines[idx].text).text, curFont) : []
        // 換句：整組往上滑一句（減少動態效果：直接換）
        if idx != shownIndex {
            if shownIndex != Int.min, idx == shownIndex + 1, !HPMotion.reduceMotion {
                shiftStep = CGFloat(max(1, curRows.count)) * T.sideLine + T.gap
                shift.set(1, now: now); shift.retarget(0, now: now)
            } else { shift.set(0, now: now) }
            shownIndex = idx
        }
        let dy = shift.value(now) * shiftStep
        let blockH = CGFloat(max(1, curRows.count)) * T.currentLine
        let top = T.centerY - blockH / 2 + dy
        let white = NSColor.white

        // 上一句（只畫一句）
        if idx - 1 >= 0 {
            let r = rows(SingTiming.stripTags(lines[idx - 1].text).text, sideFont)
            var y = top - T.gap - CGFloat(r.count) * T.sideLine
            for row in r {
                face.drawLeft(g, row.text, font: sideFont, x: T.x, y: y + T.sideLine * 0.78, color: white.withAlphaComponent(T.sideAlpha * edge(y)))
                y += T.sideLine
            }
        }
        // 目前那句：先整句畫淡，再把唱到的部分（左邊）裁出來畫亮
        if idx >= 0, let sl = SingTiming.line(lines, idx, songEnd: songEnd) {
            let sungChars = SingTiming.position(sl, at: pos)
            var y = top
            for row in curRows {
                let base = y + T.currentLine * 0.78
                face.drawLeft(g, row.text, font: curFont, x: T.x, y: base, color: white.withAlphaComponent(T.restAlpha))
                let covered = sl.text.isEmpty ? 0 : max(0, min(Double(row.text.count), sungChars - Double(row.start)))
                if covered > 0 {
                    let rc = Array(row.text), whole = Int(covered)
                    var w = Typo.width(String(rc[..<whole]), curFont)
                    if whole < rc.count { w += Typo.width(String(rc[whole]), curFont) * CGFloat(covered - Double(whole)) }
                    g.saveGState(); g.clip(to: CGRect(x: T.x - 8, y: y, width: w + 8, height: T.currentLine))
                    face.drawLeft(g, row.text, font: curFont, x: T.x, y: base, color: white)
                    g.restoreGState()
                }
                y += T.currentLine
            }
            HPAX.note(g, CGRect(x: T.x, y: top, width: T.width, height: blockH), .text, sl.text.isEmpty ? L("sing.interlude", "间奏") : sl.text, shape: .rounded(24))
        } else if idx < 0, let first = lines.first {
            // 還沒到第一句：倒數提示（第一句淡淡預告在下面）
            let wait = max(0, first.time - pos)
            let s = wait >= 1 ? String(format: L("sing.startsIn", "%d 秒后开始"), Int(wait.rounded(.up))) : HPTokens.Lyrics.gapMark
            face.drawLeft(g, s, font: curFont, x: T.x, y: top + T.currentLine * 0.78, color: white.withAlphaComponent(T.restAlpha))
        }
        // 下兩句（越後面越淡）
        var y = top + blockH + T.gap
        for k in 1...2 where idx + k < lines.count && idx + k >= 0 {
            let r = rows(SingTiming.stripTags(lines[idx + k].text).text, sideFont)
            for row in r {
                let a = T.sideAlpha * (k == 1 ? 1 : 0.6) * edge(y)
                face.drawLeft(g, row.text, font: sideFont, x: T.x, y: y + T.sideLine * 0.78, color: white.withAlphaComponent(a))
                y += T.sideLine
            }
            y += T.gap
        }
    }

    /// 上下緣柔和淡出（藥丸底下、歌名上面）
    private func edge(_ y: CGFloat) -> CGFloat {
        min(1, max(0, (y - 120) / 96), max(0, (T.captionBaseline - 72 - y) / 96))
    }

    /// 底下一行：歌名 · 演出者
    private func drawCaption(_ g: CGContext, _ face: Face, _ i: NowPlayingInfo) {
        let f = HPType.sf(T.captionSize, .semibold)
        let s = i.artist.isEmpty ? i.title : "\(i.title) · \(i.artist)"
        face.drawSymbol(g, "music.mic", in: CGRect(x: T.x, y: T.captionBaseline - 32, width: 36, height: 36), color: NSColor.white.withAlphaComponent(0.7), weight: .semibold)
        face.drawLeft(g, Face.clipped(s, f, T.width - 56), font: f, x: T.x + 56, y: T.captionBaseline, color: NSColor.white.withAlphaComponent(HPAccessibility.increaseContrast ? 0.9 : 0.7))
    }

    private func drawMessage(_ g: CGContext, _ face: Face, symbol: String, title t: String, body: String?) {
        let c = CGRect(x: 512 - 64, y: 304, width: 128, height: 128)
        face.drawSymbol(g, symbol, in: c, color: NSColor.white.withAlphaComponent(0.8), weight: .regular)
        let f = AppUI.fitted(t, size: 48, weight: .bold, maxWidth: 840)
        AppUI.center(face, g, t, f, cx: 512, y: 528, .white)
        if let body {
            let bf = HPType.sf(32, .regular)
            for (k, line) in MediaUI.wrap(body, bf, 800, maxLines: 3).enumerated() {
                AppUI.center(face, g, line, bf, cx: 512, y: 592 + CGFloat(k) * 44, NSColor.white.withAlphaComponent(HPAccessibility.increaseContrast ? 0.85 : 0.65))
            }
        }
        HPAX.note(g, CGRect(x: 112, y: 300, width: 800, height: 340), .text, t, value: body, shape: .rounded(24))
    }

    private func drawIdle(_ g: CGContext, _ face: Face) {
        drawMessage(g, face, symbol: "music.mic", title: L("sing.idle.title", "没有在播放"),
                    body: L("sing.idle.body", "在 Mac 或 iPhone 上放一首歌，歌词会一句句亮起来"))
        openButton = AppUI.button(g, face, CGRect(x: 512 - 200, y: 760, width: 400, height: HPTokens.Size.pill), L("sing.openMusic", "打开音乐"), ink: .white)
    }

    // MARK: 輸入

    func handleTap(_ p: CGPoint, face: Face, now: Double) -> Bool {
        if openButton != .zero, AppUI.hit(openButton, p) {
            MainActor.assumeIsolated { (NSApp.delegate as? AppDelegate)?.view?.shellOpenApp("music") }
            return true
        }
        return false
    }

    // MARK: 示範

    /// --demo-sing：自己寫的示範歌詞與曲目（固定在第四句唱到一半）
    func applyDemo(_ mode: String?, face: Face) {
        self.face = face
        demo = mode ?? "lyrics"
        let words = ["Morning light on the windowsill", "Coffee cooling while the world is still", "I hum the tune you left behind",
                     "A little melody stuck in my mind", "So turn it up, let the kitchen sing", "Every small thing is a golden thing",
                     "We don't need much, just the afternoon", "And a song that ends a little too soon"]   // l10n-ignore：示範歌詞（自己寫的）
        var info = NowPlayingInfo(title: "Golden Hour", artist: "Mika Lindqvist", duration: 214, position: 81.2, playing: true, stamp: CACurrentMediaTime())   // l10n-ignore：示範曲目
        info.fixed = true
        var lyrics: Lyrics? = Lyrics(synced: words.enumerated().map { Lyrics.Line(time: 60 + Double($0.offset) * 6, text: $0.element) }, plain: [], instrumental: false)
        switch demo {
        case "word":   // 逐字標籤：「A little melody」唱得慢、「stuck in my mind」趕上
            lyrics?.synced[3].text = "<01:18.00>A <01:18.50>little <01:20.40>melody <01:22.80>stuck <01:23.00>in <01:23.20>my <01:23.40>mind"   // l10n-ignore：示範
        case "plain": lyrics = Lyrics(synced: [], plain: words, instrumental: false)
        case "none": lyrics = nil
        default: break
        }
        NowPlayingPage.shared.demo = NowPlayingPage.Demo(info: info, source: .phone, art: NowPlayingPage.demoArt(), lyrics: lyrics)
    }
}

enum SingSelfTest {
    static func run(_ check: (Bool, String) -> Void) {
        let lines = [Lyrics.Line(time: 10, text: "我在这里"), Lyrics.Line(time: 12, text: "Hello world"), Lyrics.Line(time: 40, text: "")]   // l10n-ignore：自檢
        // 推估：下一句離得近就唱滿 95%
        let a = SingTiming.line(lines, 0, songEnd: 60)!
        check(a.text == "我在这里" && a.keys.count == 2 && abs(a.keys[1].time - (10 + 2 * 0.95)) < 1e-9, "跟唱：下一句很近時唱滿這段時間")   // l10n-ignore：自檢
        check(SingTiming.position(a, at: 9) == 0 && SingTiming.position(a, at: 20) == 4 && abs(SingTiming.position(a, at: 10 + 0.95) - 2) < 1e-9,
              "跟唱：中文字平均分（一半時間唱到第二個字）")   // l10n-ignore
        // 推估：下一句離得很遠（間奏），只唱推估的長度，不拖滿 28 秒
        let b = SingTiming.line(lines, 1, songEnd: 60)!
        check(b.keys[1].time - 12 < 5, "跟唱：後面是間奏時照字數推估，不拖到下一句")
        // 英文：空白幾乎不佔時間，字母平均
        let half = SingTiming.position(b, at: (b.keys[0].time + b.keys[1].time) / 2)
        check(half > 4.5 && half < 6.5, "跟唱：英文一半時間大約唱到中間的字")
        // 逐字標籤
        let t = SingTiming.stripTags("<00:01.00>Hel<00:02.00>lo <00:03.00>you")
        check(t.text == "Hello you" && t.tags.map(\.index) == [0, 3, 6] && t.tags.map(\.time) == [1, 2, 3], "跟唱：逐字標籤拿掉、記住落在第幾個字")
        let tagged = SingTiming.line([Lyrics.Line(time: 1, text: "<00:01.00>Hel<00:02.00>lo <00:03.00>you"), Lyrics.Line(time: 5, text: "x")], 0, songEnd: 0)!
        check(tagged.keys.map(\.index) == [0, 3, 6, 9] && SingTiming.position(tagged, at: 2) == 3 && SingTiming.position(tagged, at: 1.5) > 0 && SingTiming.position(tagged, at: 1.5) < 3,
              "跟唱：有逐字標籤就照標籤掃色")   // l10n-ignore
        check(SingTiming.stripTags("a < b").text == "a < b", "跟唱：不是時間的角括號照原樣顯示")
        check(SingTiming.line(lines, 2, songEnd: 60)?.text == "" && SingTiming.line(lines, 3, songEnd: 60) == nil, "跟唱：空白行（間奏）與超出範圍")
        check(AppRegistry.app("sing") != nil && !PersonalGate.personalApps.contains("sing"), "跟唱：在 App 資料庫；不是個人內容")
    }
}
