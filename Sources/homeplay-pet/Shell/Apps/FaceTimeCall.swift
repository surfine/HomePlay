// 2.0 第四輪 #10：FaceTime 通話——撥號前後由我們畫，通話本體交給「FaceTime」App（macOS 沒有公開的通話 API）。
//
// 流程：選人 → 撥出畫面（名字、鏡頭預覽、玻璃控制）→ 使用者按綠色撥號鈕（ClioTalk 不替你發聲：一律要你自己按；
// 從 ClioTalk 來的已經念過、你說了「好」，就直接撥）→ 開 facetime:// 或 facetime-audio://、把 FaceTime 帶到前面 →
// 通話中頂端膠囊是綠色的通話 Live Activity → 按紅色 ✕ 結束我們這邊的通話狀態，照影片的掛斷轉場回錶面。
//
// 通話偵測（看得到多少做多少）：FaceTime 有沒有在跑（NSWorkspace）＋「別的行程正在用麥克風」（Core Audio 的行程物件
// kAudioProcessPropertyIsRunningInput，macOS 14 起；不含我們自己）。撥出後看到麥克風被用＝接通；接通後麥克風停了 4 秒以上、
// 或 FaceTime 關了＝對方掛斷或你在 FaceTime 掛了。偵測不到（例如 FaceTime 沒用麥克風）就一直維持「通話中」，直到你按 ✕。
// 我們不讀 FaceTime 的視窗標題（要螢幕錄製權限），也不讀通話紀錄（受保護的資料庫）。
//
// 麥克風靜音鈕是真的：把系統預設輸入裝置設成靜音（kAudioDevicePropertyMute，輸入端），FaceTime 那邊也就聽不到；
// 通話結束、App 結束、下次開機都會還原（改過就記在偏好裡）。裝置不支援靜音就把鈕灰掉。

import AppKit
import AVFoundation
import Contacts
import CoreAudio

/// 通話對象（從通訊錄挑好的人與號碼）
struct FaceTimeContact: Equatable {
    var id: String          // CNContact.identifier（示範資料自己編）
    var name: String
    var handle: String      // 電話或信箱
    var label: String       // 「手機」「住家」「iCloud」…（顯示用）
    var photo: Data?
    static func == (a: Self, b: Self) -> Bool { a.id == b.id && a.handle == b.handle }
}

final class FaceTimeCall {
    static let shared = FaceTimeCall()
    enum Phase: Equatable { case idle, preDial, calling, connected }
    private(set) var phase: Phase = .idle
    private(set) var contact: FaceTimeContact?
    var video = true
    private(set) var startedAt = 0.0           // 撥出的牆上時間（timeIntervalSince1970）
    private(set) var connectedAt: Double?
    private var micSilentSince: Double?
    private var timer: Timer?
    /// 快照用：凍住狀態與經過時間（--demo-facetime）
    var demoElapsed: Double?
    /// 狀態變了（主執行緒）：外殼重畫
    var onChange: (() -> Void)?

    static let bundle = "com.apple.FaceTime"
    static var wall: Double { Date().timeIntervalSince1970 }

    // MARK: 流程

    /// 進撥出畫面（還沒撥）
    func prepare(_ c: FaceTimeContact, video: Bool) {
        guard phase == .idle || phase == .preDial else { return }
        contact = c; self.video = video; phase = .preDial
        onChange?()
    }

    /// 真的撥：只在使用者自己按了撥號鈕、或 ClioTalk 已經念過且使用者說了「好」之後才叫
    @discardableResult
    func dial(confirmedByUser: Bool) -> Bool {
        guard confirmedByUser, let c = contact, phase == .preDial else { return false }
        guard let url = ClioCallTools.url(handle: c.handle, video: video) else { return false }
        if demoElapsed == nil {
            guard NSWorkspace.shared.open(url) else { return false }
            FaceTimeRecents.add(c, video: video)
            // 交給 FaceTime：把它的視窗帶到前面（開網址有時不會自己跳到前面）
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { Self.bringFaceTimeForward() }
        }
        phase = .calling; startedAt = Self.wall; connectedAt = nil; micSilentSince = nil
        if FaceTimeMic.pendingMute { FaceTimeMic.setMuted(true) }
        startMonitor()
        onChange?()
        return true
    }

