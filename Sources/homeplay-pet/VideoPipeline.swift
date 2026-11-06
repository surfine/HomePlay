// 視訊解碼管線：健康度、零拷貝解碼、首幀閂、接收端 WS 客戶端——自 main.swift 拆出。
import Accelerate
import AppKit
import ApplicationServices
import AVFoundation
import Metal
import RealityKit
import Combine
import simd
import VideoToolbox
import CoreMedia
import CoreImage
import ImageIO
import IOKit.ps
import IOKit.hid
import Carbon.HIToolbox
import Network
import EventKit
import ServiceManagement
import Security

final class VideoHealth {
    enum Action: Equatable { case none, requestKeyframe, rebuild, giveUp }
    private(set) var received = 0, decoded = 0, totalRebuilds = 0
    private var receivedAtLastDecode = 0
    private var lastDecodeAt: Double
    private var lastReceiveAt = -1e9
    private var lastKeyframeAsk = -1e9
    private var lastRebuildAt = -1e9
    private var rebuildTimes: [Double] = []
    private var recovering = false

    init(now: Double) { lastDecodeAt = now }
    func reset(now: Double) {
        received = 0; decoded = 0; receivedAtLastDecode = 0; lastDecodeAt = now
        recovering = false; lastKeyframeAsk = -1e9
        // 新的一次直播是新的恢复预算：否则一次坏网络用完整 6 次后，后续每次重连都会立刻放弃
        rebuildTimes.removeAll(); totalRebuilds = 0
    }
    func frameReceived(now: Double) { received += 1; lastReceiveAt = now }
    func frameDecoded(now: Double) {
        decoded += 1; receivedAtLastDecode = received; lastDecodeAt = now; recovering = false
    }
    /// 解码报错：不等 2.5 s，直接按停滞处理
    func decodeError(now: Double) -> Action { (!recovering || now - lastRebuildAt > 8) ? rebuild(now) : keyframeOrNone(now) }

    func check(now: Double) -> Action {
        // 还在进帧（最近 2.5 s 有）才算停滞；流停了＝静止画面
        guard received - receivedAtLastDecode >= 3, now - lastDecodeAt > 2.5, now - lastReceiveAt < 2.5 else { return .none }
        if !recovering || now - lastRebuildAt > 8 { return rebuild(now) }
        return keyframeOrNone(now)
    }
    private func keyframeOrNone(_ now: Double) -> Action {
        guard now - lastKeyframeAsk >= 0.9 else { return .none }
        lastKeyframeAsk = now; return .requestKeyframe
    }
    private func rebuild(_ now: Double) -> Action {
        rebuildTimes = rebuildTimes.filter { now - $0 < 60 }
        guard rebuildTimes.count < 3, totalRebuilds < 6 else { return .giveUp }
        rebuildTimes.append(now); totalRebuilds += 1
        recovering = true; lastRebuildAt = now; lastKeyframeAsk = now
        return .rebuild
    }
}

final class VideoDecoder {
    private var format: CMVideoFormatDescription?
    private var session: VTDecompressionSession?
    private let ci = CIContext(options: [.cacheIntermediates: false])
    private let queue = DispatchQueue(label: "pet.decode")
    /// `busy` 在解碼回呼執行緒上讀、在主執行緒上清；`size` 在解碼佇列上寫、在主執行緒上讀。
    /// 兩者都不能裸露。
    private let stateLock = NSLock()
    private var busy = false
    private var _size = CGSize.zero
    var size: CGSize { stateLock.lock(); defer { stateLock.unlock() }; return _size }
    var onImage: ((CGImage) -> Void)?
    /// 零拷贝路：VT 解到 IOSurface 像素缓冲，CVMetalTextureCache 直接包成 MTLTexture（不経 CPU 拷貝）
    var onTexture: ((MTLTexture, Int, Int) -> Void)?
    var onDecoded: (() -> Void)?        // 主线程
    var onDecodeError: (() -> Void)?    // 主线程
    var frames = 0
    private var lastConfig: (UInt8, Data, Int, Int)?
    private var texCache: CVMetalTextureCache?
    private var framesSinceFlush = 0
    private let metalDevice: MTLDevice? = MTLCreateSystemDefaultDevice()
    private var held: CVMetalTexture?   // 保持映射到下一帧，渲染期间缓冲不被回收

