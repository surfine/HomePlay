// 2.0 cc：長按模組長成的大卡（iOS／macOS 控制中心的模組展開），與「加入控制項目」圖庫。
//
// 大卡：從模組原本的框長到整個格子區（彈簧 ControlCenter.expandSpring，有一點點過衝），其他模組 materialize 退場；
// 大卡是一塊玻璃，裡面的列、晶片、配件磚都是填色（玻璃不疊玻璃）。內容在長到一半之後才淡入（iOS 的內容晚一拍）。
// 圖庫：從下緣升起的玻璃 sheet（四角跟螢幕同心），分類照 ControlCenter.app 的 BentoGallery；點一個就加到目前這頁。

import AppKit

extension ControlCenter {
    static func lerp(_ a: CGRect, _ b: CGRect, _ k: CGFloat) -> CGRect {
        CGRect(x: a.minX + (b.minX - a.minX) * k, y: a.minY + (b.minY - a.minY) * k,
               width: a.width + (b.width - a.width) * k, height: a.height + (b.height - a.height) * k)
    }

    static func drawExpanded(_ t: Tile, k: CGFloat, face: Face, now: Double) {
        let from = expandFrom, to = expandedRect
        let r = lerp(from, to, k)
        let s = size(t)
        let r0: CGFloat = s == .s4x1 ? wideRadius : (s == .s2x2 || s == .s4x2 ? squareRadius : from.height / 2)
        let rad = r0 + (squareRadius - r0) * max(0, min(1, k))
        let path = continuousRoundedRect(r, radius: rad)
        let contentA = max(0, min(1, (k - 0.4) / 0.5))
        HPGlass.add(path, interactive: false, union: nil, presence: 1) { c in
            c.saveGState(); c.addPath(path); c.clip()
            // 縮著時的內容先淡掉（跟著框走）
            if contentA < 1, k < 0.6 {
                c.saveGState(); c.setAlpha(max(0, 1 - k / 0.4))
                drawModule(c, t, from, s, face: face, now: now)
                c.restoreGState()
            }
            if contentA > 0 {
                c.setAlpha(contentA)
                // 內容照最後的大卡排、跟著框縮放（iOS：內容跟著卡一起長）
                let sx = r.width / to.width, sy = r.height / to.height
                c.translateBy(x: r.minX, y: r.minY); c.scaleBy(x: sx, y: sy); c.translateBy(x: -to.minX, y: -to.minY)
                drawExpandedContent(c, t, to, face: face, now: now, record: k > 0.95)
            }
            c.restoreGState()
        }
        if t.isSlider, k > 0.95 { addSliderKnob(t, CGRect(x: to.minX, y: to.minY, width: to.width, height: 200), .s4x1, big: true) }
    }

    /// 開關（填色軌道＋白旋鈕；不走 HPComponents.toggle，因為它按著時會在 flush 裡再加一塊玻璃）
    static func plainToggle(_ c: CGContext, _ r: CGRect, on: Bool) {
        let off = NSColor(srgbRed: 120 / 255, green: 120 / 255, blue: 128 / 255, alpha: HPGlass.inkIsLight ? 0.36 : 0.16)
        AppUI.fillPill(c, r, color: on ? HPTokens.green : off)
        let kh = r.height - 8, kw = kh * 1.3
        let k = CGRect(x: on ? r.maxX - 4 - kw : r.minX + 4, y: r.minY + 4, width: kw, height: kh)
        c.saveGState(); HPTokens.Shadow.knob.apply(c); AppUI.fillPill(c, k, color: .white); c.restoreGState()
    }

    // MARK: 大卡內容

