// 尋找（Find My）：HomeView 內建 App 之一（HV-SPECS-88）。
// 「尋找」沒有給其他 App 用的公開 API，所以這裡**不讀**它的快取、資料庫或任何私有介面。真的能顯示的只有：
//   - 這台 Mac 自己（電腦名稱是公開的系統設定）；位置用天氣已經取得的大約位置（使用者為天氣允許過定位才有），
//     地圖用 MapKit 的 MKMapSnapshotter 畫；
//   - 其他裝置、成員與「播放聲音」都交給這台 Mac 的「尋找」App（點了就打開它）。
// 快照、示範（SnapshotPrivacy、--demo-findmy）一律用示範資料與程式畫的地圖，不碰真的位置。
// 版面照 iOS 27 的「尋找」推斷：分段（成員／裝置）、地圖卡、清單；細節頁＝大地圖＋「播放聲音」「在『尋找』中打開」。

import AppKit
import MapKit

struct FindMyItem: Equatable {
    enum Kind: Equatable { case person, device }
    var id: String
    var kind: Kind
    var name: String
    var place: String       // 「在你身邊」「家」…
    var time: String        // 「現在」「5 分鐘前」
    var symbol: String      // 裝置的符號；人用縮寫
    var tint: UInt32
    var spot: CGPoint       // 地圖上的相對位置 0…1
    var real: Bool = false  // 真的資料（這台 Mac）
}

enum FindMyModel {
    static let appPath = "/System/Applications/FindMy.app"
    static var demo: Bool { SnapshotPrivacy.active || AppUI.flag("--demo-findmy") }

    static func demoPeople() -> [FindMyItem] {
        [FindMyItem(id: "p1", kind: .person, name: L("findmy.demo.erica", "Erica"), place: L("findmy.place.home", "家"), time: L("findmy.time.now", "现在"),
                    symbol: "", tint: 0xCB30E0, spot: CGPoint(x: 0.30, y: 0.42)),
         FindMyItem(id: "p2", kind: .person, name: L("findmy.demo.alex", "Alex"), place: L("findmy.place.work", "公司"), time: String(format: L("findmy.time.minutes", "%d 分钟前"), 5),
                    symbol: "", tint: 0x00C3D0, spot: CGPoint(x: 0.72, y: 0.30))]
    }
    static func demoDevices() -> [FindMyItem] {
        let home = L("findmy.place.home", "家"), now = L("findmy.time.now", "现在")
        return [
            FindMyItem(id: "d1", kind: .device, name: L("findmy.demo.iphone", "iPhone"), place: L("findmy.place.withYou", "在你身边"), time: now, symbol: "iphone", tint: 0x34C759, spot: CGPoint(x: 0.44, y: 0.50)),
            FindMyItem(id: "d2", kind: .device, name: L("findmy.demo.airpods", "AirPods Pro"), place: home, time: now, symbol: "airpodspro", tint: 0x34C759, spot: CGPoint(x: 0.24, y: 0.66)),
            FindMyItem(id: "d3", kind: .device, name: L("findmy.demo.macbook", "MacBook Air"), place: home, time: now, symbol: "laptopcomputer", tint: 0x34C759, spot: CGPoint(x: 0.64, y: 0.52)),
            FindMyItem(id: "d4", kind: .device, name: L("findmy.demo.keys", "钥匙"), place: L("findmy.place.work", "公司"), time: String(format: L("findmy.time.minutes", "%d 分钟前"), 12), symbol: "key.fill", tint: 0x8E8E93, spot: CGPoint(x: 0.82, y: 0.30)),
        ]
    }
    /// 真的資料：只有這台 Mac（名稱來自系統的電腦名稱）
    static func thisMac() -> FindMyItem {
        FindMyItem(id: "mac", kind: .device, name: Host.current().localizedName ?? L("findmy.thisMac", "这台 Mac"),
                   place: L("findmy.place.thisMac", "这台 Mac"), time: L("findmy.time.now", "现在"), symbol: "laptopcomputer", tint: 0x34C759,
                   spot: CGPoint(x: 0.5, y: 0.55), real: true)
    }
    /// 天氣已經存的大約位置（使用者為天氣允許過定位才有；沒有就 nil）
    static func approximateLocation(_ d: UserDefaults = .standard) -> CLLocationCoordinate2D? {
        guard d.object(forKey: "HomePlayWeatherLat") != nil, d.object(forKey: "HomePlayWeatherLon") != nil else { return nil }
        let c = CLLocationCoordinate2D(latitude: d.double(forKey: "HomePlayWeatherLat"), longitude: d.double(forKey: "HomePlayWeatherLon"))
        return CLLocationCoordinate2DIsValid(c) && !(c.latitude == 0 && c.longitude == 0) ? c : nil
    }
    /// 打開這台 Mac 的「尋找」（播放聲音、其他裝置、成員都在那裡做）
    static func openFindMy() {
        let cfg = NSWorkspace.OpenConfiguration(); cfg.activates = true
        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: appPath), configuration: cfg) { _, _ in }
    }
}