    /// 我們這邊結束（紅色 ✕、取消撥出畫面、偵測到掛斷）
    func end() {
        timer?.invalidate(); timer = nil
        if FaceTimeMic.mutedByUs { FaceTimeMic.setMuted(false) }
        FaceTimeMic.pendingMute = false
        phase = .idle; contact = nil; connectedAt = nil; demoElapsed = nil
        onChange?()
    }

    static func bringFaceTimeForward() {
        NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == bundle }?.activate()
    }

    /// 通話中經過幾秒（接通後從接通算；還沒接通從撥出算）
    var elapsed: Double {
        if let d = demoElapsed { return d }
        return max(0, Self.wall - (connectedAt ?? startedAt))
    }
    var active: Bool { phase == .calling || phase == .connected }

    // MARK: 偵測

    private func startMonitor() {
        timer?.invalidate()
        guard demoElapsed == nil else { return }
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.poll() }
        t.tolerance = 0.3
        RunLoop.main.add(t, forMode: .common); timer = t
    }

    private func poll() {
        let now = Self.wall
        let running = NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == Self.bundle }
        let mic = FaceTimeMic.othersUsingInput()
        let next = Self.step(phase: phase, faceTimeRunning: running, micInUse: mic, now: now, startedAt: startedAt,
                             connectedAt: connectedAt, micSilentSince: &micSilentSince)
        if next.phase == .idle { end(); return }
        if next.phase != phase || next.connectedAt != connectedAt { phase = next.phase; connectedAt = next.connectedAt; onChange?() }
        else { onChange?() }   // 每秒更新膠囊上的時間
    }

    /// 偵測的狀態機（純函式，自檢用）
    static func step(phase: Phase, faceTimeRunning: Bool, micInUse: Bool?, now: Double, startedAt: Double, connectedAt: Double?,
                     micSilentSince: inout Double?) -> (phase: Phase, connectedAt: Double?) {
        guard phase == .calling || phase == .connected else { return (phase, connectedAt) }
        // FaceTime 開過之後又關了：通話一定結束（撥出後給它 8 秒啟動）
        if !faceTimeRunning, now - startedAt > 8 { return (.idle, nil) }
        guard let mic = micInUse else { return (phase, connectedAt) }   // 讀不到麥克風狀態：維持手動
        if phase == .calling {
            if mic { return (.connected, now) }
            // 2.0 depth：在 FaceTime 自己的「通話」提示上按了取消（FaceTime 還開著）：響 60 秒沒接通就當作沒人接（iOS 也是一分鐘左右）
            return now - startedAt > 60 ? (.idle, nil) : (.calling, nil)
        }
        if mic { micSilentSince = nil; return (.connected, connectedAt) }
        if micSilentSince == nil { micSilentSince = now }
        return now - (micSilentSince ?? now) >= 4 ? (.idle, nil) : (.connected, connectedAt)
    }
}

// MARK: - 麥克風（Core Audio）

enum FaceTimeMic {
    private static let restoreKey = "HomePlayFaceTimeMutedDevice"
    /// 撥出前就按了靜音：撥出時套用
    nonisolated(unsafe) static var pendingMute = false
    static var mutedByUs: Bool { UserDefaults.standard.object(forKey: restoreKey) != nil }

