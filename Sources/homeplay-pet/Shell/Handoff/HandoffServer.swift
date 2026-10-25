// 2.0 promo：「傳到 HomePlay」——iPhone 的捷徑把分享表單裡的網址 POST 到這台 Mac。
// 只在區網聽（NWParameters.acceptLocalOnly＋自己再看一次對方位址）、Bonjour 廣告 _homeplay-send._tcp、
// 每則都要帶配對碼（鑰匙圈裡的 26 字 base32，設定頁可以重新產生；不進 UserDefaults、不進日誌）。
// 配對碼錯 5 次就停 60 秒。只收一個端點：POST /open，本文是 {"url": "…"}、url=…，或含網址的純文字。
// 純 http：區網裡的捷徑連不上自簽憑證（iOS 要使用者手動信任），而這裡只收一個公開網頁的網址——最壞是有人知道配對碼、讓桌寵開一個網頁；
// Safari 頁本身不存 cookie、不填表、不下載（SafariApp.swift 的安全閘）。

import Foundation
import Network
import Security

final class HandoffServer {
    static let shared = HandoffServer()
    static let port: UInt16 = 47391
    static let serviceType = "_homeplay-send._tcp"
    private let queue = DispatchQueue(label: "homeplay.handoff.server")
    private var listener: NWListener?
    private var failures: [Double] = []
    private var lockedUntil = 0.0
    private(set) var state = "off"     // off｜ready｜failed（設定頁顯示）
    var onStateChange: (() -> Void)?

    var running: Bool { listener != nil }

    func start() {
        guard listener == nil, !SnapshotPrivacy.active else { return }
        _ = HandoffToken.current   // 第一次開：先產生配對碼
        let p = NWParameters.tcp
        p.acceptLocalOnly = true
        p.includePeerToPeer = false
        do {
            let l = try NWListener(using: p, on: NWEndpoint.Port(rawValue: Self.port)!)
            l.service = NWListener.Service(name: Host.current().localizedName ?? "HomePlay", type: Self.serviceType)   // l10n-ignore：Bonjour 名
            l.stateUpdateHandler = { [weak self] st in
                DispatchQueue.main.async {
                    switch st {
                    case .ready: self?.state = "ready"
                    case .failed: self?.state = "failed"; self?.listener?.cancel(); self?.listener = nil
                    case .cancelled: self?.state = "off"
                    default: break
                    }
                    self?.onStateChange?()
                    if case .failed(let e) = st { log("handoff server failed \(e)") }
                }
            }
            l.newConnectionHandler = { [weak self] c in self?.accept(c) }
            l.start(queue: queue)
            listener = l
            log("handoff server listening on \(Self.port)")
        } catch {
            state = "failed"; log("handoff server: \(error)")
        }
    }

    func stop() { listener?.cancel(); listener = nil; state = "off"; onStateChange?() }

    // MARK: 一條連線＝一則

    private func accept(_ c: NWConnection) {
        if case .hostPort(let host, _) = c.endpoint, !HandoffLogic.isLocal("\(host)") { c.cancel(); return }
        c.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 5) { if c.state != .cancelled { c.cancel() } }   // 五秒還沒送完就斷
        receive(c, Data())
    }

    private func receive(_ c: NWConnection, _ buf: Data) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, done, err in
            guard let self else { return }
            var b = buf
            if let data { b.append(data) }
            switch HandoffLogic.parse(b) {
            case .incomplete:
                if done || err != nil { c.cancel() } else { self.receive(c, b) }
            case .bad: self.reply(c, 400, #"{"ok":false,"error":"bad request"}"#)
            case .tooLarge: self.reply(c, 413, #"{"ok":false,"error":"too large"}"#)
            case .ok(let r): self.handle(c, r)
            }
        }
    }

    private func handle(_ c: NWConnection, _ r: HandoffLogic.Request) {
        let now = Date().timeIntervalSince1970
        guard now >= lockedUntil else { reply(c, 429, #"{"ok":false,"error":"try again later"}"#); return }
        guard r.path.split(separator: "?").first == "/open" else { reply(c, 404, #"{"ok":false}"#); return }
        guard r.method == "POST" else { reply(c, 405, #"{"ok":false}"#); return }
        guard HandoffLogic.authorized(r, token: HandoffToken.current) else {
            failures = failures.filter { now - $0 < 60 } + [now]
            if failures.count >= 5 { lockedUntil = now + 60; failures = []; log("handoff server: too many bad tokens, pausing 60 s") }
            reply(c, 401, #"{"ok":false,"error":"wrong pairing code"}"#); return
        }
        guard let u = HandoffLogic.url(from: r) else { reply(c, 400, #"{"ok":false,"error":"no web address"}"#); return }
        reply(c, 200, #"{"ok":true}"#)
        DispatchQueue.main.async { PhoneHandoff.receive(u, via: .shortcut) }
    }

    private func reply(_ c: NWConnection, _ code: Int, _ json: String) {
        c.send(content: HandoffLogic.response(code, json), completion: .contentProcessed { _ in c.cancel() })
    }

    // MARK: 設定頁顯示的位址

    /// 「http://Aaron-MacBook-Air.local:47391/open」：捷徑裡填這個（Bonjour 名稱，換 Wi‑Fi 也不用改）
    static var address: String {
        let h = ProcessInfo.processInfo.hostName
        let local = h.hasSuffix(".local") ? h : (h.split(separator: ".").first.map(String.init) ?? h) + ".local"
        return "http://\(local):\(port)/open"   // l10n-ignore：網址
    }
}

// MARK: - 配對碼（鑰匙圈，kSecClassGenericPassword）

enum HandoffToken {
    static let service = "me.aaronlau.homeplay.handoff", account = "send-to-homeplay"
    nonisolated(unsafe) private static var cached: String?

    private static var base: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    /// 現在的配對碼；沒有就產生一組存起來
    static var current: String {
        if let c = cached { return c }
        if let t = ProcessInfo.processInfo.environment["HOMEPLAY_HANDOFF_TOKEN"], !t.isEmpty { cached = t; return t }   // 測試用：不碰鑰匙圈
        var out: CFTypeRef?
        var q = base; q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        if SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data, let s = String(data: d, encoding: .utf8), !s.isEmpty {
            cached = s; return s
        }
        return regenerate()
    }

    /// 重新產生（舊的捷徑要改成新的碼）
    @discardableResult
    static func regenerate() -> String {
        let t = HandoffLogic.newToken()
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = Data(t.utf8)
        add[kSecAttrLabel as String] = "HomePlay · Send to HomePlay"   // l10n-ignore：鑰匙圈項目名
        let s = SecItemAdd(add as CFDictionary, nil)
        if s != errSecSuccess { log("handoff token keychain status \(s)") }
        cached = t
        return t
    }

    /// 顯示用：每 4 字一組
    static func grouped(_ t: String) -> String {
        stride(from: 0, to: t.count, by: 4).map { i in
            let a = t.index(t.startIndex, offsetBy: i), b = t.index(a, offsetBy: min(4, t.count - i))
            return String(t[a..<b])
        }.joined(separator: "-")
    }
}