final class FindMyApp: PetApp {
    static let shared = FindMyApp()
    let id = "findmy"
    var title: String { L("app.findMy", "查找") }
    let icon = AppIcon(color: srgb(0x34C759), symbol: "location.fill", system: FindMyModel.appPath)

    private var tab = 1                 // 0 成員、1 裝置（Mac 上能顯示的是裝置）
    private var detail: String?
    private var scroll = AppScroll()
    private var segRects: [CGRect] = []
    private var buttons: [(CGRect, () -> Void)] = []
    private var mapImage: CGImage?
    private var mapKey = ""
    private var mapLoading = false
    private var dirty = false
    typealias T = HPTokens.FindMy

    private var people: [FindMyItem] { FindMyModel.demo ? FindMyModel.demoPeople() : [] }
    private var devices: [FindMyItem] { FindMyModel.demo ? FindMyModel.demoDevices() : [FindMyModel.thisMac()] }
    private var list: [FindMyItem] { tab == 0 ? people : devices }

    func didOpen(now: Double) {
        detail = nil; scroll = AppScroll(); tab = 1
        if let v = AppUI.args.firstIndex(of: "--demo-findmy").flatMap({ $0 + 1 < AppUI.args.count ? AppUI.args[$0 + 1] : nil }) {
            if v == "people" { tab = 0 } else if v == "detail" { detail = devices.first?.id }
        }
        if let v = AppUI.scrollFlag("--demo-findmy-scroll") { scroll.offset = v }   // P12：快照——清單捲到一半，看地圖底下的柔邊
    }
    var backSymbol: String { detail != nil ? "chevron.left" : "xmark" }
    func handleBack(now: Double) -> Bool {
        guard detail != nil else { return false }
        detail = nil; return true
    }
    func tick(_ now: Double) -> Bool {
        if HPComponents.needsFrame(now) { return true }
        defer { dirty = false }
        return dirty
    }

    // MARK: 畫

    func render(into g: CGContext, face: Face, rect: CGRect, now: Double) {
        g.setFillColor(AppUI.bg.cgColor); g.fill(rect)
        buttons = []
        if let d = detail, let item = (people + devices).first(where: { $0.id == d }) { renderDetail(g, face, item); return }
        AppUI.title(g, face, title)
        segRects = HPComponents.segmented(g, face, T.segment, [L("findmy.people", "联系人"), L("findmy.devices", "设备")], selected: tab, key: "findmy.tab")
        drawMap(g, face, T.map, items: list, seed: tab + 3)
        let items = list
        if items.isEmpty {
            // 成員：沒有公開 API，照實說，給一顆打開「尋找」的鈕
            let r = CGRect(x: T.map.minX, y: T.listTop, width: T.map.width, height: 280)
            AppUI.group(g, r)
            let body = L("findmy.people.none", "和你共享位置的人在这台 Mac 的「查找」里。「查找」没有开放给其他 App，HomePlay 读不到。")
            let bf = AppUI.font(32)
            for (i, l) in Face.wrap(body, bf, r.width - 96, maxLines: 3).enumerated() {
                AppUI.left(face, g, l, bf, x: r.minX + 48, y: r.minY + 66 + CGFloat(i) * 44, AppUI.secondary)
            }
            let b = CGRect(x: r.minX + 48, y: r.maxY - 48 - T.buttonHeight, width: 460, height: T.buttonHeight)
            HPComponents.glassButton(g, face, b, L("findmy.open", "在「查找」中打开"), symbol: "arrow.up.forward.app")
            buttons.append((b, { FindMyModel.openFindMy() }))
            return
        }
        g.saveGState()
        // P12：上緣放到地圖卡正下方（T.map.maxY），列捲上來時從地圖底邊柔柔地淡出（柔邊在 restore 之後畫）
        g.clip(to: CGRect(x: 0, y: T.map.maxY, width: 1024, height: 1024 - T.map.maxY))
        let footer = !FindMyModel.demo
        let n = items.count + (footer ? 1 : 0)
        let top = T.listTop - scroll.offset
        AppUI.group(g, CGRect(x: T.map.minX, y: top, width: T.map.width, height: CGFloat(n) * T.rowHeight))
        for (i, it) in items.enumerated() {
            let r = CGRect(x: T.map.minX, y: top + CGFloat(i) * T.rowHeight, width: T.map.width, height: T.rowHeight)
            row(g, face, r, it, last: i == n - 1)
            buttons.append((r, { [weak self] in self?.detail = it.id; self?.dirty = true }))
        }
        if footer {   // 其他裝置在「尋找」裡（照實說：讀不到）
            let r = CGRect(x: T.map.minX, y: top + CGFloat(items.count) * T.rowHeight, width: T.map.width, height: T.rowHeight)
            let c = CGRect(x: r.minX + 28, y: r.midY - T.icon / 2, width: T.icon, height: T.icon)
            g.setFillColor(AppUI.grouped2.cgColor); g.fillEllipse(in: c)
            face.drawSymbol(g, "ellipsis", in: c.insetBy(dx: 20, dy: 20), color: AppUI.secondary)
            let s = L("findmy.otherDevices", "其他设备在「查找」里"), f = AppUI.font(40)
            AppUI.left(face, g, Face.clipped(s, f, 640), f, x: r.minX + 128, y: r.midY + 14, AppUI.blue)
            HPAX.note(g, r, .button, s)
            buttons.append((r, { FindMyModel.openFindMy() }))
        }
        g.restoreGState()
        // P12：頂端柔邊（scroll edge effect）：實心貼齊地圖卡底、柔邊接到第一列（listTop）——靜止時看不到，捲動時列從地圖底下淡出
        HPComponents.topFade(g, AppUI.bg, solidTo: T.map.maxY, height: T.listTop - T.map.maxY)
    }

