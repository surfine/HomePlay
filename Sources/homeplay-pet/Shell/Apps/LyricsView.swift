// 2.0 第四輪 #8：歌詞模式（照官方 podcast-lyrics-art 中間那台）：
// 封面糊掉當底；歌詞左對齊、SF Pro bold；目前那句白色，其他句變暗、離越遠越糊；跟著播放進度用彈簧捲到目前那句。
// 沒有時間的純文字歌詞：整份照播放進度慢慢往上捲，不標目前句。
// 每一列字先畫成一張小圖、依模糊等級快取（捲動時不必每幀重算高斯模糊）。

import AppKit

final class LyricsView {
    typealias L = HPTokens.Lyrics
    private struct Row { var line: Int; var text: String; var top: CGFloat }
    private var rows: [Row] = []
    private var lineTop: [CGFloat] = []         // 每一句第一列的 top（相對於整份歌詞）
    private var contentHeight: CGFloat = 0
    private var key = ""
    private var scroll = Anim(0, spring: L.scrollSpring, name: "lyrics.scroll")
    private var current = Int.min
    private var cache: [String: CGImage] = [:]
    /// v2-music：上一幀畫出來的每一列（點一句跳過去用）；只有同步歌詞才記
    private var drawn: [(line: Int, rect: CGRect)] = []

    /// 點在 p 的那一句（同步歌詞；沒點到回 nil）
    func line(at p: CGPoint) -> Int? {
        drawn.first { $0.rect.insetBy(dx: 0, dy: -L.lineGap / 2).contains(p) }?.line
    }

    private static var font: NSFont { HPType.sf(L.size, .bold) }

    private func layout(_ lyrics: Lyrics, synced: Bool) {
        let k = "\(synced)|\(lyrics.synced.count)|\(lyrics.plain.count)|\(lyrics.synced.first?.text ?? lyrics.plain.first ?? "")|\(L10n.language)"
        guard k != key else { return }
        key = k; rows = []; lineTop = []; cache = [:]; current = Int.min
        let texts = synced ? lyrics.synced.map { $0.text.isEmpty ? L.gapMark : $0.text } : lyrics.plain
        var y: CGFloat = 0
        for (i, t) in texts.enumerated() {
            lineTop.append(y)
            if t.isEmpty { y += L.lineHeight * 0.6; continue }   // 純文字的空行＝段落間隔
            let wrapped = MediaUI.wrap(t, Self.font, L.width, maxLines: 6)
            for (j, w) in wrapped.enumerated() { rows.append(Row(line: i, text: w, top: y + CGFloat(j) * L.lineHeight)) }
            y += CGFloat(max(1, wrapped.count)) * L.lineHeight + L.lineGap
        }
        contentHeight = y
    }

    /// 一列字的圖（模糊等級 0…L.blurLevels）；整列寬 L.width + 邊距
    private func image(_ text: String, level: Int, face: Face) -> CGImage? {
        let ck = "\(level)|\(text)"
        if let c = cache[ck] { return c }
        let pad = Int(L.blurPad), w = Int(L.width) + pad * 2, h = Int(L.lineHeight) + pad * 2
        let f = Self.font
        let sharp = makeImage(w, h) { c in
            face.drawLeft(c, text, font: f, x: CGFloat(pad), y: CGFloat(pad) + L.lineHeight * 0.78, color: .white)
        }
        var out: CGImage? = sharp
        if level > 0 {
            let ci = CIImage(cgImage: sharp)
            let b = ci.clampedToExtent().applyingGaussianBlur(sigma: Double(level) * L.blurStep).cropped(to: ci.extent)
            out = Face.ciContext.createCGImage(b, from: ci.extent)
        }
        if cache.count > 400 { cache.removeAll() }
        cache[ck] = out
        return out
    }

    /// 還在捲（要重畫）
    func animating(_ now: Double) -> Bool { !scroll.done(now) }

    /// 畫歌詞；position＝目前秒數。region 之外的列不畫。
    func draw(_ g: CGContext, face: Face, lyrics: Lyrics, position: Double, duration: Double, now: Double, bottom: CGFloat = HPTokens.Lyrics.bottom) {
        let synced = !lyrics.synced.isEmpty
        layout(lyrics, synced: synced)
        let x = L.x
        if synced {
            let idx = LRC.index(lyrics.synced, at: position + L.lead)
            if idx != current {
                let target = idx < 0 ? -L.lineHeight : lineTop[min(idx, lineTop.count - 1)]
                if current == Int.min || HPMotion.reduceMotion { scroll.set(target, now: now) } else { scroll.retarget(target, now: now) }
                current = idx
            }
        } else {
            // 純文字：照進度慢慢捲（第一句在錨點，最後一句停在畫面中間）
            let p = duration > 0 ? CGFloat(max(0, min(1, position / duration))) : 0
            scroll.set(max(0, contentHeight - (L.bottom - L.anchor) * 0.5) * p, now: now)
        }
        let off = scroll.value(now)
        drawn = []
        for r in rows {
            let y = L.anchor + r.top - off
            guard y + L.lineHeight > L.top - 40, y < bottom + 40 else { continue }
            if synced, y + L.lineHeight > L.top, y < bottom { drawn.append((r.line, CGRect(x: x - 20, y: y, width: L.width + 40, height: L.lineHeight))) }
            let d = synced ? abs(r.line - current) : 0
            let alpha: CGFloat = synced ? (d == 0 ? 1 : max(L.minAlpha, L.nearAlpha - CGFloat(d - 1) * L.alphaStep)) : L.plainAlpha
            let level = synced ? min(L.blurLevels, d == 0 ? 0 : d) : 0
            // 上下緣柔和淡出
            let edge = min(1, max(0, (y - (L.top - 40)) / 120), max(0, ((bottom + 40) - y) / 160))
            if level == 0 {   // 清楚的那幾列直接畫字（不經點陣圖，字邊才銳利）
                face.drawLeft(g, r.text, font: Self.font, x: x, y: y + L.lineHeight * 0.78, color: NSColor.white.withAlphaComponent(alpha * edge))
                continue
            }
            guard let img = image(r.text, level: level, face: face) else { continue }
            g.saveGState(); g.setAlpha(alpha * edge)
            let pad = L.blurPad
            face.drawUpright(g, img, in: CGRect(x: x - pad, y: y - pad, width: L.width + pad * 2, height: L.lineHeight + pad * 2))
            g.restoreGState()
        }
    }
}
