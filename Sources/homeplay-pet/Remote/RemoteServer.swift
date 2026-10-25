// 2.0 閒置裝置·網頁串流（docs/plans/idle-devices.md 路線一；稿：IdlePairing、IdleLayouts、IdleRoutes）。
//
// 桌寵裡一個小小的 HTTP＋WebSocket 伺服器（Network.framework NWListener，Bonjour 廣播 _homeplay._tcp）：
// - GET / 給一頁 HTML（RemotePage.swift）；/ws 升級成 WebSocket，先握手（RemoteCrypto.swift），之後全部加密。
// - 只收區網：NWParameters.acceptLocalOnly、不走行動網路與 VPN（.cellular、.other＝utun），來源位址不是私有位址就直接斷
//   （RemoteCrypto.isPrivate，Tailscale 的 fd7a:115c:a1e0::/48 不算）；Host 標頭只收 IP／.local（擋 DNS rebinding），
//   WebSocket 的 Origin 要跟 Host 同一個；同一個來源最多 4 條連線、全部最多 16 條。
// - 同一台裝置同時從兩個不同位址連進來（金鑰被偷了才會這樣）：先 ping 舊的那條，兩條都活著＝自動移除這台、在 Mac 上通知。
// - 沒配對的、金鑰不對的、被移除的：第一則訊息解不開就斷，一幀都拿不到。
// - 有裝置連著才編碼：主執行緒 15 Hz 看一眼桌寵那一幀（只拿 CGImage 參照），縮放、比對、壓 JPEG 都在背景佇列；
//   每台裝置收到一幀回 ack 才送下一幀（慢的裝置自然少收，不會堆積）。沒有裝置＝計時器停掉，什麼都不做。
// - 訪客裝置（預設）：畫面上可能有個人內容時只送「需要主人」的遮罩（guestSafe）；訪客在點的時候，PersonalGate 直接關門。
//   訪客只拿得到「畫的時候就安全」的幀（RemotePrivacy.noteRender 在每次 render 時判定，畫布記著那一幀的判定）：
//   關門前畫好的那一幀、App 收起來的動畫、拿舊畫面做的過場都不會送給訪客。
// - 一台裝置同時只有一幀在路上：等它回 ack（而且 ack 的序號要對）、送出的資料也被網路層收走（.contentProcessed）才送下一幀。
// - 日誌只記連線、配對、統計數字，不記畫面、不記點在哪、不記金鑰。

import AppKit
import Network
import CryptoKit
import SystemConfiguration
import UserNotifications

final class RemoteServer {
    static let shared = RemoteServer()

    let queue = DispatchQueue(label: "homeplay.remote", qos: .utility)
    var store = RemoteStore.shared
    private var listener: NWListener?
    private var conns: [ObjectIdentifier: RemoteConn] = [:]        // queue
    private let canvas = RemoteCanvas()                              // queue
    private var latestSafe = true                                    // queue
    private var latestInputAck: UInt32 = 0                           // queue
    static let maxConnections = 16, maxPerIP = 4
    private(set) var port: UInt16 = RemoteStore.defaultPort
    private(set) var running = false                                 // main
    /// 2.0 depth：開了卻聽不了（連接埠被占用、網路權限）：設定頁要說，不是照樣給 QR 碼
    private(set) var listenFailed = false                            // main
    private func setListenFailed(_ v: Bool) {
        guard v != listenFailed else { return }
        listenFailed = v
        NotificationCenter.default.post(name: Self.changed, object: nil)
    }

    // 主執行緒
    weak var view: PetView?
    private(set) var connected: [String: Int] = [:]                  // 裝置 id → 連線數
    private var timer: Timer?
    private weak var lastImage: CGImage?
    private var lastRenderCount = -1, lastRenderAt = 0.0, lastSelfRender = 0.0
    nonisolated(unsafe) static var lastInputAt = 0.0
    static let trace = ProcessInfo.processInfo.environment["HOMEPLAY_REMOTE_TRACE"] != nil   // 只記時間，不記內容
    nonisolated(unsafe) static var inputSeq: UInt32 = 0
    /// 自檢：不經桌寵，直接給畫面
    var frameProvider: (() -> CGImage?)?
    var frameProviderSafe = true
    /// 最近一次自動移除（設定頁顯示）：裝置名字
    nonisolated(unsafe) static var lastAutoRevoked: (name: String, at: Double)?

    // 統計（queue）
    private var stat = (frames: 0, bytes: 0, encode: 0.0, rtt: 0.0, rttN: 0, lat: 0.0, latN: 0, since: CACurrentMediaTime())
    /// 給設定頁與量測：最近一輪的統計（主執行緒讀）
    nonisolated(unsafe) static var lastStats = ""

    static let changed = Notification.Name("HomePlayRemoteChanged")

    // MARK: 開關

