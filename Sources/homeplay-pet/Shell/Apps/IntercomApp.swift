// 對講（Intercom）：HomeView 內建 App 之一（HV-SPECS-88）。
// HomePod 的對講沒有開放給其他 App（HomeKit 沒有對講 API，AirPlay 也不能指定送到哪幾台 HomePod），所以這裡照實做成：
// 按住黃色麥克風說話（AVAudioEngine 錄音、外圈電平），放開就在這台 Mac 現在的聲音輸出播出來——
// 如果在控制中心選了 AirPlay 喇叭，就是那台喇叭。畫面上寫清楚「播放到：…」與這件事。
// 錄音只在記憶體裡（最長 30 秒），不存檔、不上傳、不進日誌；離開 App 就丟掉。
// 點一下（不按住）也能用：點一下開始、再點一下送出（給 VoiceOver、切換控制用）。麥克風沒授權＝說明卡，走既有的 PermissionPrimer。

import AppKit
import AVFoundation
import CoreAudio

// MARK: - 純邏輯（--selftest 驗）

enum IntercomLogic {
    /// RMS → 0…1 的電平（−50 dB 以下算安靜，0 dB 滿）
    static func level(rms: Float) -> CGFloat {
        guard rms > 0 else { return 0 }
        let db = 20 * log10(Double(rms))
        return CGFloat(max(0, min(1, (db + 50) / 50)))
    }
    /// 按下多久算「按住說話」（放開就送）；短按＝切換（點一下開始、再點一下送）
    static func isHold(_ seconds: Double) -> Bool { seconds >= HPTokens.Intercom.holdThreshold }
    static func clock(_ seconds: Double) -> String { String(format: "%d:%02d", Int(seconds) / 60, Int(seconds) % 60) }
}

// MARK: - 錄音與播放（只在記憶體）

final class IntercomAudio {
    private var input: AVAudioEngine?
    private var output: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var buffers: [AVAudioPCMBuffer] = []
    private var format: AVAudioFormat?
    private(set) var recording = false
    private(set) var playing = false
    private(set) var levels: [CGFloat] = []
    private(set) var recordedSeconds = 0.0
    private(set) var message: (buffer: AVAudioPCMBuffer, seconds: Double)?
    var onChange: (() -> Void)?

    func start() -> Bool {
        guard !recording, AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else { return false }
        stopPlayback()
        let e = AVAudioEngine()
        let node = e.inputNode
        let fmt = node.outputFormat(forBus: 0)
        guard fmt.sampleRate > 0, fmt.channelCount > 0 else { return false }
        buffers = []; levels = []; recordedSeconds = 0; format = fmt
        let maxFrames = AVAudioFramePosition(fmt.sampleRate * HPTokens.Intercom.maxSeconds)
        var frames: AVAudioFramePosition = 0
        node.installTap(onBus: 0, bufferSize: 2048, format: fmt) { [weak self] buf, _ in
            guard frames < maxFrames, let copy = Self.copy(buf) else { return }
            frames += AVAudioFramePosition(buf.frameLength)
            var rms: Float = 0
            if let ch = buf.floatChannelData?[0], buf.frameLength > 0 {
                var sum: Float = 0
                for i in 0..<Int(buf.frameLength) { sum += ch[i] * ch[i] }
                rms = sqrt(sum / Float(buf.frameLength))
            }
            let lv = IntercomLogic.level(rms: rms), secs = Double(frames) / fmt.sampleRate
            DispatchQueue.main.async {
                guard let self, self.recording else { return }
                self.buffers.append(copy); self.levels.append(lv); if self.levels.count > 120 { self.levels.removeFirst(self.levels.count - 120) }
                self.recordedSeconds = secs
                self.onChange?()
            }
        }
        do { try e.start() } catch { node.removeTap(onBus: 0); return false }
        input = e; recording = true
        onChange?()
        return true
    }

    /// 停止錄音；send＝把剛錄的這段在 Mac 的輸出播出來
    func stop(send: Bool) {
        guard recording else { return }
        recording = false
        input?.inputNode.removeTap(onBus: 0); input?.stop(); input = nil
        if let fmt = format, let joined = Self.join(buffers, format: fmt), joined.frameLength > 0 {
            message = (joined, Double(joined.frameLength) / fmt.sampleRate)
            if send { play() }
        }
        buffers = []
        onChange?()
    }

    func play() {
        guard let m = message else { return }
        stopPlayback()
        let e = AVAudioEngine(), p = AVAudioPlayerNode()
        e.attach(p); e.connect(p, to: e.mainMixerNode, format: m.buffer.format)
        do { try e.start() } catch { return }
        p.scheduleBuffer(m.buffer, at: nil, options: []) { [weak self] in
            DispatchQueue.main.async { self?.playing = false; self?.onChange?() }
        }
        p.play()
        output = e; player = p; playing = true
        onChange?()
    }
    func stopPlayback() {
        player?.stop(); output?.stop(); player = nil; output = nil
        if playing { playing = false; onChange?() }
    }
    /// 離開 App：錄到一半的丟掉、正在播的停掉、記憶體裡那段也清掉
    func discard() { if recording { stop(send: false) }; stopPlayback(); message = nil; levels = [] }