    private static func defaultInput() -> AudioObjectID? {
        var dev = AudioObjectID(0), size = UInt32(MemoryLayout<AudioObjectID>.size)
        var a = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &dev) == noErr, dev != 0 else { return nil }
        return dev
    }
    private static func muteAddress() -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute, mScope: kAudioDevicePropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
    }

    /// 預設輸入裝置能不能靜音
    static var canMute: Bool {
        guard let dev = defaultInput() else { return false }
        var a = muteAddress(); var settable: DarwinBoolean = false
        return AudioObjectHasProperty(dev, &a) && AudioObjectIsPropertySettable(dev, &a, &settable) == noErr && settable.boolValue
    }
    static var isMuted: Bool {
        guard let dev = defaultInput() else { return false }
        var a = muteAddress(); var v: UInt32 = 0, size = UInt32(4)
        return AudioObjectGetPropertyData(dev, &a, 0, nil, &size, &v) == noErr && v != 0
    }
    /// 靜音／取消；我們設的才記下來（之後要還原），使用者原本就靜音的不碰
    static func setMuted(_ on: Bool) {
        guard let dev = defaultInput() else { return }
        if on, isMuted, !mutedByUs { return }
        var a = muteAddress(); var v: UInt32 = on ? 1 : 0
        guard AudioObjectSetPropertyData(dev, &a, 0, nil, UInt32(4), &v) == noErr else { return }
        if on { UserDefaults.standard.set(Int(dev), forKey: restoreKey) } else { UserDefaults.standard.removeObject(forKey: restoreKey) }
    }
    /// 開機時叫：上次是我們靜音的（例如當掉）就還原
    static func restoreIfNeeded() {
        guard let d = UserDefaults.standard.object(forKey: restoreKey) as? Int else { return }
        var a = muteAddress(); var v: UInt32 = 0
        _ = AudioObjectSetPropertyData(AudioObjectID(d), &a, 0, nil, UInt32(4), &v)
        UserDefaults.standard.removeObject(forKey: restoreKey)
    }

    /// 除了我們之外，有沒有行程正在用麥克風；讀不到（舊系統、Core Audio 出錯）回 nil
    static func othersUsingInput() -> Bool? {
        var a = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        let sys = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(sys, &a, 0, nil, &size) == noErr, size > 0 else { return nil }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(sys, &a, 0, nil, &size, &ids) == noErr else { return nil }
        let me = ProcessInfo.processInfo.processIdentifier
        for id in ids {
            var pa = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyPID, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var pid: pid_t = 0, ps = UInt32(MemoryLayout<pid_t>.size)
            guard AudioObjectGetPropertyData(id, &pa, 0, nil, &ps, &pid) == noErr, pid != me else { continue }
            var ra = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyIsRunningInput, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var run: UInt32 = 0, rs = UInt32(4)
            if AudioObjectGetPropertyData(id, &ra, 0, nil, &rs, &run) == noErr, run != 0 { return true }
        }
        return false
    }
}

// MARK: - 鏡頭預覽（只在已經授權時開；不錄、不存）

final class FaceTimeCamera: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    static let shared = FaceTimeCamera()
    private var session: AVCaptureSession?
    private let queue = DispatchQueue(label: "homeplay.facetime.camera", qos: .userInitiated)
    private let lock = NSLock()
    private var frame: CGImage?
    private var lastFrameAt = 0.0
    var onFrame: (() -> Void)?

    static var authorized: Bool { AVCaptureDevice.authorizationStatus(for: .video) == .authorized }

    var latest: CGImage? { lock.lock(); defer { lock.unlock() }; return frame }

    /// 已授權才開（絕不在這裡要權限：要權限走設定裡的「權限」）
    func start() {
        guard Self.authorized, session == nil, let dev = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: dev) else { return }
        let s = AVCaptureSession()
        s.sessionPreset = .medium
        guard s.canAddInput(input) else { return }
        s.addInput(input)
        let out = AVCaptureVideoDataOutput()
        out.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        out.alwaysDiscardsLateVideoFrames = true
        out.setSampleBufferDelegate(self, queue: queue)
        guard s.canAddOutput(out) else { return }
        s.addOutput(out)
        session = s
        queue.async { s.startRunning() }
    }

    func stop() {
        guard let s = session else { return }
        session = nil
        queue.async { s.stopRunning() }
        lock.lock(); frame = nil; lock.unlock()
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sb: CMSampleBuffer, from connection: AVCaptureConnection) {
        let t = CACurrentMediaTime()
        guard t - lastFrameAt > 1.0 / 15, let pb = CMSampleBufferGetImageBuffer(sb) else { return }   // 15 fps 就夠
        lastFrameAt = t
        let ci = CIImage(cvPixelBuffer: pb).oriented(.upMirrored)   // 自拍畫面照鏡子
        guard let cg = Face.ciContext.createCGImage(ci, from: ci.extent) else { return }
        lock.lock(); frame = cg; lock.unlock()
        DispatchQueue.main.async { self.onFrame?() }
    }
}