    /// 贴图路一次只压一帧：主执行绪还没消费完就丢这一帧（P 帧照样解码，不会花屏）
    private func claimPresent() -> Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        if busy { return false }
        busy = true
        return true
    }
    private func releasePresent() { stateLock.lock(); busy = false; stateLock.unlock() }

    /// 用上一份 config 重建解码会话（停滞恢复用）。lastConfig 只在解碼佇列上读写。
    func rebuild() {
        queue.async { [self] in
            guard let c = lastConfig else { return }
            configure(codec: c.0, record: c.1, width: c.2, height: c.3)
        }
    }

    func configure(codec: UInt8, record: Data, width: Int, height: Int) {
        queue.async { [self] in
            lastConfig = (codec, record, width, height)
            var fmt: CMVideoFormatDescription?
            var st: OSStatus = noErr
            if codec == 2 {
                let sets = Self.hevcParameterSets(record)
                guard sets.count >= 3 else { log("HEVC 參數集不足（\(sets.count)）"); return }
                st = sets[0].withUnsafeBufferPointer { a in
                    sets[1].withUnsafeBufferPointer { b in
                        sets[2].withUnsafeBufferPointer { c in
                            let p = [a.baseAddress!, b.baseAddress!, c.baseAddress!]
                            let sz = [sets[0].count, sets[1].count, sets[2].count]
                            return CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                                allocator: nil, parameterSetCount: 3, parameterSetPointers: p,
                                parameterSetSizes: sz, nalUnitHeaderLength: 4, extensions: nil,
                                formatDescriptionOut: &fmt)
                        }
                    }
                }
                if st != noErr { log("hvcC 解析失敗 \(st)"); return }
            } else {
                st = CMVideoFormatDescriptionCreate(allocator: nil, codecType: kCMVideoCodecType_H264,
                    width: Int32(width), height: Int32(height),
                    extensions: [kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms: ["avcC": record]] as CFDictionary,
                    formatDescriptionOut: &fmt)
            }
            guard st == noErr, let fmt else { log("解碼器設定失敗（codec \(codec)）\(st)"); return }
            if let s = session { VTDecompressionSessionInvalidate(s); session = nil }
            format = fmt
            stateLock.lock(); _size = CGSize(width: width, height: height); stateLock.unlock()
            var s: VTDecompressionSession?
            // Metal 兼容＋IOSurface 背襯：VideoToolbox 解出來的緩衝能直接給 Metal 取用（零拷貝前提）
            let attrs = [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
                         kCVPixelBufferMetalCompatibilityKey: true,
                         kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary
            let cst = VTDecompressionSessionCreate(allocator: nil, formatDescription: fmt, decoderSpecification: nil,
                                                   imageBufferAttributes: attrs, outputCallback: nil, decompressionSessionOut: &s)
            // 失敗時 session 是 nil，之後每幀都會被靜默丟掉；至少要留一行痕跡。
            guard cst == noErr, let created = s else {
                log("解碼會話建立失敗（codec \(codec)）\(cst)")
                return
            }
            session = created
        }
    }

    /// `from` 允许直接传整条 wire 消息（前 11 字节是头），省一次 Array 切片拷贝。
    func decode(annexB: [UInt8], from offset: Int = 0) {
        queue.async { [self] in
            guard let format, let session, let block = Self.avcc(annexB, from: offset) else { return }
            var sample: CMSampleBuffer?
            var size = block.dataLength
            guard CMSampleBufferCreateReady(allocator: nil, dataBuffer: block, formatDescription: format,
                sampleCount: 1, sampleTimingEntryCount: 0, sampleTimingArray: nil,
                sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample) == noErr, let sample else { return }
            // 解码一定要每帧都做（P 帧依赖前一帧）；转贴图在忙时跳过
            VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample, flags: [], infoFlagsOut: nil) { [weak self] st, _, img, _, _ in
                guard let self else { return }
                guard st == noErr, let img else {
                    if st != noErr { DispatchQueue.main.async { self.onDecodeError?() } }
                    return
                }
                DispatchQueue.main.async { self.onDecoded?() }
                self.present(img)
            }
        }
    }

    /// 接收器自家參數集包：count u8 + 每個 len u16 + NAL
    private static func hevcParameterSets(_ blob: Data) -> [[UInt8]] {
        let b = [UInt8](blob)
        guard let count = b.first else { return [] }
        var out: [[UInt8]] = []; var i = 1
        for _ in 0..<Int(count) {
            guard i + 2 <= b.count else { break }
            let len = Int(b[i]) << 8 | Int(b[i + 1]); i += 2
            guard len > 0, i + len <= b.count else { break }
            out.append(Array(b[i..<(i + len)])); i += len
        }
        return out
    }

    private func present(_ img: CVImageBuffer) {
        stateLock.lock(); frames += 1; framesSinceFlush += 1; stateLock.unlock()
        guard claimPresent() else { return }
        // 定期清掉纹理缓存里没人用的条目（分辨率切换、长时间直播后不再膨胀）。
        if framesSinceFlush >= 120, let texCache {
            CVMetalTextureCacheFlush(texCache, 0)
            stateLock.lock(); framesSinceFlush = 0; stateLock.unlock()
        }
        // 快路：直接包成 MTLTexture 交給 RealityKit 採樣，每幀不碰像素、不建 CGImage（實測 0.01 ms vs 2.8-5.4 ms）
        // 只限方形畫面：非方來源走 CI 合成方圖的慢路
        let pw = CVPixelBufferGetWidth(img), ph = CVPixelBufferGetHeight(img)
        let isSquare = abs(pw - ph) <= max(4, Int(Double(max(pw, ph)) * 0.01))
        if onTexture != nil, isSquare {
            if texCache == nil, let dev = metalDevice {
                CVMetalTextureCacheCreate(nil, nil, dev, nil, &texCache)
            }
            let w = pw, h = ph
            var cv: CVMetalTexture?
            if let texCache,
               // 一定要 sRGB：解碼器交出來的是 gamma 編碼的 BGRA，用 .bgra8Unorm 會被當線性
               // 再輸出，中間調整體提亮（128→0.74），畫面看起來灰蒙蒙。
               CVMetalTextureCacheCreateTextureFromImage(nil, texCache, img, nil, .bgra8Unorm_srgb, w, h, 0, &cv) == kCVReturnSuccess,
               let cv, let tex = CVMetalTextureGetTexture(cv) {
                DispatchQueue.main.async { [weak self] in
                    self?.releasePresent()
                    self?.held = cv          // 留到下一幀；被替換時緩衝才回收
                    self?.onTexture?(tex, w, h)
                }
                return
            }
        }
        // 慢路（像素緩衝不支援 Metal 時）：CIImage 合成方圖再轉 CGImage
        let src = CIImage(cvImageBuffer: img)
        let w = src.extent.width, h = src.extent.height, side = max(w, h)
        let placed = src.transformed(by: CGAffineTransform(translationX: (side - w) / 2, y: (side - h) / 2))
        let square = placed.composited(over: CIImage(color: .black).cropped(to: CGRect(x: 0, y: 0, width: side, height: side)))
        let cg = ci.createCGImage(square, from: square.extent)
        DispatchQueue.main.async { [weak self] in
            self?.releasePresent()
            if let cg { self?.onImage?(cg) }
        }
    }

    func reset() { queue.async { [self] in
        if let s = session { VTDecompressionSessionInvalidate(s) }; session = nil; format = nil
    } }

    /// Annex B → AVCC（4 字节大端长度前缀）。一次预分配、一遍走完：
    /// 原来是先切出 NAL 切片数组、再逐段 `+=`，帧越大越多余拷贝。
    static func avcc(_ a: [UInt8], from offset: Int = 0) -> CMBlockBuffer? {
        guard a.count > offset else { return nil }
        var out = [UInt8]()
        out.reserveCapacity(a.count - offset)
        var nalStart = -1
        func flush(_ end: Int) {
            guard nalStart >= 0, end > nalStart else { return }
            let len = UInt32(end - nalStart)
            out.append(UInt8(len >> 24 & 0xff)); out.append(UInt8(len >> 16 & 0xff))
            out.append(UInt8(len >> 8 & 0xff)); out.append(UInt8(len & 0xff))
            out.append(contentsOf: a[nalStart..<end])
        }
        var i = offset
        while i + 2 < a.count {
            guard a[i] == 0, a[i + 1] == 0 else { i += 1; continue }
            var scLen = 0
            if a[i + 2] == 1 { scLen = 3 }
            else if i + 3 < a.count, a[i + 2] == 0, a[i + 3] == 1 { scLen = 4 }
            guard scLen > 0 else { i += 1; continue }
            flush(i)
            i += scLen
            nalStart = i
        }
        flush(a.count)
        guard !out.isEmpty else { return nil }
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: out.count,
            blockAllocator: nil, customBlockSource: nil, offsetToData: 0, dataLength: out.count, flags: 0,
            blockBufferOut: &block) == kCMBlockBufferNoErr, let block else { return nil }
        _ = out.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: out.count) }
        return block
    }
}