    private static func copy(_ b: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let c = AVAudioPCMBuffer(pcmFormat: b.format, frameCapacity: b.frameLength) else { return nil }
        c.frameLength = b.frameLength
        let n = Int(b.format.channelCount), len = Int(b.frameLength)
        if let s = b.floatChannelData, let d = c.floatChannelData { for ch in 0..<n { d[ch].update(from: s[ch], count: len) } }
        return c
    }
    private static func join(_ bs: [AVAudioPCMBuffer], format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let total = bs.reduce(0) { $0 + Int($1.frameLength) }
        guard total > 0, let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(total)), let d = out.floatChannelData else { return nil }
        var at = 0
        for b in bs {
            guard let s = b.floatChannelData else { continue }
            for ch in 0..<Int(format.channelCount) { (d[ch] + at).update(from: s[ch], count: Int(b.frameLength)) }
            at += Int(b.frameLength)
        }
        out.frameLength = AVAudioFrameCount(at)
        return out
    }

    /// 這台 Mac 現在的聲音輸出（系統的預設輸出裝置名稱：內建揚聲器、耳機或 AirPlay 喇叭）
    static func outputName() -> String? {
        var dev = AudioDeviceID(0), size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var a = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &dev) == noErr, dev != 0 else { return nil }
        var name: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        a.mSelector = kAudioObjectPropertyName
        guard AudioObjectGetPropertyData(dev, &a, 0, nil, &size, &name) == noErr, let n = name?.takeRetainedValue() else { return nil }
        return n as String
    }
}

// MARK: - App

final class IntercomApp: PetApp {
    static let shared = IntercomApp()
    let id = "intercom"
    var title: String { L("app.intercom", "对讲") }
    let icon = AppIcon(color: .white, symbol: "intercom", glyph: srgb(0xF0922F))
    typealias T = HPTokens.Intercom

    private let audio = IntercomAudio()
    private var dirty = false
    private var holdStart: Double?        // 按住說話：按下的時間
    private var latched = false           // 點一下開始的那種
    private var permissionButton = CGRect.zero
    private var playRect = CGRect.zero
    private var outputRect = CGRect.zero
    private var output: String?
    private var lastOutputCheck = -10.0
    private var demo: String? { AppUI.args.firstIndex(of: "--demo-intercom").map { $0 + 1 < AppUI.args.count && !AppUI.args[$0 + 1].hasPrefix("--") ? AppUI.args[$0 + 1] : "idle" } ?? (SnapshotPrivacy.active ? "idle" : nil) }
    private var talkRect: CGRect { CGRect(x: T.talkCenter.x - T.talk / 2, y: T.talkCenter.y - T.talk / 2, width: T.talk, height: T.talk) }

    init() { audio.onChange = { [weak self] in self?.dirty = true } }

    private var authorized: Bool { demo != nil ? demo != "permission" : AVCaptureDevice.authorizationStatus(for: .audio) == .authorized }
    private var denied: Bool { demo == nil && [.denied, .restricted].contains(AVCaptureDevice.authorizationStatus(for: .audio)) }

    func didOpen(now: Double) { holdStart = nil; latched = false; lastOutputCheck = -10 }

    func tick(_ now: Double) -> Bool {
        if HPComponents.needsFrame(now) { dirty = true }
        // 按住說話：滑鼠按在麥克風上就開始錄；放開時（handleTap／handleLongPress）送出
        if let d = ShellInput.down, d.kind == .tap, !ShellInput.claimed, let uv = d.uv, authorized, demo == nil,
           holdStart == nil, !audio.recording, talkRect.contains(CGPoint(x: uv.x * 1024, y: uv.y * 1024)) {
            if audio.start() { holdStart = now; latched = false } else { noMicAt = now }
        }
        if audio.recording, audio.recordedSeconds >= T.maxSeconds { finish(send: true) }   // 錄滿 30 秒就送
        if let t = noMicAt, now - t < 4.2 { dirty = true }   // 「找不到麥克風」4 秒後換回「按住說話」
        if now - lastOutputCheck > 2 { lastOutputCheck = now; let o = IntercomAudio.outputName(); if o != output { output = o; dirty = true } }
        defer { dirty = false }
        return dirty || audio.recording
    }

    private func finish(send: Bool) { holdStart = nil; latched = false; audio.stop(send: send) }

    // MARK: 畫

