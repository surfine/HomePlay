// 追人：用前置摄像头 + Vision 人脸框，让桌宠把屏幕转向你。
//
// 参考 iMac G4「Window/Lamp」广告：关键不是瞳孔级眼动，而是整块屏幕像脖子一样
// 跟着人转、跟着歪头、人走了回正。所以这里只用 VNDetectFaceRectanglesRequest
// revision 3（boundingBox + yaw/pitch/roll），不碰 pupil landmarks——更稳、更省。
//
// 隐私：只在用户从菜单明确打开后才申请摄像头；画面不落盘、不录制，只在本进程里
// 跑 Vision；CarPlay 直播时暂停。默认关闭。
import AppKit
import AVFoundation
import Vision

final class GazeTracker: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    struct Sample {
        var x: CGFloat        // -1…1，画面右为正（已镜像成用户视角）
        var y: CGFloat        // -1…1，画面下为正（人会略低于摄像头）
        var roll: CGFloat     // 弧度，正＝屏幕顺时针歪（已按镜像修正）
        var size: CGFloat     // 人脸框高度 0…1，远近代理
        var present: Bool
    }

    static let shared = GazeTracker()
    var onSample: ((Sample) -> Void)?
    /// 同一台摄像头顺带喂给房间光估计：不另开 AVCaptureSession。
    var onLightFrame: ((CVPixelBuffer, Double) -> Void)?

    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "homeplay.gaze")
    private var output: AVCaptureVideoDataOutput?
    private var running = false
    private var paused = false
    private var starting = false
    // 每次 start/stop/pause 都换一代：权限框或 configure 晚到的结果不能覆盖用户后来的决定。
    private var generation = 0
    private var lastSeen: Double = 0
    private var sentAbsent = true
    private var lastLog: Double = 0
    private var trackFaces = true
    private var device: AVCaptureDevice?
    private var highFormat: AVCaptureDevice.Format?
    private var lowFormat: AVCaptureDevice.Format?

    private var smoothX: CGFloat = 0
    private var smoothY: CGFloat = 0
    private var smoothRoll: CGFloat = 0
    private var smoothSize: CGFloat = 0

    private override init() { super.init() }

    var isRunning: Bool { running }

    /// 只开灯估计时跳过 Vision，并把相机降到 5 fps；在采集队列上改，避免跨线程读写。
    func setTrackFaces(_ on: Bool) {
        queue.async { [weak self] in
            guard let self else { return }
            self.trackFaces = on
            guard self.running, let d = self.device else { return }
            // 只开灯时输出 320×240（相机格式仍是 640/15，VideoDataOutput 负责缩放）；
            // 追人时恢复 640×480 给 Vision。
            if let out = self.output {
                self.session.beginConfiguration()
                out.videoSettings = self.outputSettings(faces: on)
                self.session.commitConfiguration()
            }
            if on {
                if let f = self.highFormat { self.setFormat(f, fps: 15, device: d) } else { self.setFrameRate(15, device: d) }
            } else {
                if let f = self.lowFormat { self.setFormat(f, fps: 15, device: d) } else { self.setFrameRate(15, device: d) }
            }
        }
    }

    private func outputSettings(faces: Bool) -> [String: Any] {
        [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: faces ? 640 : 320,
            kCVPixelBufferHeightKey as String: faces ? 480 : 240,
            AVVideoScalingModeKey as String: AVVideoScalingModeResize,
        ]
    }

    private func setFormat(_ fmt: AVCaptureDevice.Format, fps: Int, device: AVCaptureDevice) {
        do {
            try device.lockForConfiguration()
            if device.activeFormat != fmt { device.activeFormat = fmt }
            let f = Double(fps)
            let ranges = device.activeFormat.videoSupportedFrameRateRanges
            if ranges.contains(where: { $0.minFrameRate <= f && f <= $0.maxFrameRate }) {
                let d = CMTime(value: 1, timescale: CMTimeScale(max(1, fps)))
                device.activeVideoMinFrameDuration = d
                device.activeVideoMaxFrameDuration = d
            }
            device.unlockForConfiguration()
            let fd = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
            appendDiag("gaze.log", "camera mode \(fd.width)x\(fd.height) \(fps)fps")
        } catch { }
    }

    private func setFrameRate(_ fps: Int, device: AVCaptureDevice) {
        // 超过 activeFormat 支持的帧率范围会抛 ObjC 例外（进程会直接退出），先检查。
        let f = Double(fps)
        let ranges = device.activeFormat.videoSupportedFrameRateRanges
        guard ranges.contains(where: { $0.minFrameRate <= f && f <= $0.maxFrameRate }) else { return }
        do {
            try device.lockForConfiguration()
            let d = CMTime(value: 1, timescale: CMTimeScale(max(1, fps)))
            device.activeVideoMinFrameDuration = d
            device.activeVideoMaxFrameDuration = d
            device.unlockForConfiguration()
        } catch { }
    }

    // MARK: 生命周期

    /// completion 回主线程：(成功, 失败原因)。未授权时会弹系统摄像头权限。
    func start(completion: ((Bool, String?) -> Void)? = nil) {
        if running {
            DispatchQueue.main.async { completion?(true, nil) }
            return
        }
        guard !starting else { return }
        starting = true
        paused = false
        generation += 1
        let gen = generation
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configure(completion, generation: gen)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] ok in
                guard let self else { return }
                guard gen == self.generation else { return }   // 等权限时被关掉/暂停：不启动
                if ok {
                    self.configure(completion, generation: gen)
                } else {
                    self.starting = false
                    self.finish(false, "camera permission denied", completion)
                }
            }
        default:
            starting = false
            finish(false, "camera permission denied", completion)
        }
    }

    func stop() {
        generation += 1
        paused = false
        teardown(notify: true)
    }

    /// CarPlay 直播、锁屏、桌宠被遮住时暂停：关掉采集，条件解除再 resume。
    /// 返回这次是否真的改变了状态，方便调用方只在该记日志时记一行。
    @discardableResult
    func setPaused(_ on: Bool) -> Bool {
        guard on != paused else { return false }
        paused = on
        if on {
            generation += 1   // 让正在进行的 start/configure 作废，别在暂停后又把摄像头拉起来
            teardown(notify: true)
        } else if !running, !starting {
            start()
        }
        return true
    }

    private func configure(_ completion: ((Bool, String?) -> Void)?, generation gen: Int) {
        queue.async(execute: DispatchWorkItem { [weak self] in
            guard let self, gen == self.generation else { return }
            guard !self.running else {
                self.starting = false
                self.finish(true, nil, completion)
                return
            }
            guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front)
                    ?? AVCaptureDevice.default(for: .video) else {
                self.starting = false
                self.finish(false, "no camera available", completion)
                return
            }
            self.session.beginConfiguration()
            self.session.sessionPreset = self.session.canSetSessionPreset(.vga640x480) ? .vga640x480 : .medium
            do {
                let input = try AVCaptureDeviceInput(device: device)
                guard self.session.canAddInput(input) else {
                    throw NSError(domain: "HomePlayGaze", code: 1,
                                  userInfo: [NSLocalizedDescriptionKey: "cannot add camera input"])
                }
                self.session.addInput(input)
            } catch {
                self.session.commitConfiguration()
                self.starting = false
                self.finish(false, "cannot open camera: \(error.localizedDescription)", completion)
                return
            }
            self.device = device
            let out = AVCaptureVideoDataOutput()
            out.videoSettings = self.outputSettings(faces: self.trackFaces)
            out.alwaysDiscardsLateVideoFrames = true
            out.setSampleBufferDelegate(self, queue: self.queue)
            guard self.session.canAddOutput(out) else {
                self.session.commitConfiguration()
                self.starting = false
                self.finish(false, "cannot add camera output", completion)
                return
            }
            self.session.addOutput(out)
            self.output = out
            // 镜像成用户视角：人往右走，画面也往右，桌宠就跟着往右看
            if let conn = out.connection(with: .video), conn.isVideoMirroringSupported {
                conn.automaticallyAdjustsVideoMirroring = false
                conn.isVideoMirrored = true
            }
            self.session.commitConfiguration()
            // 尽量用 640×480 / 720p：脸和房间光都不需要 1080p，省下相机与像素缓冲的 CPU。
            do {
                try device.lockForConfiguration()
                let dims = { (f: AVCaptureDevice.Format) -> (Int32, Int32) in
                    let d = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
                    return (d.width, d.height)
                }
                let highCandidates = device.formats.filter { f in
                    let (w, h) = dims(f)
                    let ok = w >= 640 && h >= 480 && w <= 1280 && h <= 720
                    return ok && f.videoSupportedFrameRateRanges.contains { $0.minFrameRate <= 15 && $0.maxFrameRate >= 15 }
                }
                let high = highCandidates.min(by: { a, b in
                    let (aw, ah) = dims(a); let (bw, bh) = dims(b)
                    return aw * ah < bw * bh
                })
                self.highFormat = high
                // 只开房间光时用 320×240 / 5 fps：灯只需要 48×32 的统计，不必每秒 15 帧 640×480。
                let lowCandidates = device.formats.filter { f in
                    let (w, h) = dims(f)
                    let ok = w >= 160 && h >= 120 && w <= 640 && h <= 480
                    return ok && f.videoSupportedFrameRateRanges.contains { $0.minFrameRate <= 15 && $0.maxFrameRate >= 15 }
                }
                self.lowFormat = lowCandidates.min(by: { a, b in
                    let (aw, ah) = dims(a); let (bw, bh) = dims(b)
                    return aw * ah < bw * bh
                })
                if let high { device.activeFormat = high }
                let d = CMTime(value: 1, timescale: 15)
                device.activeVideoMinFrameDuration = d
                device.activeVideoMaxFrameDuration = d
                device.unlockForConfiguration()
                let fd = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
                appendDiag("gaze.log", "active format \(fd.width)x\(fd.height)")
            } catch { /* 有些摄像头不让你改，忽略 */ }
            self.session.startRunning()
            // 配置期间可能被暂停/停止：晚到的启动不能把 running 留成 true（否则之后再也 resume 不了）。
            guard gen == self.generation, !self.paused else {
                self.session.stopRunning()
                self.session.beginConfiguration()
                for input in self.session.inputs { self.session.removeInput(input) }
                for output in self.session.outputs { self.session.removeOutput(output) }
                self.session.commitConfiguration()
                self.output?.setSampleBufferDelegate(nil, queue: nil)
                self.output = nil
                self.starting = false
                return
            }
            self.running = true
            self.starting = false
            if !self.trackFaces {
                if let f = self.lowFormat { self.setFormat(f, fps: 15, device: device) }
                else { self.setFrameRate(5, device: device) }
            }
            self.lastSeen = 0
            self.sentAbsent = true
            self.smoothX = 0; self.smoothY = 0; self.smoothRoll = 0; self.smoothSize = 0
            appendDiag("gaze.log", "camera started \(device.localizedName) preset=\(self.session.sessionPreset.rawValue)")
            self.finish(true, nil, completion)
        })
    }

    private func teardown(notify: Bool) {
        let wasRunning = running || session.isRunning
        running = false
        starting = false
        queue.async { [weak self] in
            guard let self else { return }
            if self.session.isRunning { self.session.stopRunning() }
            self.session.beginConfiguration()
            for input in self.session.inputs { self.session.removeInput(input) }
            for output in self.session.outputs { self.session.removeOutput(output) }
            self.session.commitConfiguration()
            self.output?.setSampleBufferDelegate(nil, queue: nil)
            self.output = nil
        }
        if notify || wasRunning {
            sentAbsent = true
            DispatchQueue.main.async { [weak self] in
                self?.onSample?(Sample(x: 0, y: 0, roll: 0, size: 0, present: false))
                appendDiag("gaze.log", "camera stopped")
            }
        }
    }

    private func finish(_ ok: Bool, _ reason: String?, _ completion: ((Bool, String?) -> Void)?) {
        if !ok { appendDiag("gaze.log", "camera failed: \(reason ?? "?")") }
        DispatchQueue.main.async { completion?(ok, reason) }
    }

    // MARK: 每一帧

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard running, !paused, let buf = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let now = CACurrentMediaTime()
        onLightFrame?(buf, now)
        guard trackFaces else { return }
        let request = VNDetectFaceRectanglesRequest()
        request.revision = VNDetectFaceRectanglesRequestRevision3
        let handler = VNImageRequestHandler(cvPixelBuffer: buf, orientation: .up, options: [:])
        do { try handler.perform([request]) } catch { return }
        let faces = (request.results ?? []).sorted {
            $0.boundingBox.width * $0.boundingBox.height > $1.boundingBox.width * $1.boundingBox.height
        }
        guard let face = faces.first, face.confidence > 0.25,
              face.boundingBox.height >= 0.05 else {   // 太小的多半是海报/屏幕里的脸，不追
            // 丢失后保持 1 秒再通知回正，避免一帧漏检就抽一下
            if !sentAbsent, now - lastSeen > 1.0 {
                sentAbsent = true
                emit(Sample(x: 0, y: 0, roll: 0, size: 0, present: false))
            }
            return
        }
        lastSeen = now
        sentAbsent = false
        let bb = face.boundingBox
        let clipped = bb.minY < 0.01 || bb.maxY > 0.99 || bb.minX < 0.01 || bb.maxX > 0.99
        let rawX = CGFloat(bb.midX - 0.5) * 2
        let rawY = CGFloat(0.5 - bb.midY) * 2     // Vision 原点在左下；屏幕 y 向下为正
        let rawRoll = CGFloat(face.roll?.doubleValue ?? 0)
        let rawYaw = CGFloat(face.yaw?.doubleValue ?? 0)
        let rawSize = CGFloat(bb.height)
        let a: CGFloat = 0.24
        smoothX += (rawX - smoothX) * a
        smoothY += (rawY - smoothY) * a
        // 侧脸/半张脸出画/roll 大得离谱时 Vision 的姿态不可靠（会 1 秒内跳几十度），
        // 这时不学歪头；镜像画面里 roll 的方向和用户视角相反，取负。
        let rollTarget = (clipped || abs(rawYaw) > 0.55 || abs(rawRoll) > 1.2) ? 0 : -rawRoll * 1.15
        smoothRoll += (rollTarget - smoothRoll) * 0.10
        smoothSize += (rawSize - smoothSize) * 0.12
        let dead: CGFloat = 0.035
        let x = abs(smoothX) < dead ? 0 : smoothX
        let y = abs(smoothY) < dead ? 0 : smoothY
        emit(Sample(x: x, y: y, roll: smoothRoll, size: smoothSize, present: true))
        if now - lastLog > 1.0 {
            lastLog = now
            appendDiag("gaze.log", String(format: "face x=%.2f y=%.2f yaw=%.2f roll=%.2f size=%.2f", x, y, rawYaw, smoothRoll, smoothSize))
        }
    }

    private func emit(_ s: Sample) {
        DispatchQueue.main.async { [weak self] in self?.onSample?(s) }
    }
}