    func start(port: UInt16 = RemoteStore.port, loopbackOnly: Bool = false) {
        guard listener == nil else { return }
        if Thread.isMainThread { RemotePage.prepareIcons() }
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.enableKeepalive = true; tcp.keepaliveIdle = 15; tcp.keepaliveInterval = 5; tcp.keepaliveCount = 3
        let params = NWParameters(tls: nil, tcp: tcp)
        params.acceptLocalOnly = true
        params.prohibitedInterfaceTypes = [.cellular, .other]   // .other＝utun（VPN、Tailscale）之類的虛擬介面
        params.allowLocalEndpointReuse = true
        if loopbackOnly { params.requiredInterfaceType = .loopback }
        guard let p = NWEndpoint.Port(rawValue: port), let l = try? NWListener(using: params, on: p) else {
            log("remote: cannot listen on \(port)"); setListenFailed(true); return
        }
        self.port = port
        if !loopbackOnly { l.service = NWListener.Service(type: "_homeplay._tcp") }
        l.newConnectionHandler = { [weak self] c in self?.accept(c) }
        l.stateUpdateHandler = { s in
            switch s {
            case .ready: log("remote: listening on \(port)"); DispatchQueue.main.async { self.setListenFailed(false) }
            case .failed(let e): log("remote: listener failed \(e)"); DispatchQueue.main.async { self.setListenFailed(true) }
            default: break
            }
        }
        l.start(queue: queue)
        listener = l
        running = true
        log("remote: on")
    }

    /// 開機時（設定裡開著），或開發測試 --remote-test [port]（不改設定、只聽 127.0.0.1；HOMEPLAY_REMOTE_PAIR_OUT＝把配對網址寫到這個檔，0600，不進日誌）
    func startFromLaunch() {
        let a = CommandLine.arguments
        var port = RemoteStore.port
        let test = a.contains("--remote-test")
        if let i = a.firstIndex(of: "--remote-test"), i + 1 < a.count, let p = UInt16(a[i + 1]) { port = p }
        start(port: port, loopbackOnly: test)
        if test, let out = ProcessInfo.processInfo.environment["HOMEPLAY_REMOTE_PAIR_OUT"] {
            let url = "http://127.0.0.1:\(port)/" + "#p=" + RemoteCrypto.encode(store.newPairing())
            FileManager.default.createFile(atPath: out, contents: Data(url.utf8), attributes: [.posixPermissions: 0o600])
        }
    }

    func stop() {
        listener?.cancel(); listener = nil
        running = false
        queue.async {
            for c in self.conns.values { c.close() }
            self.conns.removeAll()
        }
        DispatchQueue.main.async { self.connected = [:]; self.updateTimer() }
        log("remote: off")
    }

    /// 設定頁的開關
    func apply(enabled: Bool) {
        if enabled, !running { start() } else if !enabled, running { stop(); store.cancelPairing() }
    }

    /// 移除裝置：刪金鑰、踢掉它現在的連線
    func revoke(_ id: String) {
        store.revoke(id)
        queue.async { for c in self.conns.values where c.deviceID == id { c.close() } }
        log("remote: device revoked")
        NotificationCenter.default.post(name: Self.changed, object: nil)
    }

    func setPersonal(_ id: String, _ on: Bool) {
        store.setPersonal(id, on)
        queue.async {
            for c in self.conns.values where c.deviceID == id { c.guest = !on; c.ref = nil }
            self.pump(nil)
        }
    }

    // MARK: 連線

    private func accept(_ c: NWConnection) {
        // 只收區網：來源不是私有位址＝直接斷
        guard Self.admits(c.endpoint) else { log("remote: rejected non-LAN connection"); c.cancel(); return }
        let ip = Self.ip(c.endpoint)
        guard conns.count < Self.maxConnections, conns.values.filter({ $0.ip == ip }).count < Self.maxPerIP else { c.cancel(); return }
        let rc = RemoteConn(c, server: self)
        conns[ObjectIdentifier(rc)] = rc
        rc.start()
    }

    static func admits(_ e: NWEndpoint) -> Bool {
        guard case .hostPort(let host, _) = e else { return false }
        return RemoteCrypto.isPrivate(host)
    }

    /// 來源位址（不含 port、不含 %介面）
    static func ip(_ e: NWEndpoint) -> String {
        guard case .hostPort(let host, _) = e else { return "?" }
        switch host {
        case .ipv4(let a): return "\(a)"
        case .ipv6(let a):
            let b = Array(a.rawValue)
            if b.count == 16, b[0..<10].allSatisfy({ $0 == 0 }), b[10] == 0xff, b[11] == 0xff { return b[12..<16].map(String.init).joined(separator: ".") }
            return "\(a)".split(separator: "%").first.map(String.init) ?? "\(a)"
        default: return "\(host)"
        }
    }

