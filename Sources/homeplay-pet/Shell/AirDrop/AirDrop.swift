// AirDrop 整合的門面：啟動／結束、每幀、示範旗標。三塊功能各在自己的檔案：
// 收件卡片（AirDropInbox／AirDropCard）、傳到手機（AirDropShare）、訪客臨時接收（AirDropGuest）。
// 快照旗標：--demo-airdrop-carplay share|sent|nofda（CarPlay 連著時傳給自己的確認卡、已傳送、沒有完整磁碟取用權限）、
// live（只假裝在會話中，拍控制中心「收 AirDrop」可按）、paused|received（暫停 CarPlay 的倒數卡、收到檔案後）；
// --demo-airdrop photo|link|file|guest（用假檔案，不碰「下載項目」；guest＝收到一個檔案但在訪客模式下）。

import AppKit

enum AirDrop {
    /// 啟動：補還原舊版留下的可被發現設定、開始監看「下載項目」。快照／自檢／診斷不做
    static func start(view: PetView) {
        guard !CCSystem.demo, !AppDelegate.isDiagnosticRun else { return }
        AirDropGuest.shared.recoverIfNeeded()
        AirDropInbox.shared.onReceive = { [weak view] item in
            AirDropCard.receive(item, now: CACurrentMediaTime())
            CarPlayAirDropPause.shared.fileReceived()   // 「收 AirDrop」暫停 CarPlay 中：傳完再 5 秒恢復
            view?.face.forceDirty = true
        }
        if !AirDropInbox.shared.start() { log("airdrop inbox: Downloads not readable") }
    }

    /// 結束：回 true＝剛送了恢復 CarPlay 的指令（呼叫端等一下讓它送出去）
    @discardableResult
    static func shutdown() -> Bool {
        let resumed = CarPlayAirDropPause.shared.shutdown()   // 「收 AirDrop」暫停中：一定送 resume（接收端也有 3 分鐘保底）
        AirDropInbox.shared.stop()
        return resumed
    }

    /// 每幀（tickShell）：卡片的出入與逾時、倒數換秒。延長與恢復有自己的計時器（錶面不更新時照樣跑），這裡只順手補檢查。回 true＝要重畫
    static func tick(_ now: Double) -> Bool {
        var dirty = AirDropCard.tick(now)
        if CarPlayAirDropPause.shared.secondChanged(now: now) { dirty = true }   // 「收 AirDrop」：倒數換秒（延長、恢復由它自己的計時器推動）
        let cp = CarPlayAirDropCard.presence(now)
        if SelfShare.carPlayActive { SelfShareFlow.shared.prefetch(now: now) }   // CarPlay 連著：先在背景查好自己的帳號，按下時不用等
        if SelfShareFlow.shared.tick(now: now) || (cp > 0.001 && cp < 0.999) || (cp <= 0.001) != (CarPlayAirDropCard.last == nil) { dirty = true }   // 傳給自己的卡：進出、傳送中的點
        return dirty
    }

    /// 快照旗標
    static func applyDemo(_ args: [String]) {
        if let i = args.firstIndex(of: "--demo-airdrop-carplay"), i + 1 < args.count { applyCarPlayDemo(args[i + 1]) }
        guard let i = args.firstIndex(of: "--demo-airdrop"), i + 1 < args.count else { return }
        let mode = args[i + 1]
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("homeplay-airdrop-demo", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var item: AirDropItem
        switch mode {
        case "link":
            item = AirDropItem(url: dir.appendingPathComponent("Pasta carbonara.webloc"), kind: .link, link: URL(string: "https://www.example.com/recipes/pasta-carbonara"))
        case "file":
            let u = dir.appendingPathComponent("Boarding pass.pdf")
            try? Data("%PDF-1.4\n".utf8).write(to: u)
            item = AirDropItem(url: u, kind: .other, link: nil)
        case "photo", "guest":
            let u = dir.appendingPathComponent("IMG_2048.jpg")
            let img = makeImage(640, 480) { c in
                let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [NSColor(srgbRed: 0.98, green: 0.62, blue: 0.35, alpha: 1).cgColor,
                                                                                         NSColor(srgbRed: 0.35, green: 0.45, blue: 0.85, alpha: 1).cgColor] as CFArray, locations: [0, 1])!
                c.drawLinearGradient(g, start: .zero, end: CGPoint(x: 640, y: 480), options: [])
                c.setFillColor(NSColor.white.withAlphaComponent(0.85).cgColor); c.fillEllipse(in: CGRect(x: 420, y: 70, width: 90, height: 90))
            }
            if let d = CGImageDestinationCreateWithURL(u as CFURL, "public.jpeg" as CFString, 1, nil) {
                CGImageDestinationAddImage(d, img, nil); CGImageDestinationFinalize(d)
            }
            item = AirDropItem(url: u, kind: mode == "guest" ? .other : .photo, link: nil)
            if mode == "guest" { AirDropCard.redactedOverride = true; item.kind = .photo }
        default: return
        }
        AirDropCard.receive(item, now: CACurrentMediaTime())
    }
}

extension AirDrop {
    /// --demo-airdrop-carplay：假裝主人的 iPhone 在 CarPlay 會話中（不碰真的「訊息」）
    static func applyCarPlayDemo(_ mode: String) {
        SelfShare.forceCarPlay = true
        let img = makeImage(640, 480) { c in c.setFillColor(NSColor.systemOrange.cgColor); c.fill(CGRect(x: 0, y: 0, width: 640, height: 480)) }
        switch mode {
        case "share": SelfShareFlow.shared.demo(.confirming(summary: SelfShare.summary(.image(img))), payload: .image(img))
        case "sent": SelfShareFlow.shared.demo(.done(.sent), payload: .image(img))
        case "nofda": SelfShareFlow.shared.demo(.done(.needsFullDisk), payload: .image(img))
        case "paused": CarPlayAirDropPause.shared.demo(left: 42)
        case "received": CarPlayAirDropPause.shared.demo(left: 30, received: true)
        default: break
        }
    }
}