    func render(into g: CGContext, face: Face, rect: CGRect, now: Double) {
        g.setFillColor(AppUI.bg.cgColor); g.fill(rect)
        AppUI.title(g, face, title)
        permissionButton = .zero; playRect = .zero
        guard authorized else {
            permissionButton = AppUI.drawPermission(g, face, appTitle: title, symbol: "mic.fill", tint: AppUI.orange,
                headline: denied ? L("intercom.perm.denied", "麦克风没有开放") : L("intercom.perm.title", "对讲需要麦克风"),
                body: denied ? L("intercom.perm.deniedBody", "到系统设置的「隐私与安全性」里，允许 HomePlay 使用麦克风") : L("intercom.perm.body", "按住说话，放开就在这台 Mac 播出来；录音不存档、不上传"),
                button: denied ? L("perm.openSettings", "打开系统设置") : L("intercom.perm.button", "允许使用麦克风"))
            return
        }
        // 播放到哪裡（照實：這台 Mac 現在的輸出）
        let outName = demo != nil ? L("intercom.demo.output", "客厅 HomePod") : (output ?? L("intercom.thisMac", "这台 Mac"))
        let of = AppUI.font(34, .semibold), olabel = String(format: L("intercom.playsOn", "播放到：%@"), outName)
        let ow = min(Typo.width(olabel, of) + 120, AppUI.contentW)
        outputRect = CGRect(x: 512 - ow / 2, y: T.outputBaseline - 60, width: ow, height: 88)
        HPComponents.glassButton(g, face, outputRect, olabel, symbol: "airplayaudio", size: 32)

        let recording = audio.recording || demo == "talking"
        let levels = demo == "talking" ? (0..<T.bars).map { CGFloat(0.25 + 0.6 * abs(sin(Double($0) * 0.7))) } : audio.levels
        HPComponents.levelRing(g, center: T.talkCenter, inner: T.ringInner, outer: T.ringOuter,
                               levels: recording ? levels : [], color: recording ? AppUI.orange : AppUI.tertiary)
        HPComponents.actionButton(g, face, talkRect, symbol: recording ? "waveform" : "mic.fill", role: .mic,
                                  label: nil)
        HPAX.note(g, talkRect, .button, recording ? L("intercom.a11y.send", "送出对讲") : L("intercom.a11y.talk", "开始对讲"), shape: .circle)
        let caption: String
        if recording {
            let secs = demo == "talking" ? 4 : audio.recordedSeconds
            caption = (latched ? L("intercom.tapToSend", "再点一下送出") : L("intercom.releaseToSend", "放开就送出")) + " · " + IntercomLogic.clock(secs)
        } else if audio.playing { caption = String(format: L("intercom.playing", "正在 %@ 播放"), outName) }
        else if let t = noMicAt, CACurrentMediaTime() - t < 4 { caption = L("intercom.noMic", "找不到可以用的麦克风") }
        else { caption = L("intercom.holdToTalk", "按住说话") }
        let cf = AppUI.font(38, .semibold)
        AppUI.center(face, g, caption, cf, cx: 512, y: T.captionBaseline - 40, recording ? AppUI.label : AppUI.secondary)

        // 最後一則（只在記憶體）：可以再聽一次
        let r = T.lastRow
        if let secs = audio.message?.seconds ?? (demo == "sent" ? 4 : nil) {
            AppUI.group(g, r, radius: r.height / 2)
            playRect = CGRect(x: r.minX + 12, y: r.minY + 8, width: r.height - 16, height: r.height - 16)
            g.setFillColor(AppUI.orange.cgColor); g.fillEllipse(in: playRect)
            face.drawSymbol(g, audio.playing ? "stop.fill" : "play.fill", in: playRect.insetBy(dx: 26, dy: 26), color: .white)
            let tf = AppUI.font(36, .semibold)
            AppUI.left(face, g, L("intercom.yourMessage", "你的对讲"), tf, x: playRect.maxX + 24, y: r.midY + 13, AppUI.label)
            AppUI.right(face, g, IntercomLogic.clock(secs), AppUI.font(32), rightX: r.maxX - 40, y: r.midY + 12, AppUI.secondary)
            HPAX.note(g, r, .button, L("intercom.a11y.replay", "再听一次你的对讲"))
        } else {
            let note = L("intercom.honest", "HomePod 的对讲没有开放给其他 App：你的声音会在这台 Mac（或它正在用的 AirPlay 扬声器）播出，不会存档。")
            let nf = AppUI.font(28)
            for (i, l) in Face.wrap(note, nf, 820, maxLines: 3).enumerated() { AppUI.center(face, g, l, nf, cx: 512, y: r.minY + 30 + CGFloat(i) * 38, AppUI.secondary) }
        }
    }

    // MARK: 點