// MARK: - 最近通話（只記從 HomePlay 撥出去的；FaceTime 自己的通話紀錄是受保護的資料庫，不讀）

enum FaceTimeRecents {
    private static let key = "HomePlayFaceTimeRecents"
    struct Entry: Codable, Equatable { var id: String; var name: String; var handle: String; var label: String; var video: Bool; var at: Double }
    static func all() -> [Entry] {
        guard let d = UserDefaults.standard.data(forKey: key), let e = try? JSONDecoder().decode([Entry].self, from: d) else { return [] }
        return e
    }
    static func add(_ c: FaceTimeContact, video: Bool) {
        var e = all().filter { !($0.id == c.id && $0.handle == c.handle) }
        e.insert(Entry(id: c.id, name: c.name, handle: c.handle, label: c.label, video: video, at: FaceTimeCall.wall), at: 0)
        if let d = try? JSONEncoder().encode(Array(e.prefix(12))) { UserDefaults.standard.set(d, forKey: key) }
    }
}

// MARK: - 通訊錄（有電話或信箱的人）

enum FaceTimeContacts {
    static var status: CNAuthorizationStatus { CNContactStore.authorizationStatus(for: .contacts) }
    static var canAsk: Bool { Bundle.main.object(forInfoDictionaryKey: "NSContactsUsageDescription") != nil }

    /// 整本列出來（背景執行緒叫）：一個人一列，號碼挑 ClioCallTools.bestHandle
    static func load() -> [FaceTimeContact] {
        guard status == .authorized else { return [] }
        let keys: [CNKeyDescriptor] = [CNContactGivenNameKey, CNContactFamilyNameKey, CNContactNicknameKey, CNContactOrganizationNameKey,
                                       CNContactPhoneNumbersKey, CNContactEmailAddressesKey, CNContactThumbnailImageDataKey] as [CNKeyDescriptor]
        var out: [FaceTimeContact] = []
        let req = CNContactFetchRequest(keysToFetch: keys)
        req.sortOrder = .userDefault
        try? CNContactStore().enumerateContacts(with: req) { c, _ in
            let phones = c.phoneNumbers.map { (label: $0.label, value: $0.value.stringValue) }
            let emails = c.emailAddresses.map { $0.value as String }
            guard let h = ClioCallTools.bestHandle(phones: phones, emails: emails) else { return }
            let name = ClioCallTools.displayName(c)
            guard !name.isEmpty else { return }
            let raw = c.phoneNumbers.first { $0.value.stringValue == h }?.label ?? c.emailAddresses.first { ($0.value as String) == h }?.label
            let label = raw.map { CNLabeledValue<NSString>.localizedString(forLabel: $0) } ?? ""
            out.append(FaceTimeContact(id: c.identifier, name: name, handle: h, label: label, photo: c.thumbnailImageData))
        }
        return out
    }

    /// 縮寫（頭像沒有照片時）：中文取最後一個字（名），英文取名與姓的首字母
    static func initials(_ name: String) -> String {
        let t = name.trimmingCharacters(in: .whitespaces)
        if t.unicodeScalars.contains(where: { $0.value >= 0x2E80 }) { return t.last.map(String.init) ?? "" }
        let parts = t.split(separator: " ")
        return parts.prefix(2).compactMap { $0.first.map { String($0).uppercased() } }.joined()
    }

    /// 搜尋：名字含關鍵字（不分大小寫、繁簡都比），或號碼含數字
    static func filter(_ list: [FaceTimeContact], _ q: String) -> [FaceTimeContact] {
        let k = q.trimmingCharacters(in: .whitespaces).lowercased()
        guard !k.isEmpty else { return list }
        let simp = k.applyingTransform(StringTransform("Hant-Hans"), reverse: false) ?? k
        let digits = k.filter(\.isNumber)
        return list.filter { c in
            let n = c.name.lowercased(), ns = n.applyingTransform(StringTransform("Hant-Hans"), reverse: false) ?? n
            return n.contains(k) || ns.contains(simp) || (digits.count >= 3 && c.handle.filter(\.isNumber).contains(digits))
        }
    }
}