    private static func header(_ c: CGContext, _ face: Face, _ E: CGRect, _ t: Tile, sub: String?, on: Bool) {
        let ink = HPGlass.ink
        let d = CGRect(x: E.minX + 40, y: E.minY + 40, width: 88, height: 88)
        let lightGlass = !HPGlass.inkIsLight
        let fill = on ? (lightGlass ? accent(t) : .white) : ink.withAlphaComponent(lightGlass ? 0.10 : 0.30)
        c.setFillColor(fill.cgColor); c.fillEllipse(in: d)
        drawGlyph(c, face, symbol(t), in: d.insetBy(dx: 24, dy: 24), color: on ? (lightGlass ? .white : accent(t)) : ink)
        let tf = HPType.sf(40, .bold)
        if let sub {
            face.drawLeft(c, title(t), font: tf, x: d.maxX + 24, y: d.midY - 4, color: ink)
            face.drawLeft(c, Face.clipped(sub, HPType.sf(30), E.width - 400), font: HPType.sf(30), x: d.maxX + 24, y: d.midY + 36, color: ink.withAlphaComponent(0.62))
        } else {
            face.drawLeft(c, title(t), font: tf, x: d.maxX + 24, y: d.midY + 14, color: ink)
        }
    }
    static func toggleRect(_ E: CGRect) -> CGRect { CGRect(x: E.maxX - 40 - 128, y: E.minY + 84 - 38, width: 128, height: 76) }

    private struct Row { var symbol: String; var title: String; var trailing: String?; var check: Bool; var tint: NSColor?; var action: CCHit.Action; var toggle: Bool? = nil }

    private static func rows(_ c: CGContext, _ face: Face, _ E: CGRect, top: CGFloat, _ list: [Row], record: Bool, rowH: CGFloat = 92) {
        let ink = HPGlass.ink, lightGlass = !HPGlass.inkIsLight
        for (i, row) in list.enumerated() {
            let y = top + CGFloat(i) * rowH
            let rr = CGRect(x: E.minX + 24, y: y, width: E.width - 48, height: rowH)
            if i > 0 { c.setFillColor(ink.withAlphaComponent(0.14).cgColor); c.fill(CGRect(x: rr.minX + 96, y: y, width: rr.width - 112, height: 1.5)) }
            let d = CGRect(x: rr.minX + 16, y: rr.midY - 30, width: 60, height: 60)
            if let tint = row.tint {
                c.setFillColor((row.check ? tint : ink.withAlphaComponent(lightGlass ? 0.10 : 0.24)).cgColor); c.fillEllipse(in: d)
                drawGlyph(c, face, row.symbol, in: d.insetBy(dx: 16, dy: 16), color: row.check ? .white : ink)
            } else {
                face.drawSymbol(c, row.symbol, in: d.insetBy(dx: 12, dy: 12), color: ink.withAlphaComponent(0.9))
            }
            let f = HPType.sf(32, row.check ? .semibold : .regular)
            let trailingW: CGFloat = row.trailing.map { Typo.width($0, HPType.sf(28)) + 24 } ?? 0
            let w = rr.width - 112 - trailingW - (row.check || row.toggle != nil ? 140 : 24)
            face.drawLeft(c, Face.clipped(row.title, f, w), font: f, x: rr.minX + 100, y: rr.midY + 11, color: ink)
            var tx = rr.maxX - 24
            if let on = row.toggle {
                let tr = CGRect(x: rr.maxX - 24 - 112, y: rr.midY - 33, width: 112, height: 66)
                plainToggle(c, tr, on: on)
                tx = tr.minX - 20
            } else if row.check {
                face.drawSymbol(c, "checkmark", in: CGRect(x: rr.maxX - 24 - 36, y: rr.midY - 16, width: 36, height: 32), color: ink, weight: .bold)
                tx = rr.maxX - 24 - 56
            }
            if let tr = row.trailing {
                let tf = HPType.sf(28)
                face.drawLeft(c, tr, font: tf, x: tx - Typo.width(tr, tf), y: rr.midY + 10, color: ink.withAlphaComponent(0.62))
            }
            if record { hits.append(CCHit(rect: rr, action: row.action, label: row.title, value: row.trailing, toggle: row.toggle ?? (row.check ? true : nil))) }
        }
    }

    /// 清單是空的：一行次要字（iOS 控制中心大卡的「沒有…」）
    private static func emptyNote(_ c: CGContext, _ face: Face, _ E: CGRect, _ s: String, y: CGFloat? = nil) {
        let f = HPType.sf(HPType.Size.secondary)
        face.drawLeft(c, Face.clipped(s, f, E.width - 80), font: f, x: E.minX + 40, y: y ?? E.minY + 230, color: HPGlass.ink.withAlphaComponent(0.55))
    }

