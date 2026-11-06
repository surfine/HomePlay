// SideShow 的 HTTP 伺服器（Network.framework NWListener；Bonjour 廣播 _homeplay-sideshow._tcp）。
//
// - 只收區網：acceptLocalOnly、不走行動網路與 VPN（.cellular、.other＝utun），來源不是私有位址（或跟本機網卡同網段的全域 IPv6）就直接斷（RemoteCrypto.isPrivate）；
//   Host 標頭只收 IP、.local、localhost（擋 DNS rebinding）。路由在 SideShowCore.swift（純函數）。
// - 一條連線一個請求：讀到標頭與 Content-Length 那麼多的本文（最多 4 KB）就回、就關。10 秒內沒讀完就斷。
// - 有在跑才收集內容：主執行緒每 5 秒拍一份白名單內容（SideShowContent），請求直接拿最近那份。
// - 日誌只記開關、配對成功、拒絕的連線種類；不記網址、配對碼、金鑰、內容。

import AppKit
import Network

final class SideShowServer {
    static let shared = SideShowServer()

    let queue = DispatchQueue(label: "homeplay.sideshow", qos: .utility)
    var store = SideShowStore.shared
    private var listener: NWListener?
    private var open = 0                                     // queue
    static let maxConnections = 24
    private(set) var running = false                         // main
    private(set) var listenFailed = false                    // main
    private(set) var port: UInt16 = SideShowStore.defaultPort
    weak var face: Face?
    private var timer: Timer?
    private let stateLock = NSLock()
    private var stateData = Data("{}".utf8)
    /// 測試／快照：用這個取代真的收集（不讀任何使用者資料）
    var inputsOverride: (() -> SideShowContent.Inputs)?

    static let changed = Notification.Name("HomePlaySideShowChanged")

    // MARK: 開關

    func start(port: UInt16 = SideShowStore.port, loopbackOnly: Bool = false) {
        guard listener == nil else { return }
        if Thread.isMainThread { RemotePage.prepareIcons() }   // 主畫面圖示（跟網頁串流共用 👀）
        let params = NWParameters(tls: nil, tcp: NWProtocolTCP.Options())
        params.acceptLocalOnly = true
        params.prohibitedInterfaceTypes = [.cellular, .other]
        params.allowLocalEndpointReuse = true
        if loopbackOnly { params.requiredInterfaceType = .loopback }
        guard let p = NWEndpoint.Port(rawValue: port), let l = try? NWListener(using: params, on: p) else {
            log("sideshow: cannot listen"); listenFailed = true; notify(); return
        }
        self.port = port
        if !loopbackOnly { l.service = NWListener.Service(type: "_homeplay-sideshow._tcp") }
        l.newConnectionHandler = { [weak self] c in self?.accept(c) }
        l.stateUpdateHandler = { [weak self] s in
            switch s {
            case .ready: log("sideshow: listening"); DispatchQueue.main.async { self?.listenFailed = false; self?.notify() }
            case .failed(let e): log("sideshow: listener failed \(e)"); DispatchQueue.main.async { self?.listenFailed = true; self?.notify() }
            default: break
            }
        }
        l.start(queue: queue)
        listener = l
        running = true
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.refresh() }
        notify()
    }

    func stop() {
        listener?.cancel(); listener = nil
        timer?.invalidate(); timer = nil
        running = false
        store.cancelPairing()
        notify()
        log("sideshow: off")
    }

    /// 設定頁的開關
    func apply(enabled: Bool) {
        SideShowStore.enabled = enabled
        if enabled, !running { start() } else if !enabled, running { stop() }
    }

    private func notify() { NotificationCenter.default.post(name: Self.changed, object: nil) }

    // MARK: 內容

    /// 主執行緒：拍一份白名單內容
    func refresh() {
        let i = inputsOverride?() ?? Self.collect(face: face)
        let d = SideShowContent.json(SideShowContent.build(i))
        stateLock.lock(); stateData = d; stateLock.unlock()
    }
    var currentState: Data { stateLock.lock(); defer { stateLock.unlock() }; return stateData }

    /// 從 HomePlay 已有的來源收（主執行緒）
    static func collect(face: Face?) -> SideShowContent.Inputs {
        let now = Date().timeIntervalSince1970
        var i = SideShowContent.Inputs(now: now)
        i.fahrenheit = Locale.current.measurementSystem == .us
        i.h24 = !(DateFormatter.dateFormat(fromTemplate: "j", options: 0, locale: .current) ?? "").contains("a")
        i.weather = WeatherSource.shared.data
        if let f = face, let t = f.nowPlaying.info, !t.title.isEmpty {
            i.track = t
            i.trackPosition = t.position + (t.playing && !t.fixed ? max(0, CACurrentMediaTime() - t.stamp) * max(0.25, t.rate) : 0)
        }
        i.timers = Shell.timers.sorted
        i.showCalendar = SideShowStore.showCalendar
        i.guestMode = Shell.guestMode
        if i.showCalendar, !i.guestMode { i.events = SBWidgetData.events(now: Date()) ?? [] }
        i.alerts = HomeAlerts.active
        return i
    }

    // MARK: 連線

    private func accept(_ c: NWConnection) {
        guard case .hostPort(let host, _) = c.endpoint, RemoteCrypto.isPrivate(host) else {
            log("sideshow: rejected non-LAN connection"); c.cancel(); return
        }
        guard open < Self.maxConnections else { c.cancel(); return }
        open += 1
        let conn = SideShowConn(c, ip: RemoteServer.ip(c.endpoint), server: self)
        conn.start()
    }

    func closed() { open = max(0, open - 1) }   // queue
}