    /// 同一台裝置的另一條連線來自別的位址？（純函數，selftest 驗）
    static func conflicting(_ ip: String, others: [String]) -> Bool { others.contains { $0 != ip } }

    /// 裝置剛驗證完（queue）：同一台同時從別的位址連著→ ping 那幾條，3 秒內有回 pong（真的活著）＝金鑰外流，自動移除
    func authenticated(_ c: RemoteConn) {
        guard let id = c.deviceID else { return }
        let others = conns.values.filter { $0 !== c && $0.authed && $0.deviceID == id }
        guard Self.conflicting(c.ip, others: others.map(\.ip)) else { return }
        let suspects = others.filter { $0.ip != c.ip }
        let t0 = CACurrentMediaTime()
        for o in suspects { o.ping() }
        let newIP = c.ip
        queue.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self else { return }
            // 舊的那條在新的連上之後還回了 pong＝兩條同時活著（新的事後斷掉也一樣算）
            let alive = suspects.filter { $0.pongAt >= t0 }
            if !alive.isEmpty {
                self.autoRevoke(id, ips: [newIP] + alive.map(\.ip))
            } else {
                for o in suspects where !alive.contains(where: { $0 === o }) { o.close() }   // 沒回：上一個位址留下的殭屍連線
            }
        }
    }

    private func autoRevoke(_ id: String, ips: [String]) {   // queue
        let name = store.device(id)?.name ?? "?"
        store.revoke(id)
        for c in conns.values where c.deviceID == id { c.close() }
        log("remote: device auto-revoked (same key from \(Set(ips).count) addresses at once)")
        DispatchQueue.main.async {
            Self.lastAutoRevoked = (name, Date().timeIntervalSince1970)
            NotificationCenter.default.post(name: Self.changed, object: nil)
            Self.notifyMac(L("remote.autoRevoke.title", "已移除一台 iPhone／iPad"),
                           String(format: L("remote.autoRevoke.body", "「%@」同时从两个网络地址连进来，可能有人复制了它的密钥。要继续用请重新配对。"), name))
        }
    }

    /// Mac 的通知（只有包成 .app 才有通知中心；開發版、selftest 只寫日誌）
    static func notifyMac(_ title: String, _ body: String) {
        guard Bundle.main.bundleURL.pathExtension == "app", Bundle.main.bundleIdentifier != nil else { return }
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { ok, _ in
            guard ok else { return }
            let n = UNMutableNotificationContent()
            n.title = title; n.body = body
            center.add(UNNotificationRequest(identifier: UUID().uuidString, content: n, trigger: nil))
        }
    }

    func closed(_ rc: RemoteConn) {   // queue
        conns[ObjectIdentifier(rc)] = nil
        if let id = rc.deviceID, rc.authed { sessionsChanged(id, delta: -1) }
    }

    func sessionsChanged(_ id: String, delta: Int) {   // queue → main
        DispatchQueue.main.async {
            let n = (self.connected[id] ?? 0) + delta
            self.connected[id] = n > 0 ? n : nil
            if self === RemoteServer.shared {
                if self.hasClients, !RemotePrivacy.tracking { RemotePrivacy.ledger = RemotePrivacy.Ledger(tainted: true) }   // 開始前畫的都不算數
                RemotePrivacy.tracking = self.hasClients
                if RemotePrivacy.tracking { self.view?.face.forceDirty = true }   // 開始記每一幀的判定：馬上重畫一張有判定的
            }   // 開始記每一幀的判定：馬上重畫一張有判定的
            self.updateTimer()
            NotificationCenter.default.post(name: Self.changed, object: nil)
        }
    }

    var hasClients: Bool { !connected.isEmpty }

    private func updateTimer() {
        if hasClients, timer == nil {
            let t = Timer(timeInterval: 1.0 / 15, repeats: true) { [weak self] _ in self?.tick() }
            t.tolerance = 0.01
            RunLoop.main.add(t, forMode: .common)
            timer = t
            lastImage = nil
        } else if !hasClients, let t = timer {
            t.invalidate(); timer = nil
        }
    }

    // MARK: 每幀（主執行緒）

    private func tick() {
        guard hasClients else { return }
        let now = CACurrentMediaTime()
        var img: CGImage?, imgSafe = false
        let safe = RemotePrivacy.guestSafe(view)
        if let frameProvider { img = frameProvider(); imgSafe = frameProviderSafe }
        else if let v = view {
            let f = v.face
            if Face.renderCount != lastRenderCount { lastRenderCount = Face.renderCount; lastRenderAt = now }
            if let lf = f.lastFrame, lf !== lastImage { img = lf; imgSafe = RemotePrivacy.verdict(lf) }
            else if now - lastRenderAt > 1.0 {
                // 桌寵的主循環停了（被遮住、螢幕關了、深度閒置）：自己畫，平常 1 Hz、剛點過 15 Hz
                let gap = now - Self.lastInputAt < 3 ? 1.0 / 15 : 1.0
                if now - lastSelfRender >= gap - 0.01 {
                    lastSelfRender = now
                    v.shellStep(now)
                    let r = f.render(now)
                    img = r; imgSafe = RemotePrivacy.verdict(r)
                    lastRenderCount = Face.renderCount   // 自己畫的不算桌寵在跑
                }
            }
            // H1：現在可以給訪客看，但手上最新那幀是不安全時畫的：請桌寵重畫一張（不送舊的）
            if safe, let lf = f.lastFrame, !RemotePrivacy.verdict(lf) { f.forceDirty = true }
        }
        if let img { lastImage = img }
        if Self.trace { log(String(format: "remote trace tick +%.0fms since input, img=%d renders=%d", (now - Self.lastInputAt) * 1000, img == nil ? 0 : 1, Face.renderCount)) }
        let ack = Self.inputSeq
        queue.async { self.latestSafe = safe; self.latestInputAck = ack; self.pump(img, safe: imgSafe) }
    }

    /// 背景：有新的一幀就畫進畫布（連同它畫的時候安不安全），然後每台閒著的裝置送它還沒有的部分
    func pump(_ img: CGImage?, safe: Bool = false) {
        if let img { canvas.draw(img, safe: safe) }
        guard canvas.generation > 0 else { return }
        for c in conns.values where c.authed && !c.inFlight && !c.sending { send(to: c) }
        flushStats()
    }

    /// 自檢：現在的畫面狀態安不安全（tick 會設）
    func setLatestSafe(_ s: Bool) { latestSafe = s }   // queue

    private func send(to c: RemoteConn) {
        guard c.authed, !c.inFlight, !c.sending else { return }
        if c.guest {
            // 畫面現在可能有個人內容：遮起來
            if !latestSafe {
                if !c.covered { c.covered = true; c.ref = nil; c.sendJSON(["t": "cover", "on": true]) }
                return
            }
            // 畫面現在安全，但畫布上那一幀是不安全時畫的（關門前的舊幀、收起來的動畫）：什麼都不送，等下一張安全的
            guard canvas.safe else { return }
        }
        if c.covered { c.covered = false; c.sendJSON(["t": "cover", "on": false]) }
        guard c.sentGen != canvas.generation || c.ref == nil else { return }
        let t0 = CACurrentMediaTime()
        let rects: [CGRect] = c.ref.map { ref in ref.withUnsafeBufferPointer { RemoteFrames.dirtyRects(canvas.pixels, $0.baseAddress!, bytesPerRow: canvas.bytesPerRow) } }
            ?? RemoteFrames.dirtyRects(canvas.pixels, nil)
        c.sentGen = canvas.generation
        guard !rects.isEmpty, let full = canvas.image() else { return }
        var parts: [(CGRect, Data)] = []
        for r in rects {
            guard let sub = r.width == CGFloat(RemoteCanvas.size) && r.height == CGFloat(RemoteCanvas.size) ? full : full.cropping(to: r),
                  let j = RemoteFrames.jpeg(sub) else { continue }
            parts.append((r, j))
        }
        c.seq &+= 1
        let msg = RemoteFrames.message(seq: c.seq, inputAck: min(latestInputAck, c.inputN), parts: parts)
        c.ref = canvas.snapshot()
        c.inFlight = true; c.sentAt = CACurrentMediaTime()
        c.sendFrame(msg)
        stat.frames += 1; stat.bytes += msg.count; stat.encode += CACurrentMediaTime() - t0
    }

    /// ack 的序號要等於剛送出的那一幀，否則不算（M2：亂回 ack 不能讓 Mac 一直送）
    func acked(_ c: RemoteConn, seq: UInt32, latency: Double?) {   // queue
        guard c.inFlight, seq == c.seq else { return }
        c.inFlight = false
        stat.rtt += CACurrentMediaTime() - c.sentAt; stat.rttN += 1
        if let latency { stat.lat += latency; stat.latN += 1 }
        send(to: c)
    }

    /// 那一幀的資料網路層收走了（queue）
    func sendDone(_ c: RemoteConn) { send(to: c) }

    func clientLatency(_ ms: Double) { stat.lat += ms / 1000; stat.latN += 1 }   // queue

    private func flushStats() {
        let now = CACurrentMediaTime(), dt = now - stat.since
        guard dt >= 10 else { return }
        if stat.frames > 0 || stat.latN > 0 {
            let s = String(format: "remote stats: %.1f fps, %.0f kB/s, encode %.1f ms/frame, ack rtt %.0f ms, tap→frame %.0f ms (%d), clients %d",
                           Double(stat.frames) / dt, Double(stat.bytes) / dt / 1024, stat.frames > 0 ? stat.encode / Double(stat.frames) * 1000 : 0,
                           stat.rttN > 0 ? stat.rtt / Double(stat.rttN) * 1000 : 0, stat.latN > 0 ? stat.lat / Double(stat.latN) * 1000 : 0, stat.latN,
                           conns.values.filter(\.authed).count)
            log(s); Self.lastStats = s
        }
        stat = (0, 0, 0, 0, 0, 0, 0, now)
    }

    // MARK: 輸入（佇列 → 主執行緒）

    func input(_ c: RemoteConn, kind: String, x: Double, y: Double, n: UInt32) {   // queue
        // 限速（每條連線一個水桶：每秒補 90、最多 40）：移動超過就丟；按下／放開照收，但灌爆了就斷線
        let t = CACurrentMediaTime()
        c.bucket = min(40, c.bucket + (t - c.bucketAt) * 90); c.bucketAt = t
        if c.bucket < 1 {
            if kind == "m" { return }
            if c.bucket < -40 { log("remote: input flood, closing"); c.close(); return }
        }
        c.bucket -= 1
        // 輸入序號只能往前、一次最多跳 1000（不讓一台裝置把大家的 inputAck 撐到最大）
        // 連線的第一筆當基準（頁面的計數不因重連歸零）
        guard let n = c.inputN == 0 && n > 0 ? n : Self.clampInput(n, last: c.inputN) else { return }
        c.inputN = n
        let guest = c.guest
        if guest {
            // M3：先記下「訪客在用」（主執行緒每幀算門時讀得到，不會又打開），再關背景 ClioTalk 讀的那扇門
            RemotePrivacy.guestInputAt = t
            PersonalGate.cached = false
        }
        let src = ObjectIdentifier(c)
        DispatchQueue.main.async {
            let now = CACurrentMediaTime()
            Self.lastInputAt = now
            if guest { RemotePrivacy.guestTouched(now) }
            if Self.trace { log("remote trace input \(kind) queue→main \(Int((now - t) * 1000))ms") }
            RemoteInput.fromGuest = guest; RemoteInput.source = src
            defer { RemoteInput.fromGuest = false; RemoteInput.source = nil }
            if let v = self.view { RemoteInput.handle(kind, CGPoint(x: x, y: y), view: v) }
            Self.inputSeq = max(Self.inputSeq, n)
        }
    }

    static func clampInput(_ n: UInt32, last: UInt32) -> UInt32? {
        guard n > last, n - last <= 1000 else { return nil }
        return n
    }

    // MARK: 網址

    /// 這台 Mac 的名字（不查 DNS）
    static var computerName: String { (SCDynamicStoreCopyComputerName(nil, nil) as String?) ?? "Mac" }

    /// 給 QR 與設定頁：http://<名字>.local:<port>/ 與 http://<IP>:<port>/（.local 換了 IP 也找得到，放第一個）
    static func urls(port: UInt16 = RemoteStore.port) -> [String] {
        var out: [String] = []
        if let name = SCDynamicStoreCopyLocalHostName(nil) as String? { out.append("http://\(name).local:\(port)/") }
        out += lanIPv4().map { "http://\($0):\(port)/" }
        return out
    }

    static func lanIPv4() -> [String] {
        var out: [String] = []
        var ifa: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifa) == 0, let first = ifa else { return [] }
        defer { freeifaddrs(ifa) }
        for p in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let i = p.pointee
            guard let sa = i.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET), (i.ifa_flags & UInt32(IFF_UP)) != 0, (i.ifa_flags & UInt32(IFF_LOOPBACK)) == 0 else { continue }
            let name = String(cString: i.ifa_name)
            guard name.hasPrefix("en") || name.hasPrefix("bridge") else { continue }
            var a = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
            var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            inet_ntop(AF_INET, &a, &buf, socklen_t(INET_ADDRSTRLEN))
            let s = String(cString: buf)
            if let v4 = IPv4Address(s), RemoteCrypto.isPrivateV4(Array(v4.rawValue)) { out.append(s) }
        }
        return out.filter { !$0.hasPrefix("169.254.") }   // 連結本地（USB 網路之類）Wi‑Fi 上的裝置連不到，不列
    }
}