    private static func settingsRow(_ t: Tile, _ title: String) -> Row {
        Row(symbol: "gearshape", title: title, trailing: nil, check: false, tint: nil, action: .settings(t))
    }

    static func drawExpandedContent(_ c: CGContext, _ t: Tile, _ E: CGRect, face: Face, now: Double, record: Bool) {
        let sys = CCSystem.shared, ink = HPGlass.ink
        let bottom = E.maxY - 24 - 92
        switch t {
        case .wifi:
            header(c, face, E, t, sub: subtitle(t, face: face), on: sys.wifi.on)
            plainToggle(c, toggleRect(E), on: sys.wifi.on)
            if record { hits.append(CCHit(rect: toggleRect(E).insetBy(dx: -10, dy: -10), action: .header(t), label: "Wi‑Fi", toggle: sys.wifi.on)) }
            var list: [Row] = []
            if sys.wifi.on, sys.wifi.connected {
                list.append(Row(symbol: "wifi", title: sys.wifi.ssid ?? L("cc.connected", "已连接"), trailing: nil, check: true, tint: HPTokens.blue, action: .wifiRow))
            }
            rows(c, face, E, top: E.minY + 168, list, record: record)
            if sys.wifi.on, !sys.wifi.connected { emptyNote(c, face, E, L("cc.wifi.none", "没有连接网络")) }   // 2.0 depth：空清單說一句
            if sys.wifi.on, sys.wifi.ssid == nil, sys.wifi.connected {
                let f = HPType.sf(26)
                face.drawLeft(c, L("cc.wifi.locationNote", "允许定位后才能显示网络名称"), font: f, x: E.minX + 64, y: E.minY + 300, color: ink.withAlphaComponent(0.55))
            }
            rows(c, face, E, top: bottom, [settingsRow(t, L("cc.wifi.settings", "Wi‑Fi设置…"))], record: record)
        case .bluetooth:
            header(c, face, E, t, sub: subtitle(t, face: face), on: sys.bluetooth.on)
            plainToggle(c, toggleRect(E), on: sys.bluetooth.on)
            if record { hits.append(CCHit(rect: toggleRect(E).insetBy(dx: -10, dy: -10), action: .header(t), label: title(t), toggle: sys.bluetooth.on)) }
            let devs = sys.bluetooth.on ? Array(sys.bluetooth.devices.prefix(5)) : []
            rows(c, face, E, top: E.minY + 168, devs.map {
                Row(symbol: $0.symbol, title: $0.name, trailing: $0.connected ? L("cc.btConnected", "已连接") : L("cc.notConnected", "未连接"),
                    check: false, tint: HPTokens.blue, action: .btDevice($0.address))
            }, record: record)
            if sys.bluetooth.on, devs.isEmpty { emptyNote(c, face, E, L("cc.bt.none", "没有配对的设备")) }
            rows(c, face, E, top: bottom, [settingsRow(t, L("cc.bt.settings", "蓝牙设置…"))], record: record)
        case .focusMode:
            header(c, face, E, t, sub: sys.focus.readable ? subtitle(t, face: face) : L("cc.focus.unreadable", "读取当前状态需要“完全磁盘访问权限”"), on: sys.focus.active != nil)
            rows(c, face, E, top: E.minY + 168, sys.focus.modes.prefix(5).map {
                Row(symbol: $0.symbol, title: $0.name, trailing: nil, check: sys.focus.active == $0.id, tint: $0.tint, action: .focusMode($0.id))
            }, record: record)
            rows(c, face, E, top: bottom, [settingsRow(t, L("cc.focus.settings", "专注模式设置…"))], record: record)
        case .home:
            drawHomeExpanded(c, E, face: face, record: record)
        case .nowPlaying:
            drawNowPlayingExpanded(c, E, face: face, now: now, record: record)
        case .volume, .brightness:
            let big = CGRect(x: E.minX, y: E.minY, width: E.width, height: 200)
            drawSliderBig(c, t, big, face: face)
            if record {
                let v = Double(level(t))
                hits.append(CCHit(rect: track(t, big, .s4x1, big: true).insetBy(dx: -40, dy: -40), action: .slider(t), label: title(t), value: "\(Int((v * 100).rounded()))%", level: v))
            }
            if t == .volume {
                let f = HPType.sf(30, .bold)
                face.drawLeft(c, L("cc.output", "输出"), font: f, x: E.minX + 40, y: E.minY + 250, color: ink.withAlphaComponent(0.62))
                rows(c, face, E, top: E.minY + 272, (outputsLocked ? [] : sys.outputs).prefix(3).map {
                    Row(symbol: $0.symbol, title: $0.name, trailing: nil, check: $0.selected, tint: HPTokens.blue, action: .output($0.id))
                }, record: record)
                if outputsLocked { emptyNote(c, face, E, L("apps.locked.body", "认出主人之后才会显示"), y: E.minY + 330) }   // 2.0 depth：遠端訪客看到的是原因，不是空白
                rows(c, face, E, top: bottom, [settingsRow(t, L("cc.sound.settings", "声音设置…"))], record: record)
            } else {
                rows(c, face, E, top: E.minY + 240, [
                    Row(symbol: "circle.lefthalf.filled", title: L("cc.darkMode", "深色模式"), trailing: nil, check: false, tint: nil, action: .darkRow, toggle: HPTokens.dark),
                    Row(symbol: "moon.stars.fill", title: L("cc.night", "夜间"), trailing: nil, check: false, tint: nil, action: .nightRow, toggle: Shell.manualNight),
                ], record: record)
                rows(c, face, E, top: bottom, [settingsRow(t, L("cc.display.settings", "显示器设置…"))], record: record)
            }
        default: break
        }
    }

