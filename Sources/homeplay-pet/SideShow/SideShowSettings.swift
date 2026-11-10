// 螢幕上的設定 › iPhone 與 iPad：只有一個開關與一個 QR 碼。
//
// 併進 Remote 之後（docs/plans/sideshow.md 的拍板：一個平台、一個名冊、一個 listener），
// 裝置清單、鏡像／副屏的切換、個人內容都集中在 Mac 的「設定 › iPhone 與 iPad」
// （Settings/RemoteDevicesPane.swift）。這一頁只留「開／關」與「加入裝置」——站在 HomeView
// 前面的人也看得到、也能掃。
//
// 快照：--demo-sideshow pair|devices（記憶體裡的假名冊與假網址，不碰真的設定與名冊檔）。

import AppKit
import CoreImage
import CryptoKit

enum SideShowSettings {
    /// --demo-sideshow：直接打開設定的 iPhone 與 iPad 頁
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
        let s = RemoteStore(file: URL(fileURLWithPath: "/dev/null/\(UUID().uuidString).json"))
        let base = Date().timeIntervalSince1970
        s.now = { base - 3600 }
        for (n, side) in [("Kitchen iPad", true), ("iPhone SE", false)] {
            let a = P256.KeyAgreement.PrivateKey().publicKey.x963Representation
            let b = P256.Signing.PrivateKey().publicKey.x963Representation
            _ = s.add(name: n, agree: a, sign: b, mirror: !side, side: side)
        }
        s.now = { Date().timeIntervalSince1970 }
        _ = s.newPairing()
        RemoteServer.shared.store = s
        demoOn = true
    }
    nonisolated(unsafe) static var demoOn = false
    static var on: Bool { demoOn || (RemoteStore.enabled && RemoteServer.shared.running) }

    /// QR 碼要放的網址（快照用假網址，不讀這台 Mac 的名字與位址）。這一頁配的是副屏。
    static func pairURL(code: String) -> String? {
        let base = SnapshotPrivacy.active || demoOn ? "http://homeplay.local:\(RemoteStore.defaultPort)/" : RemoteServer.urls().first
        return base.map { $0 + "#pair=" + code + "&mode=side" }
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
        let srv = RemoteServer.shared, on = SideShowSettings.on
        let owner = PersonalGate.allowed
        HPComponents.groupCard(g, CGRect(x: x0, y: y, width: width, height: Self.row))
        toggleRow(g, face, CGRect(x: x0, y: y, width: width, height: Self.row), L("settings.sideshow", "iPhone 与 iPad"), on: on, key: "sideshow.enabled") {
            guard owner, !SideShowSettings.demoOn else { return }
            RemoteStore.enabled = !on
            if RemoteStore.enabled { srv.startFromLaunch() } else { srv.stop() }
            NotificationCenter.default.post(name: RemoteServer.changed, object: nil)
        }
        y += Self.row + HPGrid.Rhythm.rowGap
        footnote(g, face, L("sideshow.note", "把旧 iPhone 或 iPad 变成第二块屏幕：可以镜像整个画面，也可以只当副屏——时钟、天气、正在播放、计时器和家庭警报。Mac 睡着时，副屏照样显示最后的内容。"), y: &y)
        if srv.listenFailed && !SideShowSettings.demoOn {
            footnote(g, face, L("sideshow.listenFailed", "无法开始监听：端口被占用，或没有本地网络权限。"), y: &y)
        }
        guard on else { return }
        y += HPGrid.Rhythm.sectionGap

        HPComponents.groupCard(g, CGRect(x: x0, y: y, width: width, height: Self.row))
        row(g, face, CGRect(x: x0, y: y, width: width, height: Self.row), L("sideshow.add", "添加设备"),
            value: owner ? nil : L("sideshow.needOwner", "需要主人"), chevron: owner, dim: !owner,
            action: owner ? { [weak self] in _ = srv.store.newPairing(); self?.picking = .sideshowPair } : nil)
        y += Self.row + HPGrid.Rhythm.rowGap
        footnote(g, face, L("sideshow.manage", "已配对的设备、镜像／副屏、个人内容，都在 Mac 的「设置 › iPhone 与 iPad」里管理。"), y: &y)
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
        let store = RemoteServer.shared.store
        // 配好一台（名冊變了）或碼過期：回上一頁
        guard let code = store.pairingSecret.map({ RemoteCrypto.display($0) }), let url = SideShowSettings.pairURL(code: code) else {
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
