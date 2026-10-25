// 2.0 閒置裝置·網頁串流的自檢（--selftest 呼叫）：純函數＋一台只聽 127.0.0.1 的伺服器走真的 WebSocket。
// 驗：沒配對的被拒、配對碼打錯／用過／過期被拒、配對後拿得到畫面、移除後連線被踢而且連不回來、
// 非區網位址被拒、Host 不對被拒、裝置端的 JavaScript 加密跟 CryptoKit 一樣、變更區塊、訪客遮罩的真值表、檔案權限 0600。
// 安全複審（2026-10-25）加的：訪客拿不到不安全時畫的舊幀（H1）、允許清單用真的 App id、相片觀眾（H2）、訪客寫不了門鎖（H3）、
// 同一台兩個位址同時連＝自動移除（H4）、交接碼（M1）、控制框／ack／pong（M2）、訪客一碰 ClioTalk 就拿不到個人工具（M3）、
// 撤銷不會被舊快照寫回來（M5）、單一來源連線上限與打錯碼的上限。

import Foundation
import CryptoKit
import Network
import JavaScriptCore
import ImageIO
import QuartzCore

enum RemoteSelftest {
    static func run(_ check: (Bool, String) -> Void) {
        codes(check)
        addresses(check)
        jsCrypto(check)
        frames(check)
        privacy(check)
        ledger(check)
        homeAndClio(check)
        guestHomeAndMusic(check)
        storeRace(check)
        server(check)
    }

    // MARK: 配對碼