    /// 大卡裡的寬滑桿（標題 40、軌道 14 高）
    private static func drawSliderBig(_ c: CGContext, _ t: Tile, _ r: CGRect, face: Face) {
        let ink = HPGlass.ink
        face.drawLeft(c, title(t), font: HPType.sf(40, .bold), x: r.minX + 40, y: r.minY + 76, color: ink)
        let tr = track(t, r, .s4x1, big: true), lv = max(0, min(1, level(t)))
        AppUI.fillPill(c, tr, color: ink.withAlphaComponent(0.14))
        if lv > 0.001 { AppUI.fillPill(c, CGRect(x: tr.minX, y: tr.minY, width: max(tr.height, tr.width * lv), height: tr.height), color: ink.withAlphaComponent(0.96)) }
        let lo = t == .volume ? "speaker.fill" : "sun.min", hi = t == .volume ? "speaker.wave.3.fill" : "sun.max.fill"
        face.drawSymbol(c, lo, in: CGRect(x: tr.minX - 64, y: tr.midY - 20, width: 40, height: 40), color: ink.withAlphaComponent(0.9))
        face.drawSymbol(c, hi, in: CGRect(x: tr.maxX + 20, y: tr.midY - 20, width: 48, height: 40), color: ink.withAlphaComponent(0.9))
        let f = HPType.sf(28)
        let pct = "\(Int((lv * 100).rounded()))%"
        face.drawLeft(c, pct, font: f, x: r.maxX - 40 - Typo.width(pct, f), y: r.minY + 76, color: ink.withAlphaComponent(0.62))
    }

