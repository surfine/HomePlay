// 和「HomePlay Home」幫手（Mac Catalyst，持有 HomeKit 權利）通訊的客戶端。
//
// 幫手在 ~/Library/Application Support/HomePlay/home.sock 提供換行分隔的 JSON。
// 這裡負責：連線、socket 不在就用 NSWorkspace 拉起幫手、訂閱、解碼、斷線重連（1/2/5/10/30 秒，不狂敲）。
// 回呼一律在主執行緒。配件資料只留在記憶體。
import AppKit
import Foundation

struct HomeValue: Codable, Equatable {
    var raw: Double?
    var bool: Bool?
    var string: String?
    init(from d: Decoder) throws {
        let c = try d.singleValueContainer()
        if let b = try? c.decode(Bool.self) { bool = b; raw = b ? 1 : 0 }
        else if let n = try? c.decode(Double.self) { raw = n }
        else if let s = try? c.decode(String.self) { string = s }
    }
    func encode(to e: Encoder) throws {
        var c = e.singleValueContainer()
        if let bool { try c.encode(bool) } else if let raw { try c.encode(raw) } else if let string { try c.encode(string) } else { try c.encodeNil() }
    }
    var number: Double? { raw }
    var isOn: Bool? { bool ?? raw.map { $0 != 0 } }
}

struct HomeCharacteristic: Codable, Equatable {
    var id: String
    var type: String            // power brightness hue saturation currentTemp targetTemp currentMode targetMode lockCurrent lockTarget doorState humidity contact motion occupancy battery
    var value: HomeValue?
    var writable: Bool
    var units: String?
    var min: Double?
    var max: Double?
    var step: Double?
}

struct HomeAccessory: Codable, Equatable {
    var id: String
    var name: String
    var home: String?
    var room: String?
    var category: String        // HMAccessoryCategoryType（UUID 字串）
    var categoryName: String?   // 系統給的名稱，例：Lightbulb
    var reachable: Bool
    var characteristics: [HomeCharacteristic]
    func characteristic(_ type: String) -> HomeCharacteristic? { characteristics.first { $0.type == type } }
}

struct HomeInfo: Codable, Equatable { var id: String; var name: String; var primary: Bool }
struct HomeRoom: Codable, Equatable { var id: String; var name: String; var home: String? }
struct HomeScene: Codable, Equatable { var id: String; var name: String; var type: String; var home: String? }

struct HomeSnapshot: Codable, Equatable {
    var ready: Bool
    var homes: [HomeInfo]
    var rooms: [HomeRoom]
    var accessories: [HomeAccessory]
    var scenes: [HomeScene]
    static let empty = HomeSnapshot(ready: false, homes: [], rooms: [], accessories: [], scenes: [])
}

struct HomeChange: Equatable {
    var accessory: String
    var characteristic: String
    var type: String
    var value: HomeValue?
}

extension Notification.Name {
    static let homeLinkSnapshot = Notification.Name("HomePlay.homeLink.snapshot")   // object: HomeSnapshot
    static let homeLinkChanged = Notification.Name("HomePlay.homeLink.changed")     // object: HomeChange
    static let homeLinkConnection = Notification.Name("HomePlay.homeLink.connection") // object: Bool
}

final class HomeLink: @unchecked Sendable {
    static let shared = HomeLink()
    /// 這台 Mac 有沒有裝「HomePlay Home」小幫手（~/Applications 或 /Applications）；快照示範模式當作有
    static var helperInstalled: Bool {
        if Face.demoData { return true }
        let fm = FileManager.default
        return [NSHomeDirectory() + "/Applications", "/Applications"].contains { fm.fileExists(atPath: $0 + "/HomePlay Home.app") }
    }

    // 主執行緒
    private(set) var snapshot = HomeSnapshot.empty
    private(set) var connected = false
    var onSnapshot: ((HomeSnapshot) -> Void)?
    var onChanged: ((HomeChange) -> Void)?
    var onConnection: ((Bool) -> Void)?

    static let socketPath = NSHomeDirectory() + "/Library/Application Support/HomePlay/home.sock"
    static let backoff: [Double] = [1, 2, 5, 10, 30]

