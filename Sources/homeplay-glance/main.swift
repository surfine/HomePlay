// homeplay-glance：把 macOS 上「來自 iPhone 的即時動態」寫成一份 JSON，給桌寵讀。
//
// 為什麼是獨立進程：同樣的 ActivityKit 訂閱在 CLI 裡穩定（實測 24 秒無事），但在 homeplay-pet 的
// NSApplication 事件迴圈裡必定在幾秒後踩到 BoardServices 斷言（BSSimpleAssertion dealloc brk）。
// 私有 API 放在自己的進程，崩了只影響這一份 JSON；桌寵照常跑。
//
//   homeplay-glance [--out <path>] [--interval 2]
//
// 每 2 秒檢查一次、有變化就原子寫入。沒有活動時寫空陣列（桌寵會把膠囊收回）。

import AppKit

let args = CommandLine.arguments
func arg(_ k: String) -> String? {
    guard let i = args.firstIndex(of: k), i + 1 < args.count else { return nil }
    return args[i + 1]
}

let interval = max(0.5, Double(arg("--interval") ?? "2") ?? 2)
let outURL: URL = {
    if let p = arg("--out") { return URL(fileURLWithPath: p) }
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    let dir = base.appendingPathComponent("HomePlay", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.appendingPathComponent("glance.json")
}()

// MARK: 訂閱

final class Glance: NSObject {
    private var center: NSObject?
    private var descriptors: [[String: Any]] = []
    private var handlers: [AnyObject] = []

    func start() -> Bool {
        dlopen("/System/Library/Frameworks/ActivityKit.framework/Versions/A/ActivityKit", RTLD_NOW)
        guard let cls = NSClassFromString("ACActivityCenter") as? NSObject.Type else { return false }
        let c = cls.init()
        center = c
        let block: @convention(block) (NSArray?) -> Void = { [weak self] list in
            let items = ((list as? [Any]) ?? []).compactMap(Self.row)
            DispatchQueue.main.async {
                guard let self else { return }
                if !(items as NSArray).isEqual(self.descriptors as NSArray) {
                    self.descriptors = items
                    self.write()
                }
            }
        }
        // 必須是真正的 ObjC block（unsafeBitCast），而且要被持有
        let obj = unsafeBitCast(block, to: AnyObject.self)
        handlers.append(obj)
        guard c.responds(to: NSSelectorFromString("observeDescriptorsWithHandler:")) else { return false }
        _ = c.perform(NSSelectorFromString("observeDescriptorsWithHandler:"), with: obj)
        return true
    }

    private static func row(_ any: Any) -> [String: Any]? {
        let o = any as AnyObject
        guard let id = o.value(forKey: "activityIdentifier") as? String, !id.isEmpty else { return nil }
        let bundle = o.value(forKey: "platterTargetBundleIdentifier") as? String
        let name = (o.value(forKey: "localizedAppName") as? String)?.trimmingCharacters(in: .whitespaces)
        let created = (o.value(forKey: "createdDate") as? Date)?.timeIntervalSince1970
            ?? Date().timeIntervalSince1970
        let remote = !(o.value(forKey: "remoteDeviceIdentifier").map { $0 is NSNull } ?? true)
        let fallback = bundle?.split(separator: ".").last.map(String.init) ?? "iPhone"
        return ["id": id,
                "app": (name?.isEmpty == false ? name! : fallback),
                "bundle": bundle ?? "",
                "start": created,
                "remote": remote]
    }

    func write() {
        let payload: [String: Any] = ["at": Date().timeIntervalSince1970, "activities": descriptors]
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) else { return }
        try? data.write(to: outURL, options: .atomic)
    }
}

let glance = Glance()
guard glance.start() else {
    // 沒有 ActivityKit／沒有這座橋：寫一份空清單，桌寵就不顯示，也不需要重試
    glance.write()
    FileHandle.standardError.write(Data("homeplay-glance: ActivityKit bridge unavailable\n".utf8))
    exit(3)
}
glance.write()

let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in
    if let p = arg("--parent").flatMap({ pid_t($0) }), kill(p, 0) != 0 { exit(0) }   // 桌寵關了，自己也收
    glance.write()
}
RunLoop.main.add(timer, forMode: .common)
RunLoop.main.run()