    private static func drawHomeExpanded(_ c: CGContext, _ E: CGRect, face: Face, record: Bool) {
        let ink = HPGlass.ink, lightGlass = !HPGlass.inkIsLight
        let snap = homeSnapshot
        header(c, face, E, .home, sub: HomeAppModel.homeName(snap), on: homeOnCount > 0)
        if locked(.home) {
            face.drawLeft(c, L("apps.locked.body", "认出主人之后才会显示"), font: HPType.sf(32), x: E.minX + 40, y: E.minY + 220, color: ink.withAlphaComponent(0.62))
            return
        }
        let st = homeState
        if st != .ready {   // 2.0 depth：跟家庭 App 同一句話，底下照樣能「打開家庭」
            let (title, sub): (String, String) = {
                switch st {
                case .noHelper: return (L("home.needHelper", "家庭需要 HomePlay Home 小帮手（目前只在开发版提供）"), "")
                case .connecting: return (L("home.connecting", "正在连接家庭…"), L("home.connecting.sub", "HomePlay Home 小帮手启动后，配件会自动出现"))
                default: return (L("home.empty", "这个家庭还没有配件"), L("home.empty.sub", "先在 Mac 的「家庭」App 里添加配件"))
                }
            }()
            let tf = HPType.sf(HPType.Size.list, .semibold), sf = HPType.sf(HPType.Size.secondary)
            var y = E.minY + 210
            for l in MediaUI.wrap(title, tf, E.width - 80, maxLines: 2) { face.drawLeft(c, l, font: tf, x: E.minX + 40, y: y, color: ink); y += 54 }
            for l in MediaUI.wrap(sub, sf, E.width - 80, maxLines: 2) where !sub.isEmpty { face.drawLeft(c, l, font: sf, x: E.minX + 40, y: y + 4, color: ink.withAlphaComponent(0.62)); y += 42 }
            rows(c, face, E, top: E.maxY - 24 - 92, [Row(symbol: "house", title: L("cc.home.open", "打开“家庭”"), trailing: nil, check: false, tint: nil, action: .homeOpen)], record: record)
            return
        }
        // 場景晶片
        var x = E.minX + 40
        let chipF = HPType.sf(28, .semibold)
        for s in HomeAppModel.scenes(snap).prefix(4) {
            let w = Typo.width(s.name, chipF) + 48
            guard x + w < E.maxX - 40 else { break }
            let r = CGRect(x: x, y: E.minY + 160, width: w, height: 68)
            AppUI.fillPill(c, r, color: ink.withAlphaComponent(lightGlass ? 0.08 : 0.16))
            face.drawLeft(c, s.name, font: chipF, x: r.minX + 24, y: r.midY + 10, color: ink)
            if record { hits.append(CCHit(rect: r, action: .scene(s.id), label: s.name)) }
            x = r.maxX + 16
        }
        // 配件磚（3 × 2；開著白底，照家庭 App）
        let tiles = homeTiles
        let tw = (E.width - 80 - 2 * 24) / 3, th: CGFloat = 132
        for (i, t) in tiles.enumerated() {
            let col = i % 3, row = i / 3
            let r = CGRect(x: E.minX + 40 + CGFloat(col) * (tw + 24), y: E.minY + 256 + CGFloat(row) * (th + 24), width: tw, height: th)
            AppUI.fillRound(c, r, radius: 40, color: t.on ? NSColor.white.withAlphaComponent(0.94) : ink.withAlphaComponent(lightGlass ? 0.08 : 0.16))
            let ti = t.on ? srgb(0x1d1d1f) : ink
            face.drawSymbol(c, t.symbol, in: CGRect(x: r.minX + 24, y: r.minY + 22, width: 44, height: 40), color: t.on ? HPTokens.orange : ti)
            let f = HPType.sf(28, .semibold)
            face.drawLeft(c, Face.clipped(t.name, f, r.width - 48), font: f, x: r.minX + 24, y: r.maxY - 24, color: ti)
            if record { hits.append(CCHit(rect: r, action: .homeTile(t.id), label: t.name, toggle: t.on)) }
        }
        rows(c, face, E, top: E.maxY - 24 - 92, [Row(symbol: "house", title: L("cc.home.open", "打开“家庭”"), trailing: nil, check: false, tint: nil, action: .homeOpen)], record: record)
    }