    private func row(_ g: CGContext, _ face: Face, _ r: CGRect, _ it: FindMyItem, last: Bool) {
        let c = CGRect(x: r.minX + 28, y: r.midY - T.icon / 2, width: T.icon, height: T.icon)
        drawBadge(g, face, it, in: c)
        let tf = AppUI.font(42, .semibold), sf = AppUI.font(30)
        let cx = AppUI.chevron(g, face, rightX: r.maxX - 36, midY: r.midY)
        AppUI.left(face, g, Face.clipped(it.name, tf, cx - r.minX - 300), tf, x: r.minX + 128, y: r.midY - 4, AppUI.label)
        AppUI.left(face, g, Face.clipped(it.place, sf, 400), sf, x: r.minX + 128, y: r.midY + 36, AppUI.secondary)
        AppUI.right(face, g, it.time, sf, rightX: cx - 20, y: r.midY + 12, AppUI.secondary)
        if !last { AppUI.separator(g, x: r.minX + 128, maxX: r.maxX, y: r.maxY) }
        HPAX.note(g, r, .button, "\(it.name), \(it.place), \(it.time)")
    }

    private func drawBadge(_ g: CGContext, _ face: Face, _ it: FindMyItem, in c: CGRect) {
        if it.kind == .person {
            g.setFillColor(srgb(it.tint).cgColor); g.fillEllipse(in: c)
            let t = AvatarResolver.initials(it.name), f = AppUI.font(c.height * 0.4, .semibold)
            AppUI.left(face, g, t, f, x: c.midX - Typo.width(t, f) / 2, y: c.midY + f.capHeight / 2, .white)
        } else {
            g.setFillColor(AppUI.grouped2.cgColor); g.fillEllipse(in: c)
            face.drawSymbol(g, it.symbol, in: c.insetBy(dx: c.width * 0.24, dy: c.width * 0.24), color: AppUI.label)
        }
    }

    /// 地圖卡：真的模式且有大約位置＝MapKit 的地圖快照；其他（快照、示範、沒有位置）＝程式畫的地圖
    private func drawMap(_ g: CGContext, _ face: Face, _ r: CGRect, items: [FindMyItem], seed: Int) {
        var located = FindMyModel.demo
        if !FindMyModel.demo, let img = realMap(r.size) {
            g.saveGState(); g.addPath(continuousRoundedRect(r, radius: HPTokens.Radius.group)); g.clip()
            face.drawUpright(g, img, in: r); g.restoreGState()
            located = true
        } else {
            HPComponents.mapCard(g, r, seed: seed)
        }
        g.saveGState(); g.addPath(continuousRoundedRect(r, radius: HPTokens.Radius.group)); g.clip()
        if located, FindMyModel.demo || tab == 1 { HPComponents.meDot(g, at: CGPoint(x: r.minX + r.width * 0.5, y: r.minY + r.height * 0.6)) }
        if !located {   // 2.0 depth：沒有位置（沒為天氣允許定位、地圖抓不到）：不在假地圖上畫「我」，照 iOS 寫「位置不可用」
            let f = HPType.sf(HPType.Size.secondary, .semibold), s = L("findmy.noLocation", "位置不可用")
            let w = Typo.width(s, f) + 56, pill = CGRect(x: r.midX - w / 2, y: r.midY - 32, width: w, height: 64)
            AppUI.fillPill(g, pill, color: HPTokens.card.withAlphaComponent(0.92))
            face.drawLeft(g, s, font: f, x: pill.midX - Typo.width(s, f) / 2, y: pill.midY + 11, color: HPTokens.secondary)
            HPAX.note(g, pill, .text, s)
        }
        for it in items where !it.real {
            let tip = CGPoint(x: r.minX + r.width * it.spot.x, y: r.minY + r.height * it.spot.y)
            if it.kind == .person { HPComponents.mapPin(g, face, tip: tip, initials: AvatarResolver.initials(it.name), tint: srgb(it.tint)) }
            else { HPComponents.mapPin(g, face, tip: tip, symbol: it.symbol, tint: srgb(it.tint)) }
        }
        g.restoreGState()
    }

