// 2.0 閒置裝置（鏡像整個畫面＋副屏）：一份名冊、一套配對碼、一種身分。
//
// 這是 Windows SideShow 的「一個平台、多個 endpoint」在 HomePlay 的等價物（考據見 docs/plans/sideshow.md）：
// 裝置是同一台、名冊是同一份、配對碼只有一種，差別只在「這台收哪種內容」——
// mirror（整頁畫面，Mac 要醒著）與 side（白名單內容，快取在裝置上，Mac 睡了照看）。
//
// 身分：裝置自己產金鑰對，Mac 只存公鑰（Remote/RemoteIdentity.swift）。所以名冊檔裡沒有任何祕密，
// 被讀走也冒充不了裝置；移除裝置＝刪掉公鑰，它下次簽章就驗不過。
//
// 配對碼：40 bits（5 bytes）、10 分鐘失效、用一次就失效；同一個來源打錯 3 次就不再讓它試，
// 全部加起來 20 次才作廢——陌生人打錯幾次不能讓主人的碼立刻失效。
//
// 舊版（beta 7 以前）留了兩份名冊（remote 的長期金鑰、sideshow 的雜湊）。金鑰式握手已移除，
// 那些裝置無法再證明身分，所以第一次啟動把它們搬到 *.legacy.json 保留證據，然後從空名冊開始。

import Foundation

struct RemoteDevice: Codable, Equatable {
    var id: String          // 16 個十六進位字
    var name: String
    var agree: String       // base64，P-256 ECDH 公鑰（raw 65 bytes）
    var sign: String        // base64，P-256 ECDSA 公鑰（raw 65 bytes）
    var mirror = true       // 收整頁畫面
    var side = false        // 當副屏
    var personal = false    // 顯示個人內容（主人自己的裝置）
    var created: Double = 0
    var lastSeen: Double?
    var lastIP: String?     // 上次連線的來源位址（設定頁顯示；不同位址同時連線＝自動移除）

    /// 這台收哪幾種內容；兩個都關＝留著配對但什麼都不給
    enum Cap: String, CaseIterable { case mirror, side }
    var caps: Set<Cap> {
        var s: Set<Cap> = []
        if mirror { s.insert(.mirror) }
        if side { s.insert(.side) }
        return s
    }
}

final class RemoteStore {
    static let shared = RemoteStore()

    static let enabledKey = "remote.enabled"
    static let portKey = "remote.port"
    static let defaultPort: UInt16 = 52424
    static let pairingLifetime: Double = 600
    static let maxPairingFailures = 20          // 全部來源加起來：到了就作廢
    static let maxPairingFailuresPerIP = 3      // 單一來源：到了就不再讓它試這個碼
    static let maxDevices = 12

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
    var now: () -> Double = { Date().timeIntervalSince1970 }

    init(file: URL? = nil) {
        self.file = file ?? Self.defaultFile
        if let d = try? Data(contentsOf: self.file), let list = try? JSONDecoder().decode([RemoteDevice].self, from: d) { devices = list }
    }