    private static func drawNowPlayingExpanded(_ c: CGContext, _ E: CGRect, face: Face, now: Double, record: Bool) {
        let ink = HPGlass.ink, lightGlass = !HPGlass.inkIsLight
        let info = nowInfo(face, now)
        let ir = CGRect(x: E.minX + 40, y: E.minY + 40, width: 184, height: 184)
        drawArt(c, face, ir, info: info, ink: ink, lightGlass: lightGlass)
        let x = ir.maxX + 32, w = E.maxX - 40 - x
        let tf = HPType.sf(40, .bold), af = HPType.sf(32)
        face.drawLeft(c, Face.clipped(info?.title ?? L("cc.notPlaying", "未在播放"), tf, w), font: tf, x: x, y: E.minY + 92, color: ink)
        if let a = info?.artist, !a.isEmpty { face.drawLeft(c, Face.clipped(a, af, w), font: af, x: x, y: E.minY + 134, color: ink.withAlphaComponent(0.62)) }
        // 進度
        let bar = CGRect(x: x, y: E.minY + 176, width: w, height: 10)
        AppUI.fillPill(c, bar, color: ink.withAlphaComponent(0.16))
        if let i = info, i.duration > 0 {
            let pos = i.fixed || !i.playing ? i.position : i.position + (now - i.stamp) * i.rate
            let k = CGFloat(max(0, min(1, pos / i.duration)))
            AppUI.fillPill(c, CGRect(x: bar.minX, y: bar.minY, width: max(bar.height, bar.width * k), height: bar.height), color: ink.withAlphaComponent(0.9))
            let f = HPType.numeric(26, .regular)
            func mmss(_ s: Double) -> String { String(format: "%d:%02d", Int(s) / 60, Int(s) % 60) }
            face.drawLeft(c, mmss(pos), font: f, x: bar.minX, y: bar.maxY + 34, color: ink.withAlphaComponent(0.62))
            let rem = "-" + mmss(max(0, i.duration - pos))
            face.drawLeft(c, rem, font: f, x: bar.maxX - Typo.width(rem, f), y: bar.maxY + 34, color: ink.withAlphaComponent(0.62))
        }
        // 控制（88 的點按區）
        let cy = E.minY + 300, ctlInk = info == nil ? ink.withAlphaComponent(0.4) : ink
        let specs: [(CGFloat, String, CCHit.Action, String)] = [
            (-160, "backward.fill", .npPrev, L("cc.np.previous", "上一首")),
            (0, info?.playing == true ? "pause.fill" : "play.fill", .npPlay, info?.playing == true ? L("cc.np.pause", "暂停") : L("cc.np.play", "播放")),
            (160, "forward.fill", .npNext, L("cc.np.next", "下一首"))]
        for (dx, sym, act, label) in specs {
            let r = CGRect(x: E.midX + dx - 48, y: cy - 48, width: 96, height: 96)
            face.drawSymbol(c, sym, in: r.insetBy(dx: dx == 0 ? 22 : 16, dy: dx == 0 ? 20 : 28), color: ctlInk)
            if record { hits.append(CCHit(rect: r, action: act, label: label)) }
        }
        // 輸出（Core Audio 的輸出裝置）
        face.drawLeft(c, L("cc.output", "输出"), font: HPType.sf(30, .bold), x: E.minX + 40, y: E.minY + 410, color: ink.withAlphaComponent(0.62))
        rows(c, face, E, top: E.minY + 432, (outputsLocked ? [] : CCSystem.shared.outputs).prefix(3).map {
            Row(symbol: $0.symbol, title: $0.name, trailing: nil, check: $0.selected, tint: HPTokens.blue, action: .output($0.id))
        }, record: record, rowH: 88)
    }

    // MARK: 加入控制項目（圖庫）

    static var galleryRect: CGRect { CGRect(x: 14, y: 40, width: 996, height: 1024 - 40 - 14) }
    static var galleryRadius: CGFloat { Screen.concentric(inset: 14) }
    static func categorySymbol(_ c: CCCategory) -> String {
        switch c {
        case .connectivity: return "antenna.radiowaves.left.and.right"
        case .display: return "sun.max.fill"
        case .sound: return "speaker.wave.2.fill"
        case .focus: return "moon.fill"
        case .home: return "house.fill"
        case .clock: return "clock.fill"
        case .homePlay: return "eyes"
        }
    }