    private let lock = NSLock()
    private var fd: Int32 = -1
    private var running = false
    private var pending: [(Bool, String?) -> Void] = []   // 依序對應回應；鎖保護
    private var lastLaunch = Date.distantPast

    func start() {
        lock.lock(); defer { lock.unlock() }
        guard !running else { return }
        running = true
        Thread.detachNewThread { [self] in loop() }
    }

    func stop() {
        lock.lock(); running = false; let f = fd; lock.unlock()
        if f >= 0 { shutdown(f, SHUT_RDWR) }
    }

    func set(characteristic: String, value: Any, completion: ((Bool, String?) -> Void)? = nil) {
        send(["op": "set", "characteristic": characteristic, "value": value], completion)
    }

    func runScene(id: String, completion: ((Bool, String?) -> Void)? = nil) {
        send(["op": "scene", "id": id], completion)
    }

    // MARK: 連線迴圈（背景執行緒）

    private func loop() {
        var attempt = 0
        while isRunning {
            if let f = connectSocket() {
                attempt = 0
                lock.lock(); fd = f; lock.unlock()
                writeLine(f, ["op": "subscribe"])
                lock.lock(); pending.append({ _, _ in }); lock.unlock()   // subscribe 的回應
                readLines(f)
                lock.lock(); fd = -1; let waiting = pending; pending = []; lock.unlock()
                close(f)
                for w in waiting { w(false, "disconnected") }
                DispatchQueue.main.async { self.setConnected(false) }
            } else {
                launchHelperIfNeeded()
            }
            let wait = Self.backoff[min(attempt, Self.backoff.count - 1)]
            attempt += 1
            var slept = 0.0
            while slept < wait && isRunning { Thread.sleep(forTimeInterval: 0.25); slept += 0.25 }
        }
    }

