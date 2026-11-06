// AirDrop 收件：iPhone 傳來的檔案落在「下載項目」，檔案的 com.apple.quarantine 擴充屬性第三欄是 sharingd（本機實測格式：
// 0081;6aecd829;sharingd;<UUID>），靠這個認出「是 AirDrop 收到的」，不是瀏覽器或別的 App 下載的。
// 監看：對資料夾開一個 DispatchSource（有檔案增減就掃一次）；新檔要等「大小與修改時間穩定」才處理（AirDrop 還在寫的時候不碰）。
// 啟動時資料夾裡原有的檔案一律當舊檔，不彈卡片。quarantine 第二欄是寫入時間（十六進位秒）：只認最近幾分鐘內寫入的，
// 在「下載項目」裡改名或 ⌘D 複製以前收到的檔案（屬性跟著帶過去）不算新收到。每次掃描把「已知」縮成目前真的在的檔名，
// 收過的檔案刪掉後再收一個同名的照樣認得。卡片的畫法與點按在 AirDropCard.swift；規則（純函數）都在這個檔，--selftest 直接驗。
// 「下載項目」是受保護的資料夾：第一次監看時系統會問一次「檔案和資料夾」權限；拒絕了就收不到卡片，其他功能不受影響。
// 快照、自檢、示範不碰真的資料夾（CCSystem.demo）。

import AppKit

enum AirDropKind: Equatable { case photo, link, other }

/// 一個收到的檔案
struct AirDropItem: Equatable {
    var url: URL
    var kind: AirDropKind
    /// 連結類才有：.webloc／.url／純文字網址裡的那個網址
    var link: URL?
    var name: String { url.lastPathComponent }
}

enum AirDropRules {
    /// quarantine 值的第三欄是 sharingd 才算 AirDrop（0081;6aecd829;sharingd;UUID）
    static func isAirDrop(quarantine: String?) -> Bool {
        guard let q = quarantine else { return false }
        let f = q.split(separator: ";", omittingEmptySubsequences: false)
        return f.count >= 3 && f[2] == "sharingd"
    }

    /// AirDrop 寫入多久以內才算剛收到（秒）。大檔要傳一陣子，從寫入到穩定最多等 AirDropInbox.giveUp，再寬一點
    static let recentWindow: Double = 300

    /// quarantine 第二欄的寫入時間（十六進位秒，1970 起算）；格式不對回 nil
    static func quarantineTime(_ quarantine: String?) -> Double? {
        guard let q = quarantine else { return nil }
        let f = q.split(separator: ";", omittingEmptySubsequences: false)
        guard f.count >= 2, let t = UInt64(f[1], radix: 16) else { return nil }
        return Double(t)
    }
    /// 剛收到：寫入時間在 now 之前 window 秒以內（時鐘誤差容許 60 秒的未來）
    static func isRecent(quarantine: String?, now: Double, window: Double = recentWindow) -> Bool {
        guard let t = quarantineTime(quarantine) else { return false }
        return t <= now + 60 && now - t <= window
    }

    /// 還在寫的暫存檔（瀏覽器的 .download、.crdownload、.part）與隱藏檔不處理
    static func isTemporary(_ name: String) -> Bool {
        if name.hasPrefix(".") { return true }
        return ["download", "crdownload", "part", "partial", "tmp"].contains((name as NSString).pathExtension.lowercased())
    }

    static let photoExts = PhotoShelf.exts

    /// 純文字網址：整份內容只有一個 http／https 網址（前後空白不算），不超過 2 KB
    static func linkURL(plain text: String) -> URL? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, t.utf8.count <= 2048, !t.contains(where: \.isWhitespace),
              let u = URL(string: t), ["http", "https"].contains(u.scheme?.lowercased() ?? ""), u.host?.isEmpty == false else { return nil }
        return u
    }
    /// .webloc 是 plist，網址在 URL 鍵
    static func linkURL(webloc data: Data) -> URL? {
        guard let p = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let s = p["URL"] as? String else { return nil }
        return linkURL(plain: s)
    }
    /// .url（Windows 捷徑）是 ini，網址在 URL= 那一行
    static func linkURL(internetShortcut text: String) -> URL? {
        for line in text.split(whereSeparator: \.isNewline) {
            let l = line.trimmingCharacters(in: .whitespaces)
            if l.lowercased().hasPrefix("url=") { return linkURL(plain: String(l.dropFirst(4))) }
        }
        return nil
    }

    /// 這個檔是哪一類；link 是讀檔內容得到的（只對 .webloc／.url／.txt／無副檔名去讀，其他不讀）
    static func classify(name: String, read: () -> Data?) -> (AirDropKind, URL?) {
        let ext = (name as NSString).pathExtension.lowercased()
        if photoExts.contains(ext) { return (.photo, nil) }
        switch ext {
        case "webloc": if let d = read(), let u = linkURL(webloc: d) { return (.link, u) }
        case "url": if let d = read(), let s = String(data: d, encoding: .utf8), let u = linkURL(internetShortcut: s) { return (.link, u) }
        case "txt", "": if let d = read(), let s = String(data: d, encoding: .utf8), let u = linkURL(plain: s) { return (.link, u) }
        default: break
        }
        return (.other, nil)
    }

    /// 大小與修改時間連續兩次一樣、而且隔了 hold 秒以上才算寫完
    static func settled(prev: (sig: String, since: Double)?, sig: String, now: Double, hold: Double = 1.0) -> Bool {
        guard let p = prev, p.sig == sig else { return false }
        return now - p.since >= hold
    }

    /// 放進照片錶面的資料夾時的檔名：已經有同名就加「 2」「 3」
    static func uniqueName(_ name: String, exists: (String) -> Bool) -> String {
        guard exists(name) else { return name }
        let ext = (name as NSString).pathExtension, stem = (name as NSString).deletingPathExtension
        var n = 2
        while true {
            let c = ext.isEmpty ? "\(stem) \(n)" : "\(stem) \(n).\(ext)"
            if !exists(c) { return c }
            n += 1
        }
    }
}

