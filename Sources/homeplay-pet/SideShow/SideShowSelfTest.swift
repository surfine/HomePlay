// SideShow、桌面小工具、CarPlay 小工具頁探驗的自檢（ShellSelfTest.run 呼叫），
// 和端對端測試用的伺服器（--sideshow-serve-test [port]：只聽 127.0.0.1、假內容、記憶體名冊；配對碼寫到 HOMEPLAY_SIDESHOW_PAIR_OUT 指的檔，0600，不進日誌）。

import AppKit

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
        check(ProcessInfo.processInfo.environment["HOMEPLAY_SIDESHOW_DIR"] != nil
              || SideShowStore.defaultFile.deletingLastPathComponent().standardizedFileURL == HomePlayState.directory.standardizedFileURL,
              "SideShow：名冊放在 HomePlayState.directory，跟著預演隔離")   // l10n-ignore
        // 金鑰工具
        check(SideShowCrypto.equal([1, 2, 3], [1, 2, 3]) && !SideShowCrypto.equal([1, 2, 3], [1, 2, 4]) && !SideShowCrypto.equal([1, 2], [1, 2, 3]), "SideShow：常數時間比對")   // l10n-ignore
        let r1 = SideShowCrypto.random(32), r2 = SideShowCrypto.random(32)
        check(r1 != nil && r1 != r2, "SideShow：系統亂數")   // l10n-ignore
        let k = SideShowCrypto.b64url(r1 ?? [])
        check(k.count == 43 && !k.contains("+") && !k.contains("/") && !k.contains("="), "SideShow：金鑰是 base64url")   // l10n-ignore
        check(SideShowCrypto.unhex(SideShowCrypto.hex([0, 255, 16])) == [0, 255, 16], "SideShow：十六進位往返")   // l10n-ignore

        // 配對碼：一次性、打錯的來源 3 次就擋、別的來源照樣能用、過期失效
        let store = SideShowStore(file: nil)
        var t = 1000.0
        store.now = { t }
        guard let code = store.newPairing() else { check(false, "SideShow：產生配對碼"); return }   // l10n-ignore
        check(code.count == 9 && store.pairingCode == code, "SideShow：配對碼 XXXX-XXXX")   // l10n-ignore
        for _ in 0..<3 { _ = store.redeem(code: "0000-0000", ip: "192.168.1.9", name: "x") }
        check(store.redeem(code: code, ip: "192.168.1.9", name: "x") == .blocked, "SideShow：同一來源打錯 3 次就不能再試")   // l10n-ignore
        guard case .ok(let id, let key) = store.redeem(code: code.lowercased(), ip: "192.168.1.10", name: "Kitchen\niPad") else {
            check(false, "SideShow：別的來源用對的碼配對成功"); return   // l10n-ignore
        }
        check(store.all.count == 1 && store.all[0].name == "KitcheniPad", "SideShow：裝置名字只留可見字元")   // l10n-ignore
        check(store.redeem(code: code, ip: "192.168.1.11", name: "y") == .badCode, "SideShow：配對碼用過一次就失效")   // l10n-ignore
        check(store.all[0].keyHash == SideShowCrypto.hex(SideShowCrypto.sha256(key)) && store.all[0].keyHash != key, "SideShow：Mac 只存金鑰雜湊")   // l10n-ignore
        let c2 = store.newPairing() ?? ""
        t += SideShowStore.pairingLifetime + 1
        check(store.pairingCode == nil && store.redeem(code: c2, ip: "192.168.1.12", name: "z") == .badCode, "SideShow：配對碼 10 分鐘失效")   // l10n-ignore

        // 驗證
        check(store.authenticate("Bearer \(id).\(key)")?.id == id, "SideShow：金鑰對＝通過")   // l10n-ignore
        check(store.authenticate("Bearer \(id).\(key)x") == nil && store.authenticate("Bearer ffff.\(key)") == nil
              && store.authenticate(nil) == nil && store.authenticate("Basic abc") == nil && store.authenticate("Bearer \(key)") == nil, "SideShow：金鑰錯、沒有、格式不對都不通過")   // l10n-ignore

        // 檔案裡沒有明文金鑰、權限 0600
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sideshow-selftest-\(UUID().uuidString)")
        let fileStore = SideShowStore(file: dir.appendingPathComponent("d.json"))
        if let c = fileStore.newPairing(), case .ok(_, let fk) = fileStore.redeem(code: c, ip: "10.0.0.2", name: "f") {
            let text = (try? String(contentsOf: fileStore.file!, encoding: .utf8)) ?? ""
            let mode = ((try? FileManager.default.attributesOfItem(atPath: fileStore.file!.path))?[.posixPermissions] as? Int) ?? 0
            check(!text.isEmpty && !text.contains(fk) && mode == 0o600, "SideShow：名冊檔只有雜湊、權限 0600")   // l10n-ignore
            check(SideShowStore(file: fileStore.file).all.count == 1, "SideShow：名冊檔讀得回來")   // l10n-ignore
        } else { check(false, "SideShow：寫名冊檔") }   // l10n-ignore
        try? FileManager.default.removeItem(at: dir)

        // 內容白名單
        let now = 1_800_000_000.0
        let off = SideShowContent.build(demoInputs(now: now))
        let onData = SideShowContent.json(SideShowContent.build(demoInputs(now: now, showCalendar: true)))
        check(SideShowContent.keys(onData).isSubset(of: SideShowState.allowedKeys), "SideShow：送出去的欄位都在白名單")   // l10n-ignore
        let onText = String(decoding: onData, as: UTF8.self)
        check(!onText.contains("Secret Street") && !onText.contains("private notes") && !onText.contains("Personal"), "SideShow：行程不帶地點、備註、日曆名")   // l10n-ignore
        check(off.next == nil && SideShowContent.build(demoInputs(now: now, showCalendar: true)).next?.title == "Dentist", "SideShow：下一個行程要主人打開才給")   // l10n-ignore
        check(SideShowContent.build(demoInputs(now: now, showCalendar: true, guestMode: true)).next == nil, "SideShow：訪客模式不給行程")   // l10n-ignore
        check(off.weather?.code == 2 && off.track?.title == "Demo Track" && off.timers.first.map { abs($0.end - (now + 300)) < 0.001 } == true && off.alerts.first?.kind == "leak",
              "SideShow：天氣、正在播放、計時器（換成 Unix 秒）、家庭警報")   // l10n-ignore

        // 路由：沒金鑰一律 401、回應裡沒有內容
        let state = { onData }
        func req(_ m: String, _ p: String, auth: String? = nil, host: String = "192.168.1.5:52426", body: String = "") -> SideShowResponse {
            var h = ["host": host]
            if let auth { h["authorization"] = auth }
            return SideShowRouter.handle(SideShowRequest(method: m, path: p, headers: h, body: Data(body.utf8), ip: "192.168.1.20"), store: store, state: state)
        }
        let noKey = req("GET", "/api/state"), badKey = req("GET", "/api/state", auth: "Bearer \(id).nope")
        check(noKey.code == 401 && badKey.code == 401 && !String(decoding: noKey.body + badKey.body, as: UTF8.self).contains("Demo Track"), "SideShow：沒金鑰或金鑰錯＝401，不洩漏內容")   // l10n-ignore
        check(req("GET", "/api/whatever").code == 401, "SideShow：其他 /api/ 也是 401")   // l10n-ignore
        let ok = req("GET", "/api/state", auth: "Bearer \(id).\(key)")
        check(ok.code == 200 && String(decoding: ok.body, as: UTF8.self).contains("Demo Track"), "SideShow：金鑰對＝拿得到內容")   // l10n-ignore
        check(req("GET", "/api/state", auth: "Bearer \(id).\(key)", host: "evil.example.com").code == 421, "SideShow：Host 不是區網名字就拒絕（擋 DNS rebinding）")   // l10n-ignore
        let page = req("GET", "/")
        check(page.code == 200 && page.page && !String(decoding: page.body, as: UTF8.self).contains("Demo Track"), "SideShow：網頁殼不帶內容")   // l10n-ignore
        let pc = store.newPairing() ?? ""
        let paired = req("POST", "/api/pair", body: #"{"code":"\#(pc)","name":"Phone"}"#)
        let po = (try? JSONSerialization.jsonObject(with: paired.body)) as? [String: String]
        check(paired.code == 200 && po?["key"] != nil && store.authenticate("Bearer \(po?["id"] ?? "").\(po?["key"] ?? "")") != nil, "SideShow：POST /api/pair 換到能用的金鑰")   // l10n-ignore
        check(req("POST", "/api/pair", body: #"{"code":"\#(pc)"}"#).code == 403 && req("POST", "/api/pair", body: "nope").code == 400, "SideShow：用過的碼 403、格式錯 400")   // l10n-ignore
        store.revoke(id)
        check(req("GET", "/api/state", auth: "Bearer \(id).\(key)").code == 401, "SideShow：移除後 401")   // l10n-ignore

        // 網頁：三語都在、格式參數一致
        if let d = SideShowPage.strings.data(using: .utf8), let all = try? JSONSerialization.jsonObject(with: d) as? [String: [String: String]] {
            check(Set(all.keys) == ["en", "zh-Hans", "zh-Hant"] && all.values.allSatisfy { $0.count == all["en"]!.count && $0["lastUpdate"]?.contains("%@") == true },
                  "SideShow：網頁字串三語齊、格式參數一致")   // l10n-ignore
        } else { check(false, "SideShow：網頁字串是 JSON") }   // l10n-ignore
        check(SideShowPage.html.contains("manifest=\"/sideshow.appcache\"") && SideShowPage.appCache.contains(SideShowPage.version), "SideShow：AppCache 版本跟著頁面")   // l10n-ignore

        // 桌面小工具：找視窗、排版、推 App
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

        // CarPlay 小工具頁探驗：步驟與訊息
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
        let srv = SideShowServer.shared
        srv.store = SideShowStore(file: nil)
        srv.inputsOverride = { SideShowSelfTest.demoInputs(now: Date().timeIntervalSince1970) }
        srv.start(port: port, loopbackOnly: true)
        if let out = ProcessInfo.processInfo.environment["HOMEPLAY_SIDESHOW_PAIR_OUT"], let code = srv.store.newPairing() {
            FileManager.default.createFile(atPath: out, contents: Data(code.utf8), attributes: [.posixPermissions: 0o600])
        }
        print("sideshow-serve-test: 127.0.0.1:\(port) for \(Int(secs)) s")
        DispatchQueue.main.asyncAfter(deadline: .now() + secs) { srv.stop(); exit(0) }
        RunLoop.main.run()
        exit(0)
    }
}
