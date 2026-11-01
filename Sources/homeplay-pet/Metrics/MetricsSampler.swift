// 2.0 D1：儀表的取樣器——定時叫各資料源、量實際間隔、做指針平滑、把結果交給主執行緒（規格 R11：平滑在取樣端做）。
//
// 只用 Foundation；資料源各自在自己的檔案裡（MetricSources.standard()）。

import Foundation

/// 指針值的指數平滑。nil 原樣傳下去並清掉那一欄的狀態：讀不到就是「—」，不拿舊值假裝，回來時從新值重新起步。
struct MetricSmoother {
    /// 每 1 秒的平滑係數；間隔不是 1 秒時換算成等效係數，省電改成 2 秒取樣時指針的跟手程度不變
    var alpha: Double
    private var state: [String: Double] = [:]

    init(alpha: Double = 0.35) { self.alpha = min(max(alpha, 0.01), 1) }

    mutating func reset() { state.removeAll() }

    /// 只平滑會畫成指針的值：負載、GPU、整機功率、各叢集頻率。其他欄位原樣保留。
    mutating func apply(_ raw: MetricSnapshot, interval: TimeInterval?) -> MetricSnapshot {
        let a = 1 - pow(1 - alpha, max(interval ?? 1, 0.01))
        var s = raw
        s.cpuPercent = step("cpu", raw.cpuPercent, a)
        s.gpuPercent = step("gpu", raw.gpuPercent, a)
        if var p = raw.power {
            p.systemW = step("sysW", p.systemW, a)
            s.power = p
        } else { state["sysW"] = nil }
        let live = Set(raw.clusters.map { "mhz." + $0.name })
        for k in state.keys where k.hasPrefix("mhz.") && !live.contains(k) { state[k] = nil }
        for i in s.clusters.indices { s.clusters[i].mhz = step("mhz." + s.clusters[i].name, s.clusters[i].mhz, a) }
        return s
    }

    private mutating func step(_ key: String, _ v: Double?, _ a: Double) -> Double? {
        guard let v, v.isFinite else { state[key] = nil; return nil }
        let next = state[key].map { $0 + a * (v - $0) } ?? v
        state[key] = next
        return next
    }
}

