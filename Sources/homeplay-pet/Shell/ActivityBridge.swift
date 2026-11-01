// 2.0 iPhone 延伸：把「來自 iPhone 的即時動態」接進頂端膠囊。
//
// 取證見 docs/iphone-continuity-feasibility.md：macOS 27 的 ActivityKit 讓未簽名進程也能訂閱，
// 但同一段呼叫在 homeplay-pet 的 NSApplication 事件迴圈裡幾秒內必踩 BoardServices 斷言
// （BSSimpleAssertion dealloc brk）。所以私有 API 移到獨立進程 homeplay-glance，由它寫一份 JSON：
//   ~/Library/Application Support/HomePlay/glance.json  {"at": <時間>, "activities": [ {id, app, bundle, start, remote} ]}
// 這裡只讀檔。helper 不在、當掉、或資料過期（>6 秒）就當作沒有活動——桌寵完全不受影響。
//
// 內容是資料不是畫面：ACActivityContent.contentData 是 App 自己序列化的，第三方解不開，
// 所以卡片顯示 App 名＋已進行時間＋「來自 iPhone」，點一下進 iPhone Mirroring（跟 Apple 的雙擊一致）。

import AppKit

struct RemoteActivity: Equatable {
    var id: String
    var appName: String
    var bundleID: String?
    var started: Double
    var isRemote: Bool
}

final class ActivityBridge {
    /// 不是自家 App：點膠囊時交給 iPhone Mirroring
    static let mirroringAppID = "iphone-activity"
    private static let mirroringPath = "/System/Applications/iPhone Mirroring.app"
    /// helper 超過這麼久沒更新，就當它掛了
    private static let staleAfter: Double = 6

    nonisolated(unsafe) static let shared = ActivityBridge()

    private(set) var activities: [RemoteActivity] = []
    private(set) var available = false
    private var hidden: Set<String> = []
    nonisolated(unsafe) private var dirty = false
    private var helper: Process?
    private var demo = false
    private var fileURL: URL
    private var lastRead: Double = 0
    private var lastStamp: Double = 0

    private init() {
        if let p = ProcessInfo.processInfo.environment["HOMEPLAY_GLANCE_FILE"] {
            fileURL = URL(fileURLWithPath: p)
        } else if let i = CommandLine.arguments.firstIndex(of: "--glance-file"), i + 1 < CommandLine.arguments.count {
            fileURL = URL(fileURLWithPath: CommandLine.arguments[i + 1])
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            fileURL = base.appendingPathComponent("HomePlay/glance.json")
        }
    }

    // MARK: 啟動

    /// 開機叫一次：拉起 helper（找得到才拉），並讀一次檔。
    func start() {
        launchHelper()
        refresh(force: true)
    }

    private func launchHelper() {
        guard helper == nil else { return }
        let exe = Bundle.main.executableURL?.deletingLastPathComponent()
        let candidates = [
            ProcessInfo.processInfo.environment["HOMEPLAY_GLANCE"].map { URL(fileURLWithPath: $0) },
            Bundle.main.resourceURL?.appendingPathComponent("homeplay-glance"),   // .app：放 Resources（make-app.sh 開頭說明為什麼不放 MacOS）
            exe?.appendingPathComponent("homeplay-glance"),                       // swift build：跟 homeplay-pet 同一個資料夾
            exe?.appendingPathComponent("../../../release/homeplay-glance"),   // swift build -c release 從 debug 找
            URL(fileURLWithPath: "/usr/local/bin/homeplay-glance"),
        ].compactMap { $0 }
        guard let path = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) else { return }
        let p = Process()
        p.executableURL = path
        p.arguments = ["--out", fileURL.path, "--parent", String(getpid())]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do {
            try p.run()
            helper = p
            available = true
        } catch {
            helper = nil
        }
    }

    func stop() {
        helper?.terminate()
        helper = nil
    }

    // MARK: 讀檔

    /// 每幀便宜地問；超過 2 秒才真的讀檔
    func refreshIfNeeded(now: Double) {
        guard !demo, now - lastRead >= 2 else { return }   // 截圖／自測餵的假資料不被檔案蓋掉
        refresh(force: false)
    }

    private func refresh(force: Bool) {
        lastRead = CACurrentMediaTime()
        guard let data = try? Data(contentsOf: fileURL),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let stamp = obj["at"] as? Double,
              let rows = obj["activities"] as? [[String: Any]] else {
            if !activities.isEmpty { activities = []; dirty = true }
            return
        }
        lastStamp = stamp
        guard force || Date().timeIntervalSince1970 - stamp <= Self.staleAfter else {
            if !activities.isEmpty { activities = []; dirty = true }
            return
        }
        let next = rows.compactMap { r -> RemoteActivity? in
            guard let id = r["id"] as? String, !id.isEmpty else { return nil }
            return RemoteActivity(id: id,
                                  appName: (r["app"] as? String) ?? "iPhone",
                                  bundleID: (r["bundle"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                                  started: (r["start"] as? Double) ?? Date().timeIntervalSince1970,
                                  isRemote: (r["remote"] as? Bool) ?? true)
        }
        guard next != activities else { return }
        activities = next
        hidden.formIntersection(Set(next.map(\.id)))
        dirty = true
    }

    // MARK: 給膠囊用

    /// 這一幀要顯示的活動：收起過的不顯示
    func liveActivities(now: Double) -> [LiveActivity] {
        refreshIfNeeded(now: CACurrentMediaTime())
        let blue = NSColor(srgbRed: 0x00 / 255.0, green: 0x88 / 255.0, blue: 0xFF / 255.0, alpha: 1)
        return activities
            .filter { !hidden.contains($0.id) }
            .sorted { $0.started > $1.started }
            .map { a in
                LiveActivity(kind: .iphone, title: a.appName,
                             detail: Self.elapsed(Date().timeIntervalSince1970 - a.started),
                             accent: blue, progress: nil,
                             appID: Self.mirroringAppID, symbol: "iphone", link: a.id)
            }
    }

    func hide(_ id: String) {
        guard !id.isEmpty else { return }
        hidden.insert(id)
        dirty = true
    }

    func consumeDirty() -> Bool {
        defer { dirty = false }
        return dirty
    }

    static func openMirroring() {
        guard FileManager.default.fileExists(atPath: mirroringPath) else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: mirroringPath))
    }

    /// 截圖／自測：不必真的連 iPhone，直接餵一份資料
    func applyDemo(appName: String) {
        demo = true
        activities = [RemoteActivity(id: "demo-iphone", appName: appName,
                                     bundleID: "com.apple.demo",
                                     started: Date().timeIntervalSince1970 - 754, isRemote: true)]
        available = true
        dirty = true
    }

    private static func elapsed(_ s: Double) -> String {
        let t = max(0, Int(s))
        if t < 60 { return "0:\(String(format: "%02d", t))" }
        if t < 3600 { return "\(t / 60):\(String(format: "%02d", t % 60))" }
        return "\(t / 3600):\(String(format: "%02d", (t % 3600) / 60))"
    }
}