    static var defaultFile: URL {
        let dir = ProcessInfo.processInfo.environment["HOMEPLAY_REMOTE_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("HomePlay")
        return dir.appendingPathComponent("remote-devices.json")
    }

    /// 舊版的副屏名冊（雜湊式身分）。只為了搬家與自檢，不再有人寫它。
    static var legacySideFile: URL {
        let dir = ProcessInfo.processInfo.environment["HOMEPLAY_SIDESHOW_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) } ?? HomePlayState.directory
        return dir.appendingPathComponent("sideshow-devices.json")
    }

    // MARK: 裝置

    var all: [RemoteDevice] { lock.lock(); defer { lock.unlock() }; return devices }

    func device(_ id: String) -> RemoteDevice? { lock.lock(); defer { lock.unlock() }; return devices.first { $0.id == id } }

    /// 驗簽用的兩把公鑰（base64 → raw）；格式不對回 nil
    func keys(for id: String) -> (agree: Data, sign: Data)? {
        guard let d = device(id), let a = Data(base64Encoded: d.agree), let s = Data(base64Encoded: d.sign),
              a.count == 65, s.count == 65 else { return nil }
        return (a, s)
    }

    /// 裝置自己報的名字：只留可見字元、最多 40 字
    static func clean(_ s: String) -> String {
        let t = String(s.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }.prefix(40)).trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? "iPad" : t
    }

    /// 加一台（公鑰驗不過就不加，避免名冊裡出現永遠驗不過的裝置）
    @discardableResult
    func add(name: String, agree: Data, sign: Data, mirror: Bool = true, side: Bool = false, personal: Bool = false) -> RemoteDevice? {
        guard RemoteIdentity.agreeKey(agree) != nil, RemoteIdentity.signKey(sign) != nil, devices.count < Self.maxDevices else { return nil }
        var idb = [UInt8](repeating: 0, count: 8)
        for i in idb.indices { idb[i] = UInt8.random(in: 0...255) }
        let d = RemoteDevice(id: idb.map { String(format: "%02x", $0) }.joined(), name: Self.clean(name),
                             agree: agree.base64EncodedString(), sign: sign.base64EncodedString(),
                             mirror: mirror, side: side, personal: personal, created: now())
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

    func setMirror(_ id: String, _ on: Bool) {
        lock.lock(); if let i = devices.firstIndex(where: { $0.id == id }) { devices[i].mirror = on }; lock.unlock()
        save()
    }

    func setSide(_ id: String, _ on: Bool) {
        lock.lock(); if let i = devices.firstIndex(where: { $0.id == id }) { devices[i].side = on }; lock.unlock()
        save()
    }

    func touch(_ id: String, ip: String? = nil) {
        lock.lock()
        if let i = devices.firstIndex(where: { $0.id == id }) { devices[i].lastSeen = now(); if let ip { devices[i].lastIP = ip } }
        lock.unlock()
        save()
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

    // MARK: 舊名冊搬家

    /// 舊版的兩份名冊在新身分模型下用不了：搬到 <檔名>.legacy.json（不刪，留著對帳），回傳各幾台。
    /// 已經搬過就不再動（目標檔存在就跳過）。
    @discardableResult
    static func archiveLegacy(remote: URL? = nil, side: URL? = nil) -> (remote: Int, side: Int) {
        let fm = FileManager.default
        func move(_ from: URL) -> Int {
            guard fm.fileExists(atPath: from.path) else { return 0 }
            let n = (try? Data(contentsOf: from)).flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [Any]
            let dest = from.deletingPathExtension().appendingPathExtension("legacy.json")
            if fm.fileExists(atPath: dest.path) { try? fm.removeItem(at: dest) }
            try? fm.moveItem(at: from, to: dest)
            return n?.count ?? 1
        }
        return (move(remote ?? defaultFile), move(side ?? legacySideFile))
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

    enum PairResult: Equatable { case ok(id: String), badCode, blocked, full }

    /// 裝置拿配對碼＋自己的公鑰換一個身分。成功只回 id——沒有任何祕密要傳。
    func redeem(code: String, ip: String, name: String, agree: Data, sign: Data, mirror: Bool, side: Bool) -> PairResult {
        lock.lock()
        guard var p = pairing, now() < p.expires else { lock.unlock(); return .badCode }
        if p.perIP[ip, default: 0] >= Self.maxPairingFailuresPerIP { lock.unlock(); return .blocked }
        guard let given = RemoteCrypto.decode(code), RemoteCrypto.equal(given, p.secret) else {
            p.failures += 1; p.perIP[ip, default: 0] += 1
            pairing = p.failures >= Self.maxPairingFailures ? nil : p
            lock.unlock(); return .badCode
        }
        guard devices.count < Self.maxDevices else { lock.unlock(); return .full }
        lock.unlock()
        guard let d = add(name: name, agree: agree, sign: sign, mirror: mirror, side: side, personal: true) else { return .badCode }
        lock.lock(); pairing = nil; lock.unlock()
        return .ok(id: d.id)
    }
}
