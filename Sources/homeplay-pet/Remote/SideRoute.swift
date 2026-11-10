// 一個 listener 上的所有路由（Windows SideShow 的 endpoint 模型：同一台裝置、同一份名冊，
// 差別只在「收哪種內容」——/ 是鏡像、/side/ 是副屏）。
//
// 純函數：收好請求、回位元組，連線生命週期在 RemoteServer。
// 只認區網（RemoteServer 已經擋過一次），Host 標頭再由 RemoteCrypto.canonicalHost 驗一次（擋 DNS rebinding）。
//
// 配對：POST /pair {code, name, agree, sign, mode} → {id}。沒有任何祕密回給裝置——它自己的私鑰從來沒離開裝置。
// 副屏：POST /side/session {id, at, sig} → {ticket}；GET /side/state 帶 X-Side-Ticket。
//   簽章證明「這台就是名冊上那台」，票據只在記憶體、5 分鐘；內容本身照舊只在區網。

import Foundation

enum SideRoute {
    /// 路由回傳 nil＝不認得，交給呼叫端回 404
    static func handle(_ r: SideShowRequest, store: RemoteStore, tickets: RemoteSideTickets, feed: SideShowFeed) -> SideShowResponse? {
        guard RemoteCrypto.canonicalHost(r.headers["host"] ?? "") != nil else { return .json(421, ["error": "host"]) }
        let p = r.path
        // 頁面與它的資產
        if p == "/side" { return .redirect("/side/") }
        switch (r.method, p) {
        case ("GET", "/side/"), ("GET", "/side/index.html"):
            return SideShowResponse(code: 200, type: "text/html; charset=utf-8", body: Data(SideShowPage.html.utf8), page: true)
        case ("GET", "/side/manifest.webmanifest"):
            return SideShowResponse(code: 200, type: "application/manifest+json", body: Data(SideShowPage.manifest.utf8))
        case ("GET", "/side/sw.js"):
            return SideShowResponse(code: 200, type: "text/javascript; charset=utf-8", body: Data(SideShowPage.serviceWorker.utf8))
        case ("GET", "/side/sideshow.appcache"):
            return SideShowResponse(code: 200, type: "text/cache-manifest", body: Data(SideShowPage.appCache.utf8))
        case ("GET", "/side/icon-180.png"), ("GET", "/side/icon-512.png"):
            return SideShowResponse(code: 200, type: "image/png", body: SideShowPage.icon(p.hasSuffix("180.png") ? 180 : 512))
        case ("GET", "/side/identity.js"):
            return SideShowResponse(code: 200, type: "text/javascript; charset=utf-8", body: Data(RemoteIdentityJS.source.utf8))
        default: break
        }

        // 配對（兩個頁面共用：私鑰留在裝置，這裡只收公鑰）
        if r.method == "POST", p == "/pair" {
            guard r.body.count <= 4096, let o = (try? JSONSerialization.jsonObject(with: r.body)) as? [String: Any] else { return .json(400, ["error": "format"]) }
            guard let code = o["code"] as? String, code.count <= 32,
                  let agree = (o["agree"] as? String).flatMap({ Data(base64Encoded: $0) }),
                  let sign = (o["sign"] as? String).flatMap({ Data(base64Encoded: $0) }) else { return .json(400, ["error": "format"]) }
            let mode = o["mode"] as? String ?? "mirror"
            switch store.redeem(code: code, ip: r.ip, name: o["name"] as? String ?? "",
                                agree: agree, sign: sign, mirror: mode != "side", side: mode != "mirror") {
            case .ok(let id): log("remote: device paired"); return .json(200, ["id": id])
            case .badCode: return .json(403, ["error": "code"])
            case .blocked: return .json(429, ["error": "blocked"])
            case .full: return .json(409, ["error": "full"])
            }
        }

        // 副屏：簽一張短票
        if r.method == "POST", p == "/side/session" {
            guard r.body.count <= 4096, let o = (try? JSONSerialization.jsonObject(with: r.body)) as? [String: Any],
                  let id = o["id"] as? String, let at = o["at"] as? Double, let sig = (o["sig"] as? String).flatMap({ Data(base64Encoded: $0) }) else {
                return .json(400, ["error": "format"])
            }
            let now = Date().timeIntervalSince1970
            guard abs(now - at) <= RemoteIdentity.sideClockWindow else { return .json(401, ["error": "clock"]) }
            guard let dev = store.device(id), dev.side, let k = store.keys(for: id),
                  RemoteIdentity.verify(sig, transcript: RemoteIdentity.sideTranscript(id: id, at: at), signKey: k.sign) else {
                log("remote: side sign-in rejected"); return .unauthorized
            }
            store.touch(id, ip: r.ip)
            return .json(200, ["ticket": tickets.issue(id)])
        }

        // 副屏：內容（票據 → 這台裝置 → 個人內容版本）
        if r.method == "GET", p == "/side/state" {
            guard let t = r.headers["x-side-ticket"], let id = tickets.device(t), let dev = store.device(id), dev.side else { return .unauthorized }
            return SideShowResponse(code: 200, type: "application/json", body: feed.state(personal: dev.personal))
        }

        if p.hasPrefix("/side/") { return .unauthorized }
        return nil
    }
}