final class AirDropInbox {
    nonisolated(unsafe) static let shared = AirDropInbox()
    static var downloads: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads", isDirectory: true) }
    /// 等多久沒寫完就放棄（秒）
    static let giveUp: Double = 180

    private let folder: URL
    private var source: DispatchSourceFileSystemObject?
    private var known: Set<String> = []
    private var pending: [String: (sig: String, since: Double, first: Double)] = [:]
    private var poll: Timer?
    /// 主執行緒回呼：收到一個（等寫完、認出是 AirDrop 之後）
    var onReceive: ((AirDropItem) -> Void)?
    /// 牆上時間（跟 quarantine 的寫入時間比；自檢換成假的）
    var wallNow: () -> Double = { Date().timeIntervalSince1970 }

    init(folder: URL = AirDropInbox.downloads) { self.folder = folder }

    var running: Bool { source != nil }
    /// 有新檔案還在寫（還沒穩定）：「收 AirDrop」暫停 CarPlay 時據此延長（AirDropCarPlayPause）
    var writing: Bool { !pending.isEmpty }

    /// 開始監看。回 false＝資料夾打不開（沒權限或不存在）
    @discardableResult
    func start() -> Bool {
        guard source == nil else { return true }
        let fd = open(folder.path, O_EVTONLY)
        guard fd >= 0 else { return false }
        known = Set(names())   // 原有的都是舊檔
        let s = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .extend], queue: .main)
        s.setEventHandler { [weak self] in self?.scan(now: CACurrentMediaTime()) }
        s.setCancelHandler { close(fd) }
        s.resume()
        source = s
        return true
    }

    func stop() {
        source?.cancel(); source = nil
        poll?.invalidate(); poll = nil
        pending = [:]
    }

    private func names() -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
    }

    private func signature(_ url: URL) -> String? {
        guard let v = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isDirectoryKey]) else { return nil }
        return "\(v.fileSize ?? -1)|\(v.contentModificationDate?.timeIntervalSince1970 ?? 0)|\(v.isDirectory == true)"
    }

    /// 掃一次：新名字進 pending，pending 裡穩定的處理掉。事件與 0.5 秒計時器都叫它
    func scan(now: Double) {
        let present = Set(names())
        known.formIntersection(present)   // 刪掉的不再算「已知」：之後收到同名的照樣認得
        for n in present where !known.contains(n) && pending[n] == nil {
            if AirDropRules.isTemporary(n) { known.insert(n); continue }
            pending[n] = (sig: "", since: now, first: now)
        }
        for (n, p) in pending {
            let url = folder.appendingPathComponent(n)
            guard let sig = signature(url) else { pending[n] = nil; continue }   // 不見了（改名、刪掉）
            if sig != p.sig { pending[n] = (sig, now, p.first) }
            else if AirDropRules.settled(prev: (p.sig, p.since), sig: sig, now: now) {
                pending[n] = nil; known.insert(n)
                if let item = Self.item(for: url, now: wallNow()) { onReceive?(item) }
            }
            if let q = pending[n], now - q.first > Self.giveUp { pending[n] = nil; known.insert(n) }
        }
        if pending.isEmpty { poll?.invalidate(); poll = nil }
        else if poll == nil {
            poll = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.scan(now: CACurrentMediaTime()) }
        }
    }

    /// 寫完的檔案：quarantine 認得出是 AirDrop、而且是最近寫入的才回（改名、複製舊檔不算）
    static func item(for url: URL, now: Double) -> AirDropItem? {
        let q = quarantine(of: url)
        guard AirDropRules.isAirDrop(quarantine: q), AirDropRules.isRecent(quarantine: q, now: now) else { return nil }
        let (kind, link) = AirDropRules.classify(name: url.lastPathComponent) {
            guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
            defer { try? h.close() }
            return try? h.read(upToCount: 4096)
        }
        return AirDropItem(url: url, kind: kind, link: link)
    }

    static func quarantine(of url: URL) -> String? {
        let key = "com.apple.quarantine"
        let n = getxattr(url.path, key, nil, 0, 0, XATTR_NOFOLLOW)
        guard n > 0 else { return nil }
        var buf = [UInt8](repeating: 0, count: n)
        let m = getxattr(url.path, key, &buf, n, 0, XATTR_NOFOLLOW)
        guard m > 0 else { return nil }
        return String(decoding: buf.prefix(m), as: UTF8.self)
    }
}
