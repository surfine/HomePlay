// 2.0 imsg：附件的縮圖與語音訊息播放（只讀本機 ~/Library/Messages 底下的檔案，別的路徑一律不碰）。
// 照片／貼圖：ImageIO 縮圖（HEIC、PNG、JPEG、GIF、WebP 都吃）；影片：AVAssetImageGenerator 取第一格；
// 語音訊息（.caf／.m4a）：AVAudioPlayer 在原地播，跟手錶一樣點一下播、再點停。
// 縮圖在背景佇列做、記憶體快取（最多 60 張）；做好了叫 onReady 讓 App 重畫。
// 隱私：不記錄檔名或路徑；快照與示範資料不走這裡（MessagesDemo 自己畫假圖）。

import AppKit
import AVFoundation
import ImageIO

final class MessagesMedia: @unchecked Sendable {
    static let shared = MessagesMedia()
    private let queue = DispatchQueue(label: "homeplay.messages.media", qos: .userInitiated)
    private let lock = NSLock()
    private var cache: [Int64: CGImage] = [:]
    private var order: [Int64] = []
    private var pending: Set<Int64> = []
    private var durations: [Int64: Double] = [:]
    /// 主執行緒：有新縮圖好了
    var onReady: (() -> Void)?
    /// 示範資料：id → 圖（不讀檔）
    nonisolated(unsafe) static var demoImages: [Int64: CGImage] = [:]

    /// 只准讀「訊息」自己的資料夾（附件、貼圖快取）
    static func allowed(_ path: String) -> Bool {
        guard !path.isEmpty else { return false }
        let root = NSHomeDirectory() + "/Library/Messages/"
        let std = (path as NSString).standardizingPath
        return std.hasPrefix(root) && !std.contains("/../")
    }

    func image(_ ref: MessagesMediaRef, video: Bool = false) -> CGImage? {
        if let d = Self.demoImages[ref.id] { return d }
        lock.lock(); let hit = cache[ref.id]; let busy = pending.contains(ref.id); lock.unlock()
        if let hit { return hit }
        guard !busy, Self.allowed(ref.path) else { return nil }
        lock.lock(); pending.insert(ref.id); lock.unlock()
        let path = ref.path, id = ref.id
        queue.async { [weak self] in
            let img = video ? Self.videoFrame(path) : Self.thumbnail(path, max: 720)
            guard let self else { return }
            self.lock.lock()
            self.pending.remove(id)
            if let img {
                self.cache[id] = img; self.order.append(id)
                if self.order.count > 60 { self.cache[self.order.removeFirst()] = nil }
            }
            self.lock.unlock()
            if img != nil { DispatchQueue.main.async { self.onReady?() } }
        }
        return nil
    }

    static func thumbnail(_ path: String, max px: Int) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                                     kCGImageSourceThumbnailMaxPixelSize: px, kCGImageSourceShouldCacheImmediately: true]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
    }

    static func videoFrame(_ path: String) -> CGImage? {
        let gen = AVAssetImageGenerator(asset: AVURLAsset(url: URL(fileURLWithPath: path)))
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 720, height: 720)
        let sem = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var out: CGImage?
        gen.generateCGImageAsynchronously(for: .zero) { img, _, _ in out = img; sem.signal() }
        _ = sem.wait(timeout: .now() + 4)
        return out
    }

    /// 附件不在這台 Mac 上：路徑是空的（被清掉）或檔案不存在（iCloud 最佳化儲存空間）；結果快取
    private var missingCache: [Int64: Bool] = [:]
    func isMissing(_ ref: MessagesMediaRef) -> Bool {
        if Self.demoImages[ref.id] != nil || ref.id < 0 { return false }
        lock.lock(); let c = missingCache[ref.id]; lock.unlock()
        if let c { return c }
        let gone = ref.path.isEmpty || !FileManager.default.fileExists(atPath: ref.path)
        lock.lock(); missingCache[ref.id] = gone; lock.unlock()
        return gone
    }

    // MARK: 語音訊息

    private var player: AVAudioPlayer?
    private(set) var playingID: Int64?

    /// 秒數（讀一次檔頭；示範資料給固定值）
    func duration(_ ref: MessagesMediaRef) -> Double? {
        if Self.demoImages[ref.id] != nil || ref.id < 0 { return 7 }
        lock.lock(); let d = durations[ref.id]; lock.unlock()
        if let d { return d }
        guard Self.allowed(ref.path), let p = try? AVAudioPlayer(contentsOf: URL(fileURLWithPath: ref.path)) else { return nil }
        lock.lock(); durations[ref.id] = p.duration; lock.unlock()
        return p.duration
    }

    /// 點一下播、再點停；回傳現在是不是在播
    @discardableResult
    func toggle(_ ref: MessagesMediaRef) -> Bool {
        if playingID == ref.id { stop(); return false }
        stop()
        guard Self.allowed(ref.path), let p = try? AVAudioPlayer(contentsOf: URL(fileURLWithPath: ref.path)) else { return false }
        p.prepareToPlay(); p.play()
        player = p; playingID = ref.id
        return true
    }
    func stop() { player?.stop(); player = nil; playingID = nil }
    /// 0…1；沒在播回 nil（播完自動歸零）
    var progress: Double? {
        guard let p = player, playingID != nil else { return nil }
        if !p.isPlaying { stop(); return nil }
        return p.duration > 0 ? p.currentTime / p.duration : 0
    }
}
