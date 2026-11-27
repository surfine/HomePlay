import AppKit
import Foundation
import QuartzCore

/// 强制门户（captive portal）探测：酒店、机场、Apple Store 这类 Wi-Fi 要先在网页上登录。
/// 这类网络常挡住两台设备互连，无线 CarPlay 很可能根本连不回来；排障卡据此换成
/// 「先登录」的说法与退路（插线、iPhone 热点），而不是一直叫用户检查 Wi-Fi 名称。
enum CaptiveWiFi {
    struct Result: Equatable {
        var captive: Bool
        var portal: URL?     // 登录页；open 网络为 nil
        var at: Double
    }

    private static let lock = NSLock()
    private static var last: Result?
    private static var inFlight = false
    private static let cacheSeconds: Double = 20

    /// 最近一次结果（同步；主执行绪可读）
    static var latest: Result? {
        lock.lock(); defer { lock.unlock() }
        return last
    }

    /// 探测当前 Wi-Fi 是不是强制门户。没有网／超时回 nil（不知道，不当作门户）。
    /// 结果缓存 20 秒；同一时间只跑一次请求。
    static func probe(force: Bool = false, done: ((Result?) -> Void)? = nil) {
        let now = CACurrentMediaTime()
        lock.lock()
        let cached = last
        if !force, let cached, now - cached.at < cacheSeconds {
            lock.unlock()
            done?(cached)
            return
        }
        if inFlight {
            lock.unlock()
            done?(last)
            return
        }
        inFlight = true
        lock.unlock()

        var req = URLRequest(url: URL(string: "http://captive.apple.com/hotspot-detect.html")!)
        req.timeoutInterval = 4
        req.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 4
        cfg.timeoutIntervalForResource = 6
        cfg.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        let session = URLSession(configuration: cfg)
        session.dataTask(with: req) { data, response, error in
            var result: Result?
            if error == nil, let http = response as? HTTPURLResponse {
                let body = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                let host = http.url?.host?.lowercased() ?? ""
                let open = isOpen(status: http.statusCode, host: host, body: body)
                let portal = open ? nil : (http.url ?? URL(string: "http://captive.apple.com")!)
                result = Result(captive: !open, portal: portal, at: CACurrentMediaTime())
            }
            lock.lock(); last = result; inFlight = false; lock.unlock()
            session.invalidateAndCancel()
            done?(result)
        }.resume()
    }

    /// 純判定：200、還是 captive.apple.com、內文是 Success 才算正常網路。
    /// 被門戶劫持時會換頁、導到別的主機或回不同的內文；DNS 失敗（error）走 nil，不算門戶。
    static func isOpen(status: Int, host: String, body: String) -> Bool {
        status == 200 && host == "captive.apple.com" && body.contains("Success")
    }

    /// 用默认浏览器打开登录页；探测不到就开 captive.apple.com（open 网络会显示 Success）。
    static func openLoginPage() {
        probe(force: true) { r in
            DispatchQueue.main.async {
                let url = r?.portal ?? URL(string: "http://captive.apple.com")!
                NSWorkspace.shared.open(url)
            }
        }
    }
}