    static func codes(_ check: (Bool, String) -> Void) {
        let s = RemoteCrypto.newPairingSecret()
        check(s.count == 10, "remote: 配對碼 80 bits")
        check(RemoteCrypto.decode(RemoteCrypto.encode(s)) == s, "remote: 配對碼 base32 來回")
        let d = RemoteCrypto.display(s)
        check(d.count == 19 && d.split(separator: "-").count == 4, "remote: 配對碼顯示成 4 組 4 字")
        check(RemoteCrypto.decode(d.lowercased().replacingOccurrences(of: "0", with: "o")) == s, "remote: 小寫、O 當 0 也讀得懂")
        check(RemoteCrypto.decode("ABCU") == nil, "remote: 不在字母表的字拒絕")

        // 一次性、過期、打錯 5 次
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hp-remote-\(UUID().uuidString)")
        let st = RemoteStore(file: dir.appendingPathComponent("remote-devices.json"))
        var t = 1000.0
        st.now = { t }
        check(st.pairingSecret == nil, "remote: 沒產生碼就不能配對")
        st.newPairing()
        check(st.pairingSecret != nil, "remote: 產生的碼可用")
        t += RemoteStore.pairingLifetime + 1
        check(st.pairingSecret == nil, "remote: 10 分鐘後失效")
        st.newPairing()
        for _ in 0..<RemoteStore.maxPairingFailuresPerIP { st.pairingFailed(ip: "192.168.1.66") }
        check(st.pairingSecret(for: "192.168.1.66") == nil && st.pairingSecret(for: "192.168.1.20") != nil, "remote: 一個來源打錯 3 次只擋它自己，主人的碼對別的裝置照樣有效")
        for i in 0..<(RemoteStore.maxPairingFailures - RemoteStore.maxPairingFailuresPerIP - 1) { st.pairingFailed(ip: "10.0.0.\(i)") }
        check(st.pairingSecret != nil, "remote: 全部打錯 19 次還能用")
        st.pairingFailed(ip: "10.0.1.1")
        check(st.pairingSecret == nil, "remote: 全部打錯 20 次作廢")
        st.newPairing(); st.pairingUsed()
        check(st.pairingSecret == nil, "remote: 用過一次就失效")
        // 裝置與權限
        let dev = st.add(name: "iPad\u{0007} · iPadOS 15.8")
        check(dev.name == "iPad · iPadOS 15.8" && !dev.personal, "remote: 新裝置名字去控制字元、預設是訪客")
        let mode = (try? FileManager.default.attributesOfItem(atPath: st.file.path)[.posixPermissions] as? Int) ?? -1
        check(mode == 0o600, "remote: 裝置金鑰檔 0600（實際 \(String(mode, radix: 8))）")
        check(RemoteStore(file: st.file).key(for: dev.id) != nil, "remote: 金鑰存檔後讀得回來")
        // 交接碼：60 秒、用一次、移除後失效
        let tok = st.newHandoff(for: dev.id)
        let tb = tok.flatMap { RemoteCrypto.decode($0) } ?? []
        let tid = tb.prefix(8).map { String(format: "%02x", $0) }.joined()
        check(tb.count == 24 && st.takeHandoff(tid)?.device == dev.id && st.takeHandoff(tid) == nil, "remote: 交接碼用一次就沒了")
        let tok2 = st.newHandoff(for: dev.id).flatMap { RemoteCrypto.decode($0) } ?? []
        t += RemoteStore.handoffLifetime + 1
        check(st.takeHandoff(tok2.prefix(8).map { String(format: "%02x", $0) }.joined()) == nil, "remote: 交接碼 60 秒後失效")
        func tidOf(_ b: [UInt8]) -> String { b.prefix(8).map { String(format: "%02x", $0) }.joined() }
        let tok3 = st.newHandoff(for: dev.id).flatMap { RemoteCrypto.decode($0) } ?? []
        let tok4 = st.newHandoff(for: dev.id).flatMap { RemoteCrypto.decode($0) } ?? []
        let tok5 = st.newHandoff(for: dev.id).flatMap { RemoteCrypto.decode($0) } ?? []
        check(st.takeHandoff(tidOf(tok3)) == nil && st.takeHandoff(tidOf(tok4)) != nil && st.takeHandoff(tidOf(tok5)) != nil, "remote: 同一台只留最近兩張交接碼（網址換新的時，分享選單拿到的上一張還能用）")
        st.revoke(dev.id)
        check(RemoteStore(file: st.file).key(for: dev.id) == nil, "remote: 移除後金鑰不在檔裡")
        check(st.newHandoff(for: dev.id) == nil, "remote: 移除的裝置拿不到交接碼")
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: 區網

    static func addresses(_ check: (Bool, String) -> Void) {
        func h(_ s: String) -> NWEndpoint.Host { NWEndpoint.Host(s) }
        for a in ["192.168.5.9", "10.0.0.2", "172.16.0.1", "172.31.255.255", "169.254.3.4", "127.0.0.1", "::1", "fe80::1", "fd12:3456::1", "::ffff:192.168.1.2"] {
            check(RemoteCrypto.isPrivate(h(a)), "remote: \(a) 是區網")
        }
        for a in ["8.8.8.8", "172.32.0.1", "100.64.1.1", "1.1.1.1", "2001:db8::1", "::ffff:8.8.8.8", "192.169.0.1", "fd7a:115c:a1e0::1", "fd7a:115c:a1e0:ab12::5"] {
            check(!RemoteCrypto.isPrivate(h(a)), "remote: \(a) 不是區網")
        }
        check(!RemoteServer.admits(.hostPort(host: "203.0.113.7", port: 50000)), "remote: 外網來源的連線被拒")
        check(RemoteServer.admits(.hostPort(host: "192.168.1.20", port: 50000)), "remote: 區網來源的連線收下")
        let hostsOK = RemoteCrypto.hostAllowed("192.168.5.9:52424") && RemoteCrypto.hostAllowed("Aarons-MacBook-Air.local:52424") && RemoteCrypto.hostAllowed("[fe80::1]:52424")
        check(hostsOK, "remote: IP／.local 的 Host 收下")
        check(!RemoteCrypto.hostAllowed("evil.example.com") && !RemoteCrypto.hostAllowed("evil.example.com:52424"), "remote: 別的網域（DNS rebinding）被拒")
        let badHosts = ["[evil.example.com]:52424", "[fe80::1", "[::1]x", "[fe80::1%en0]:1", "a.local; script-src *", "a b.local", "192.168.1.2:99999", "192.168.1.2:x", ".local", ""]
        check(badHosts.allSatisfy { RemoteCrypto.canonicalHost($0) == nil }, "remote: 方括號裡不是 IPv6、怪字元、壞 port 的 Host 被拒")
        check(RemoteCrypto.canonicalHost("[FE80::0001]:52424") == "[fe80::1]:52424" && RemoteCrypto.canonicalHost("Mac.LOCAL:52424") == "mac.local:52424" && RemoteCrypto.canonicalHost("192.168.5.9") == "192.168.5.9", "remote: Host 重組成標準寫法（CSP 不回填原字串）")
        check(RemoteServer.clampInput(5, last: 4) == 5 && RemoteServer.clampInput(4, last: 4) == nil && RemoteServer.clampInput(UInt32.max, last: 4) == nil, "remote: 裝置的輸入序號只能往前、一次最多跳 1000")
        check(RemoteServer.conflicting("192.168.1.2", others: ["192.168.1.9"]) && !RemoteServer.conflicting("192.168.1.2", others: ["192.168.1.2"]) && !RemoteServer.conflicting("192.168.1.2", others: []), "remote: 同一台從兩個位址連＝衝突")
    }

    // MARK: 裝置端 JavaScript 加密＝CryptoKit

    static func jsCrypto(_ check: (Bool, String) -> Void) {
        guard let js = JSContext() else { check(false, "remote: JavaScriptCore"); return }
        js.evaluateScript(RemotePage.cryptoJS + "\nvar HPCok = typeof HPC;")
        check(js.objectForKeyedSubscript("HPCok").toString() == "object", "remote: 頁面的加密程式載得起來")
        let keyB = (0..<32).map { UInt8(($0 * 7 + 3) & 255) }, nonceB = (0..<12).map { UInt8(($0 * 13 + 1) & 255) }
        let key = SymmetricKey(data: Data(keyB)), nonce = try! ChaChaPoly.Nonce(data: Data(nonceB))
        func arr(_ b: [UInt8]) -> String { "new Uint8Array([" + b.map(String.init).joined(separator: ",") + "])" }
        func hexJS(_ expr: String) -> String {
            js.evaluateScript("(function(a){var s='';for(var i=0;i<a.length;i++){s+=(a[i]<16?'0':'')+a[i].toString(16)}return s})(\(expr))")?.toString() ?? ""
        }
        func hex(_ d: Data) -> String { d.map { String(format: "%02x", $0) }.joined() }
        var same = true
        for n in [0, 1, 16, 63, 64, 65, 500] {
            let pt = (0..<n).map { UInt8(($0 * 31 + 5) & 255) }
            let box = try! ChaChaPoly.seal(Data(pt), using: key, nonce: nonce)
            if hexJS("HPC.seal(\(arr(keyB)),\(arr(nonceB)),\(arr(pt)))") != hex(box.ciphertext + box.tag) { same = false }
            if hexJS("HPC.open(\(arr(keyB)),\(arr(nonceB)),\(arr(Array(box.ciphertext + box.tag))))") != hex(Data(pt)) { same = false }
        }
        check(same, "remote: 頁面的 ChaCha20-Poly1305 跟 CryptoKit 逐位元組一樣")
        let tampered = Array(try! ChaChaPoly.seal(Data([1, 2, 3]), using: key, nonce: nonce).ciphertext) + [UInt8](repeating: 0, count: 16)
        check(js.evaluateScript("HPC.open(\(arr(keyB)),\(arr(nonceB)),\(arr(tampered)))")?.isNull == true, "remote: 頁面拒絕被改過的訊息")
        let nc = Array(nonceB[0..<6]), ns = Array(nonceB[6..<12])
        let sk = RemoteCrypto.sessionKey(key, nonceC: nc, nonceS: ns)!.withUnsafeBytes { Data($0) }
        check(hexJS("HPC.derive(\(arr(keyB)),\(arr(nonceB)))") == hex(sk), "remote: session key 兩邊算的一樣")
    }

    // MARK: 變更區塊

    static func frames(_ check: (Bool, String) -> Void) {
        let n = 1024 * 1024 * 4
        var a = [UInt8](repeating: 0, count: n), b = a
        a.withUnsafeBufferPointer { pa in b.withUnsafeBufferPointer { pb in
            check(RemoteFrames.dirtyRects(pa.baseAddress!, pb.baseAddress!).isEmpty, "remote: 沒變＝不送")
        } }
        b[(100 * 1024 + 100) * 4] = 9
        b[(700 * 1024 + 900) * 4] = 9
        a.withUnsafeBufferPointer { pa in b.withUnsafeBufferPointer { pb in
            let r = RemoteFrames.dirtyRects(pb.baseAddress!, pa.baseAddress!)
            check(r == [CGRect(x: 64, y: 64, width: 64, height: 64), CGRect(x: 896, y: 640, width: 64, height: 64)], "remote: 只送變了的兩格（\(r)）")
            check(RemoteFrames.dirtyRects(pb.baseAddress!, nil) == [CGRect(x: 0, y: 0, width: 1024, height: 1024)], "remote: 第一幀整張")
        } }
        for y in 0..<1024 { for x in stride(from: 0, to: 640, by: 64) { a[(y * 1024 + x) * 4 + 1] = 7 } }
        a.withUnsafeBufferPointer { pa in b.withUnsafeBufferPointer { pb in
            check(RemoteFrames.dirtyRects(pa.baseAddress!, pb.baseAddress!) == [CGRect(x: 0, y: 0, width: 1024, height: 1024)], "remote: 變了超過一半就整張")
        } }
        let m = RemoteFrames.message(seq: 7, inputAck: 3, parts: [(CGRect(x: 64, y: 128, width: 64, height: 192), Data([1, 2, 3]))])
        check(Array(m) == [0x46, 7, 0, 0, 0, 3, 0, 0, 0, 1, 0, 64, 0, 128, 0, 64, 0, 192, 0, 3, 0, 0, 0, 1, 2, 3], "remote: 幀格式（小端）")
    }

    // MARK: 訪客

    static func privacy(_ check: (Bool, String) -> Void) {
        typealias S = RemotePrivacy.Screen
        check(RemotePrivacy.guestSafe(S()), "remote: 錶面給訪客看")
        check(!RemotePrivacy.guestSafe(S(screen: .home)), "remote: 主人的主畫面（行程、照片）不給訪客")
        check(RemotePrivacy.guestSafe(S(gateOpen: false, screen: .home)), "remote: 門關著的主畫面（訪客版）可以")
        // H2：允許清單，用 AppRegistry 真的 id
        let ids = AppRegistry.all.map(\.id)
        check(RemotePrivacy.guestApps.isSubset(of: Set(ids)), "remote: 訪客允許清單裡的 id 都是真的 App（\(RemotePrivacy.guestApps.subtracting(ids))）")
        check(RemotePrivacy.guestPartialApps.isSubset(of: Set(ids)), "remote: 部分給訪客的 App（家庭、音樂）id 是真的")
        let blocked = ids.filter { !RemotePrivacy.guestApps.contains($0) }
        let allBlocked = blocked.allSatisfy { id in !RemotePrivacy.guestSafe(S(screen: .app(id))) && !RemotePrivacy.guestSafe(S(gateOpen: false, screen: .app(id))) }
        check(allBlocked && blocked.contains("home") && blocked.contains("findmy") && blocked.contains("music") && blocked.contains("cliotalk") && blocked.contains("settings"), "remote: 清單外的 App（家庭、尋找、音樂、ClioTalk、設定…）預設不給訪客")
        // 使用者 2026-10-25：家庭只給燈的訪客版、音樂只給「正在播放」
        check(RemotePrivacy.guestSafe(S(screen: .app("home"), homeGuestView: true)) && !RemotePrivacy.guestSafe(S(screen: .app("home"))), "remote: 家庭的訪客版（只有燈）給訪客，主人版不給")
        check(RemotePrivacy.guestSafe(S(screen: .app("music"), musicNowPlaying: true)) && !RemotePrivacy.guestSafe(S(screen: .app("music"))), "remote: 音樂只有「正在播放」給訪客")
        check(!RemotePrivacy.guestSafe(S(screen: .app("findmy"), musicNowPlaying: true, homeGuestView: true)), "remote: 家庭、音樂的旗標不會放行別的 App")
        check(!RemotePrivacy.guestSafe(S(screen: .app("someNewApp"))), "remote: 新加的 App 預設不給訪客（允許清單）")
        check(RemotePrivacy.guestSafe(S(screen: .app("podcasts"), mediaNowPlaying: true)) && !RemotePrivacy.guestSafe(S(screen: .app("podcasts"))) && !RemotePrivacy.guestSafe(S(screen: .app("messages"), mediaNowPlaying: true)) && !PersonalGate.locks("music", { var i = PersonalGate.Inputs(); i.remoteGuest = true; return i }()), "remote: 播客的正在播放給訪客（音樂見上一條）；資料庫不給、其他 App 不因此放行")
        check(["timers", "worldclock", "alarms", "weather"].allSatisfy { RemotePrivacy.guestSafe(S(screen: .app($0))) }, "remote: 計時器、世界時鐘、鬧鐘、天氣給訪客")
        check(!RemotePrivacy.guestSafe(S(gateOpen: false, overlayClio: true)), "remote: 門關著 ClioTalk 的卡片也不給訪客")
        check(!RemotePrivacy.guestSafe(S(gateOpen: false, screen: .home, photoFace: true)), "remote: 照片錶面拍成的主畫面桌布不給訪客")
        check(!RemotePrivacy.guestSafe(S(peopleOverlay: true)), "remote: 「嗨，某某」問候不給訪客")
        let faces = FaceStyle.allCases.map(\.rawValue)
        check(RemotePrivacy.guestFaces.isSubset(of: Set(faces)), "remote: 訪客錶面清單的名字都是真的錶面")
        check(["modular", "pocket", "homeModular", "photos"].allSatisfy { f in faces.contains(f) && !RemotePrivacy.guestSafe(S(gateOpen: false, face: f)) } && RemotePrivacy.guestSafe(S(face: "island")) && !RemotePrivacy.guestSafe(S(face: "someNewFace")), "remote: Modular（行程、正在播放）、Home Modular（門鎖）、照片錶面不給訪客；新錶面預設不給")
        var gi = PersonalGate.Inputs(); gi.remoteGuest = true
        check(PersonalGate.audience(gi) == .none && PersonalGate.audience(PersonalGate.Inputs()) == .owner, "remote: 訪客裝置在用時相片小工具的觀眾是 none（不給主人的圖庫）")
        check(PersonalGate.locks("findmy", gi) && PersonalGate.locks("messages", gi) && !PersonalGate.locks("podcasts", gi) && !PersonalGate.locks("timers", gi) && !PersonalGate.locks("home", gi) && !PersonalGate.locks("music", gi), "remote: 訪客在用時尋找、訊息在 Mac 上也鎖起來；家庭（燈）、音樂與播客（正在播放）不鎖")
        check(!RemotePrivacy.guestSafe(S(gateOpen: false, photoFace: true)), "remote: 照片錶面不給訪客（門關著也不行）")
        check(!RemotePrivacy.guestSafe(S(gateOpen: false, personalActivity: true)), "remote: 訊息的 Live Activity 不給訪客")
        check(!RemotePrivacy.guestSafe(S(overlayClio: true)), "remote: ClioTalk 的回答不給訪客")
        var i = PersonalGate.Inputs(); i.remoteGuest = true
        check(!PersonalGate.allowed(i), "remote: 訪客裝置在點的時候 PersonalGate 關門")
        let owner = Person(id: "o", name: "O", colorIndex: 0, isOwner: true)
        check(PersonalGate.avatarPerson(PersonalGate.Inputs(), people: [owner], owner: owner) == owner
              ? PersonalGate.avatarPerson(i, people: [owner], owner: owner) == nil : false, "remote: avatar")
    }

    // MARK: H1：每一幀的判定帳本

    static func ledger(_ check: (Bool, String) -> Void) {
        typealias L = RemotePrivacy.Ledger
        // 主人的主畫面（不安全）→ 訪客一點門關了 → 換錶面的過場拿舊畫面（主畫面）淡出：過場中每一幀都不安全
        var l = L()
        var v = [l.judge(render: 1, safeNow: false, usesOldFrame: false)]
        v.append(l.judge(render: 2, safeNow: true, usesOldFrame: true))
        v.append(l.judge(render: 3, safeNow: true, usesOldFrame: true))
        v.append(l.judge(render: 4, safeNow: true, usesOldFrame: false))
        v.append(l.judge(render: 5, safeNow: true, usesOldFrame: true))   // 之後的過場拿的是乾淨的舊畫面
        check(v == [false, false, false, true, true], "remote: 拿不安全舊畫面做的過場不給訪客，過場結束、乾淨地畫完一幀才給（\(v)）")
        // 收起個人 App（~80 ms 的動畫）：動畫中狀態已經「安全」也不給
        l = L()
        _ = l.judge(render: 10, safeNow: true, usesOldFrame: false)
        let open = l.judge(render: 11, safeNow: false, usesOldFrame: true)
        let closing = l.judge(render: 12, safeNow: true, usesOldFrame: true)
        check(!open && !closing && l.judge(render: 13, safeNow: true, usesOldFrame: false), "remote: 個人 App 收起來的動畫不給訪客")
        // tick 取樣：不比最後一張不安全的幀新就不給
        l = L(); _ = l.judge(render: 20, safeNow: false, usesOldFrame: false)
        check(!l.judge(render: 20, safeNow: true, usesOldFrame: false), "remote: 不安全時畫的那一幀之後狀態變安全也不給")
        var fresh = L(tainted: true)
        check(fresh.judge(render: 1, safeNow: true, usesOldFrame: true) == false, "remote: 剛開始記之前的舊畫面一律當不安全")
        let img = makeImage(8, 8) { _ in }
        check(!RemotePrivacy.verdict(img), "remote: 沒判定過的幀一律不給訪客")
    }

    // MARK: H3／M3：家庭寫入、ClioTalk

    // MARK: 使用者 2026-10-25：訪客的家庭只有燈、音樂只有「正在播放」

    static func guestHomeAndMusic(_ check: (Bool, String) -> Void) {
        // 家庭：示範家庭裡有燈、插座、門鎖、溫控、窗簾、攝影機、場景；訪客只寫得了燈的開關、亮度
        let snap = HomeAppModel.demoSnapshot()
        let tiles = HomeAppModel.groups(snap).flatMap(\.tiles)
        let lights = tiles.filter { $0.kind == .light }, others = tiles.filter { $0.kind != .light }
        let lightIDs = lights.flatMap { [$0.powerID, $0.brightnessID].compactMap { $0 } }
        let otherIDs = others.flatMap { [$0.powerID, $0.brightnessID, $0.lockTargetID, $0.targetTempID, $0.targetPositionID, $0.activeID].compactMap { $0 } }
        check(!lightIDs.isEmpty && lightIDs.allSatisfy { HomeApp.guestWritable($0, in: snap) }, "remote: 訪客可以開關燈、調亮度")
        check(others.contains { $0.kind == .lock } && others.contains { $0.kind == .thermostat } && !otherIDs.isEmpty && otherIDs.allSatisfy { !HomeApp.guestWritable($0, in: snap) }, "remote: 訪客寫不了門鎖、溫控、插座、窗簾（\(otherIDs.filter { HomeApp.guestWritable($0, in: snap) })）")
        let f = HomeWriteSelfTest.Fake()
        f.values["light"] = HomeValue(bool: false)
        RemoteInput.fromGuest = true
        HomeWrite.perform("light", HomeValue(bool: true), via: f, guestOK: true)
        RemoteInput.fromGuest = false
        check(f.values["light"]?.isOn == true && f.log.contains("set light"), "remote: 訪客點燈照常寫入")
        let savedAt = RemotePrivacy.guestInputAt
        RemotePrivacy.guestInputAt = CACurrentMediaTime()
        let guestView = HomeApp.guestView && RemotePrivacy.screen(Face(), now: CACurrentMediaTime()).homeGuestView
        RemotePrivacy.guestInputAt = -1e9
        check(guestView && !HomeApp.guestView, "remote: 訪客在用時家庭畫訪客版（只有燈），沒在用時是主人版")
        RemotePrivacy.guestInputAt = savedAt

        // 音樂：真的 MusicApp／NowPlayingPage（示範資料），只有「正在播放」與歌詞給訪客
        guard let m = AppRegistry.app("music") as? MusicApp else { check(false, "remote: 音樂 App"); return }
        let np = NowPlayingPage.shared
        let saved = (np.demo, MusicControl.shared.demo, MusicControl.shared.demoHistory)
        let face = Face(); face.frozen = true
        let g = CGContext(data: nil, width: 1024, height: 1024, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        func settle() { _ = np.render(g, face: face, now: CACurrentMediaTime() + 5, withLibraryStrip: true); m.render(into: g, face: face, rect: CGRect(x: 0, y: 0, width: 1024, height: 1024), now: CACurrentMediaTime() + 5) }
        m.applyDemo(page: nil, face: face); m.didOpen(now: CACurrentMediaTime()); settle()
        var r: [String: Bool] = ["nowPlaying": RemotePrivacy.musicNowPlaying]
        for p in ["lyrics", "queue", "route", "more"] { m.applyDemo(page: p, face: face); r[p] = RemotePrivacy.musicNowPlaying }
        np.closePanel()
        r["panelClosing"] = RemotePrivacy.musicNowPlaying   // 收起「…」的過場還疊著舊畫面
        settle()
        r["panelClosed"] = RemotePrivacy.musicNowPlaying
        m.applyDemo(page: "library", face: face)
        r["library"] = RemotePrivacy.musicNowPlaying
        _ = m.handleBack(now: CACurrentMediaTime())   // 資料庫 → 正在播放：模糊交叉淡化還畫著資料庫
        r["libraryFading"] = RemotePrivacy.musicNowPlaying
        settle()
        r["back"] = RemotePrivacy.musicNowPlaying
        let want: [String: Bool] = ["nowPlaying": true, "lyrics": true, "queue": false, "route": false, "more": false, "panelClosing": false, "panelClosed": true, "library": false, "libraryFading": false, "back": true]
        check(r == want, "remote: 音樂給訪客的只有正在播放與歌詞；資料庫、待播、AirPlay、「…」、過場不給（\(r.filter { want[$0.key] != $0.value })）")
        np.closePanel(); settle()
        (np.demo, MusicControl.shared.demo, MusicControl.shared.demoHistory) = saved
        m.didOpen(now: CACurrentMediaTime())
    }

    static func homeAndClio(_ check: (Bool, String) -> Void) {
        let f = HomeWriteSelfTest.Fake()
        f.values["lock"] = HomeValue(number: 1)
        var result: Bool?
        RemoteInput.fromGuest = true
        HomeWrite.perform("lock", HomeValue(number: 0), via: f) { result = $0 }
        RemoteInput.fromGuest = false
        check(f.log.isEmpty && f.values["lock"]?.number == 1 && result == false, "remote: 訪客裝置點的門鎖寫入被拒（沒送出、本機也沒改）")
        HomeWrite.perform("lock", HomeValue(number: 0), via: f) { result = $0 }
        check(f.log.first == "local lock=0.0" && result == true, "remote: 主人自己點照常寫入")
        // M3：訪客一碰，背景的 ClioTalk 立刻拿不到個人工具（不等下一幀）
        let saved = (PersonalGate.cached, PersonalGate.cachedAudience, RemotePrivacy.guestInputAt)
        PersonalGate.cached = true
        RemotePrivacy.guestTouched(CACurrentMediaTime())
        let sem = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var r: ClioToolResult?
        Task.detached { r = await ClioMessagesTools.run(name: "messages_send", input: ["contact": "x", "text": "y"]); sem.signal() }
        _ = sem.wait(timeout: .now() + 5)
        check(!PersonalGate.cached && PersonalGate.cachedAudience == .none && r?.isError == true, "remote: 訪客一碰，ClioTalk 的「好」送不出主人的訊息")
        (PersonalGate.cached, PersonalGate.cachedAudience, RemotePrivacy.guestInputAt) = saved
    }

    // MARK: M5：撤銷不會被舊快照寫回來

    static func storeRace(_ check: (Bool, String) -> Void) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hp-remote-\(UUID().uuidString)")
        let st = RemoteStore(file: dir.appendingPathComponent("remote-devices.json"))
        var resurrected = 0
        for _ in 0..<60 {
            let d = st.add(name: "iPad")
            DispatchQueue.concurrentPerform(iterations: 8) { i in if i == 3 { st.revoke(d.id) } else { st.touch(d.id, ip: "192.168.1.\(i)") } }
            if RemoteStore(file: st.file).device(d.id) != nil { resurrected += 1 }
        }
        check(resurrected == 0 && st.all.isEmpty, "remote: 同時寫檔，撤銷的裝置不會被寫回來（\(resurrected)/60）")
        try? FileManager.default.removeItem(at: dir)
    }

    /// 自己組的 TCP 用戶端：送手工的 WebSocket 框（測控制框、pong、連線上限）
    final class Raw {
        let c: NWConnection
        let q = DispatchQueue(label: "hp.selftest.raw")
        let port: UInt16
        private var got = Data(), closed = false
        init(port: UInt16) {
            self.port = port
            c = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
            c.start(queue: q)
            pump()
        }
        private func pump() {
            c.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] d, _, done, err in
                guard let self else { return }
                if let d { self.got.append(d) }
                if done || err != nil { self.closed = true } else { self.pump() }
            }
        }
        func send(_ d: Data) {
            let sem = DispatchSemaphore(value: 0)
            c.send(content: d, completion: .contentProcessed { _ in sem.signal() })
            _ = sem.wait(timeout: .now() + 2)
        }
        /// 等到有資料或對方關了（最多 timeout 秒）：(這段時間收到的資料, 對方關了沒)
        func read(_ timeout: Double = 2) -> (Data?, Bool) {
            let end = CACurrentMediaTime() + timeout
            while CACurrentMediaTime() < end {
                let (n, c) = q.sync { (got.count, closed) }
                if n > 0 || c { break }
                Thread.sleep(forTimeInterval: 0.02)
            }
            return q.sync { let d = got; got = Data(); return (d.isEmpty ? nil : d, closed) }
        }
        func upgrade() -> Bool {
            send(Data("GET /ws HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n".utf8))
            return read().0.map { String(decoding: $0, as: UTF8.self).contains(" 101 ") } ?? false
        }
        static func frame(op: UInt8, _ p: [UInt8], fin: Bool = true) -> Data {
            var d = Data([(fin ? 0x80 : 0) | op])
            if p.count < 126 { d.append(0x80 | UInt8(p.count)) } else { d.append(0x80 | 126); d.append(UInt8(p.count >> 8)); d.append(UInt8(p.count & 255)) }
            let m: [UInt8] = [1, 2, 3, 4]
            d.append(contentsOf: m)
            d.append(contentsOf: p.enumerated().map { $0.element ^ m[$0.offset & 3] })
            return d
        }
        func close() { c.cancel() }
    }

    /// 送到裝置的一幀：中心那一點的顏色（R, G, B）
    static func frameColor(_ f: Data?) -> (Int, Int, Int)? {
        guard let f, f.first == 0x46, f.count > 23 else { return nil }
        let b = [UInt8](f), len = Int(b[19]) | Int(b[20]) << 8 | Int(b[21]) << 16 | Int(b[22]) << 24
        guard 23 + len <= b.count, let src = CGImageSourceCreateWithData(Data(b[23..<(23 + len)]) as CFData, nil),
              let im = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        var px = [UInt8](repeating: 0, count: 4)
        guard let g = CGContext(data: &px, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        g.draw(im, in: CGRect(x: -CGFloat(im.width) / 2, y: -CGFloat(im.height) / 2, width: CGFloat(im.width), height: CGFloat(im.height)))
        return (Int(px[0]), Int(px[1]), Int(px[2]))
    }

    static func solid(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> CGImage {
        makeImage(1024, 1024) { c in c.setFillColor(CGColor(red: r, green: g, blue: b, alpha: 1)); c.fill(CGRect(x: 0, y: 0, width: 1024, height: 1024)) }
    }

    // MARK: 真的伺服器（只聽 127.0.0.1）

    final class Client {
        let task: URLSessionWebSocketTask
        var key: SymmetricKey?
        var rx: UInt64 = 0, tx: UInt64 = 0
        init(port: UInt16, host: String? = nil, address: String = "127.0.0.1") {
            var req = URLRequest(url: URL(string: "ws://\(address):\(port)/ws")!)
            if let host { req.setValue(host, forHTTPHeaderField: "Host") }
            task = URLSession.shared.webSocketTask(with: req)
            task.resume()
            pump()
        }
        // 一直有一個 receive 掛著（逾時不會吃掉下一則；URLSession 也才會回 pong）；收到的放進信箱，nil＝斷了
        private var inbox: [Data?] = []
        private let lock = NSLock(), avail = DispatchSemaphore(value: 0)
        private func pump() {
            task.receive { [weak self] r in
                guard let self else { return }
                var d: Data?, ok = false
                if case .success(let m) = r { ok = true; if case .data(let x) = m { d = x } else if case .string(let s) = m { d = Data(s.utf8) } }
                self.lock.lock(); self.inbox.append(ok ? (d ?? Data()) : nil); self.lock.unlock(); self.avail.signal()
                if ok { self.pump() }
            }
        }
        /// 等伺服器斷線（不是逾時）：timeout 內斷了回 true
        func waitClosed(_ timeout: Double = 5) -> Bool {
            let end = CACurrentMediaTime() + timeout
            while CACurrentMediaTime() < end {
                if lock.withLock({ inbox.contains { $0 == nil } }) { return true }
                Thread.sleep(forTimeInterval: 0.05)
            }
            return false
        }
        func receive(_ timeout: Double = 3) -> Data? {
            guard avail.wait(timeout: .now() + timeout) == .success else { return nil }
            lock.lock(); defer { lock.unlock() }
            let d = inbox.removeFirst()
            if d == nil { inbox.insert(nil, at: 0); avail.signal() }   // 斷了：之後每次都回 nil
            return d
        }
        func send(_ d: Data) {
            let sem = DispatchSemaphore(value: 0)
            task.send(.data(d)) { _ in sem.signal() }
            _ = sem.wait(timeout: .now() + 3)
        }
        /// 握手：成功回 session key；被拒（伺服器斷線）回 false
        func hello(kind: UInt8, id: String?, longKey: SymmetricKey) -> Bool {
            var b: [UInt8] = [0x48, 1, kind]
            if let id { b += stride(from: 0, to: 16, by: 2).map { UInt8(id.dropFirst($0).prefix(2), radix: 16)! } } else { b += [UInt8](repeating: 0, count: 8) }
            let nc = (0..<6).map { _ in UInt8.random(in: 0...255) }
            send(Data(b + nc))
            guard let r = receive(), r.count == 8, r.first == 0x48 else { return false }
            key = RemoteCrypto.sessionKey(longKey, nonceC: nc, nonceS: Array(r.dropFirst(2)))
            return key != nil
        }
        func sendJSON(_ o: [String: Any]) {
            guard let key, let box = RemoteCrypto.seal(try! JSONSerialization.data(withJSONObject: o), key: key, dir: 0, counter: tx) else { return }
            tx += 1; send(box)
        }
        func receivePlain(_ timeout: Double = 3) -> Data? {
            guard let key, let d = receive(timeout), let p = RemoteCrypto.open(d, key: key, dir: 1, counter: rx) else { return nil }
            rx += 1; return p
        }
        func receiveJSON(_ timeout: Double = 3) -> [String: Any]? {
            receivePlain(timeout).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        }
        /// 收到 t＝want 的那一則（中間的 cover 之類跳過）
        func receiveJSON(_ want: String, tries: Int = 4, timeout: Double = 2) -> [String: Any]? {
            for _ in 0..<tries {
                guard let p = receivePlain(timeout) else { return nil }
                if p.first == 0x7b, let o = try? JSONSerialization.jsonObject(with: p) as? [String: Any], o["t"] as? String == want { return o }
            }
            return nil
        }
        func close() { task.cancel(with: .goingAway, reason: nil) }
    }

    static func server(_ check: (Bool, String) -> Void) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hp-remote-\(UUID().uuidString)")
        let srv = RemoteServer()
        srv.store = RemoteStore(file: dir.appendingPathComponent("remote-devices.json"))
        let port = UInt16.random(in: 40000...49000)
        srv.start(port: port, loopbackOnly: true)
        defer { srv.stop(); try? FileManager.default.removeItem(at: dir) }
        // 等它開始聽
        var up = false
        for _ in 0..<40 where !up {
            var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/")!); req.timeoutInterval = 1
            let sem = DispatchSemaphore(value: 0)
            URLSession.shared.dataTask(with: req) { d, r, _ in
                up = (r as? HTTPURLResponse)?.statusCode == 200 && (d.map { String(decoding: $0, as: UTF8.self).contains("HPC") } ?? false)
                sem.signal()
            }.resume()
            _ = sem.wait(timeout: .now() + 2)
            if !up { Thread.sleep(forTimeInterval: 0.1) }
        }
        check(up, "remote: 伺服器給得出頁面")
        guard up else { return }

        // 同一個來源最多 4 條
        do {
            let held = (0..<RemoteServer.maxPerIP).map { _ in Raw(port: port) }
            Thread.sleep(forTimeInterval: 0.3)
            let fifth = Raw(port: port)
            fifth.send(Data("GET / HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\n\r\n".utf8))
            let r = fifth.read()
            check(r.0 == nil, "remote: 同一個來源第 5 條連線被拒")
            fifth.close(); held.forEach { $0.close() }
            Thread.sleep(forTimeInterval: 0.3)
        }
        // M2：驗證前的 ping 不回 pong、直接斷；控制框超過 125 bytes 斷線
        do {
            let r = Raw(port: port)
            _ = r.upgrade()
            r.send(Raw.frame(op: 0x9, [1, 2]))
            let (d, closed) = r.read()
            check(closed && !(d.map { $0.first == 0x8A } ?? false), "remote: 驗證前的 ping 不回 pong、斷線")
            r.close()
        }
        do {
            let r = Raw(port: port)
            _ = r.upgrade()
            r.send(Raw.frame(op: 0xA, [1, 2]))
            let small = r.read(0.6)   // 小的 pong：0.6 秒內沒被斷
            r.send(Raw.frame(op: 0xA, [UInt8](repeating: 7, count: 126)))
            Thread.sleep(forTimeInterval: 0.3)
            let big = r.read()
            check(!small.1 && big.1, "remote: 控制框超過 125 bytes 就斷線（小的照收：\(!small.1)）")
            r.close()
            let f = Raw(port: port)
            _ = f.upgrade()
            f.send(Raw.frame(op: 0xA, [1], fin: false))
            check(f.read().1, "remote: 分段的控制框斷線")
            f.close()
            let g = Raw(port: port)
            _ = g.upgrade()
            g.send(Raw.frame(op: 0x2, [UInt8](repeating: 1, count: 3000), fin: false))
            let first = g.read(0.4)
            g.send(Raw.frame(op: 0x0, [UInt8](repeating: 1, count: 3000), fin: false))
            check(!first.1 && g.read().1, "remote: 驗證前用分段湊超過 4 KB 的訊息就斷線")
            g.close()
            let h = Raw(port: port)
            _ = h.upgrade()
            h.send(Raw.frame(op: 0x0, [1, 2, 3]))
            check(h.read().1, "remote: 沒有開頭框的延續框斷線")
            h.close()
        }

        // Host 不對（DNS rebinding）
        do {
            var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/")!); req.setValue("evil.example.com", forHTTPHeaderField: "Host")
            let sem = DispatchSemaphore(value: 0); var code = 0
            URLSession.shared.dataTask(with: req) { _, r, _ in code = (r as? HTTPURLResponse)?.statusCode ?? 0; sem.signal() }.resume()
            _ = sem.wait(timeout: .now() + 3)
            check(code == 421, "remote: 別的網域的 Host 被拒（\(code)）")
        }

        // 沒配對的裝置
        let fakeID = "0123456789abcdef"
        do {
            let c = Client(port: port)
            check(!c.hello(kind: 0x44, id: fakeID, longKey: SymmetricKey(size: .bits256)), "remote: 沒配對的裝置被拒")
            c.close()
        }
        // 沒有配對碼時配對
        do {
            let c = Client(port: port)
            check(!c.hello(kind: 0x50, id: nil, longKey: RemoteCrypto.pairingKey(RemoteCrypto.newPairingSecret())), "remote: 沒產生配對碼時不能配對")
            c.close()
        }
        // 打錯碼
        let secret = srv.store.newPairing()
        do {
            let c = Client(port: port)
            _ = c.hello(kind: 0x50, id: nil, longKey: RemoteCrypto.pairingKey(RemoteCrypto.newPairingSecret()))
            c.sendJSON(["t": "pair", "name": "Attacker"])
            check(c.receiveJSON() == nil, "remote: 打錯配對碼拿不到金鑰")
            c.close()
        }
        // 對的碼
        var creds: (id: String, key: SymmetricKey)?
        do {
            let c = Client(port: port)
            _ = c.hello(kind: 0x50, id: nil, longKey: RemoteCrypto.pairingKey(secret))
            c.sendJSON(["t": "pair", "name": "iPad · iPadOS 15.8"])
            if let o = c.receiveJSON(), o["t"] as? String == "paired", let id = o["id"] as? String, let k = (o["key"] as? String).flatMap({ Data(base64Encoded: $0) }) {
                creds = (id, SymmetricKey(data: k))
            }
            c.close()
        }
        check(creds != nil && srv.store.all.count == 1, "remote: 對的配對碼拿到這台裝置自己的金鑰")
        do {
            let c = Client(port: port)
            _ = c.hello(kind: 0x50, id: nil, longKey: RemoteCrypto.pairingKey(secret))
            c.sendJSON(["t": "pair", "name": "Again"])
            check(c.receiveJSON() == nil && srv.store.all.count == 1, "remote: 用過的配對碼不能再用")
            c.close()
        }
        guard let creds else { return }
        // 拿錯的金鑰冒充這台裝置
        do {
            let c = Client(port: port)
            _ = c.hello(kind: 0x44, id: creds.id, longKey: SymmetricKey(size: .bits256))
            c.sendJSON(["t": "hi"])
            check(c.receiveJSON() == nil, "remote: 冒用裝置 id（金鑰不對）被拒")
            c.close()
        }
        // 配過的裝置：連上、拿到畫面
        let live = Client(port: port)
        _ = live.hello(kind: 0x44, id: creds.id, longKey: creds.key)
        live.sendJSON(["t": "hi", "v": 1])
        let ok = live.receiveJSON()
        check(ok?["t"] as? String == "ok" && ok?["guest"] as? Bool == true, "remote: 配過的裝置連上（預設訪客）")
        let img = makeImage(1024, 1024) { g in
            g.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.9, alpha: 1)); g.fill(CGRect(x: 0, y: 0, width: 1024, height: 1024))
            g.setFillColor(CGColor(gray: 1, alpha: 1)); g.fill(CGRect(x: 300, y: 300, width: 200, height: 120))
        }
        srv.queue.async { srv.setLatestSafe(true); srv.pump(img, safe: true) }
        var frameOK = false
        if let f = live.receivePlain(), f.first == 0x46, f.count > 23 {
            let b = [UInt8](f), n = Int(b[9]) | Int(b[10]) << 8
            let len = Int(b[19]) | Int(b[20]) << 8 | Int(b[21]) << 16 | Int(b[22]) << 24
            if n == 1, 23 + len <= b.count, let src = CGImageSourceCreateWithData(Data(b[23..<(23 + len)]) as CFData, nil),
               let im = CGImageSourceCreateImageAtIndex(src, 0, nil) { frameOK = im.width == 1024 && im.height == 1024 }
        }
        check(frameOK, "remote: 收到加密的第一幀（整張 JPEG 1024²）")

        // M2：ack 的序號要對，才送下一幀
        func near(_ c: (Int, Int, Int)?, _ r: Int, _ g: Int, _ b: Int) -> Bool { c.map { abs($0.0 - r) < 70 && abs($0.1 - g) < 70 && abs($0.2 - b) < 70 } ?? false }
        live.sendJSON(["t": "a", "s": 999])
        srv.queue.async { srv.pump(solid(0, 1, 0), safe: true) }
        check(live.receivePlain(1) == nil, "remote: ack 序號不對，Mac 不送下一幀")
        live.sendJSON(["t": "a", "s": 1])
        check(near(frameColor(live.receivePlain()), 0, 255, 0), "remote: 對的 ack 才送下一幀")
        live.sendJSON(["t": "a", "s": 2])

        // H1：狀態已經安全，但這一幀是不安全時畫的（關門前的主人畫面）：訪客收不到；下一張安全的才送
        srv.queue.async { srv.setLatestSafe(true); srv.pump(solid(1, 0, 0), safe: false) }
        check(live.receivePlain(1) == nil, "remote: 不安全時畫的舊幀不送給訪客（狀態已經安全也一樣）")
        do {
            let late = Client(port: port)   // 剛連上的（ref＝nil 會送整張畫布）也拿不到
            _ = late.hello(kind: 0x44, id: creds.id, longKey: creds.key)
            late.sendJSON(["t": "hi"])
            let ok2 = late.receiveJSON()
            check(ok2?["t"] as? String == "ok" && late.receivePlain(1) == nil, "remote: 剛連上的訪客也拿不到畫布上的不安全幀")
            srv.queue.async { srv.pump(solid(0, 0, 1), safe: true) }
            let lc = live.receivePlain(), tc = late.receivePlain()
            check(near(frameColor(lc), 0, 0, 255) && near(frameColor(tc), 0, 0, 255), "remote: 下一張安全的幀才送，而且送的就是它（\(String(describing: frameColor(lc))) \(lc?.count ?? -1)／\(String(describing: frameColor(tc))) \(tc?.count ?? -1)）")
            late.close()
        }
        live.sendJSON(["t": "a", "s": 3])
        srv.queue.async { srv.setLatestSafe(false); srv.pump(solid(1, 0, 0), safe: false) }
        check(live.receiveJSON("cover")?["on"] as? Bool == true, "remote: 畫面有個人內容時訪客收到遮罩")
        srv.queue.async { srv.setLatestSafe(true); srv.pump(solid(0, 0, 1), safe: true) }
        check(live.receiveJSON("cover")?["on"] as? Bool == false && near(frameColor(live.receivePlain()), 0, 0, 255), "remote: 安全了才拿掉遮罩、送新的一幀")

        // M3：訪客的輸入一到，背景讀的 PersonalGate.cached 立刻關（不等主執行緒）
        let savedCached = PersonalGate.cached
        PersonalGate.cached = true
        live.sendJSON(["t": "i", "k": "d", "x": 10.0, "y": 10.0, "n": 1])
        var closedGate = false
        for _ in 0..<20 where !closedGate { Thread.sleep(forTimeInterval: 0.05); closedGate = !PersonalGate.cached }
        check(closedGate, "remote: 訪客一碰，PersonalGate.cached 馬上變 false")
        PersonalGate.cached = savedCached

        // M1：交接碼換金鑰：用一次；金鑰不進網址
        live.sendJSON(["t": "h"])
        let ho = live.receiveJSON("handoff")?["tok"] as? String
        let tb = ho.flatMap { RemoteCrypto.decode($0) } ?? []
        var handed = false, reused = true
        if tb.count == 24 {
            let tid = tb.prefix(8).map { String(format: "%02x", $0) }.joined()
            let h1 = Client(port: port)
            _ = h1.hello(kind: 0x54, id: tid, longKey: RemoteCrypto.pairingKey(Array(tb[8..<24])))
            h1.sendJSON(["t": "claim"])
            if let o = h1.receiveJSON(), o["t"] as? String == "paired", o["id"] as? String == creds.id,
               let k = (o["key"] as? String).flatMap({ Data(base64Encoded: $0) }) { handed = SymmetricKey(data: k) == creds.key }
            h1.close()
            let h2 = Client(port: port)
            reused = h2.hello(kind: 0x54, id: tid, longKey: RemoteCrypto.pairingKey(Array(tb[8..<24])))
            h2.close()
        }
        check(handed, "remote: 交接碼換到這台裝置的金鑰")
        check(!reused, "remote: 交接碼用過就不能再用")
        let page = RemotePage.html(host: "127.0.0.1:1")
        check(!page.contains("'#d='") && page.contains("'#t=' + o.tok") && page.contains("clearHash()"), "remote: 頁面不把金鑰寫進網址，只放交接碼")
        // 移除：現在的連線被踢、之後連不回來
        srv.revoke(creds.id)
        check(live.waitClosed(), "remote: 移除裝置後現在的連線斷掉")
        live.close()
        do {
            let c = Client(port: port)
            check(!c.hello(kind: 0x44, id: creds.id, longKey: creds.key), "remote: 移除的裝置連不回來")
            c.close()
        }

        // H4：同一台裝置同時從兩個位址（127.0.0.1 與 ::1）連進來＝金鑰外流：自動移除、兩條都斷
        let secret2 = srv.store.newPairing()
        var creds2: (id: String, key: SymmetricKey)?
        do {
            let c = Client(port: port)
            _ = c.hello(kind: 0x50, id: nil, longKey: RemoteCrypto.pairingKey(secret2))
            c.sendJSON(["t": "pair", "name": "iPad"])
            if let o = c.receiveJSON(), let id = o["id"] as? String, let k = (o["key"] as? String).flatMap({ Data(base64Encoded: $0) }) { creds2 = (id, SymmetricKey(data: k)) }
            c.close()
        }
        guard let creds2 else { check(false, "remote: 第二台配對"); return }
        let a = Client(port: port)
        _ = a.hello(kind: 0x44, id: creds2.id, longKey: creds2.key)
        a.sendJSON(["t": "hi"])
        let okA = a.receiveJSON("ok") != nil
        let b = Client(port: port, address: "[::1]")
        _ = b.hello(kind: 0x44, id: creds2.id, longKey: creds2.key)
        b.sendJSON(["t": "hi"])
        let okB = b.receiveJSON("ok") != nil
        // 讓 a 一直在收（URLSession 收著才會回 pong）
        var gone = false
        for _ in 0..<60 where !gone { Thread.sleep(forTimeInterval: 0.1); gone = srv.store.device(creds2.id) == nil }
        check(okA && okB && gone, "remote: 同一把金鑰同時從兩個位址連進來，自動移除（ok \(okA)/\(okB)）")
        check(a.waitClosed() && b.waitClosed(), "remote: 自動移除後兩條連線都斷掉")
        a.close(); b.close()
        // 只有一條（換了位址重連、舊的已斷）：不算
        let secret3 = srv.store.newPairing()
        do {
            let c = Client(port: port)
            _ = c.hello(kind: 0x50, id: nil, longKey: RemoteCrypto.pairingKey(secret3))
            c.sendJSON(["t": "pair", "name": "iPad"])
            if let o = c.receiveJSON(), let id = o["id"] as? String, let k = (o["key"] as? String).flatMap({ Data(base64Encoded: $0) }) {
                c.close()
                let x = Client(port: port); _ = x.hello(kind: 0x44, id: id, longKey: SymmetricKey(data: k)); x.sendJSON(["t": "hi"]); _ = x.receiveJSON("ok"); x.close()
                Thread.sleep(forTimeInterval: 0.5)
                let y = Client(port: port, address: "[::1]"); _ = y.hello(kind: 0x44, id: id, longKey: SymmetricKey(data: k)); y.sendJSON(["t": "hi"]); _ = y.receiveJSON("ok")
                Thread.sleep(forTimeInterval: 3.5)
                check(srv.store.device(id) != nil && srv.store.device(id)?.lastIP == "::1", "remote: 換了位址重連（舊連線已斷）不會被移除，設定頁看得到上次的位址")
                y.close()
            } else { check(false, "remote: 第三台配對") }
        }
    }
}