// MARK: - 一條連線：HTTP 或 WebSocket

final class RemoteConn {
    enum Phase { case http, hello, auth, live, closing }
    let conn: NWConnection
    unowned let server: RemoteServer
    private var buf = Data()
    private var phase = Phase.http
    private var wsMessage = Data()
    // 握手
    private var kind: UInt8 = 0
    private var longKey: SymmetricKey?
    private var key: SymmetricKey?
    private var rx: UInt64 = 0, tx: UInt64 = 0
    // 已驗證的裝置
    private(set) var deviceID: String?
    private(set) var authed = false
    var guest = true
    var inFlight = false, sentAt = 0.0, seq: UInt32 = 0, sentGen = -1
    /// 一幀交給網路層、還沒 .contentProcessed（M2：同時只有一幀在路上）
    var sending = false
    var ref: [UInt8]?
    var covered = false
    /// 輸入：限速水桶、最後收下的序號
    var bucket = 40.0, bucketAt = CACurrentMediaTime(), inputN: UInt32 = 0
    /// 來源位址；最近一次收到 pong
    let ip: String
    private(set) var pongAt = -1.0
    private var host = ""
    private var didClose = false
    private var handoffAt = -1e9
    var isClosed: Bool { phase == .closing || didClose }

    init(_ c: NWConnection, server: RemoteServer) { conn = c; self.server = server; ip = RemoteServer.ip(c.endpoint) }

