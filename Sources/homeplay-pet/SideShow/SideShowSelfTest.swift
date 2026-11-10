// 副屏、桌面小工具、CarPlay 小工具頁探驗的自檢（ShellSelfTest.run 呼叫），
// 和端對端測試用的伺服器（--sideshow-serve-test [port]：只聽 127.0.0.1、假內容、記憶體名冊；配對碼寫到 HOMEPLAY_SIDESHOW_PAIR_OUT 指的檔，0600，不進日誌）。
//
// 身分改成公鑰之後（docs/plans/sideshow.md 的拍板），這裡釘住的是：
// 裝置簽得出、Mac 驗得過、改一個 byte 就驗不過；名冊檔裡沒有私鑰；副屏要看得到內容得先簽票；
// 個人內容（下一個行程）只有主人那台拿得到；舊版兩份名冊會被搬到 *.legacy.json。

import AppKit
import CryptoKit

enum SideShowSelfTest {
    static func demoInputs(now: Double, showCalendar: Bool = false, guestMode: Bool = false) -> SideShowContent.Inputs {
        var i = SideShowContent.Inputs(now: now)
        i.weather = WeatherData(temp: 21.4, hi: 25, lo: 17, code: 2, wind: 9, humidity: 60, aqi: nil, sunset: nil, city: "Cupertino", night: false)
        i.track = NowPlayingInfo(title: "Demo Track", artist: "Demo Artist", duration: 200, position: 50, playing: true, stamp: 0)
        i.trackPosition = 50
        i.timers = [ShellTimer(id: 1, label: "Pasta", total: 600, end: now - SideShowContent.referenceOffset + 300)]
        i.events = [AgendaEvent(id: "e1", title: "Dentist", start: Date(timeIntervalSince1970: now + 3600), end: Date(timeIntervalSince1970: now + 7200),
                                allDay: false, location: "Secret Street 1", notes: "private notes", calendarTitle: "Personal", color: 0xFF0000)]
        i.alerts = [HomeAlerts.Alert(kind: .leak, room: "Kitchen", detail: nil, at: 0)]
        i.showCalendar = showCalendar; i.guestMode = guestMode
        return i
    }

