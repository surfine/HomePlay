// 螢幕上的設定 › SideShow：開關、加入裝置（QR 碼）、已配對的裝置（移除）、主人允許的個人內容。
// 加入與移除裝置只給主人（PersonalGate）：站在 HomeView 前面的訪客不能替自己配一台。
// 快照：--demo-sideshow pair|devices（記憶體裡的假名冊與假網址，不碰真的設定與名冊檔）。

import AppKit
import CoreImage

enum SideShowSettings {
    /// --demo-sideshow：直接打開設定的 SideShow 頁
    static var demoPicker: SettingsApp.Picker? {
        guard let v = demoMode else { return nil }
        return v == "pair" ? .sideshowPair : .sideshow
    }
    static let demoMode: String? = {
        let a = CommandLine.arguments
        guard let i = a.firstIndex(of: "--demo-sideshow") else { return nil }
        return i + 1 < a.count && !a[i + 1].hasPrefix("--") ? a[i + 1] : "devices"
    }()

    /// 快照用的假名冊（記憶體）：兩台裝置、一個配對碼
    static func installDemo() {
        guard demoMode != nil else { return }
        let s = SideShowStore(file: nil)
        let base = Date().timeIntervalSince1970
        s.now = { base - 3600 }
        for n in ["Kitchen iPad", "iPhone SE"] { if let c = s.newPairing() { _ = s.redeem(code: c, ip: "192.168.1.20", name: n) } }
        s.now = { Date().timeIntervalSince1970 }
        _ = s.newPairing()
        SideShowServer.shared.store = s
        demoOn = true
    }
    nonisolated(unsafe) static var demoOn = false
    static var on: Bool { demoOn || SideShowServer.shared.running }

    /// QR 碼要放的網址（快照用假網址，不讀這台 Mac 的名字與位址）
    static func pairURL(code: String) -> String? {
        let base = SnapshotPrivacy.active || demoOn ? "http://homeplay.local:\(SideShowStore.defaultPort)/" : SideShowServer.baseURL(port: SideShowServer.shared.port)
        return base.map { $0 + "#pair=" + code }
    }

    /// Core Image 的 QR 碼，放大成 px 見方、不內插（每個模組邊界清楚）
    static func qr(_ text: String, px: Int) -> CGImage? {
        guard let f = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        f.setValue(Data(text.utf8), forKey: "inputMessage")
        f.setValue("M", forKey: "inputCorrectionLevel")
        guard let img = f.outputImage, img.extent.width > 0 else { return nil }
        let k = floor(CGFloat(px) / img.extent.width)
        let big = img.transformed(by: CGAffineTransform(scaleX: max(1, k), y: max(1, k)))
        return CIContext(options: [.useSoftwareRenderer: true]).createCGImage(big, from: big.extent)
    }
    nonisolated(unsafe) private static var qrCache: (String, CGImage)?
    static func cachedQR(_ text: String) -> CGImage? {
        if let c = qrCache, c.0 == text { return c.1 }
        guard let i = qr(text, px: 480) else { return nil }
        qrCache = (text, i); return i
    }
}

extension SettingsApp {
    private var x0: CGFloat { Self.x0 }
    private var width: CGFloat { Self.x1 - Self.x0 }

    /// 一列：左邊名稱、右邊開關（點整列切換）
    private func toggleRow(_ g: CGContext, _ face: Face, _ r: CGRect, _ title: String, on: Bool, key: String, action: @escaping () -> Void) {
        let sw = CGRect(x: r.maxX - Self.inset - 106, y: r.midY - 31, width: 106, height: 62)
        face.drawLeft(g, Face.clipped(title, lf, sw.minX - r.minX - Self.inset - 24), font: lf, x: r.minX + Self.inset, y: r.midY + 15, color: HPComponents.label)
        HPComponents.toggle(g, sw, on: on, key: key, label: title)
        hits.append((r, action))
    }