/// 一條連線、一個請求
final class SideShowConn {
    let conn: NWConnection
    let ip: String
    unowned let server: SideShowServer
    private var buf = Data()
    private var done = false
    private var self_: SideShowConn?      // 連線活著時自己留住自己

    init(_ c: NWConnection, ip: String, server: SideShowServer) { conn = c; self.ip = ip; self.server = server }

    func start() {
        self_ = self
        conn.stateUpdateHandler = { [weak self] s in
            guard let self else { return }
            switch s {
            case .ready:
                if let path = self.conn.currentPath, path.usesInterfaceType(.cellular) || path.usesInterfaceType(.other) { self.finish() }
            case .failed, .cancelled: self.finish()
            default: break
            }
        }
        conn.start(queue: server.queue)
        receive()
        server.queue.asyncAfter(deadline: .now() + 10) { [weak self] in self?.finish() }
    }

    private func finish() {
        guard !done else { return }
        done = true
        conn.cancel()
        server.closed()
        self_ = nil
    }

    private func receive() {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, end, err in
            guard let self, !self.done else { return }
            if let data { self.buf.append(data) }
            if self.process() { return }
            if end || err != nil || self.buf.count > 20 * 1024 { self.finish(); return }
            self.receive()
        }
    }

    /// 收齊一個請求就回（true＝已處理）
    private func process() -> Bool {
        if buf.first == 0x16 { finish(); return true }   // TLS ClientHello（Safari 先試 https）：馬上斷，讓它退回 http
        guard let end = buf.range(of: Data("\r\n\r\n".utf8)) else { return false }
        let head = String(decoding: buf[..<end.lowerBound], as: UTF8.self)
        var lines = head.components(separatedBy: "\r\n")
        let req = lines.removeFirst().split(separator: " ")
        var h: [String: String] = [:]
        for l in lines { if let i = l.firstIndex(of: ":") { h[l[..<i].lowercased()] = l[l.index(after: i)...].trimmingCharacters(in: .whitespaces) } }
        let length = Int(h["content-length"] ?? "0") ?? -1
        guard req.count >= 2, length >= 0, length <= 4096 else { respond(.json(400, ["error": "request"])); return true }
        let bodyStart = end.upperBound
        guard buf.count - (bodyStart - buf.startIndex) >= length else { return false }
        let body = buf.subdata(in: bodyStart..<(bodyStart + length))
        let path = String(req[1].split(separator: "?").first ?? "/")
        let r = SideShowRequest(method: String(req[0]), path: path, headers: h, body: body, ip: ip)
        let srv = server
        respond(SideShowRouter.handle(r, store: srv.store, state: { srv.currentState }))
        return true
    }

    private func respond(_ r: SideShowResponse) {
        let reason = [200: "OK", 400: "Bad Request", 401: "Unauthorized", 403: "Forbidden", 404: "Not Found", 405: "Method Not Allowed",
                      409: "Conflict", 421: "Misdirected Request", 429: "Too Many Requests"][r.code] ?? "Error"
        var head = "HTTP/1.1 \(r.code) \(reason)\r\nContent-Type: \(r.type)\r\nContent-Length: \(r.body.count)\r\nConnection: close\r\n"
        head += "Cache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\nReferrer-Policy: no-referrer\r\nX-Frame-Options: DENY\r\n"
        if r.page {
            head += "Content-Security-Policy: default-src 'none'; script-src 'unsafe-inline' 'self'; style-src 'unsafe-inline'; img-src 'self' data:; manifest-src 'self'; connect-src 'self'; worker-src 'self'\r\n"
        }
        conn.send(content: Data((head + "\r\n").utf8) + r.body, completion: .contentProcessed { [weak self] _ in self?.finish() })
    }
}

// MARK: - 網址（QR 碼、設定頁）

extension SideShowServer {
    /// http://<名字>.local:<port>/ 優先（換了 IP 也找得到），其次區網 IPv4
    static func baseURL(port: UInt16 = SideShowStore.port) -> String? {
        RemoteServer.urls(port: port).first
    }
}