    static func run(_ check: (Bool, String) -> Void) {
        // 名冊跟其他狀態同一個資料夾：預演（HOMEPLAY_STATE_NAME）隔開時名冊也隔開
        check(ProcessInfo.processInfo.environment["HOMEPLAY_REMOTE_DIR"] != nil
              || RemoteStore.defaultFile.deletingLastPathComponent().standardizedFileURL == HomePlayState.directory.standardizedFileURL,
              "remote: 名冊放在 HomePlayState.directory，跟著預演隔離")   // l10n-ignore
        check(RemoteCrypto.equal([1, 2, 3], [1, 2, 3]) && !RemoteCrypto.equal([1, 2, 3], [1, 2, 4]) && !RemoteCrypto.equal([1, 2], [1, 2, 3]), "remote: 常數時間比對")   // l10n-ignore

        // MARK: 身分：裝置簽、Mac 驗；ECDH 兩邊一樣；改一個 byte 就失敗
        let devAgree = P256.KeyAgreement.PrivateKey(), devSign = P256.Signing.PrivateKey()
        let devAgreeRaw = devAgree.publicKey.x963Representation, devSignRaw = devSign.publicKey.x963Representation
        check(devAgreeRaw.count == 65 && devSignRaw.count == 65, "identity: P-256 公鑰是 raw 65 bytes")   // l10n-ignore
        let nonceC = [UInt8](repeating: 7, count: 6), nonceS = [UInt8](repeating: 9, count: 6)
        let eph = RemoteIdentity.newEphemeral()
        let transcript = RemoteIdentity.streamTranscript(kind: 0x44, id: "0011223344556677", nonceC: nonceC, ephS: eph.publicKey.x963Representation, nonceS: nonceS)
        let sig = (try? devSign.signature(for: transcript))?.rawRepresentation ?? Data()
        check(RemoteIdentity.verify(sig, transcript: transcript, signKey: devSignRaw), "identity: 裝置簽章驗得過")   // l10n-ignore
        check(!RemoteIdentity.verify(sig, transcript: transcript + Data([0]), signKey: devSignRaw), "identity: 訊息多一個 byte 就驗不過")   // l10n-ignore
        check(!RemoteIdentity.verify(Data(repeating: 0, count: 64), transcript: transcript, signKey: devSignRaw), "identity: 亂數簽章驗不過")   // l10n-ignore
        var otherKey = devSignRaw; otherKey[64] ^= 1
        check(!RemoteIdentity.verify(sig, transcript: transcript, signKey: otherKey), "identity: 公鑰不對就驗不過")   // l10n-ignore
        let a = RemoteIdentity.streamKey(privateKey: eph, peer: devAgreeRaw, nonceC: nonceC, nonceS: nonceS)
        let b = RemoteIdentity.streamKey(privateKey: devAgree, peer: eph.publicKey.x963Representation, nonceC: nonceC, nonceS: nonceS)
        check(a != nil && b != nil && a!.withUnsafeBytes({ Data($0) }) == b!.withUnsafeBytes({ Data($0) }), "identity: ECDH 兩邊算出同一把工作階段金鑰")   // l10n-ignore
        check(RemoteIdentity.streamKey(privateKey: eph, peer: Data(repeating: 4, count: 65), nonceC: nonceC, nonceS: nonceS) == nil, "identity: 公鑰格式不對＝金鑰 nil")   // l10n-ignore

        // MARK: 配對碼：一次性、打錯的來源 3 次就擋、別的來源照樣能用、過期失效
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hp-selftest-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("devices.json")
        let store = RemoteStore(file: file)
        var t = 1000.0
        store.now = { t }
        let code = RemoteCrypto.display(store.newPairing())
        check(code.count == 19 && store.pairingSecret != nil, "remote: 配對碼 XXXX-XXXX-XXXX-XXXX")   // l10n-ignore
        let bad = { store.redeem(code: "0000-0000", ip: "192.168.1.9", name: "x", agree: devAgreeRaw, sign: devSignRaw, mirror: true, side: false) }
        for _ in 0..<3 { _ = bad() }
        check(bad() == .blocked, "remote: 同一來源打錯 3 次就不能再試")   // l10n-ignore
        guard case .ok(let id) = store.redeem(code: code.lowercased(), ip: "192.168.1.10", name: "Kitchen\niPad", agree: devAgreeRaw, sign: devSignRaw, mirror: false, side: true) else {
            check(false, "remote: 別的來源用對的碼配對成功"); return   // l10n-ignore
        }
        check(store.all.count == 1 && store.all[0].name == "KitcheniPad" && store.all[0].side && !store.all[0].mirror, "remote: 裝置名字只留可見字元、記下收哪種內容")   // l10n-ignore
        check(store.redeem(code: code, ip: "192.168.1.11", name: "y", agree: devAgreeRaw, sign: devSignRaw, mirror: true, side: false) == .badCode, "remote: 配對碼用過一次就失效")   // l10n-ignore
        let c2 = RemoteCrypto.display(store.newPairing())
        t += RemoteStore.pairingLifetime + 1
        check(store.pairingSecret == nil && store.redeem(code: c2, ip: "192.168.1.12", name: "z", agree: devAgreeRaw, sign: devSignRaw, mirror: true, side: false) == .badCode, "remote: 配對碼 10 分鐘失效")   // l10n-ignore

        // 名冊檔：沒有私鑰、權限 0600、讀得回來
        let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        let mode = ((try? FileManager.default.attributesOfItem(atPath: file.path))?[.posixPermissions] as? Int) ?? 0
        check(!text.isEmpty && !text.lowercased().contains("private") && mode == 0o600, "remote: 名冊檔只有公鑰、權限 0600")   // l10n-ignore
        check(RemoteStore(file: file).all.first?.id == id, "remote: 名冊檔讀得回來")   // l10n-ignore
        check(store.keys(for: id)?.sign == devSignRaw && store.keys(for: id)?.agree == devAgreeRaw, "remote: 公鑰讀得回來")   // l10n-ignore
        check(store.add(name: "x", agree: Data(repeating: 3, count: 65), sign: devSignRaw) == nil, "remote: 公鑰格式不對就不進名冊")   // l10n-ignore

        // MARK: 內容白名單
        let now = 1_800_000_000.0
        let off = SideShowContent.build(demoInputs(now: now))
        let onData = SideShowContent.json(SideShowContent.build(demoInputs(now: now, showCalendar: true)))
        check(SideShowContent.keys(onData).isSubset(of: SideShowState.allowedKeys), "SideShow：送出去的欄位都在白名單")   // l10n-ignore
        let onText = String(decoding: onData, as: UTF8.self)
        check(!onText.contains("Secret Street") && !onText.contains("private notes") && !onText.contains("Personal"), "SideShow：行程不帶地點、備註、日曆名")   // l10n-ignore
        check(off.next == nil && SideShowContent.build(demoInputs(now: now, showCalendar: true)).next?.title == "Dentist", "SideShow：下一個行程要看得到才給")   // l10n-ignore
        check(SideShowContent.build(demoInputs(now: now, showCalendar: true, guestMode: true)).next == nil, "SideShow：訪客模式不給行程")   // l10n-ignore
        check(off.weather?.code == 2 && off.track?.title == "Demo Track" && off.timers.first.map { abs($0.end - (now + 300)) < 0.001 } == true && off.alerts.first?.kind == "leak",
              "SideShow：天氣、正在播放、計時器（換成 Unix 秒）、家庭警報")   // l10n-ignore

        // MARK: 路由：沒票一律 401；簽票要對得上名冊；鏡像／副屏各自把關
        let feed = SideShowFeed()
        feed.inputsOverride = { demoInputs(now: now, showCalendar: true) }
        feed.refresh()
        let tickets = RemoteSideTickets()
        tickets.now = { t }
        func req(_ m: String, _ p: String, host: String = "192.168.1.5:52424", headers: [String: String] = [:], body: String = "") -> SideShowResponse {
            var h = headers; h["host"] = host
            return SideRoute.handle(SideShowRequest(method: m, path: p, headers: h, body: Data(body.utf8), ip: "192.168.1.20"),
                                    store: store, tickets: tickets, feed: feed) ?? .json(404, ["error": "not found"])
        }
        func signIn(_ at: Double) -> SideShowResponse {
            let sec = Int(at.rounded())   // 裝置與 Mac 都以整秒簽（RemoteIdentity.sideTranscript 會四捨五入）
            let tr = RemoteIdentity.sideTranscript(id: id, at: Double(sec))
            let s = (try? devSign.signature(for: tr))?.rawRepresentation ?? Data()
            return req("POST", "/side/session", body: #"{"id":"\#(id)","at":\#(sec),"sig":"\#(s.base64EncodedString())"}"#)
        }
        let noTicket = req("GET", "/side/state")
        check(noTicket.code == 401 && !String(decoding: noTicket.body, as: UTF8.self).contains("Demo Track"), "remote: 沒票＝401，不洩漏內容")   // l10n-ignore
        t = Date().timeIntervalSince1970
        let signed = signIn(t)
        let ticket = (try? JSONSerialization.jsonObject(with: signed.body)) as? [String: String]
        check(signed.code == 200 && ticket?["ticket"] != nil, "remote: 簽票換得到票據")   // l10n-ignore
        let ok = req("GET", "/side/state", headers: ["x-side-ticket": ticket?["ticket"] ?? ""])
        check(ok.code == 200 && String(decoding: ok.body, as: UTF8.self).contains("Demo Track"), "remote: 有票＝拿得到內容")   // l10n-ignore
        check(String(decoding: ok.body, as: UTF8.self).contains("Dentist"), "remote: 主人那台看得到下一個行程")   // l10n-ignore
        check(req("GET", "/side/state", host: "evil.example.com", headers: ["x-side-ticket": ticket?["ticket"] ?? ""]).code == 421, "remote: Host 不是區網名字就拒絕（擋 DNS rebinding）")   // l10n-ignore
        check(signIn(t + RemoteIdentity.sideClockWindow + 10).code == 401, "remote: 簽票的時間差太多＝401")   // l10n-ignore
        let forged = req("POST", "/side/session", body: #"{"id":"\#(id)","at":\#(Int(t)),"sig":"\#(Data(repeating: 0, count: 64).base64EncodedString())"}"#)
        check(forged.code == 401, "remote: 簽章不對＝401")   // l10n-ignore

        // 訪客裝置（personal 關）只拿得到公開版本
        let guestTicket = tickets.issue(id)
        store.setPersonal(id, false)
        let guest = req("GET", "/side/state", headers: ["x-side-ticket": guestTicket])
        check(guest.code == 200 && !String(decoding: guest.body, as: UTF8.self).contains("Dentist"), "remote: 沒開個人內容就沒有下一個行程")   // l10n-ignore
        store.setPersonal(id, true)

        // 關掉副屏：舊票立刻作廢
        store.setSide(id, false)
        tickets.revoke(id)
        check(req("GET", "/side/state", headers: ["x-side-ticket": guestTicket]).code == 401, "remote: 關掉副屏＝401")   // l10n-ignore
        store.setSide(id, true)

        // 頁面與資產在 /side/，根目錄那頁不帶內容
        let page = req("GET", "/side/")
        check(page.code == 200 && page.page && !String(decoding: page.body, as: UTF8.self).contains("Demo Track"), "remote: 副屏頁不帶內容")   // l10n-ignore
        check(req("GET", "/side").code == 308 && req("GET", "/side").location == "/side/", "remote: /side 導到 /side/（service worker 的作用域）")   // l10n-ignore
        check(req("GET", "/side/sw.js").code == 200 && req("GET", "/side/manifest.webmanifest").code == 200, "remote: 副屏的 sw 與 manifest")   // l10n-ignore
        check(req("GET", "/nope").code == 404, "remote: 不認得的路徑 404")   // l10n-ignore

        // 配對走 HTTP：公鑰進名冊、回應裡沒有祕密
        let pc = RemoteCrypto.display(store.newPairing())
        let d2Sign = P256.Signing.PrivateKey()
        let paired = req("POST", "/pair", body: #"{"code":"\#(pc)","name":"Phone","mode":"both","agree":"\#(devAgreeRaw.base64EncodedString())","sign":"\#(d2Sign.publicKey.x963Representation.base64EncodedString())"}"#)
        let po = (try? JSONSerialization.jsonObject(with: paired.body)) as? [String: String]
        check(paired.code == 200 && po?["id"] != nil && po?["key"] == nil, "remote: POST /pair 只回 id，不回任何祕密")   // l10n-ignore
        check(store.device(po?["id"] ?? "")?.mirror == true && store.device(po?["id"] ?? "")?.side == true, "remote: mode=both 兩種都開")   // l10n-ignore
        check(req("POST", "/pair", body: #"{"code":"\#(pc)","agree":"x","sign":"y"}"#).code == 403 || req("POST", "/pair", body: "nope").code == 400, "remote: 用過的碼 403、格式錯 400")   // l10n-ignore

        // 舊名冊搬家：兩份都變成 *.legacy.json，新名冊從空的開始
        let oldR = dir.appendingPathComponent("old-remote.json"), oldS = dir.appendingPathComponent("old-side.json")
        try? Data(#"[{"id":"a","name":"x","key":"SECRET"}]"#.utf8).write(to: oldR)
        try? Data(#"[{"id":"b"},{"id":"c"}]"#.utf8).write(to: oldS)
        let moved = RemoteStore.archiveLegacy(remote: oldR, side: oldS)
        check(moved.remote == 1 && moved.side == 2 && !FileManager.default.fileExists(atPath: oldR.path)
              && FileManager.default.fileExists(atPath: dir.appendingPathComponent("old-remote.legacy.json").path), "remote: 舊名冊搬到 *.legacy.json（不刪）")   // l10n-ignore
        check(RemoteStore.archiveLegacy(remote: oldR, side: oldS) == (0, 0), "remote: 搬過就不再動")   // l10n-ignore

        store.revoke(id)
        check(store.all.count == 1 && store.all[0].id == (po?["id"] ?? ""), "remote: 移除只踢掉那一台")   // l10n-ignore

        // MARK: 網頁：三語都在、格式參數一致、AppCache 跟著頁面
        if let d = SideShowPage.strings.data(using: .utf8), let all = try? JSONSerialization.jsonObject(with: d) as? [String: [String: String]] {
            check(Set(all.keys) == ["en", "zh-Hans", "zh-Hant"] && all.values.allSatisfy { $0.count == all["en"]!.count && $0["lastUpdate"]?.contains("%@") == true },
                  "SideShow：網頁字串三語齊、格式參數一致")   // l10n-ignore
        } else { check(false, "SideShow：網頁字串是 JSON") }   // l10n-ignore
        check(SideShowPage.html.contains("manifest=\"/side/sideshow.appcache\"") && SideShowPage.appCache.contains(SideShowPage.version), "SideShow：AppCache 版本跟著頁面")   // l10n-ignore
        check(SideShowPage.serviceWorker.contains("/side/state") && SideShowPage.manifest.contains("\"start_url\":\"/side/\""), "SideShow：快取不含內容、manifest 指到 /side/")   // l10n-ignore

        // MARK: 桌面小工具：找視窗、排版、推 App
        let lvl = -2147483601
        check(DesktopWidgets.isWidget(bundle: DesktopWidgets.ownerBundle, layer: lvl, frame: CGRect(x: 8, y: 42, width: 180, height: 180)), "桌面小工具：通知中心在桌面層的小視窗")   // l10n-ignore
        check(!DesktopWidgets.isWidget(bundle: DesktopWidgets.ownerBundle, layer: 21, frame: CGRect(x: 0, y: 0, width: 300, height: 300))
              && !DesktopWidgets.isWidget(bundle: DesktopWidgets.ownerBundle, layer: lvl, frame: CGRect(x: 0, y: 0, width: 1710, height: 1107))
              && !DesktopWidgets.isWidget(bundle: "com.apple.finder", layer: lvl, frame: CGRect(x: 8, y: 42, width: 180, height: 180)), "桌面小工具：一般層、全螢幕、別的 App 都不算")   // l10n-ignore
        let lay = DesktopWidgets.layout([CGRect(x: 8, y: 42, width: 180, height: 180), CGRect(x: 8, y: 222, width: 360, height: 180)], in: CGRect(x: 0, y: 0, width: 400, height: 400))
        check(lay.count == 2 && abs(lay[1].width - lay[0].width * 2) < 0.01 && lay[1].minY > lay[0].minY && abs(lay[0].minX - lay[1].minX) < 0.01, "桌面小工具：照桌面上的相對位置縮放")   // l10n-ignore
        let apps = ["行事曆": "com.apple.iCal", "天氣": "com.apple.weather", "Notes": "com.apple.Notes"]   // l10n-ignore
        check(DesktopWidgets.bundle(forTitle: "行事曆", apps: apps) == "com.apple.iCal" && DesktopWidgets.bundle(forTitle: "月曆", apps: apps) == "com.apple.iCal"   // l10n-ignore
              && DesktopWidgets.bundle(forTitle: "Notes Folder", apps: apps) == "com.apple.Notes", "桌面小工具：照名字推 App")   // l10n-ignore
        check(DesktopWidgets.bundle(forTitle: "Batteries", apps: apps) == nil && DesktopWidgets.bundle(forTitle: "Zzz", apps: apps) == nil, "桌面小工具：推不出就回 nil（開桌面）")   // l10n-ignore

        // MARK: CarPlay 小工具頁探驗：步驟與訊息
        let st = CarPlayWidgetProbe.steps(nil)
        check(st.count == CarPlayWidgetProbe.candidates.count * 2 && st[0] == .init(url: "dashboard:", kind: "requestUI", uuid: false) && st[1].uuid, "CarPlay 探驗：每個網址兩種請求")   // l10n-ignore
        check(CarPlayWidgetProbe.steps("widgets:,bad,x-y:z").map(\.url) == ["widgets:", "widgets:", "x-y:z", "x-y:z"], "CarPlay 探驗：自訂網址清單")   // l10n-ignore
        check(CarPlayWidgetProbe.message(st[1]) == #"{"kind":"showUI","type":"showUI","url":"dashboard:","uuid":true}"#, "CarPlay 探驗：接收端認得的訊息")   // l10n-ignore
    }
}

/// --sideshow-serve-test [port] [--sideshow-test-seconds N]
enum SideShowServeTest {
    static func run() -> Never {
        let a = CommandLine.arguments
        var port: UInt16 = 52499
        if let i = a.firstIndex(of: "--sideshow-serve-test"), i + 1 < a.count, let p = UInt16(a[i + 1]) { port = p }
        let secs = arg("--sideshow-test-seconds").flatMap(Double.init) ?? 120
        let srv = RemoteServer.shared
        srv.store = RemoteStore(file: URL(fileURLWithPath: "/dev/null/\(UUID().uuidString).json"))
        srv.feed.inputsOverride = { SideShowSelfTest.demoInputs(now: Date().timeIntervalSince1970) }
        srv.start(port: port, loopbackOnly: true)
        if let out = ProcessInfo.processInfo.environment["HOMEPLAY_SIDESHOW_PAIR_OUT"] {
            FileManager.default.createFile(atPath: out, contents: Data(RemoteCrypto.display(srv.store.newPairing()).utf8), attributes: [.posixPermissions: 0o644])
        }
        print("sideshow-serve-test: 127.0.0.1:\(port) for \(Int(secs)) s")
        DispatchQueue.main.asyncAfter(deadline: .now() + secs) { srv.stop(); exit(0) }
        RunLoop.main.run()
        exit(0)
    }
}