// MARK: - 接收器 client（wire 解析，和 WS2CarPlayReceiverWire 对齐）

/// 每條 WS 的「首幀／結束只報一次」標記。接收器換手機時同一條 WS 上會送
/// session ended → started，之後的第一幀要再報一次 live，桌寵才會從「正在連線」切回畫面。
/// 純值型別，不帶鎖；ReceiverClient 在自己的鎖裡用它，selftest 直接測。
struct FirstFrameLatch {
    private(set) var gotFrame = false
    private(set) var ended = false
    mutating func open() { gotFrame = false; ended = false }
    /// 首幀只報一次；返回 true 表示這次是第一次。
    mutating func takeFirstFrame() -> Bool {
        if gotFrame { return false }
        gotFrame = true; return true
    }
    /// 結束只報一次；返回 true 表示這次是第一次。
    mutating func markEnded() -> Bool {
        if ended { return false }
        ended = true; gotFrame = false; return true
    }
    mutating func resetFirstFrame() { gotFrame = false }
    /// 接收器的會話邊界（換手機／手機自己 TEARDOWN）：之後的第一幀要重新報 live。
    static func isSessionBoundary(_ s: String) -> Bool {
        s.contains("\"type\":\"session\"") && (s.contains("\"state\":\"ended\"") || s.contains("\"state\":\"started\""))
    }
    /// 依序餵入文字與幀（nil 代表一幀），回傳每一幀是否觸發 live。selftest 用。
    static func replay(_ events: [String?]) -> [Bool] {
        var l = FirstFrameLatch(); l.open()
        return events.compactMap { e in
            if let s = e { if isSessionBoundary(s) { l.resetFirstFrame() }; return nil }
            return l.takeFirstFrame()
        }
    }
}