enum FaceTimeSelfTest {
    static func run(_ check: (Bool, String) -> Void) {
        var silent: Double? = nil
        var r = FaceTimeCall.step(phase: .calling, faceTimeRunning: true, micInUse: false, now: 100, startedAt: 95, connectedAt: nil, micSilentSince: &silent)
        check(r.phase == .calling, "FaceTime：撥出後還沒有人用麥克風＝還在撥")
        r = FaceTimeCall.step(phase: .calling, faceTimeRunning: true, micInUse: true, now: 101, startedAt: 95, connectedAt: nil, micSilentSince: &silent)
        check(r.phase == .connected && r.connectedAt == 101, "FaceTime：別的行程開始用麥克風＝接通")
        r = FaceTimeCall.step(phase: .connected, faceTimeRunning: true, micInUse: false, now: 110, startedAt: 95, connectedAt: 101, micSilentSince: &silent)
        check(r.phase == .connected && silent == 110, "FaceTime：麥克風剛停不算掛斷")
        r = FaceTimeCall.step(phase: .connected, faceTimeRunning: true, micInUse: false, now: 114.5, startedAt: 95, connectedAt: 101, micSilentSince: &silent)
        check(r.phase == .idle, "FaceTime：接通後麥克風停 4 秒＝掛斷")
        silent = nil
        r = FaceTimeCall.step(phase: .connected, faceTimeRunning: true, micInUse: nil, now: 300, startedAt: 95, connectedAt: 101, micSilentSince: &silent)
        check(r.phase == .connected, "FaceTime：讀不到麥克風就維持手動狀態")
        r = FaceTimeCall.step(phase: .calling, faceTimeRunning: false, micInUse: nil, now: 100, startedAt: 95, connectedAt: nil, micSilentSince: &silent)
        check(r.phase == .calling, "FaceTime：剛撥出、FaceTime 還在啟動不算結束")
        r = FaceTimeCall.step(phase: .connected, faceTimeRunning: false, micInUse: true, now: 200, startedAt: 95, connectedAt: 101, micSilentSince: &silent)
        check(r.phase == .idle, "FaceTime：FaceTime 關了＝結束")
        r = FaceTimeCall.step(phase: .calling, faceTimeRunning: true, micInUse: false, now: 160, startedAt: 95, connectedAt: nil, micSilentSince: &silent)
        check(r.phase == .idle, "FaceTime：響了 60 秒沒接通＝沒人接（FaceTime 還開著也一樣）")
        check(FaceTimeContacts.initials("Mari Tanaka") == "MT" && FaceTimeContacts.initials("王小明") == "明" && FaceTimeContacts.initials("cher") == "C", "FaceTime：頭像縮寫")
        let list = [FaceTimeContact(id: "1", name: "媽媽", handle: "+886 912-345-678", label: "", photo: nil),   // l10n-ignore：自檢
                    FaceTimeContact(id: "2", name: "Mari", handle: "mari@example.com", label: "", photo: nil)]
        check(FaceTimeContacts.filter(list, "妈妈").map(\.id) == ["1"] && FaceTimeContacts.filter(list, "MAR").map(\.id) == ["2"]
              && FaceTimeContacts.filter(list, "345").map(\.id) == ["1"] && FaceTimeContacts.filter(list, " ").count == 2, "FaceTime：搜尋（繁簡、大小寫、號碼）")   // l10n-ignore：自檢
        // 撥號一定要使用者確認
        let call = FaceTimeCall()
        call.demoElapsed = 0
        call.prepare(list[1], video: true)
        check(!call.dial(confirmedByUser: false) && call.phase == .preDial, "FaceTime：沒確認不撥")
        check(call.dial(confirmedByUser: true) && call.phase == .calling, "FaceTime：確認後才撥")
        call.end()
        check(call.phase == .idle && call.contact == nil, "FaceTime：結束清掉狀態")
    }
}
