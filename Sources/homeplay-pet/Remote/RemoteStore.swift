// 2.0 閒置裝置·網頁串流：配過的裝置、一次性配對碼、開關。
//
// - 預設關著；設定 › iPhone 與 iPad 打開才開伺服器。
// - 每台裝置一把自己的 32 bytes 金鑰，存在 ~/Library/Application Support/HomePlay/remote-devices.json（權限 0600，只有這個使用者讀得到）。
//   移除裝置＝刪掉那把金鑰並踢掉它的連線，之後它要重新配對。
// - 配對碼只在記憶體裡：10 分鐘失效、用過一次就失效。打錯：同一個來源位址 3 次就不再讓它試（碼對別人照樣有效），
//   全部加起來 20 次才作廢——陌生人打錯幾次不能讓主人的碼立刻失效；80 bits 的碼，20 次猜中的機率可以忽略。
// - 交接碼（M1）：主人配好的裝置跟 Mac 要一張 60 秒、用一次的交接碼放進網址（#t=），「加入主畫面」後第一次打開拿它換回
//   這台裝置的金鑰；金鑰本身永遠不進網址、不進瀏覽紀錄。
// - 寫檔在同一把鎖裡「拍快照＋寫入」，撤銷之後不會被比它早拍的快照寫回來（M5）。
// - 每台裝置預設是「訪客」：個人內容（訊息、聯絡人、FaceTime、照片、行事曆、提醒）不傳過去（RemoteServer 的 guestSafe）。

import Foundation
import CryptoKit

struct RemoteDevice: Codable, Equatable {
    var id: String          // 16 個十六進位字
    var name: String
    var key: String         // base64
    var personal = false    // 顯示個人內容（主人自己的裝置）；預設訪客
    var created: Double
    var lastSeen: Double?
    var lastIP: String?     // 上次連線的來源位址（設定頁顯示；不同位址同時連線＝自動移除）
}

final class RemoteStore {
    static let shared = RemoteStore()

    static let enabledKey = "remote.enabled"
    static let portKey = "remote.port"
    static let defaultPort: UInt16 = 52424
    static let pairingLifetime: Double = 600
    static let maxPairingFailures = 20          // 全部來源加起來：到了就作廢
    static let maxPairingFailuresPerIP = 3      // 單一來源：到了就不再讓它試這個碼
    static let handoffLifetime: Double = 60