    static func drawGallery(face: Face, k: CGFloat, now: Double) {
        let G0 = galleryRect
        let G = G0.offsetBy(dx: 0, dy: (1 - k) * (1024 - G0.minY))
        let path = continuousRoundedRect(G, radius: galleryRadius)
        let record = k > 0.95
        HPGlass.add(path, interactive: false, union: nil, presence: min(1, k * 1.4)) { c in
            let ink = HPGlass.ink, lightGlass = !HPGlass.inkIsLight
            c.saveGState(); c.addPath(path); c.clip()
            AppUI.fillPill(c, CGRect(x: G.midX - 36, y: G.minY + 16, width: 72, height: 8), color: ink.withAlphaComponent(0.3))
            let tf = HPType.sf(40, .bold), heading = L("cc.addControl", "添加控制")
            face.drawLeft(c, heading, font: tf, x: G.midX - Typo.width(heading, tf) / 2, y: G.minY + 92, color: ink)
            // 完成（右上，填色膠囊）
            let df = HPType.sf(28, .semibold), done = L("home.done", "完成")
            let dr = CGRect(x: G.maxX - 56 - Typo.width(done, df) - 48, y: G.minY + 48, width: Typo.width(done, df) + 48, height: 60)
            AppUI.fillPill(c, dr, color: ink.withAlphaComponent(lightGlass ? 0.08 : 0.16))
            face.drawLeft(c, done, font: df, x: dr.minX + 24, y: dr.midY + 10, color: ink)
            if record { hits.append(CCHit(rect: dr.insetBy(dx: -8, dy: -14), action: .galleryClose, label: done)) }
            // 分類
            let top = G.minY + 140
            c.saveGState(); c.clip(to: CGRect(x: G.minX, y: top, width: G.width, height: G.maxY - top))
            var y = top - galleryScroll
            let colW = (G.width - 80) / 6, d: CGFloat = 104
            for cat in CCCategory.allCases {
                let items = Tile.allCases.filter { $0.category == cat }
                c.setFillColor(ink.withAlphaComponent(0.14).cgColor); c.fill(CGRect(x: G.minX + 40, y: y, width: G.width - 80, height: 1.5))
                let ic = CGRect(x: G.minX + 40, y: y + 24, width: 52, height: 52)
                AppUI.fillRound(c, ic, radius: 13, color: ink.withAlphaComponent(lightGlass ? 0.10 : 0.2))
                face.drawSymbol(c, categorySymbol(cat), in: ic.insetBy(dx: 12, dy: 12), color: ink)
                face.drawLeft(c, cat.title, font: HPType.sf(32, .bold), x: ic.maxX + 18, y: ic.midY + 11, color: ink)
                y += 100
                for (i, t) in items.enumerated() {
                    if i > 0, i % 6 == 0 { y += 180 }
                    let cx = G.minX + 40 + colW * (CGFloat(i % 6) + 0.5)
                    let disc = CGRect(x: cx - d / 2, y: y, width: d, height: d)
                    let added = layout.contains(t)
                    c.saveGState(); if added { c.setAlpha(0.4) }
                    c.setFillColor(ink.withAlphaComponent(lightGlass ? 0.10 : 0.22).cgColor); c.fillEllipse(in: disc)
                    drawGlyph(c, face, symbol(t), in: disc.insetBy(dx: 30, dy: 30), color: ink)
                    let lf = HPType.sf(24)
                    let lines = Face.wrap(title(t), lf, colW - 8, maxLines: 2)
                    for (li, s) in lines.enumerated() {
                        face.drawLeft(c, s, font: lf, x: cx - Typo.width(s, lf) / 2, y: disc.maxY + 34 + CGFloat(li) * 28, color: ink.withAlphaComponent(0.8))
                    }
                    c.restoreGState()
                    if added { face.drawSymbol(c, "checkmark.circle.fill", in: CGRect(x: disc.maxX - 32, y: disc.minY - 4, width: 36, height: 36), color: HPTokens.green) }
                    if record, !added, disc.midY > top, disc.midY < G.maxY {
                        hits.append(CCHit(rect: CGRect(x: cx - colW / 2, y: disc.minY, width: colW, height: d + 60), action: .galleryAdd(t),
                                          label: String(format: L("cc.a11y.add", "添加“%@”"), title(t))))
                    }
                }
                y += 180
            }
            galleryContentH = y + galleryScroll - top
            c.restoreGState()
            c.restoreGState()
        }
    }
}