    private var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return running }

    private func connectSocket() -> Int32? {
        let f = socket(AF_UNIX, SOCK_STREAM, 0)
        guard f >= 0 else { return nil }
        var one: Int32 = 1
        setsockopt(f, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(Self.socketPath.utf8CString)
        guard bytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else { close(f); return nil }
        withUnsafeMutablePointer(to: &addr.sun_path) {
            $0.withMemoryRebound(to: CChar.self, capacity: bytes.count) { p in for (i, b) in bytes.enumerated() { p[i] = b } }
        }
        let r = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(f, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        if r != 0 { close(f); return nil }
        return f
    }

    /// socket 不在或連不上：拉起幫手（20 秒內不重複拉）。
    private func launchHelperIfNeeded() {
        guard Date().timeIntervalSince(lastLaunch) > 20 else { return }
        let fm = FileManager.default
        let dirs = [NSHomeDirectory() + "/Applications", "/Applications"]
        guard let path = dirs.map({ $0 + "/HomePlay Home.app" }).first(where: { fm.fileExists(atPath: $0) }) else { return }
        lastLaunch = Date()
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = false
        cfg.addsToRecentItems = false
        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: path), configuration: cfg) { _, _ in }
    }

    private func readLines(_ f: Int32) {
        var buf = Data()
        var chunk = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = read(f, &chunk, chunk.count)
            if n <= 0 { if n < 0 && errno == EINTR { continue }; return }
            buf.append(chunk, count: n)
            while let nl = buf.firstIndex(of: 0x0A) {
                let line = buf.subdata(in: buf.startIndex..<nl)
                buf.removeSubrange(buf.startIndex...nl)
                if !line.isEmpty { handle(line) }
            }
        }
    }

    private struct Envelope: Decodable {
        var ok: Bool?
        var error: String?
        var event: String?
        var snapshot: HomeSnapshot?
        var accessory: String?
        var characteristic: String?
        var type: String?
        var value: HomeValue?
    }

    private func handle(_ line: Data) {
        guard let e = try? JSONDecoder().decode(Envelope.self, from: line) else { return }
        if let ev = e.event {
            if ev == "snapshot", let s = e.snapshot {
                DispatchQueue.main.async { self.apply(s) }
            } else if ev == "changed", let a = e.accessory, let c = e.characteristic, let t = e.type {
                let ch = HomeChange(accessory: a, characteristic: c, type: t, value: e.value)
                DispatchQueue.main.async { self.apply(ch) }
            }
            return
        }
        if let ok = e.ok {
            if ok, let s = e.snapshot { DispatchQueue.main.async { self.apply(s) } }
            lock.lock(); let cb = pending.isEmpty ? nil : pending.removeFirst(); lock.unlock()
            cb?(ok, e.error)
        }
    }

    // MARK: 主執行緒

    private func setConnected(_ c: Bool) {
        guard connected != c else { return }
        connected = c
        onConnection?(c)
        NotificationCenter.default.post(name: .homeLinkConnection, object: c)
    }

    private func apply(_ s: HomeSnapshot) {
        setConnected(true)
        snapshot = s
        onSnapshot?(s)
        NotificationCenter.default.post(name: .homeLinkSnapshot, object: s)
    }

    private func apply(_ ch: HomeChange) {
        for ai in snapshot.accessories.indices where snapshot.accessories[ai].id == ch.accessory {
            for ci in snapshot.accessories[ai].characteristics.indices where snapshot.accessories[ai].characteristics[ci].id == ch.characteristic {
                snapshot.accessories[ai].characteristics[ci].value = ch.value
            }
        }
        onChanged?(ch)
        NotificationCenter.default.post(name: .homeLinkChanged, object: ch)
    }

    // MARK: 送出

    private func send(_ obj: [String: Any], _ completion: ((Bool, String?) -> Void)?) {
        lock.lock(); let f = fd; lock.unlock()
        guard f >= 0 else { completion?(false, "not connected"); return }
        lock.lock()
        pending.append({ ok, err in
            guard let completion else { return }
            DispatchQueue.main.async { completion(ok, err) }
        })
        lock.unlock()
        writeLine(f, obj)
    }

    private func writeLine(_ f: Int32, _ obj: [String: Any]) {
        guard var d = try? JSONSerialization.data(withJSONObject: obj) else { return }
        d.append(0x0A)
        lock.lock(); defer { lock.unlock() }   // 寫入序列化，免得兩行交錯
        d.withUnsafeBytes { p in
            var off = 0
            while off < p.count {
                let n = write(f, p.baseAddress! + off, p.count - off)
                if n > 0 { off += n } else if n < 0 && errno == EINTR { continue } else { return }
            }
        }
    }
}

/// `homeplay-pet --home-dump`：連上幫手、印出摘要就結束。
func runHomeDump() -> Never {
    let link = HomeLink.shared
    link.start()
    let deadline = Date().addingTimeInterval(45)
    var settle: Date?
    while Date() < deadline {
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        let s = link.snapshot
        if s.ready && !s.homes.isEmpty {
            settle = settle ?? Date().addingTimeInterval(1.5)   // 等第一輪 readValue 回來
            if Date() >= settle! { break }
        }
    }
    let s = link.snapshot
    guard link.connected else { print("home-dump: 連不上 HomePlay Home 幫手"); exit(1) }
    guard let home = s.homes.first(where: \.primary) ?? s.homes.first else { print("home-dump: 幫手已連上，但沒有家庭資料（ready=\(s.ready)）"); exit(1) }
    print("home: \(home.name)  accessories: \(s.accessories.count)  rooms: \(s.rooms.count)  scenes: \(s.scenes.count)")
    func fmt(_ c: HomeCharacteristic?) -> String? {
        guard let c, let v = c.value else { return nil }
        if let b = v.bool { return b ? "on" : "off" }
        if let n = v.number { return c.type.hasSuffix("Temp") ? String(format: "%.1f°", n) : String(format: "%g", n) }
        return v.string
    }
    for a in s.accessories.prefix(10) {
        var bits: [String] = []
        if let p = fmt(a.characteristic("power")) { bits.append("power=\(p)") }
        if let t = fmt(a.characteristic("currentTemp")) { bits.append("temp=\(t)") }
        print("  - \(a.name) [\(a.categoryName ?? a.category)]\(a.reachable ? "" : " (unreachable)") \(bits.joined(separator: " "))")
    }
    exit(0)
}