    func drawSideShow(_ g: CGContext, _ face: Face) {
        var y = HPTokens.contentTop
        let srv = SideShowServer.shared, on = SideShowSettings.on
        let owner = PersonalGate.allowed
        HPComponents.groupCard(g, CGRect(x: x0, y: y, width: width, height: Self.row))
        toggleRow(g, face, CGRect(x: x0, y: y, width: width, height: Self.row), L("settings.sideshow", "SideShow"), on: on, key: "sideshow.enabled") {
            guard owner, !SideShowSettings.demoOn else { return }
            srv.apply(enabled: !srv.running)
        }
        y += Self.row + HPGrid.Rhythm.rowGap
        footnote(g, face, L("sideshow.note", "让旧 iPad 或手机当副屏：显示时钟、天气、正在播放、计时器和家庭警报。Mac 睡着时，它照样显示最后的内容。"), y: &y)
        footnote(g, face, L("sideshow.tribute", "向 Windows SideShow 致敬：主机睡着时，小屏幕照样看得到最后的信息。"), y: &y)
        if srv.listenFailed && !SideShowSettings.demoOn {
            footnote(g, face, L("sideshow.listenFailed", "无法开始监听：端口被占用，或没有本地网络权限。"), y: &y)
        }
        guard on else { return }
        y += HPGrid.Rhythm.sectionGap

        // 加入裝置＋已配對的裝置（最多列 4 台）
        let devs = Array(srv.store.all.prefix(4))
        let rows = 1 + max(1, devs.count)
        HPComponents.groupCard(g, CGRect(x: x0, y: y, width: width, height: Self.row * CGFloat(rows)))
        row(g, face, CGRect(x: x0, y: y, width: width, height: Self.row), L("sideshow.add", "添加设备"),
            value: owner ? nil : L("sideshow.needOwner", "需要主人"), chevron: owner, dim: !owner,
            action: owner ? { [weak self] in _ = srv.store.newPairing(); self?.picking = .sideshowPair } : nil)
        if devs.isEmpty {
            let r = CGRect(x: x0, y: y + Self.row, width: width, height: Self.row)
            HPComponents.separatorLine(g, x: x0 + Self.inset, maxX: Self.x1, y: r.minY)
            row(g, face, r, L("sideshow.none", "还没有设备"), value: nil, chevron: false, dim: true, action: nil)
        }
        for (i, d) in devs.enumerated() {
            let r = CGRect(x: x0, y: y + Self.row * CGFloat(i + 1), width: width, height: Self.row)
            HPComponents.separatorLine(g, x: x0 + Self.inset, maxX: Self.x1, y: r.minY)
            let rm = L("sideshow.remove", "移除"), rf = HPType.sf(42, .regular)
            let rw = Typo.width(rm, rf)
            face.drawLeft(g, rm, font: rf, x: r.maxX - Self.inset - rw, y: r.midY + 15, color: owner ? HPComponents.red : HPComponents.tertiary)
            let seen = d.lastSeen.map { Self.seenText($0) } ?? ""
            let sw = Typo.width(seen, sf)
            face.drawLeft(g, seen, font: sf, x: r.maxX - Self.inset - rw - 32 - sw, y: r.midY + 11, color: HPComponents.secondary)
            face.drawLeft(g, Face.clipped(d.name, lf, r.width - 2 * Self.inset - rw - sw - 72), font: lf, x: r.minX + Self.inset, y: r.midY + 15, color: HPComponents.label)
            let hit = CGRect(x: r.maxX - Self.inset - rw - 24, y: r.minY, width: rw + Self.inset + 24, height: r.height)
            HPAX.note(g, hit, .button, rm + " " + d.name)
            if owner, !SideShowSettings.demoOn { let id = d.id; hits.append((hit, { srv.store.revoke(id) })) }
        }
        y += Self.row * CGFloat(rows) + HPGrid.Rhythm.sectionGap

        // 主人允許的個人內容
        HPComponents.groupCard(g, CGRect(x: x0, y: y, width: width, height: Self.row))
        toggleRow(g, face, CGRect(x: x0, y: y, width: width, height: Self.row), L("sideshow.calendar", "显示下一个日程"), on: SideShowStore.showCalendar, key: "sideshow.calendar") {
            guard owner, !SideShowSettings.demoOn else { return }
            SideShowStore.showCalendar.toggle(); srv.refresh()
        }
        y += Self.row + HPGrid.Rhythm.rowGap
        footnote(g, face, L("sideshow.privacy", "日程是个人内容，访客模式开着时不显示。信息、摄像头、通讯录一律不上副屏。"), y: &y)
    }

    /// 「剛剛」「14:05」「11/5」
    static func seenText(_ t: Double) -> String {
        let now = Date().timeIntervalSince1970
        if now - t < 90 { return L("sideshow.justNow", "刚刚") }
        let d = Date(timeIntervalSince1970: t), f = DateFormatter()
        Face.setTimeFormat(f, datePrefix: Calendar.current.isDateInToday(d) ? "" : "Md")
        return f.string(from: d)
    }

    func drawSideShowPair(_ g: CGContext, _ face: Face, now: Double) {
        let store = SideShowServer.shared.store
        // 配好一台（名冊變了）或碼過期：回 SideShow 頁
        guard let code = store.pairingCode, let url = SideShowSettings.pairURL(code: code) else {
            picking = .sideshow; drawSideShow(g, face); return
        }
        let card = CGRect(x: 512 - 220, y: HPTokens.contentTop, width: 440, height: 440)
        HPComponents.groupCard(g, card, radius: 48, color: .white)   // QR 碼一律白底黑點（深色外觀也一樣，相機才讀得到）
        if let img = SideShowSettings.cachedQR(url) {
            // 自己翻回來畫（drawUpright 會開高品質內插，QR 碼的模組邊要銳利）
            let qr = card.insetBy(dx: 36, dy: 36)
            g.saveGState(); g.translateBy(x: 0, y: qr.minY + qr.maxY); g.scaleBy(x: 1, y: -1)
            g.interpolationQuality = .none; g.draw(img, in: qr)
            g.restoreGState()
        }
        HPAX.note(g, card, .text, L("sideshow.qr.a11y", "配对二维码"), shape: .rounded(48))
        var y = card.maxY + HPGrid.Rhythm.groupGap
        let bf = HPType.sf(42, .semibold)
        face.drawCentered(g, L("sideshow.scan", "用 iPad 或手机的相机扫描"), font: bf, y: y + 40, color: HPComponents.label)
        y += 64
        let left = max(0, Int(((store.pairingExpires ?? 0) - Date().timeIntervalSince1970) / 60 + 0.99))
        face.drawCentered(g, String(format: L("sideshow.code", "配对码 %@ · %d 分钟内有效"), code, left), font: sf, y: y + 38, color: HPComponents.secondary)
        y += 56
        footnote(g, face, L("sideshow.pairHint", "扫码后先把网页添加到主屏幕，再从主屏幕打开，Mac 睡着时也能显示最后的内容。也可以在 Safari 打开下面的网址，再输入配对码。"), y: &y)
        let base = url.components(separatedBy: "#").first ?? url
        face.drawCentered(g, Face.clipped(base, sf, width - 2 * Self.inset), font: sf, y: y + 38, color: HPComponents.blue)
    }
}