    static var enabled: Bool {
        get { UserDefaults.standard.bool(forKey: enabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }
    static var port: UInt16 {
        let p = UserDefaults.standard.integer(forKey: portKey)
        return p > 1024 && p < 65536 ? UInt16(p) : defaultPort
    }

    private let lock = NSLock()
    private let ioLock = NSLock()               // 寫檔：快照與寫入在同一把鎖裡，依序
    private var devices: [RemoteDevice] = []
    let file: URL
    /// 配對碼（記憶體）
    private var pairing: (secret: [UInt8], expires: Double, failures: Int, perIP: [String: Int])?
    /// 交接碼（記憶體）：查找用的 id → (密碼, 裝置, 失效時間)
    private var handoffs: [String: (secret: [UInt8], device: String, expires: Double)] = [:]
    /// 發碼順序（同一時刻發的幾張也分得出新舊）
    private var handoffSeq: [String: Int] = [:]
    private var handoffCounter = 0
    var now: () -> Double = { Date().timeIntervalSince1970 }

    init(file: URL? = nil) {
        if let file { self.file = file } else {
            let dir = ProcessInfo.processInfo.environment["HOMEPLAY_REMOTE_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
                ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("HomePlay")
            self.file = dir.appendingPathComponent("remote-devices.json")
        }
        if let d = try? Data(contentsOf: self.file), let list = try? JSONDecoder().decode([RemoteDevice].self, from: d) { devices = list }
    }

    // MARK: 裝置

    var all: [RemoteDevice] { lock.lock(); defer { lock.unlock() }; return devices }

    func device(_ id: String) -> RemoteDevice? { lock.lock(); defer { lock.unlock() }; return devices.first { $0.id == id } }

    func key(for id: String) -> SymmetricKey? {
        guard let d = device(id), let k = Data(base64Encoded: d.key), k.count == 32 else { return nil }
        return SymmetricKey(data: k)
    }

    @discardableResult
    func add(name: String) -> RemoteDevice {
        var idb = [UInt8](repeating: 0, count: 8), kb = [UInt8](repeating: 0, count: 32)
        for i in idb.indices { idb[i] = UInt8.random(in: 0...255) }
        for i in kb.indices { kb[i] = UInt8.random(in: 0...255) }
        let d = RemoteDevice(id: idb.map { String(format: "%02x", $0) }.joined(), name: Self.clean(name), key: Data(kb).base64EncodedString(), created: now())
        lock.lock(); devices.append(d); lock.unlock()
        save()
        return d
    }

    func revoke(_ id: String) {
        lock.lock(); devices.removeAll { $0.id == id }; lock.unlock()
        save()
    }

    func setPersonal(_ id: String, _ on: Bool) {
        lock.lock(); if let i = devices.firstIndex(where: { $0.id == id }) { devices[i].personal = on }; lock.unlock()
        save()
    }

    func touch(_ id: String, ip: String? = nil) {
        lock.lock()
        if let i = devices.firstIndex(where: { $0.id == id }) { devices[i].lastSeen = now(); if let ip { devices[i].lastIP = ip } }
        lock.unlock()
        save()
    }

    /// 裝置自己報的名字：只留可見字元、最多 40 字
    static func clean(_ s: String) -> String {
        let t = String(s.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }.prefix(40)).trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? "iPad" : t
    }

    /// 寫檔：先寫暫存檔、設 0600、再換上（不會留下別人讀得到的半截檔）
    private func save() {
        ioLock.lock(); defer { ioLock.unlock() }
        lock.lock(); let list = devices; lock.unlock()
        guard let data = try? JSONEncoder().encode(list) else { return }
        let fm = FileManager.default
        try? fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let tmp = file.deletingLastPathComponent().appendingPathComponent(".remote-devices.\(UUID().uuidString).tmp")
        guard fm.createFile(atPath: tmp.path, contents: nil, attributes: [.posixPermissions: 0o600]),
              let h = try? FileHandle(forWritingTo: tmp) else { return }
        h.write(data); try? h.close()
        if rename(tmp.path, file.path) != 0 { try? fm.removeItem(at: tmp) }
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    // MARK: 配對碼

    /// 產生新的配對碼（舊的同時失效）
    @discardableResult
    func newPairing() -> [UInt8] {
        let s = RemoteCrypto.newPairingSecret()
        lock.lock(); pairing = (s, now() + Self.pairingLifetime, 0, [:]); lock.unlock()
        return s
    }

    var pairingSecret: [UInt8]? {
        lock.lock(); defer { lock.unlock() }
        guard let p = pairing, now() < p.expires, p.failures < Self.maxPairingFailures else { return nil }
        return p.secret
    }

    /// 這個來源還能不能試配對碼（打錯 3 次的來源不能，碼對別人照樣有效）
    func pairingSecret(for ip: String) -> [UInt8]? {
        lock.lock(); let tries = pairing?.perIP[ip] ?? 0; lock.unlock()
        return tries < Self.maxPairingFailuresPerIP ? pairingSecret : nil
    }

    var pairingExpires: Double? { lock.lock(); defer { lock.unlock() }; return pairing?.expires }

    func pairingFailed(ip: String = "") {
        lock.lock(); defer { lock.unlock() }
        guard var p = pairing else { return }
        p.failures += 1
        p.perIP[ip, default: 0] += 1
        pairing = p.failures >= Self.maxPairingFailures ? nil : p
    }

    /// 配對成功：碼立刻作廢（一次性）
    func pairingUsed() { lock.lock(); pairing = nil; lock.unlock() }

    func cancelPairing() { lock.lock(); pairing = nil; lock.unlock() }

    // MARK: 交接碼（M1）

    /// 發給已驗證的裝置：8 bytes 查找 id＋16 bytes 密碼，base32。同一台只留最近兩張（頁面每 45 秒換一張，
    /// 使用者打開分享選單時拿到的那張還有完整的 60 秒）
    func newHandoff(for device: String) -> String? {
        guard self.device(device) != nil else { return nil }
        var b = [UInt8](repeating: 0, count: 24)
        for i in b.indices { b[i] = UInt8.random(in: 0...255) }
        let tid = b[0..<8].map { String(format: "%02x", $0) }.joined()
        lock.lock()
        let t = now()
        handoffs = handoffs.filter { $0.value.expires > t }
        let mine = handoffs.filter { $0.value.device == device }.sorted { (handoffSeq[$0.key] ?? 0) > (handoffSeq[$1.key] ?? 0) }
        for old in mine.dropFirst(1) { handoffs[old.key] = nil }   // 加上這張新的＝最多兩張
        if handoffs.count < 64 { handoffs[tid] = (Array(b[8..<24]), device, t + Self.handoffLifetime); handoffCounter += 1; handoffSeq[tid] = handoffCounter }
        handoffSeq = handoffSeq.filter { handoffs[$0.key] != nil }
        let ok = handoffs[tid] != nil
        lock.unlock()
        return ok ? RemoteCrypto.encode(b) : nil
    }

    /// 握手時查交接碼：查到就同時拿走（用一次，不管後面成不成功）
    func takeHandoff(_ tid: String) -> (secret: [UInt8], device: String)? {
        lock.lock(); defer { lock.unlock() }
        guard let h = handoffs.removeValue(forKey: tid), now() < h.expires, devices.contains(where: { $0.id == h.device }) else { return nil }
        return (h.secret, h.device)
    }
}