    private func realMap(_ size: CGSize) -> CGImage? {
        guard let c = FindMyModel.approximateLocation() else { return nil }
        let key = String(format: "%.2f,%.2f,%d,%d", c.latitude, c.longitude, HPTokens.dark ? 1 : 0, Int(size.width))
        if key == mapKey, let m = mapImage { return m }
        guard !mapLoading else { return mapImage }
        mapLoading = true
        let o = MKMapSnapshotter.Options()
        o.region = MKCoordinateRegion(center: c, latitudinalMeters: 1600, longitudinalMeters: 1600 * size.width / size.height)
        o.size = NSSize(width: size.width / 2, height: size.height / 2)
        o.appearance = NSAppearance(named: HPTokens.dark ? .darkAqua : .aqua)
        o.pointOfInterestFilter = .excludingAll
        MKMapSnapshotter(options: o).start(with: .main) { [weak self] snap, _ in
            guard let self else { return }
            self.mapLoading = false
            if let img = snap?.image.cgImage(forProposedRect: nil, context: nil, hints: nil) { self.mapImage = img; self.mapKey = key; self.dirty = true }
        }
        return mapImage
    }

    private func renderDetail(_ g: CGContext, _ face: Face, _ it: FindMyItem) {
        HPComponents.bigTitle(g, face, it.name)
        let r = T.detailMap
        drawMap(g, face, r, items: [it], seed: tab + 3)
        let sf = AppUI.font(36, .semibold), tf = AppUI.font(32)
        AppUI.left(face, g, it.place, sf, x: r.minX + 8, y: r.maxY + 50, AppUI.label)
        AppUI.right(face, g, it.time, tf, rightX: r.maxX - 8, y: r.maxY + 50, AppUI.secondary)
        let y = T.detailButtonY
        if it.kind == .device {
            // 播放聲音：「尋找」沒有開放，交給 Mac 上的「尋找」App（照實寫在鈕下面）
            let b = CGRect(x: r.minX, y: y, width: r.width / 2 - 10, height: T.buttonHeight)
            HPComponents.filledButton(g, face, b, L("findmy.playSound", "播放声音"), tint: AppUI.green, symbol: "speaker.wave.2.fill")
            buttons.append((b, { FindMyModel.openFindMy() }))
            let o = CGRect(x: b.maxX + 20, y: y, width: r.width / 2 - 10, height: T.buttonHeight)
            HPComponents.glassButton(g, face, o, L("findmy.openShort", "打开「查找」"), symbol: "arrow.up.forward.app")
            buttons.append((o, { FindMyModel.openFindMy() }))
        } else {
            let o = CGRect(x: r.minX, y: y, width: r.width, height: T.buttonHeight)
            HPComponents.glassButton(g, face, o, L("findmy.open", "在「查找」中打开"), symbol: "arrow.up.forward.app")
            buttons.append((o, { FindMyModel.openFindMy() }))
        }
        let note = L("findmy.handoff", "「查找」没有开放给其他 App：播放声音、路线和通知会在这台 Mac 的「查找」里完成。")
        let nf = AppUI.font(28)
        for (i, l) in Face.wrap(note, nf, r.width - 20, maxLines: 3).enumerated() {
            AppUI.left(face, g, l, nf, x: r.minX + 8, y: y + T.buttonHeight + 56 + CGFloat(i) * 38, AppUI.secondary)
        }
    }

    // MARK: 點與滾

    func handleTap(_ p: CGPoint, face: Face, now: Double) -> Bool {
        if detail == nil {
            for (i, r) in segRects.enumerated() where r.contains(p) { if tab != i { tab = i; scroll = AppScroll() }; return true }
        }
        if let b = buttons.first(where: { $0.0.contains(p) && (detail != nil || $0.0.minY >= T.listTop - 8 || p.y >= T.listTop - 8) }) { b.1(); return true }
        return false
    }
    func handleScroll(_ dy: CGFloat, now: Double) -> Bool {
        guard detail == nil else { return false }
        let n = list.count + (FindMyModel.demo ? 0 : 1)
        return scroll.scroll(dy, contentHeight: T.listTop + CGFloat(n) * T.rowHeight + 40, viewport: 1024)
    }
}