    func handleTap(_ p: CGPoint, face: Face, now: Double) -> Bool {
        guard authorized else {
            guard AppUI.hit(permissionButton, p) else { return false }
            if denied { if let u = PermissionKind.microphone.settingsURL { NSWorkspace.shared.open(u) } }
            else { (NSApp.delegate as? AppDelegate)?.withPermission(.microphone) { _ in face.forceDirty = true } }
            return true
        }
        if talkRect.insetBy(dx: -10, dy: -10).contains(p) { release(now: now); return true }
        if audio.recording { finish(send: true); return true }
        if AppUI.hit(playRect, p) { if audio.playing { audio.stopPlayback() } else { audio.play() }; return true }
        if AppUI.hit(outputRect, p) {
            if let u = URL(string: "x-apple.systempreferences:com.apple.Sound-Settings.extension") { NSWorkspace.shared.open(u) }
            return true
        }
        return false
    }
    func handleLongPress(_ p: CGPoint, face: Face, now: Double) -> Bool {
        guard authorized, talkRect.insetBy(dx: -10, dy: -10).contains(p) || audio.recording else { return false }
        release(now: now); return true
    }
    /// 放開麥克風：按住的＝送出；短按＝切換（開始／送出）
    private func release(now: Double) {
        if let h = holdStart, audio.recording, !latched {
            if IntercomLogic.isHold(now - h) { finish(send: true) } else { latched = true; holdStart = nil }   // 短按：繼續錄，等下一下
            return
        }
        if audio.recording { finish(send: true); return }
        if audio.start() { latched = true; holdStart = nil } else { noMicAt = now }
    }
    /// 2.0 depth：有權限卻開不了麥克風（Mac mini 沒接麥克風、被別的 App 占著）：說一聲，不是按了沒反應
    private var noMicAt: Double?
    /// 2.0 depth：被閒置、Live Activity、ClioTalk 帶走時也一樣：錄到一半不送、麥克風關掉（30 秒上限在 tick 裡，App 不在畫面上就不跑了）
    func didClose() { if audio.recording { finish(send: false) }; audio.discard() }

    func handleBack(now: Double) -> Bool {
        if audio.recording { finish(send: false); return true }   // 錄到一半按返回＝不送
        audio.discard()
        return false
    }
}

// MARK: - 自檢（P10 三個 App 的純邏輯）

enum P10AppsSelfTest {
    static func run(_ check: (Bool, String) -> Void) {
        SafariSelfTest.run(check)
        WebAppSelftest.run(check); WebAppWidgetSelftest.run(check); AppProviderSelftest.run(check)   // 2.0 Web App 與 App 平台
        check(IntercomLogic.level(rms: 0) == 0 && IntercomLogic.level(rms: 1) == 1 && IntercomLogic.level(rms: 0.001) < 0.1
              && IntercomLogic.level(rms: 0.1) > 0.5 && IntercomLogic.level(rms: 0.1) < 0.7, "對講：電平 −50…0 dB 對到 0…1")   // l10n-ignore：selftest 訊息
        check(!IntercomLogic.isHold(0.1) && IntercomLogic.isHold(0.6) && IntercomLogic.clock(65) == "1:05", "對講：短按切換、按住送出；時間 m:ss")   // l10n-ignore
        check(HPComponents.actionSize <= HPTokens.Intercom.talk && HPTokens.Intercom.ringInner > HPTokens.Intercom.talk / 2, "對講：電平圈在大圓鈕外面")   // l10n-ignore
        let d = UserDefaults(suiteName: "homeplay.selftest.findmy")!
        d.removeObject(forKey: "HomePlayWeatherLat"); d.removeObject(forKey: "HomePlayWeatherLon")
        let none = FindMyModel.approximateLocation(d)
        d.set(25.03, forKey: "HomePlayWeatherLat"); d.set(121.56, forKey: "HomePlayWeatherLon")
        let some = FindMyModel.approximateLocation(d)
        d.removePersistentDomain(forName: "homeplay.selftest.findmy")
        check(none == nil && some?.latitude == 25.03, "尋找：位置只用天氣已經存的大約位置，沒有就不顯示")   // l10n-ignore
        check(FindMyModel.thisMac().real && FindMyModel.demoDevices().allSatisfy { !$0.real } && FindMyModel.demoPeople().count == 2,
              "尋找：真的只有這台 Mac，其他是示範資料")   // l10n-ignore
        check(OfficialIcons.names["findmy"] == "findmy" && OfficialIcons.names["safari"] == "safari" && OfficialIcons.fallback["safari"] != nil,
              "圖示：尋找、Safari 有官網圖示可退")   // l10n-ignore
        check(["findmy", "intercom", "safari"].allSatisfy { id in AppRegistry.visible.contains { $0.id == id } } && AppRegistry.visible.count <= 16,
              "內建 App：尋找、對講、Safari 都在，App 資料庫 4×4 放得下")   // l10n-ignore
    }
}