final class ReceiverClient: NSObject, URLSessionWebSocketDelegate {
    private let endpoint: URL
    private let decoder: VideoDecoder
    var onLive: ((Bool) -> Void)?
    var onText: ((String) -> Void)?   // 接收器的狀態文字（例如未配對）
    var onOpen: (() -> Void)?         // WS 真的开了：补发掉线前排队的切换命令
    var onFrameReceived: (() -> Void)?   // 主线程
    /// 主动换线时旧连接的回调必须作废；否则旧 socket 的迟到结束会把新会话打回“重连中”。
    /// task / session / 首帧标记都收在这把锁下：写入在 main，读取在 URLSession 的回调线程。
    private let stateLock = NSLock()
    private var task: URLSessionWebSocketTask?
    private var session: URLSession?
    private var latch = FirstFrameLatch()
    private var closedByUs = false

    init?(endpoint: String, decoder: VideoDecoder) {
        guard let url = URL(string: endpoint), ["ws", "wss"].contains(url.scheme?.lowercased()) else { return nil }
        self.endpoint = url; self.decoder = decoder
    }
    private func isClosedByUs() -> Bool { stateLock.lock(); defer { stateLock.unlock() }; return closedByUs }
    private func currentTask() -> URLSessionWebSocketTask? {
        stateLock.lock(); defer { stateLock.unlock() }; return task
    }
    /// 首帧只报一次；返回 true 表示这次是第一次。
    private func takeFirstFrame() -> Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return latch.takeFirstFrame()
    }
    /// 结束只报一次；返回 true 表示这次是第一次。
    private func markEnded() -> Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return latch.markEnded()
    }
    /// 同一條 WS 上接收器換了會話：下一幀再報一次 onLive(true)。
    func resetFirstFrame() {
        stateLock.lock(); latch.resetFirstFrame(); stateLock.unlock()
    }
    /// URLSession 會強引用它的 delegate（就是本物件），沒有 invalidate 就永遠不釋放：
    /// 斷線重連每建一條 WS 就漏一個 session 加一個 client。
    /// graceful=true 時讓已取消的 task 收完再失效，保留 close frame 的機會。
    private func releaseSession(graceful: Bool = false) {
        stateLock.lock(); let s = session; session = nil; stateLock.unlock()
        if graceful { s?.finishTasksAndInvalidate() } else { s?.invalidateAndCancel() }
    }

    func open() {
        releaseSession()   // 防禦：同一個物件重開時先收掉上一條
        stateLock.lock(); closedByUs = false; latch.open(); stateLock.unlock()
        let s = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        let t = s.webSocketTask(with: endpoint)
        t.maximumMessageSize = 8 * 1024 * 1024   // 專輯封面 base64 可能超過預設 1 MB
        stateLock.lock(); session = s; task = t; stateLock.unlock()
        t.resume()
        receive()
    }
    func close() {
        stateLock.lock(); closedByUs = true; let t = task; task = nil; stateLock.unlock()
        t?.cancel(with: .goingAway, reason: nil)
        releaseSession(graceful: true)
    }

    func urlSession(_ s: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol p: String?) {
        guard !isClosedByUs() else { return }
        onOpen?()
        send(#"{"type":"keyframe"}"#)
    }
    func urlSession(_ s: URLSession, task: URLSessionTask, didCompleteWithError e: Error?) { end() }
    /// 连接结束只报一次（完成回调和收包失败都会走到这里）
    private func end() {
        guard !isClosedByUs() else { releaseSession(); return }
        releaseSession()
        guard markEnded() else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.isClosedByUs() else { return }
            self.onLive?(false)
        }
    }
    func requestKeyframe() { send(#"{"type":"keyframe"}"#) }
    /// 真正断开：先請接收器 TEARDOWN 手機會話，再關本地 WS。接收器收到後會結束並退出。
    /// reason 會寫進接收器日誌（2026-10-30：事後查不到是誰送了 stop）
    func requestTeardown(reason: String) {
        guard let t = currentTask() else { close(); return }
        t.send(.string(#"{"type":"stop","reason":"\#(reason)"}"#)) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self?.close() }
        }
    }
    private func send(_ s: String) { currentTask()?.send(.string(s)) { _ in } }
    /// 送一則現成的 JSON 給接收器（CarPlay 影片的狀態回報用）
    func sendRaw(_ s: String) { send(s) }
    private func receive() {
        currentTask()?.receive { [weak self] r in
            guard let self, !self.isClosedByUs() else { return }
            if case .success(let m) = r {
                if case .data(let d) = m { self.handle([UInt8](d)) }
                if case .string(let s) = m {
                    // 在收包線程上就重置：保證排在這則訊息之後的幀一定看得到
                    if FirstFrameLatch.isSessionBoundary(s) { self.resetFirstFrame() }
                    DispatchQueue.main.async { [weak self] in
                        guard let self, !self.isClosedByUs() else { return }
                        self.onText?(s)
                    }
                }
                self.receive()
            } else {
                self.end()
            }
        }
    }
    private func u32(_ b: [UInt8], _ o: Int) -> Int { Int(b[o]) | Int(b[o+1]) << 8 | Int(b[o+2]) << 16 | Int(b[o+3]) << 24 }
    private func handle(_ b: [UInt8]) {
        guard !isClosedByUs(), b.count >= 2 else { return }
        if b[0] == 1, b.count >= 12, b[2] == 1 || b[2] == 2 {
            let w = u32(b, 3), h = u32(b, 7)
            log("VIDEO_CONFIG \(w)x\(h) codec=\(b[2] == 2 ? "HEVC" : "H.264")")
            decoder.configure(codec: b[2], record: Data(b[11...]), width: w, height: h)
        } else if b[0] == 2, b.count >= 11 {
            decoder.decode(annexB: b, from: 11)
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.isClosedByUs() else { return }
                self.onFrameReceived?()
            }
            if takeFirstFrame() {
                DispatchQueue.main.async { [weak self] in
                    guard let self, !self.isClosedByUs() else { return }
                    self.onLive?(true)
                }
            }
        }
    }
    func sendTouch(x: Double, y: Double, down: Bool) {
        send(#"{"type":"touch","contacts":[{"id":0,"x":\#(String(format: "%.5f", x)),"y":\#(String(format: "%.5f", y)),"down":\#(down ? "true" : "false")}]}"#)
    }
    /// CarPlay 兩指（實驗旗標；接收端依 id 分槽送兩指 HID 報告，見 docs/plans/touch.md「CarPlay 兩指」）
    func sendTouches(_ contacts: [(Int, Double, Double, Bool)]) {
        let items = contacts.map { #"{"id":\#($0.0),"x":\#(String(format: "%.5f", $0.1)),"y":\#(String(format: "%.5f", $0.2)),"down":\#($0.3 ? "true" : "false")}"# }
        send(#"{"type":"touch","contacts":["# + items.joined(separator: ",") + "]}")
    }
    func sendMedia(_ command: String) {
        send(#"{"type":"media","command":"\#(command)"}"#)
    }
    /// 叫手机 Siri（接收器转成 CarPlay 的 requestSiri 事件）
    func sendSiri() { send(#"{"type":"siri"}"#) }
    /// F5 按住說話：按下送 down、放開送 up（接收器轉成 requestSiri siriAction 2／3）
    func sendSiri(down: Bool) { send(down ? #"{"type":"siri","action":"down"}"# : #"{"type":"siri","action":"up"}"#) }
    /// 車機的旋鈕／返回鍵（接收器轉成 CarPlay knob HID）；Esc 走這條。
    func sendKnob(_ command: String) { send(#"{"type":"knob","command":"\#(command)"}"#) }
    /// CarPlay 主螢幕開某個 App（接收端送 requestUI＋URL；Shell/AppPlatform/PhoneApps.swift）
    func openCarPlayApp(_ url: String) {
        guard let d = try? JSONSerialization.data(withJSONObject: ["type": "openCarPlayApp", "url": url]), let s = String(data: d, encoding: .utf8) else { return }
        send(s)
    }
    /// 獨立通話音量（MacPlay 的 callVolume）；接收器改 DynamicsProcessor 的 OverallGain。
    func sendCallGain(_ db: Double) { send(#"{"type":"audio","command":"callGain","db":\#(db)}"#) }
    /// 來電卡的按鍵（接收器轉成 CarPlay 電話 HID）
    func sendTelephony(_ action: PhoneCallAction) { send(#"{"type":"telephony","command":"\#(action.rawValue)"}"#) }
    func sendUsePhone(address: String) {
        let d: [String: Any] = ["type": "usePhone", "address": address]
        if let data = try? JSONSerialization.data(withJSONObject: d), let text = String(data: data, encoding: .utf8) {
            send(text)
        }
    }
    func sendPairNewPhone() {
        send(#"{"type":"pairNewPhone"}"#)
    }
    func sendPassphrase(_ value: String) {
        let d: [String: Any] = ["type": "setPassphrase", "value": value]
        if let data = try? JSONSerialization.data(withJSONObject: d), let text = String(data: data, encoding: .utf8) {
            send(text)
        }
    }
    func sendWiFi(ssid: String, passphrase: String) {
        let d: [String: Any] = ["type": "setWiFi", "ssid": ssid, "passphrase": passphrase]
        if let data = try? JSONSerialization.data(withJSONObject: d), let text = String(data: data, encoding: .utf8) {
            send(text)
        }
    }
    func sendForgetPhone(address: String) {
        let d: [String: Any] = ["type": "forgetPhone", "address": address]
        if let data = try? JSONSerialization.data(withJSONObject: d), let text = String(data: data, encoding: .utf8) {
            send(text)
        }
    }
    func sendRestorePhones() {
        send(#"{"type":"restorePhones"}"#)
    }
    /// 只送 Wi-Fi 名稱（自動讀到的）：接收器保留原本的密碼；不寫 wireless.json
    func sendSSID(_ ssid: String) {
        if let data = try? JSONSerialization.data(withJSONObject: ["type": "setWiFi", "ssid": ssid]),
           let text = String(data: data, encoding: .utf8) { send(text) }
    }
    /// 「拷貝診斷報告」：接收器回 {"type":"diagnostics","report":…}（只有次數、秒數、狀態）
    func requestDiagnostics() { send(#"{"type":"diagnostics"}"#) }
    /// 告诉 receiver 桌宠现在是在前台看引导，还是只在后台等画面。
    /// 后台挂接时 receiver 不要为配对自己弹系统设置。
    func sendEngaged(_ engaged: Bool) {
        send(engaged ? #"{"type":"foreground"}"# : #"{"type":"background"}"#)
    }
    func sendSeek(positionMs: UInt32, trackId: String?) {
        var d: [String: Any] = ["type": "seek", "positionMs": Int(positionMs)]
        if let trackId { d["trackId"] = trackId }
        if let data = try? JSONSerialization.data(withJSONObject: d), let text = String(data: data, encoding: .utf8) {
            send(text)
        }
    }
}

// MARK: - 3D 视图：转动、拆开、缩放、触控

/// 主循環的時鐘：60 Hz（手勢、直播、彈簧）用 NSView 的 display link（跟螢幕刷新同步，動畫不抖）；
/// 低幀率或視窗不在任何螢幕上（快照放在螢幕外）時退回 Timer，低幀率允許系統合併喚醒。
