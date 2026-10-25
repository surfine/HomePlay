// 叫手机回连：手机在局域网广播 _carplay-ctrl._tcp，我们找到它后发
// `GET /ctrl-int/1/connect`（带我们的设备 ID），手机就会连回我们的 _airplay._tcp 控制口。
// 行为对应 MacPlay Engine/discovery.ts（resolve / probe）：一次只探一个端点，HTTP 2xx 只表示收到请求，
// 不代表已回连；没回连就隔 5 s 再探，每个端点最多 7 次。
import Foundation
import Network

/// 每个端点的探测节拍：前 7 次每 5 s，之后退到 30 s 一次并重新从 1 数。
/// 不能像旧代码那样 7 次后永久放弃——手机晚一点解锁/回网时就再也叫不回来了。
package struct CtrlProbeSchedule {
    package private(set) var attempts: [String: Int] = [:]
    package private(set) var nextAt: [String: Double] = [:]
    package init() {}

    /// 到点就返回本次尝试序号并推进节拍；没到点返回 nil。
    package mutating func due(_ name: String, now: Double) -> Int? {
        if let t = nextAt[name], now < t { return nil }
        let prev = attempts[name] ?? 0
        let n = prev >= 7 ? 1 : prev + 1
        attempts[name] = n
        nextAt[name] = now + (n == 7 ? 30 : 5)
        return n
    }
}

/// 給診斷用的結構化事件（日誌照舊另寫）。browse：ready／waiting／denied（本地網路權限被拒）／failed。
package enum CtrlProbeEvent: Sendable, Equatable {
    case browse(String)
    case services(Int)
    case probe(answered: Bool)
}

package final class CtrlProbe {
    private let deviceId: String
    private let phoneId: String?          // 手机 TXT 里的 id=（蓝牙地址），给了就只探这台
    private let queue = DispatchQueue(label: "session.ctrlprobe")
    private var browser: NWBrowser?
    private var schedule = CtrlProbeSchedule()
    private var busy = false
    private var stopped = false
    private var latest: [NWBrowser.Result] = []
    private var lastReportedCount = -1
    private var reportedFiltered = false
    package var onLog: ((String) -> Void)?
    /// 在探測佇列上呼叫
    package var onEvent: ((CtrlProbeEvent) -> Void)?

    /// macOS 15 起「本地網路」權限被拒時，Bonjour／連線會停在 waiting，錯誤是 kDNSServiceErr_PolicyDenied（-65570）
    package static func isPolicyDenied(_ e: NWError) -> Bool {
        if case .dns(let code) = e { return code == -65570 }
        return false
    }

    package init(deviceId: String, phoneBluetoothAddress: String?) {
        self.deviceId = deviceId
        self.phoneId = phoneBluetoothAddress.map(Self.norm)
    }

    package static func norm(_ s: String) -> String { s.lowercased().filter { $0.isHexDigit } }

    package static func request(host: String, port: UInt16, deviceId: String) -> String {
        let h = host.contains(":") ? "[\(host)]" : host
        return "GET /ctrl-int/1/connect HTTP/1.1\r\nHost: \(h):\(port)\r\nUser-Agent: AirPlay/950.7.1\r\n" +
            "AirPlay-Receiver-Device-ID: \(deviceId.replacingOccurrences(of: ":", with: ""))\r\nConnection: close\r\n\r\n"
    }

    package func start() {
        let b = NWBrowser(for: .bonjourWithTXTRecord(type: "_carplay-ctrl._tcp", domain: nil), using: .tcp)
        b.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self else { return }
            if results.count != self.lastReportedCount {
                self.lastReportedCount = results.count
                self.onLog?("ctrl 浏览到 \(results.count) 个控制服务")
                self.onEvent?(.services(results.count))
            }
            self.latest = Array(results); self.next()
        }
        b.stateUpdateHandler = { [weak self] st in
            switch st {
            case .ready: self?.onLog?("ctrl 浏览就绪"); self?.onEvent?(.browse("ready"))
            case .waiting(let e):
                self?.onLog?("ctrl 浏览等待：\(e)")
                self?.onEvent?(.browse(Self.isPolicyDenied(e) ? "denied" : "waiting"))
            case .failed(let e):
                self?.onLog?("ctrl 浏览失败：\(e)")
                self?.onEvent?(.browse(Self.isPolicyDenied(e) ? "denied" : "failed"))
            default: break
            }
        }
        b.start(queue: queue)
        browser = b
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 5, repeating: 5)
        t.setEventHandler { [weak self] in self?.next() }
        t.resume(); timer = t
    }
    private var timer: DispatchSourceTimer?

    /// 手机已经连回来了：停止探测
    package func stop() {
        queue.async { [self] in stopped = true; browser?.cancel(); browser = nil; timer?.cancel(); timer = nil }
    }

    private func next() {
        guard !stopped, !busy else { return }
        let now = ProcessInfo.processInfo.systemUptime
        for r in latest {
            guard case .service(let name, _, _, _) = r.endpoint else { continue }
            if let phoneId, case .bonjour(let txt) = r.metadata, let id = txt["id"], Self.norm(id) != phoneId {
                if !reportedFiltered {
                    reportedFiltered = true
                    onLog?("ctrl 有控制服务，但不是当前 iPhone，已跳过")
                }
                continue   // 不是选定的那台
            }
            guard let attempt = schedule.due(name, now: now) else { continue }
            probe(r.endpoint, name: name, attempt: attempt)
            return
        }
    }

    private func probe(_ endpoint: NWEndpoint, name: String, attempt: Int) {
        busy = true
        let c = NWConnection(to: endpoint, using: .tcp)
        var answered = false
        var done = false   // 这一次探测自己的收尾标记（超时回调可能晚于下一次探测开始）
        func finish(_ why: String) {
            guard !done else { return }
            done = true; busy = false; c.cancel()
            onLog?("ctrl 探测 \(name) 第 \(attempt) 次：\(why)")
            onEvent?(.probe(answered: why.hasPrefix("HTTP/")))
        }
        c.stateUpdateHandler = { st in
            switch st {
            case .ready:
                var host = "phone", port: UInt16 = 0
                if case .hostPort(let h, let p) = c.currentPath?.remoteEndpoint {
                    port = p.rawValue
                    switch h {
                    case .ipv4(let a): host = "\(a)"
                    case .ipv6(let a): host = "\(a)".components(separatedBy: "%").first ?? "\(a)"
                    case .name(let n, _): host = n
                    @unknown default: break
                    }
                }
                c.send(content: Data(Self.request(host: host, port: port, deviceId: self.deviceId).utf8),
                       completion: .contentProcessed { _ in })
                c.receive(minimumIncompleteLength: 1, maximumLength: 256) { data, _, _, _ in
                    let line = data.flatMap { String(data: $0, encoding: .ascii) }?.components(separatedBy: "\r\n").first ?? ""
                    answered = true
                    finish(line.isEmpty ? "无应答" : line)
                }
            case .failed(let e): finish("失败 \(e)")
            case .waiting(let e) where Self.isPolicyDenied(e):
                self.onEvent?(.browse("denied"))
                finish("本地网络权限被拒")
            case .cancelled: if !answered { finish("取消") }
            default: break
            }
        }
        c.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 3) { if !answered { finish("超时") } }
    }
}
