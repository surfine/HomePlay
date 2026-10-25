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

extension HomeValue {
    /// 寫進 JSON 用（布林優先，其次數字）
    var jsonAny: Any { if let bool { return bool }; return raw ?? 0 }
    init(number n: Double) { raw = n }
    init(bool b: Bool) { bool = b; raw = b ? 1 : 0 }
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
    var service: String? = nil      // 2.0 第六輪：所屬 HomeKit 服務的 id（多鍵開關要靠它分開；舊幫手沒有這欄）
    var serviceName: String? = nil  // 該服務的名稱
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
    var camera: Bool?           // 2.0：幫手標出有攝影機設定檔的配件（舊幫手沒有這欄）
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
    private var lastImage: Data?   // 最近一則回應帶的快照圖；鎖保護

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

    /// 2.0：要一張攝影機快照（JPEG 資料）。幫手端用 HMCameraSnapshotControl（未驗證，見 Helpers/HomeBridge/Src/HomeBridge.swift）
    func cameraSnapshot(id: String, completion: @escaping (Data?, String?) -> Void) {
        // 回呼在讀取執行緒上、緊接在 lastImage 設好之後被叫，所以這裡取到的一定是自己的那張
        sendRaw(["op": "cameraSnapshot", "id": id]) { [weak self] ok, err in
            guard let self else { DispatchQueue.main.async { completion(nil, "gone") }; return }
            self.lock.lock(); let img = self.lastImage; self.lastImage = nil; self.lock.unlock()
            let e = ok ? (img == nil ? "no image" : nil) : err
            DispatchQueue.main.async { completion(ok ? img : nil, e) }
        }
    }

    /// 2.0：寫入之後先把本機快照改成新值（幫手的 changed 事件隨後會校正）；只在主執行緒叫
    func applyLocal(characteristic id: String, value: HomeValue) {
        for ai in snapshot.accessories.indices {
            for ci in snapshot.accessories[ai].characteristics.indices where snapshot.accessories[ai].characteristics[ci].id == id {
                snapshot.accessories[ai].characteristics[ci].value = value
                NotificationCenter.default.post(name: .homeLinkChanged, object: HomeChange(accessory: snapshot.accessories[ai].id, characteristic: id, type: snapshot.accessories[ai].characteristics[ci].type, value: value))
            }
        }
    }

    /// 回應行裡的 image（base64 JPEG）解成資料；不是快照回應就 nil（純函式，selftest 用）
    static func decodeImage(line: Data) -> Data? {
        guard let e = try? JSONDecoder().decode(Envelope.self, from: line), e.ok == true, let b = e.image else { return nil }
        return Data(base64Encoded: b)
    }

    /// 2.0 第四輪：重讀一個特性（寫入成功後校正磚的狀態）。新幫手回 ok、新值走 changed 事件；
    /// 舊幫手不認得 read（unknownOp）就改要一份整個快照（快照回應會直接套用）
    func reread(characteristic id: String, completion: ((Bool) -> Void)? = nil) {
        sendRaw(["op": "read", "characteristic": id]) { [weak self] ok, err in
            if !ok, (err ?? "").contains("unknownOp") {
                self?.sendRaw(["op": "snapshot"]) { ok2, _ in DispatchQueue.main.async { completion?(ok2) } }
                return
            }
            DispatchQueue.main.async { completion?(ok) }
        }
    }
    /// 2.0 第四輪：本機快照裡某個特性目前的值（寫入失敗時還原用；主執行緒）
    func value(of id: String) -> HomeValue? {
        for a in snapshot.accessories { if let c = a.characteristics.first(where: { $0.id == id }) { return c.value } }
        return nil
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
        var image: String?
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
            lock.lock()
            lastImage = e.image.flatMap { Data(base64Encoded: $0) }   // 緊接著的 pending 回呼（cameraSnapshot）會取走
            let cb = pending.isEmpty ? nil : pending.removeFirst(); lock.unlock()
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
        sendRaw(obj) { ok, err in
            guard let completion else { return }
            DispatchQueue.main.async { completion(ok, err) }
        }
    }

    /// 回呼直接在讀取執行緒上叫（不回主執行緒）
    private func sendRaw(_ obj: [String: Any], _ cb: @escaping (Bool, String?) -> Void) {
        lock.lock(); let f = fd; lock.unlock()
        guard f >= 0 else { DispatchQueue.main.async { cb(false, "not connected") }; return }
        lock.lock()
        pending.append(cb)
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
    if CommandLine.arguments.contains("all") {   // --home-dump all：每個配件拆成幾塊磚、各叫什麼
        for a in s.accessories {
            let tiles = HomeAppModel.tiles(a)
            if tiles.count > 1 { print("  * \(a.name): \(tiles.count) 塊 → \(tiles.map(\.name).joined(separator: "、"))") }
        }
    }
    for a in s.accessories.prefix(10) {
        var bits: [String] = []
        if let p = fmt(a.characteristic("power")) { bits.append("power=\(p)") }
        if let t = fmt(a.characteristic("currentTemp")) { bits.append("temp=\(t)") }
        print("  - \(a.name) [\(a.categoryName ?? a.category)]\(a.reachable ? "" : " (unreachable)") \(bits.joined(separator: " "))")
    }
    exit(0)
}

/// `homeplay-pet --home-set <配件名> on|off`：真機驗證寫入——連上幫手、照名字找配件、寫 power、等回覆、重讀一次狀態印出來就結束。
func runHomeSet(name: String, on: Bool) -> Never {
    let link = HomeLink.shared
    link.start()
    func pump(_ s: Double) { let end = Date().addingTimeInterval(s); while Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) } }
    let deadline = Date().addingTimeInterval(45)
    while Date() < deadline, !(link.snapshot.ready && !link.snapshot.accessories.isEmpty) { pump(0.1) }
    pump(1.5)
    guard let a = link.snapshot.accessories.first(where: { $0.name == name }) else { print("home-set: 找不到配件「\(name)」"); exit(1) }
    guard let c = a.characteristic("power") else { print("home-set: 「\(name)」沒有開關"); exit(1) }
    print("home-set: \(name) power 目前 \(c.value?.bool.map { $0 ? "on" : "off" } ?? "?") → \(on ? "on" : "off")")
    var result: (Bool, String?)?
    link.set(characteristic: c.id, value: on) { ok, err in result = (ok, err) }
    let t0 = Date()
    while result == nil, Date().timeIntervalSince(t0) < 10 { pump(0.05) }
    let ms = Int(Date().timeIntervalSince(t0) * 1000)
    guard let (ok, err) = result else { print("home-set: 10 秒內沒有回覆"); exit(1) }
    pump(1.0)
    let now = link.snapshot.accessories.first { $0.id == a.id }?.characteristic("power")?.value?.bool
    print("home-set: 寫入 \(ok ? "成功" : "失敗") \(err ?? "")（\(ms) ms），重讀狀態 \(now.map { $0 ? "on" : "off" } ?? "?")")
    exit(ok ? 0 : 1)
}
