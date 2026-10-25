// 2.0 Web App 的實機驗收（不是快照）：--webapp-e2e <網址>（例如 scratchpad 的 PWA、公開的 PWA）
// 用真的網路與真的持久網站資料庫，驗：manifest／圖示抓得到、兩個 Web App 的 localStorage／cookie 互相看不到、也不會漏到 Safari、
// 關掉再開資料還在、service worker 註冊得起來、範圍外的連結交給 Safari。存檔放在 HOMEPLAY_WEBAPPS_DIR（不碰真的主畫面），最後把兩個資料庫刪掉。
// 只印結果（不印網址內容、cookie 值）。

import AppKit
import WebKit

enum WebAppE2E {
    static func js(_ w: WKWebView, _ s: String) -> Any? {
        var out: Any?, done = false
        w.callAsyncJavaScript(s, arguments: [:], in: nil, in: .page) { r in if case .success(let v) = r { out = v }; done = true }
        WebAppDemo.spin(10) { done }
        return out
    }
    static func run(_ url: URL) {
        var ok = true
        func report(_ pass: Bool, _ what: String) { ok = ok && pass; print("webapp-e2e \(pass ? "PASS" : "FAIL") \(what)") }   // l10n-ignore：驗收輸出
        guard ProcessInfo.processInfo.environment["HOMEPLAY_WEBAPPS_DIR"] != nil else { print("webapp-e2e: set HOMEPLAY_WEBAPPS_DIR"); exit(2) }
        let safari = SafariApp.shared
        safari.open(url)
        WebAppDemo.spin(25) { safari.pumpWeb(CACurrentMediaTime()); return safari.hasPage }
        report(safari.hasPage, "Safari loaded the page")
        guard let sv = safari.currentWebView else { exit(1) }
        var draft: WebAppDraft?
        WebAppInstaller.prepare(sv) { draft = $0 }
        WebAppDemo.spin(20) { draft?.ready == true }
        guard let d = draft else { report(false, "manifest/icon"); exit(1) }
        print("webapp-e2e name=\(d.name) display=\(d.manifest.display) scope=\(d.manifest.scope.path) icons=\(d.manifest.icons.count) widgets=\(d.manifest.widgets.count) icon=\(d.icon != nil) theme=\(d.theme.map { String(format: "%06X", $0) } ?? "-")")   // l10n-ignore
        report(d.ready, "manifest and icon fetched")
        let a = d.makeApp(person: nil), b = d.makeApp(person: nil)
        let store = WebAppStore.shared
        store.add(a, icon: d.icon); store.add(b, icon: nil)
        func open(_ app: WebApp) -> WebAppWeb {
            let w = WebAppRuntimes.web(for: app)
            w.load(app.start!)
            w.settle(until: Date().addingTimeInterval(20))
            return w
        }
        // 巢狀的 run loop 不會倒掉外層的 autorelease pool：用完的網頁要在這裡真的釋放，資料庫才刪得掉（平常的 App 每個事件都會倒）
        autoreleasepool {
            var wa: WebAppWeb? = open(a)
            _ = js(wa!.view, "localStorage.setItem('hp-e2e','A'); document.cookie='hpE2E=A; max-age=600; path=/'; return 1")
            let swCount = js(wa!.view, "if(!navigator.serviceWorker) return -1; await new Promise(r=>setTimeout(r,1500)); return (await navigator.serviceWorker.getRegistrations()).length") as? Int ?? -2
            report(swCount > 0, "service worker registered in the web app (\(swCount))")
            var wb: WebAppWeb? = open(b)
            let bLS = js(wb!.view, "return localStorage.getItem('hp-e2e')") as? String
            let bCookie = (js(wb!.view, "return document.cookie") as? String ?? "").contains("hpE2E")
            report(bLS == nil && !bCookie, "second web app of the same site sees none of the first one's storage/cookies")
            let sLS = js(sv, "return localStorage.getItem('hp-e2e')") as? String
            let sCookie = (js(sv, "return document.cookie") as? String ?? "").contains("hpE2E")
            report(sLS == nil && !sCookie, "Safari sees none of the web app's storage/cookies")
            WebAppRuntimes.drop(a.uuid); WebAppRuntimes.drop(b.uuid); wa = nil; wb = nil
            WebAppDemo.spin(1.5) { false }
            var wa2: WebAppWeb? = open(a)
            let again = js(wa2!.view, "return localStorage.getItem('hp-e2e')") as? String
            let cookieAgain = (js(wa2!.view, "return document.cookie") as? String ?? "").contains("hpE2E")
            report(again == "A" && cookieAgain, "web app's own storage and cookies persist after closing and reopening")
            // 範圍外：點一個範圍外的連結＝交給 Safari（不在 Web App 裡開）
            var left: URL?
            wa2!.onLeaveScope = { left = $0 }
            _ = js(wa2!.view, "var a=document.createElement('a');a.href='https://www.apple.com/apple-homeview/';document.body.appendChild(a);a.click();return 1")
            WebAppDemo.spin(3) { left != nil }
            report(left?.host == "www.apple.com" && wa2!.url.map { a.inScope($0) } == true, "out-of-scope link goes to Safari, web app stays in scope")
            _ = js(wa2!.view, "location.href='file:///etc/hosts';return 1")
            WebAppDemo.spin(1) { false }
            report(wa2!.url?.scheme?.hasPrefix("http") == true, "file: navigation blocked")
            WebAppRuntimes.drop(a.uuid); wa2 = nil
        }
        store.remove(a.uuid); store.remove(b.uuid)
        // 刪除＝資料清空（開著也清得掉）；資料夾本身留給下次啟動的 purgeOrphans（WebKit 這時回 in use）
        var leftData = -1
        WebAppDemo.spin(3) { false }
        for u in [a.uuid, b.uuid] {
            var done = false
            WKWebsiteDataStore(forIdentifier: WebAppData.identifier(u)).fetchDataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes()) { r in leftData = max(leftData, r.count); done = true }
            WebAppDemo.spin(5) { done }
        }
        report(leftData == 0, "deleting the web apps cleared all of their website data")
        print(ok ? "webapp-e2e OK" : "webapp-e2e FAIL")   // l10n-ignore
        exit(ok ? 0 : 1)
    }
}