    func start() {
        conn.stateUpdateHandler = { [weak self] s in
            switch s {
            case .ready:
                // M4：路徑走了行動網路或 VPN（utun）就斷（listener 已經擋過一次，這裡再確認）
                guard let self, let path = self.conn.currentPath else { return }
                if path.usesInterfaceType(.cellular) || path.usesInterfaceType(.other) { log("remote: rejected connection over VPN/cellular"); self.close() }
            case .failed, .cancelled:
                guard let self, !self.didClose else { return }
                self.didClose = true; self.server.closed(self)
            default: break
            }
        }
        conn.start(queue: server.queue)
        receive()
        // 10 秒內沒完成握手就斷
        server.queue.asyncAfter(deadline: .now() + 10) { [weak self] in
            guard let self, !self.authed, self.phase != .closing else { return }
            self.close()
        }
    }

    func close() {
        guard phase != .closing else { return }
        phase = .closing
        conn.cancel()
    }

    private func receive() {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] data, _, done, err in
            guard let self else { return }
            if let data, !data.isEmpty { self.buf.append(data); self.process() }
            if done || err != nil { self.close(); return }
            if self.phase != .closing { self.receive() }
        }
    }

    private func process() {
        if phase == .http { handleHTTP() }
        while phase == .hello || phase == .auth || phase == .live {
            guard let (op, payload) = nextWSFrame() else { break }
            switch op {
            case 0x8: sendWS(op: 0x8, Data()); close(); return
            case 0x9: guard authed else { close(); return }; sendWS(op: 0xA, payload)   // M2：驗證前不回 pong
            case 0xA: pongAt = CACurrentMediaTime()
            case 0x1, 0x2, 0x0:
                // 分段順序：延續框（0）只能接在開頭框後面；分段中途不能插新的開頭框
                if (op == 0x0) != inFragment { close(); return }
                inFragment = !fin
                wsMessage.append(payload)
                if wsMessage.count > (authed ? 64 * 1024 : 4096) { close(); return }   // 驗證前的訊息（分段湊的也算）最多 4 KB
                if fin { let m = wsMessage; wsMessage = Data(); handleMessage(m) }
            default: close(); return
            }
        }
    }

    // MARK: HTTP

    private func handleHTTP() {
        // Safari 先試 https（「預設使用 HTTPS」）：TLS 的 ClientHello 一來就斷，讓它馬上退回 http，不要等 10 秒
        if buf.first == 0x16 { close(); return }
        guard let end = buf.range(of: Data("\r\n\r\n".utf8)) else {
            if buf.count > 16 * 1024 { close() }
            return
        }
        let head = String(decoding: buf[..<end.lowerBound], as: UTF8.self)
        buf.removeSubrange(..<end.upperBound)
        var lines = head.components(separatedBy: "\r\n")
        let req = lines.removeFirst().split(separator: " ")
        var h: [String: String] = [:]
        for l in lines { if let i = l.firstIndex(of: ":") { h[l[..<i].lowercased()] = l[l.index(after: i)...].trimmingCharacters(in: .whitespaces) } }
        guard req.count >= 2, req[0] == "GET" else { respond(405, "text/plain", Data("method".utf8)); return }
        guard let ch = RemoteCrypto.canonicalHost(h["host"] ?? "") else { respond(421, "text/plain", Data("host".utf8)); return }
        host = ch   // 之後 CSP、Origin 比對都用重組過的，不回填原字串
        let path = String(req[1].split(separator: "?").first ?? "/")
        switch path {
        case "/ws":
            guard h["upgrade"]?.lowercased() == "websocket", let k = h["sec-websocket-key"] else { respond(400, "text/plain", Data()); return }
            if let o = h["origin"], !(o.lowercased().hasPrefix("http://") && RemoteCrypto.canonicalHost(String(o.dropFirst(7))) == host) {
                log("remote: rejected cross-origin socket"); respond(403, "text/plain", Data()); return
            }
            let accept = Data(Insecure.SHA1.hash(data: Data((k + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))).base64EncodedString()
            let resp = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: \(accept)\r\n\r\n"
            conn.send(content: Data(resp.utf8), completion: .contentProcessed { _ in })
            phase = .hello
        case "/", "/index.html":
            respond(200, "text/html; charset=utf-8", Data(RemotePage.html(host: host).utf8), page: true)
        case "/manifest.webmanifest":
            respond(200, "application/manifest+json", Data(RemotePage.manifest.utf8))
        case "/icon-180.png", "/icon-512.png":
            respond(200, "image/png", RemotePage.icon(path == "/icon-180.png" ? 180 : 512))
        default:
            respond(404, "text/plain", Data("not found".utf8))
        }
    }

    private func respond(_ code: Int, _ type: String, _ body: Data, page: Bool = false) {
        let reason = [200: "OK", 400: "Bad Request", 403: "Forbidden", 404: "Not Found", 405: "Method Not Allowed", 421: "Misdirected Request"][code] ?? "Error"
        var head = "HTTP/1.1 \(code) \(reason)\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n"
        head += "Cache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\nReferrer-Policy: no-referrer\r\nX-Frame-Options: DENY\r\n"
        if page {
            head += "Content-Security-Policy: default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src 'self' blob: data:; media-src data: blob:; manifest-src 'self'; connect-src 'self' ws://\(host)\r\n"
        }
        conn.send(content: Data((head + "\r\n").utf8) + body, completion: .contentProcessed { [weak self] _ in self?.close() })
        phase = .closing
    }

    // MARK: WebSocket 框

    private var fin = true
    private var inFragment = false

    private func nextWSFrame() -> (UInt8, Data)? {
        let b = [UInt8](buf.prefix(14))
        guard b.count >= 2 else { return nil }
        let finBit = b[0] & 0x80 != 0, op = b[0] & 0x0f, masked = b[1] & 0x80 != 0
        var len = Int(b[1] & 0x7f), off = 2
        // M2：控制框（close／ping／pong）最多 125 bytes、不能分段（RFC 6455 §5.5）
        if op & 0x8 != 0, len > 125 || !finBit { close(); return nil }
        if len == 126 { guard b.count >= 4 else { return nil }; len = Int(b[2]) << 8 | Int(b[3]); off = 4 }
        else if len == 127 {
            guard b.count >= 10 else { return nil }
            var l: UInt64 = 0; for i in 2..<10 { l = l << 8 | UInt64(b[i]) }
            guard l <= 64 * 1024 else { close(); return nil }
            len = Int(l); off = 10
        }
        guard masked else { close(); return nil }   // 瀏覽器送來的一定有遮罩
        if !authed, len > 4096 { close(); return nil }   // 驗證前的訊息都很小
        guard buf.count >= off + 4 + len else { return nil }
        let start = buf.startIndex
        let mask = [UInt8](buf[(start + off)..<(start + off + 4)])
        var p = [UInt8](buf[(start + off + 4)..<(start + off + 4 + len)])
        for i in p.indices { p[i] ^= mask[i & 3] }
        buf.removeSubrange(start..<(start + off + 4 + len))
        fin = finBit
        return (op, Data(p))
    }

    private func sendWS(op: UInt8, _ payload: Data) {
        var h = Data([0x80 | op])
        let n = payload.count
        if n < 126 { h.append(UInt8(n)) }
        else if n < 65536 { h.append(126); h.append(UInt8(n >> 8)); h.append(UInt8(n & 255)) }
        else { h.append(127); for i in (0..<8).reversed() { h.append(UInt8((UInt64(n) >> (8 * UInt64(i))) & 255)) } }
        conn.send(content: h + payload, completion: .contentProcessed { [weak self] e in if e != nil { self?.close() } })
    }

    func sendEncrypted(_ plain: Data) {
        guard let key, let box = RemoteCrypto.seal(plain, key: key, dir: 1, counter: tx) else { return }
        tx += 1
        sendWS(op: 0x2, box)
    }

    /// 送一幀：網路層收走（.contentProcessed）之前不送下一幀
    func sendFrame(_ plain: Data) {
        guard let key, let box = RemoteCrypto.seal(plain, key: key, dir: 1, counter: tx) else { return }
        tx += 1
        sending = true
        var h = Data([0x82])
        let n = box.count
        if n < 126 { h.append(UInt8(n)) }
        else if n < 65536 { h.append(126); h.append(UInt8(n >> 8)); h.append(UInt8(n & 255)) }
        else { h.append(127); for i in (0..<8).reversed() { h.append(UInt8((UInt64(n) >> (8 * UInt64(i))) & 255)) } }
        conn.send(content: h + box, completion: .contentProcessed { [weak self] e in
            guard let self else { return }
            self.sending = false
            if e != nil { self.close(); return }
            self.server.sendDone(self)
        })
    }

    /// 確認這條連線真的活著（瀏覽器會自動回 pong）
    func ping() { sendWS(op: 0x9, Data("hp".utf8)) }

    func sendJSON(_ obj: [String: Any]) {
        guard let d = try? JSONSerialization.data(withJSONObject: obj) else { return }
        sendEncrypted(d)
    }

    // MARK: 握手與訊息

    private func handleMessage(_ m: Data) {
        switch phase {
        case .hello:
            // 'H' 1 kind id(8) nonceC(6)
            let b = [UInt8](m)
            guard b.count == 17, b[0] == 0x48, b[1] == 1, b[2] == 0x50 || b[2] == 0x44 || b[2] == 0x54 else { close(); return }
            kind = b[2]
            if kind == 0x50 {
                guard let s = server.store.pairingSecret(for: ip) else { log("remote: pairing refused (no active code for this address)"); close(); return }
                longKey = RemoteCrypto.pairingKey(s)
            } else if kind == 0x54 {
                // M1：交接碼（「加入主畫面」後第一次打開）：查到就拿走，用一次
                let tid = b[3..<11].map { String(format: "%02x", $0) }.joined()
                guard let t = server.store.takeHandoff(tid) else { log("remote: handoff refused (unknown, used or expired)"); close(); return }
                longKey = RemoteCrypto.pairingKey(t.secret); deviceID = t.device
            } else {
                let id = b[3..<11].map { String(format: "%02x", $0) }.joined()
                guard let k = server.store.key(for: id) else { log("remote: unknown device rejected"); close(); return }
                longKey = k; deviceID = id
            }
            var ns = [UInt8](repeating: 0, count: 6)
            for i in ns.indices { ns[i] = UInt8.random(in: 0...255) }
            guard let lk = longKey, let sk = RemoteCrypto.sessionKey(lk, nonceC: Array(b[11..<17]), nonceS: ns) else { close(); return }
            key = sk
            sendWS(op: 0x2, Data([0x48, 1] + ns))
            phase = .auth
        case .auth:
            guard let key, let plain = RemoteCrypto.open(m, key: key, dir: 0, counter: rx),
                  let obj = try? JSONSerialization.jsonObject(with: plain) as? [String: Any] else {
                if kind == 0x50 { server.store.pairingFailed(ip: ip); log("remote: wrong pairing code") } else { log("remote: device key mismatch") }
                close(); return
            }
            rx += 1
            if kind == 0x54 {
                // 交接：把這台裝置自己的金鑰交給剛從主畫面圖示打開的那一頁（只放 localStorage，不進網址）
                guard let id = deviceID, let d = server.store.device(id) else { close(); return }
                sendJSON(["t": "paired", "id": d.id, "key": d.key])
                log("remote: handoff used")
                server.queue.asyncAfter(deadline: .now() + 1) { [weak self] in self?.close() }
                phase = .live
            } else if kind == 0x50 {
                // 配對：發一把這台裝置自己的金鑰，碼作廢，斷線讓它用新身分重連
                guard server.store.pairingSecret != nil else { close(); return }
                server.store.pairingUsed()
                let d = server.store.add(name: obj["name"] as? String ?? "iPad")
                sendJSON(["t": "paired", "id": d.id, "key": d.key])
                log("remote: paired new device")
                NotificationCenter.default.post(name: RemoteServer.changed, object: nil)
                server.queue.asyncAfter(deadline: .now() + 1) { [weak self] in self?.close() }
                phase = .live   // 不會再處理它的訊息（沒有 authed）
            } else {
                guard let id = deviceID, let dev = server.store.device(id) else { close(); return }
                authed = true; guest = !dev.personal
                phase = .live
                server.store.touch(id, ip: ip)
                sendJSON(["t": "ok", "guest": guest, "mac": RemoteServer.computerName])
                server.sessionsChanged(id, delta: 1)
                log("remote: device connected")
                server.authenticated(self)
                server.pump(nil)
            }
        case .live:
            guard authed, let key, let plain = RemoteCrypto.open(m, key: key, dir: 0, counter: rx),
                  let obj = try? JSONSerialization.jsonObject(with: plain) as? [String: Any], let t = obj["t"] as? String else { close(); return }
            rx += 1
            switch t {
            case "a": server.acked(self, seq: UInt32(clamping: (obj["s"] as? Int) ?? -1), latency: nil)
            case "h":
                // 要一張交接碼（放進網址給「加入主畫面」用）：20 秒最多一張
                let now = CACurrentMediaTime()
                guard let id = deviceID, now - handoffAt >= 20, let tok = server.store.newHandoff(for: id) else { return }
                handoffAt = now
                sendJSON(["t": "handoff", "tok": tok])
            case "i":
                guard let k = obj["k"] as? String, ["d", "m", "u"].contains(k), let x = obj["x"] as? Double, let y = obj["y"] as? Double else { return }
                server.input(self, kind: k, x: max(0, min(1024, x)), y: max(0, min(1024, y)), n: UInt32(clamping: (obj["n"] as? Int) ?? 0))
            case "l": if let v = obj["v"] as? Double, v >= 0, v < 10000 { server.clientLatency(v) }
            default: break
            }
        default: break
        }
    }
}