final class MetricsSampler {
    /// 一般取樣間隔
    let interval: TimeInterval
    /// 主執行緒上收到（原始, 平滑後）。開始時若有上次的讀值，會先用它立刻叫一次（一亮就有東西畫）。
    var onUpdate: ((MetricSnapshot, MetricSnapshot) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return _onUpdate }
        set { lock.lock(); _onUpdate = newValue; lock.unlock() }
    }

    private let queue = DispatchQueue(label: "app.homeplay.metrics", qos: .utility)
    private let lock = NSLock()
    private var _onUpdate: ((MetricSnapshot, MetricSnapshot) -> Void)?
    private var _latest: MetricSnapshot?
    private var _smoothed: MetricSnapshot?
    private var _measured: TimeInterval?
    private var _activeNames: [String] = []

    // 下面只在 queue 上碰
    private var pending: [MetricSource]
    private var sources: [MetricSource] = []
    private var sourcesStarted = false
    private var smoother: MetricSmoother
    private var lastUptime: TimeInterval?
    private var timer: DispatchSourceTimer?
    private var currentPeriod: TimeInterval

    init(sources: [MetricSource] = MetricSources.standard(), interval: TimeInterval = 1.0, smoothing alpha: Double = 0.35) {
        pending = sources
        self.interval = interval
        currentPeriod = interval
        smoother = MetricSmoother(alpha: alpha)
    }

    deinit { timer?.cancel() }

    /// 最近一次原始讀值（任何執行緒都可讀）
    var latest: MetricSnapshot? { lock.lock(); defer { lock.unlock() }; return _latest }
    /// 最近一次平滑後的讀值，錶面用這個
    var latestSmoothed: MetricSnapshot? { lock.lock(); defer { lock.unlock() }; return _smoothed }
    /// 上一次實際量到的取樣間隔（秒）
    var measuredInterval: TimeInterval? { lock.lock(); defer { lock.unlock() }; return _measured }
    /// 實際在用的資料源（start() 回 false 的已剔除）；第一次取樣前是空的
    /// 走 lock 不走 queue.sync：主執行緒讀它時不必等第一次 tick 裡 IOReport/SMC 的 start()
    var activeSourceNames: [String] { lock.lock(); defer { lock.unlock() }; return _activeNames }

    func start() {
        queue.async { [weak self] in
            guard let self, self.timer == nil else { return }
            if let raw = self.latest, let sm = self.latestSmoothed { self.deliver(raw, sm) }
            let t = DispatchSource.makeTimerSource(queue: self.queue)
            t.setEventHandler { [weak self] in self?.tick() }
            t.schedule(deadline: .now(), repeating: self.currentPeriod, leeway: .milliseconds(100))
            self.timer = t
            t.resume()
        }
    }

    func stop() {
        queue.async { [weak self] in
            self?.timer?.cancel()
            self?.timer = nil
        }
    }

    /// 同步取一次（CLI、自測用）。不可在取樣佇列上呼叫（queue.sync 會死鎖）；主執行緒呼叫會等到這次取樣做完。
    @discardableResult
    func sampleOnce() -> MetricSnapshot {
        queue.sync { tick(notify: false) }
    }

    // MARK: - 佇列內

    private func startSourcesIfNeeded() {
        guard !sourcesStarted else { return }
        sourcesStarted = true
        sources = pending.filter { $0.start() }
        pending = []
        let names = sources.map(\.name)
        lock.lock(); _activeNames = names; lock.unlock()
    }

    @discardableResult
    private func tick(notify: Bool = true) -> MetricSnapshot {
        startSourcesIfNeeded()
        let now = ProcessInfo.processInfo.systemUptime
        let dt = lastUptime.map { now - $0 }
        lastUptime = now
        var s = MetricSnapshot()
        for src in sources { src.sample(into: &s, interval: dt) }
        let sm = smoother.apply(s, interval: dt)
        lock.lock(); _latest = s; _smoothed = sm; _measured = dt; lock.unlock()
        if notify { deliver(s, sm) }
        retime(after: s)
        return s
    }

    /// 省電：用電池、電量 ≤20% 時降到一半頻率（0.5 Hz）
    static func period(base: TimeInterval, after s: MetricSnapshot) -> TimeInterval {
        let saving = s.battery.map { !$0.onAC && $0.percent <= 20 } ?? false
        return saving ? base * 2 : base
    }

    private func retime(after s: MetricSnapshot) {
        let want = Self.period(base: interval, after: s)
        guard want != currentPeriod else { return }
        currentPeriod = want
        timer?.schedule(deadline: .now() + want, repeating: want, leeway: .milliseconds(100))
    }

    private func deliver(_ raw: MetricSnapshot, _ sm: MetricSnapshot) {
        guard let cb = onUpdate else { return }
        DispatchQueue.main.async { cb(raw, sm) }
    }
}

/// `homeplay-pet --metrics-json [count]`：每行一個 JSON（原始讀值），給 tooling/metrics-vs-mactop.py 對照用。
/// count 預設 2（第二筆才有速率），0＝一直跑。`--metrics-json-pretty` 改成縮排輸出。
enum MetricsCLI {
    static func run(_ args: [String]) -> Never {
        let pretty = args.contains("--metrics-json-pretty")
        let flag = pretty ? "--metrics-json-pretty" : "--metrics-json"
        var count = 2
        if let i = args.firstIndex(of: flag), i + 1 < args.count, let n = Int(args[i + 1]), n >= 0 { count = n }
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = pretty ? [.sortedKeys, .prettyPrinted] : [.sortedKeys]
        let sampler = MetricsSampler()
        var n = 0
        while count == 0 || n < count {
            let started = ProcessInfo.processInfo.systemUptime
            let s = sampler.sampleOnce()
            if let d = try? enc.encode(s), let line = String(data: d, encoding: .utf8) { print(line) }
            fflush(stdout)
            n += 1
            if count == 0 || n < count {
                // 扣掉取樣本身花的時間，間隔才是 1 秒；第一筆含各資料源的 start()（SMC 列舉鍵）常超過 1 秒，扣完會變成不等，第二筆就貼著第一筆，所以第一筆後睡滿
                let spent = n == 1 ? 0 : ProcessInfo.processInfo.systemUptime - started
                Thread.sleep(forTimeInterval: max(0, sampler.interval - spent))
            }
        }
        exit(0)
    }
}
