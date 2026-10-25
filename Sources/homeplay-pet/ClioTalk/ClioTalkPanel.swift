// ClioTalk 的畫面：照 SiriConversation.dc.html 的「回答」「追問」兩格——整塊螢幕變白卡，
// 頂端小彩球（在想時轉動）、上一輪縮成一行、你的話在右邊灰泡泡、一句話先講結論、下面接資料卡、
// 「来自日历 · 模型」、跟進的小膠囊（≥ 88 單位高），最底下一條狀態列。
// 輸入：按住 F5 說話（ClioVoiceSession），或桌寵旁邊的原生文字框（NSPopover）。朗讀用 AVSpeechSynthesizer 一句一句念。
// 快照：--cliotalk-demo [answer|cyanotype|confirm|thinking|error|listening|followup] 用示範內容畫這張卡。

import AppKit
import AVFoundation
import NaturalLanguage
import SwiftUI

// MARK: - 卡片狀態（PetView 餵點擊，Face 畫）

enum ClioTalkPanel {
    enum Chip: Equatable { case ok, cancel, keep, deeper, ask, stop, settings, retry, listen }

    static var alpha: CGFloat = 0
    static var entering = true
    static var lastDraw: Double = -1e9
    static var openedAt: Double = 0
    static var buttons: [(Chip, CGRect)] = []
    static var pressed: Chip?
    static var pressAt: Double = 0
    static var tracking = false
    static var menuTracking = false
    private static var pressPoint: CGPoint?   // 按下那一點（拖出取消後回來，亮光還從原點亮起）
    /// 2.0 R9：打開那一刻底下的畫面（清楚、模糊）與錶面上眼睛膠囊的位置
    static var backdrop: (sharp: CGImage, blurred: CGImage)?
    static var islandFrom: CGRect?
    static var revealKey = ""
    static var revealAt: Double = 0
    /// 影片 v1 0:21.60→21.81 量到 0.21 s（臨界阻尼）；每行字 ≈ 0.04–0.08 s 浮現 → 0.12 s 的彈簧
    static let dropSpring = HPMotion.T.clioDrip.spring   // 動效包：參數表（Design/HPMotionTable.swift）
    static let lineSpring = HPMotion.T.clioLine.spring
    static let hold = HPMotion.T.clioHold
    static func progress(_ sp: Spring, _ t: CGFloat) -> CGFloat {
        guard t > 0 else { return 0 }
        if HPMotion.reduceMotion { return min(1, t / 0.2) }
        return max(0, min(1, sp.value(from: 0, to: 1, velocity: 0, t: t).x))
    }
    /// 快照：--cliotalk-demo 的哪一格
    static let demo: String? = {
        let a = CommandLine.arguments
        guard let i = a.firstIndex(of: "--cliotalk-demo") else { return nil }
        return i + 1 < a.count && !a[i + 1].hasPrefix("--") ? a[i + 1] : "answer"
    }()

    static var active: Bool { demo != nil || ClioTalkController.shared.isOpen }
    static var visible: Bool { alpha > 0.01 }
    /// 要不要 60fps：進出場、按鈕回彈、在想或在串流（彩球在轉）
    static func animating(_ now: Double) -> Bool {
        guard alpha > 0.003 || active else { return false }
        let p = snapshot.phase
        return (active ? alpha < 1 : alpha > 0) || now - pressAt < 0.2 || p == .thinking || p == .streaming
            || voiceAnimating || now - openedAt < 0.8 || now - revealAt < 0.8
    }
    /// 語音：在聽（球在動）、跟進倒數、下載進度
    static var voiceAnimating: Bool { demo == "listening" || ClioTalkController.shared.voice.active || ClioTalkController.shared.swipeDemoAt != nil }

    static var snapshot: ClioSnapshot {
        if let d = demo { return demoSnapshot(d) }
        return ClioTalkController.shared.snapshot
    }

    /// 示範內容（照設計稿；不是真資料）
    static func demoSnapshot(_ kind: String) -> ClioSnapshot {
        var s = ClioSnapshot()
        s.model = ClioModels.displayName("claude-haiku-5-5")
        s.question = L("clio.demo.question", "这周有谁生日？")
        switch kind {
        case "confirm":
            s.phase = .confirm
            s.previous = L("clio.demo.answerShort", "这周有两个生日")
            s.question = L("clio.demo.ask2", "提醒我周四买 B 的礼物")
            s.confirm = L("clio.confirm.reminder", "要加这个提醒吗？") + "\n" + L("clio.demo.confirmDetail", "10月29日 周四 18:00：买 B 的生日礼物")
            s.handoff = ClioHandoff.demoDraft   // 第五輪：草稿卡
        case "card":
            // 第五輪：做完的物件卡（計時器交給「計時器」）
            s.phase = .idle
            s.question = L("clio.demo.askTimer", "南瓜汤计时 15 分钟")
            s.answer = L("clio.demo.timerDone", "好了，15 分钟。")
            s.handoff = ClioHandoff.demoTimer
        case "kept":
            s.phase = .idle
            s.answer = L("clio.demo.answer", "这周有两个生日：\n周二 10月27日：[朋友 A] 生日\n周五 10月30日 · 19:00：[朋友 B] 生日晚餐")
            s.source = ClioToolGroup.calendar.source
            s.kept = true
        case "thinking":
            s.phase = .thinking
        case "error":
            s.phase = .error
            s.error = ClioError.missingKey.message
        case "empty":
            s.phase = .idle
            s.question = ""
            s.model = ""
        case "cyanotype":
            // 第三輪：官方 siri-cyanotype 的那種回答——一段話、重點詞粗體、來源晶片、圖片卡
            s.phase = .idle
            s.answer = L("clio.demo.cyanotype", "蓝晒法由英国天文学家兼化学家**约翰·赫歇尔爵士**在 **1842** 年发明。他用这种方法复制自己的笔记与图表：涂上感光铁盐的纸被阳光照到的地方会变成深深的普鲁士蓝，被遮住的地方留下白色的影像。")
            s.sources = ["Wikipedia", "Britannica", "The Met", "Getty"]   // l10n-ignore：來源名稱是專有名詞
            s.demoImage = true
        default:
            s.phase = .idle
            s.answer = OfficialDemo.on ? OfficialDemo.clioAnswer : L("clio.demo.answer", "这周有两个生日：\n周二 10月27日：[朋友 A] 生日\n周五 10月30日 · 19:00：[朋友 B] 生日晚餐")
            s.source = ClioToolGroup.calendar.source
        }
        return s
    }

    static func chips(for s: ClioSnapshot) -> [(Chip, String)] {
        switch s.phase {
        case .confirm: return [(.ok, L("clio.chip.ok", "好")), (.cancel, L("clio.chip.cancel", "取消"))]
        case .thinking, .streaming: return [(.stop, L("clio.chip.stop", "停止"))]
        case .error: return [(.retry, L("clio.chip.retry", "再试一次")), (.settings, L("clio.chip.settings", "设置…"))]
        case .idle:
            // 2.0 depth：第一次用、還沒接模型：先給「設定…」，不要等問完才說
            if s.answer.isEmpty, ClioTalkController.keyMissing { return [(.settings, L("clio.chip.settings", "设置…")), (.ask, L("clio.chip.ask", "问点什么"))] }
            guard !s.answer.isEmpty else { return [(.ask, L("clio.chip.ask", "问点什么"))] }
            var c: [(Chip, String)] = [(.keep, L("clio.chip.keep", "留下"))]
            if s.tier == .fast, ClioSettings.provider != .onDevice, ClioSettings.provider != .lmStudio { c.append((.deeper, L("clio.chip.deeper", "想深一点"))) }
            c.append((.ask, L("clio.chip.followUp", "继续问")))
            return c
        }
    }

    private static func hit(_ x: CGFloat, _ y: CGFloat) -> Chip? {
        buttons.first { $0.1.insetBy(dx: -8, dy: -8).contains(CGPoint(x: x, y: y)) }?.0
    }
    /// 按下（1024 座標）：卡片在時螢幕上的點擊都歸卡片
    static func press(x: CGFloat, y: CGFloat) {
        tracking = true
        if Clio1988Menu.press(x: x, y: y) { menuTracking = true; pressAt = CACurrentMediaTime(); return }   // 第六輪：1988 的選單列（ClioTalk1988.swift）
        pressed = hit(x, y)
        pressAt = CACurrentMediaTime()
        if pressed != nil { pressPoint = CGPoint(x: x, y: y); HPGlass.pressDown(pressPoint!) }   // 2.0 R14：按下那一刻就變亮放大
    }
    /// 拖曳中（1024 座標）：拖出按住的那顆就收掉按壓亮光、拖回來再亮（放開本來就要還在同一顆才作用）
    static func drag(x: CGFloat, y: CGFloat) -> Bool {
        guard tracking, !menuTracking, let chip = pressed, let pt = pressPoint else { return false }
        return HPGlass.pressOver(hit(x, y) == chip, at: pt)
    }
    /// 放開：還在同一顆上才算；點在卡片空白處＝打開輸入框
    static func release(x: CGFloat?, y: CGFloat?) {
        tracking = false
        if menuTracking {
            menuTracking = false
            pressAt = CACurrentMediaTime()
            if let item = Clio1988Menu.release(x: x, y: y) { ClioTalkController.shared.menu(item) }
            return
        }
        let b = pressed
        pressed = nil
        pressAt = CACurrentMediaTime()
        HPGlass.pressUp()
        guard let x, let y else { return }
        if let b { if hit(x, y) == b { ClioTalkController.shared.tap(b) } }
        else if !ClioTalkController.shared.voice.loop.listening { ClioTalkController.shared.showInput() }
    }

    static func nextAlpha(_ a: CGFloat, target: CGFloat, dt: Double) -> CGFloat {
        target > a ? min(target, a + CGFloat(dt / 0.32)) : max(target, a - CGFloat(dt / 0.18))
    }
    static func easeOut(_ x: Double) -> Double { 1 - pow(1 - min(1, max(0, x)), 3) }
}

// MARK: - 控制器（主執行緒）

final class ClioTalkController: NSObject, NSPopoverDelegate {
    static let shared = ClioTalkController()

    private(set) var isOpen = false
    private(set) var snapshot = ClioSnapshot()
    private var task: Task<Void, Never>?
    private weak var view: PetView?
    private var popover: NSPopover?
    private let input = ClioInputModel()
    private var autoClose: DispatchWorkItem?
    private let speaker = ClioSpeaker()
    private var f5 = ClioF5Router()
    /// 語音的一次對話（麥克風、轉寫、跟進）
    let voice = ClioVoiceSession()
    /// 送出後見過引擎的新階段沒有（還沒見過就不算「回答完」）
    private var answerSeen = false
    private var voiceWired = false

    private lazy var engine = ClioEngine(
        store: ClioHistoryStore(dir: ClioHistoryStore.defaultDir), runner: ClioSystemTools(), ledger: ClioLedger(),
        config: { ClioSettings.config }, makeProvider: ClioEngine.liveProvider,
        context: { ClioContext.live($0, $1) },   // 2.0 第五輪：每輪帶裝置狀態（時間、地點、誰在看、開著的 App、家裡的摘要）
        onSnapshot: { s in DispatchQueue.main.async { ClioTalkController.shared.apply(s) } })

    private func redraw() { view?.face.forceDirty = true }

    /// 右鍵「ClioTalk…」、F5
    /// 2.0 depth：這次打開時還沒有金鑰（打開時查一次 Keychain，不每幀查）
    nonisolated(unsafe) static var keyMissing = false
    static func refreshKeyMissing() {
        let p = ClioSettings.provider
        keyMissing = !Face.demoData && p.needsKey && ClioKeychain.load(p) == nil
    }

    func open(from v: PetView) {
        Self.refreshKeyMissing()
        view = v
        if !isOpen { isOpen = true; ClioTalkPanel.openedAt = CACurrentMediaTime() }
        cancelAutoClose()
        redraw()
        showInput()
    }

    func close() {
        swipeIntro = false; swipeDemoAt = nil   // 2.0 P10
        voice.cancel()
        task?.cancel(); task = nil
        speaker.stop()
        popover?.performClose(nil)
        isOpen = false
        cancelAutoClose()
        redraw()
    }

    /// 2.0: 外殼往回退時：在想／在回答就只收起卡片、讓這一輪答完（頂端藥丸「ClioTalk 回答中」，點它回來）；沒事就關掉
    func dismissFromShell() {
        let p = snapshot.phase
        guard isOpen, p == .thinking || p == .streaming else { close(); return }
        popover?.performClose(nil)
        isOpen = false
        cancelAutoClose()
        redraw()
    }

    /// F5：回 true＝這次歸 ClioTalk（CarPlay 直播中一律回 false，照舊給 iPhone 的 Siri）
    /// 按住＝按著說（放開送出）；點一下＝免按住（停頓 0.7 秒送出）；念回答時按＝立刻停
    func handleF5(down: Bool, carPlayLive: Bool, view v: PetView?) -> Bool {
        if carPlayLive { voice.cancel() }   // CarPlay 的 Siri 要用麥克風：先放掉
        let mine = f5.route(down: down, carPlayLive: carPlayLive, clioEnabled: ClioSettings.f5OpensClioTalk)
        guard mine else { return false }
        if down {
            openForVoice(v)
            voice.press()
        } else {
            voice.release()
        }
        return true
    }

    /// CarPlay 開始直播：放掉麥克風（卡片留著）
    func carPlayWentLive() { voice.cancel() }

    /// 開卡片但不開文字框（語音）
    private func openForVoice(_ v: PetView?) {
        wireVoice()
        if let v { view = v }
        if !isOpen { isOpen = true; ClioTalkPanel.openedAt = CACurrentMediaTime() }
        cancelAutoClose()
        popover?.performClose(nil)
        redraw()
    }

    private func wireVoice() {
        guard !voiceWired else { return }
        voiceWired = true
        voice.spokenText = { [weak self] in (self?.snapshot.spoken ?? "") + (self?.snapshot.answer ?? "") + (self?.snapshot.confirm ?? "") }
        voice.onSubmit = { [weak self] t in self?.submitSpoken(t) }
        voice.onInterrupt = { [weak self] in
            guard let self else { return }
            self.speaker.stop()
            if self.snapshot.phase == .thinking || self.snapshot.phase == .streaming { self.task?.cancel(); self.task = nil }
        }
        voice.onFail = { [weak self] msg in self?.voiceNotice = msg; self?.showInput() }
        voice.onMicClosed = { [weak self] in self?.scheduleAutoClose() }
        voice.redraw = { [weak self] in self?.redraw() }
        speaker.onStart = { [weak self] in self?.voice.answerSpeaking() }
        speaker.onIdle = { [weak self] in self?.checkVoiceDone() }
    }

    /// 說完的一句：在等「好」時先認「好／取消」，其他照常送出
    private func submitSpoken(_ t: String) {
        voiceNotice = nil
        answerSeen = false
        if snapshot.phase == .confirm {
            switch ClioConfirm.classifySpoken(t) {
            case .yes: speaker.stop(); let e = engine; task = Task { await e.confirm(true) }; return
            case .no: speaker.stop(); let e = engine; task = Task { await e.confirm(false) }; return
            case .other: break
            }
        }
        // 第四輪：回答畫面沒有按鈕，「留下」「想深一點」用說的（ClioAnswerCommands.swift）
        if snapshot.phase == .idle, !snapshot.answer.isEmpty, let cmd = ClioAnswerCommand.classify(t) {
            speaker.stop()
            tap(cmd == .keep ? .keep : .deeper)
            return
        }
        // 2.0 promo：烹飪畫面開著時，「下一步」「勾掉蛋」「開始計時」在本機做掉，不送模型（Shell/Apps/RecipeCooking.swift）
        if Shell.currentApp === RecipesApp.shared, let cmd = RecipeVoice.classify(t), RecipesApp.shared.handleVoice(cmd, now: CACurrentMediaTime()) {
            speaker.stop(); close(); return
        }
        send(t, mode: ClioSettings.speak ? .voice : .display)   // 2.0 第五輪：用說的問＝語音模式（另給念稿、選項一個一個念）
    }

    /// 回答出完、也念完了：開始跟進的 8 秒（設定可關）
    private func checkVoiceDone() {
        let st = voice.loop.state
        guard answerSeen, st == .waiting || st == .speaking || st == .bargeCheck else { return }
        let p = snapshot.phase
        guard p == .idle || p == .confirm || p == .error, speaker.pending == 0 else { return }
        voice.answerDone(followUp: ClioSettings.followUpListening)
    }

    /// 2.0 P10（HV-SPECS-65）：從螢幕頂端往下滑＝立刻開始聽（免按住、停頓就送出），不出文字框；
    /// 麥克風還沒允許時走權限卡（先說明一次再跳系統框），被拒才退回打字。第一次用時最底下那行多說一句怎麼叫出來。
    func listenFromSwipe(from v: PetView) {
        if Face.demoData {   // 快照與自檢：不碰麥克風、不記「說明過了」，只畫「在聽」
            view = v
            if !isOpen { isOpen = true; ClioTalkPanel.openedAt = CACurrentMediaTime() }
            swipeDemoAt = CACurrentMediaTime(); swipeIntro = ProcessInfo.processInfo.environment["HOMEPLAY_SWIPE_REPEAT"] == nil
            redraw(); return
        }
        if !UserDefaults.standard.bool(forKey: Self.swipeIntroKey) { UserDefaults.standard.set(true, forKey: Self.swipeIntroKey); swipeIntro = true }
        openForVoice(v)
        voice.tapOrb()
    }
    static let swipeIntroKey = "ClioTalkSwipeIntroShown"
    /// 這次是第一次從頂端滑下來叫 ClioTalk（聆聽畫面最底下那行換成說明）
    private(set) var swipeIntro = false
    /// 快照：從頂端滑下來那一刻（只畫，不開麥克風）
    private(set) var swipeDemoAt: Double?

    /// 點彩球、或卡片上在聽的那一整塊
    func listenTapped() {
        guard ClioTalkPanel.demo == nil else { return }
        openForVoice(view ?? (NSApp.delegate as? AppDelegate)?.view)
        voice.tapOrb()
    }

    /// 不能用語音時卡片上的一句說明
    private(set) var voiceNotice: String?

    func showInput() {
        guard let v = view ?? (NSApp.delegate as? AppDelegate)?.view else { return }
        view = v
        if popover?.isShown == true { return }
        input.onSend = { [weak self] t in self?.voice.cancel(); self?.voiceNotice = nil; self?.send(t) }
        input.onConfirm = { [weak self] yes in self?.tap(yes ? .ok : .cancel) }
        input.onStop = { [weak self] in self?.tap(.stop) }
        let p = NSPopover()
        p.behavior = .transient
        p.animates = true
        p.delegate = self
        p.contentViewController = NSHostingController(rootView: ClioInputView(model: input))
        NSApp.activate(ignoringOtherApps: true)
        p.show(relativeTo: v.bounds, of: v, preferredEdge: .maxX)
        popover = p
        cancelAutoClose()
    }

    func popoverDidClose(_ notification: Notification) {
        popover = nil
        scheduleAutoClose()
    }

    /// 文字框裡沒人、也不在等「好」：15 秒後收起卡片
    private func scheduleAutoClose() {
        cancelAutoClose()
        guard isOpen, snapshot.phase != .confirm, !voice.active else { return }
        let w = DispatchWorkItem { [weak self] in
            guard let self, self.popover == nil, !self.voice.active, self.snapshot.phase == .idle || self.snapshot.phase == .error else { return }
            self.close()
        }
        autoClose = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 15, execute: w)
    }
    private func cancelAutoClose() { autoClose?.cancel(); autoClose = nil }

    func send(_ text: String, mode: ClioResponseMode = .display) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        task?.cancel()
        speaker.stop()
        cancelAutoClose()
        let e = engine
        task = Task { await e.send(t, mode: mode) }
    }

    func tap(_ c: ClioTalkPanel.Chip) {
        guard ClioTalkPanel.demo == nil else { return }
        let e = engine
        switch c {
        case .ok, .cancel:
            guard !RemoteInput.fromGuest else { log("clio: 訪客裝置不能確認"); return }   // 2.0 idle: 「好」只給主人
            speaker.stop()
            task = Task { await e.confirm(c == .ok) }
        case .stop:
            task?.cancel(); task = nil
            speaker.stop()
        case .keep:
            Task { await e.keepLast() }
            view?.mood.show(.happy, for: 0.8, now: CACurrentMediaTime())
        case .deeper:
            send(L("clio.chip.deeper", "想深一点"), mode: snapshot.mode)
        case .ask:
            showInput()
        case .retry:
            if !snapshot.question.isEmpty { send(snapshot.question) }
        case .settings:
            if let app = NSApp.delegate as? AppDelegate { SettingsWindowController.show(app: app, pane: .cliotalk) }
        case .listen:
            listenTapped()
        }
    }

    func clearHistory() {
        task?.cancel()
        let e = engine
        Task { await e.clear() }
    }

    // MARK: 引擎 → 畫面與朗讀

    private var spoken = ""
    private var spokenBlockSaid: String?
    private var splitter = ClioSentenceSplitter()

    private func apply(_ s: ClioSnapshot) {
        let old = snapshot
        snapshot = s
        input.phase = s.phase
        input.confirm = s.confirm
        if s.phase != .idle { answerSeen = true }
        redraw()
        defer { checkVoiceDone() }
        guard ClioSettings.speak else { return }
        // 2.0 第五輪：語音模式的回答帶一段念稿——念它（寫完才念），不念畫面上的字
        if s.spokenBlock {
            if let say = s.spoken, say != spokenBlockSaid { spokenBlockSaid = say; speaker.say(say) }
            spoken = s.answer
            return
        }
        if s.phase == .thinking { spokenBlockSaid = nil }
        // 回答被換掉（升級到深模型、新的一輪）：停掉、重新切句
        if !s.answer.hasPrefix(spoken) {
            speaker.stop(); spoken = ""; splitter = ClioSentenceSplitter()
        }
        if s.answer.count > spoken.count {
            let delta = String(s.answer.dropFirst(spoken.count))
            spoken = s.answer
            for sentence in splitter.feed(delta) { speaker.say(sentence) }
        }
        if s.phase == .idle, old.phase == .streaming, let rest = splitter.flush() { speaker.say(rest) }
        if s.phase == .confirm, old.phase != .confirm, let c = s.confirm { speaker.say(c) }   // 念給你聽，等你說「好」
        if s.phase == .error, old.phase != .error, let e = s.error { speaker.say(e) }
    }
}

// MARK: - 朗讀

/// 照語言挑聲音（有裝 premium／enhanced 就用，不用 Eloquence 那種趣味聲音），比預設快一點；
/// 一句一句排隊，排空了告訴控制器（開始跟進）。
final class ClioSpeaker: NSObject, AVSpeechSynthesizerDelegate, @unchecked Sendable {   // 只在主執行緒用；回呼都轉回主執行緒
    private let synth = AVSpeechSynthesizer()
    /// 還沒念完的句子（stop 之後舊的回呼不算）
    private var queued: [AVSpeechUtterance] = []
    var pending: Int { queued.count }
    var onStart: (() -> Void)?
    var onIdle: (() -> Void)?
    /// 2.0 P10：語速與聲音在設定 › ClioTalk 挑（ClioSpeechVoices.swift）；預設快 8%
    static var rate: Float { ClioSpeechVoices.rate }

    override init() {
        super.init()
        synth.delegate = self
    }

    func say(_ text: String) {
        let clean = text.replacingOccurrences(of: "[", with: "").replacingOccurrences(of: "]", with: "")
        guard !clean.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        let u = AVSpeechUtterance(string: clean)
        u.voice = Self.voice(for: Self.language(for: clean))
        u.rate = Self.rate
        queued.append(u)
        synth.speak(u)
    }
    func stop() {
        queued.removeAll()
        synth.stopSpeaking(at: .immediate)
    }

    func speechSynthesizer(_ s: AVSpeechSynthesizer, didStart u: AVSpeechUtterance) {
        DispatchQueue.main.async { if self.queued.contains(where: { $0 === u }) { self.onStart?() } }
    }
    func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish u: AVSpeechUtterance) { done(u) }
    func speechSynthesizer(_ s: AVSpeechSynthesizer, didCancel u: AVSpeechUtterance) { done(u) }
    private func done(_ u: AVSpeechUtterance) {
        DispatchQueue.main.async {
            guard let i = self.queued.firstIndex(where: { $0 === u }) else { return }
            self.queued.remove(at: i)
            guard self.queued.isEmpty else { return }
            self.onIdle?()
        }
    }

    /// 有漢字：照介面語言念國語（繁中介面用台灣的聲音）；其他文字先認文字系統（日文假名、韓文…），
    /// 拉丁字母再用系統的語言辨識（西班牙文、法文…以前一律 en-US，假名也念錯）；認不出＝英文
    static func language(for text: String) -> String {
        let scalars = Array(text.unicodeScalars)
        func has(_ r: ClosedRange<UInt32>) -> Bool { scalars.contains { r.contains($0.value) } }
        if has(0x3040...0x30FF) || has(0x31F0...0x31FF) { return "ja-JP" }   // 平假名＋片假名（比漢字先判：日文也有漢字）
        if has(0x4E00...0x9FFF) { return L10n.language == .zhHans ? "zh-CN" : "zh-TW" }
        if has(0xAC00...0xD7AF) { return "ko-KR" }        // 諺文
        if has(0x0400...0x04FF) { return "ru-RU" }        // 西里爾
        if has(0x0370...0x03FF) { return "el-GR" }        // 希臘
        if has(0x0590...0x05FF) { return "he-IL" }        // 希伯來
        if has(0x0600...0x06FF) { return "ar-SA" }        // 阿拉伯
        if has(0x0E00...0x0E7F) { return "th-TH" }        // 泰文
        if has(0x0900...0x097F) { return "hi-IN" }        // 天城文
        guard let lang = NLLanguageRecognizer.dominantLanguage(for: text)?.rawValue else { return "en-US" }
        return ["es": "es-ES", "fr": "fr-FR", "de": "de-DE", "it": "it-IT", "pt": "pt-BR", "nl": "nl-NL", "pl": "pl-PL", "tr": "tr-TR",
                "vi": "vi-VN", "id": "id-ID", "sv": "sv-SE", "da": "da-DK", "nb": "nb-NO", "fi": "fi-FI", "cs": "cs-CZ", "ro": "ro-RO"][lang] ?? "en-US"
    }

    private static var voices: [String: AVSpeechSynthesisVoice] = [:]
    static func voice(for lang: String) -> AVSpeechSynthesisVoice? {
        if let v = ClioSpeechVoices.chosen(for: lang) { return v }   // 2.0 P10：你挑的那個
        if let v = voices[lang] { return v }
        let ok = AVSpeechSynthesisVoice.speechVoices().filter {
            $0.language == lang && !$0.voiceTraits.contains(.isNoveltyVoice) && !$0.voiceTraits.contains(.isPersonalVoice)
        }
        let best = ok.filter { $0.quality != .default }.max { $0.quality.rawValue < $1.quality.rawValue }
        let v = best ?? AVSpeechSynthesisVoice(language: lang)
        voices[lang] = v
        return v
    }
}

// MARK: - 文字輸入（桌寵旁邊的原生小框）

final class ClioInputModel: ObservableObject {
    @Published var text = ""
    @Published var phase = ClioSnapshot.Phase.idle
    @Published var confirm: String?
    var onSend: ((String) -> Void)?
    var onConfirm: ((Bool) -> Void)?
    var onStop: (() -> Void)?
}

struct ClioInputView: View {
    @ObservedObject var model: ClioInputModel
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if model.phase == .confirm, let c = model.confirm {
                Text(c).font(.callout).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Spacer()
                    Button(L("clio.chip.cancel", "取消")) { model.onConfirm?(false) }
                    Button(L("clio.chip.ok", "好")) { model.onConfirm?(true) }.keyboardShortcut(.defaultAction)
                }
            }
            HStack(spacing: 8) {
                TextField(L("clio.input.placeholder", "问 ClioTalk…"), text: $model.text)
                    .textFieldStyle(.roundedBorder)
                    .focused($focused)
                    .onSubmit(send)
                    .frame(width: 280)
                if model.phase == .thinking || model.phase == .streaming {
                    Button { model.onStop?() } label: { Image(systemName: "stop.circle.fill").font(.title2) }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                        .help(L("clio.chip.stop", "停止"))
                } else {
                    Button(action: send) { Image(systemName: "arrow.up.circle.fill").font(.title2) }
                        .buttonStyle(.plain).foregroundStyle(model.text.isEmpty ? Color.secondary : Color.accentColor)
                        .disabled(model.text.trimmingCharacters(in: .whitespaces).isEmpty)
                        .help(L("clio.input.send", "发送"))
                }
            }
        }
        .padding(12)
        .onAppear { focused = true }
    }

    private func send() {
        let t = model.text
        guard !t.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        model.text = ""
        model.onSend?(t)
    }
}

// MARK: - 右鍵選單

extension PetView {
    @objc func menuClioTalk() { ClioTalkController.shared.open(from: self) }
}

// MARK: - 畫在螢幕上

extension Face {
    func tickClioTalk(_ now: Double, _ dt: Double) -> Bool {
        let a = ClioTalkPanel.alpha
        if ClioTalkPanel.demo != nil { if a < 1 { ClioTalkPanel.alpha = 1; ClioTalkPanel.entering = true; return true }; return false }
        let target: CGFloat = ClioTalkPanel.active ? 1 : 0
        let na = ClioTalkPanel.nextAlpha(a, target: target, dt: dt)
        if na != a { ClioTalkPanel.entering = na > a }
        ClioTalkPanel.alpha = na
        if na == 0 { if a != 0 { ClioTalkPanel.buttons = [] }; return a != 0 }
        let p = ClioTalkPanel.snapshot.phase
        ClioTalkController.shared.voice.tick()   // 2.0 語音：跟進倒數、沒開口逾時
        let moving = p == .thinking || p == .streaming || now - ClioTalkPanel.pressAt < 0.3 || ClioTalkPanel.voiceAnimating
            || now - ClioTalkPanel.openedAt < 0.8 || now - ClioTalkPanel.revealAt < 0.8   // 2.0 R9：滴下來、逐行浮現
        return na != a || (moving && now - ClioTalkPanel.lastDraw >= 1.0 / 30)
    }

    func drawClioTalk(_ g: CGContext, _ now: Double) {
        let a = ClioTalkPanel.alpha
        guard a > 0.003 else { ClioTalkPanel.backdrop = nil; return }
        HPAX.enter("clio")   // 2.0 P05：之後記的字與按鈕屬於這張卡（Design/HPAccessibility.swift）
        ClioTalkPanel.lastDraw = now
        let s = ClioTalkPanel.snapshot
        let P = ClioTalkPanel.self
        // 2.0 R9：時間軸（影片 v1 0:21.60→21.81：膠囊收成水滴、錶面模糊轉淺色 0.21 s；白幕停 0.4 s；答案逐行 0.03 s）
        let t = CGFloat(HPMotion.frozen("cliodrop") ?? (now - P.openedAt))
        // 底下的畫面：打開那一刻拍下來（之後不必每幀模糊整面）
        if P.backdrop == nil, let shot = g.makeImage() {
            let ci = CIImage(cgImage: shot)
            let blurred = ci.clampedToExtent().applyingGaussianBlur(sigma: Double(shot.width) / 1024 * 40).cropped(to: ci.extent)
            P.backdrop = (shot, Face.ciContext.createCGImage(blurred, from: ci.extent) ?? shot)
            // 動效包（ClioTalk drip union，外殼那一半）：主畫面／App 上的膠囊是頂端藥丸（有 Live Activity 時是長大的那顆）——
            // 一樣挖掉、由珠接手，不在清楚的底圖裡留第二顆
            P.islandFrom = shellCoversFace ? Shell.pillRect(Shell.pillT) : islandRect.map { ir in
                let ch = ir.height / 1.9, cw = max(ch, ir.width - 1.2 * ch)
                return CGRect(x: ir.midX - cw / 2, y: ir.midY - ch / 2, width: cw, height: ch)
            }
        }
        // 2.0 第五輪：1988 年代用 System 6 的 1-bit 視窗畫同一份回答（ClioTalk1988.swift）
        if isSystem6Era {
            drawClioTalk1988(g, now, s, t: t)
            return
        }
        Clio1988Menu.live = false   // 第六輪：2026 的卡片不接 1988 選單的點擊
        let full = CGRect(x: 0, y: 0, width: 1024, height: 1024)
        let w = P.progress(P.dropSpring, t)       // 模糊＋轉淺色、膠囊到頂、水滴滴下來，同一條彈簧
        g.saveGState()
        defer { g.restoreGState() }
        if !ClioTalkPanel.entering { g.setAlpha(a) }   // 收起：整層淡出
        if let b = P.backdrop {
            g.saveGState()
            g.setAlpha(ClioTalkPanel.entering ? 1 : a); drawUpright(g, b.blurred, in: full)
            // 清楚的那張在上面淡掉；原本眼睛膠囊那一塊挖掉（膠囊正在往頂端走，不留第二顆）
            g.setAlpha((ClioTalkPanel.entering ? 1 : a) * (1 - w))
            if let ir = P.islandFrom {
                let cap = ir.insetBy(dx: -6, dy: -6)
                g.addRect(full); g.addPath(CGPath(roundedRect: cap, cornerWidth: cap.height / 2, cornerHeight: cap.height / 2, transform: nil))
                g.clip(using: .evenOdd)
            }
            drawUpright(g, b.sharp, in: full)
            g.restoreGState()
        }
        // 第三輪：回答的底是純白（官方 #FFFFFF），完全蓋住模糊的錶面
        g.saveGState(); g.setAlpha((ClioTalkPanel.entering ? 1 : a) * w)
        g.setFillColor(HPTokens.Assistant.bg.cgColor); g.fill(full)
        g.restoreGState()

        // 第三輪：👀 膠囊本身就是珠——從錶面上的位置走到官方珠的位置、收成正圓、換上黑色玻璃珠的材質；眼睛照舊（不改樣子）
        let A = HPTokens.Assistant.self
        let voice = ClioTalkPanel.voiceView(s, now)
        let think: CGFloat = voice.screen == .thinking ? P.progress(HPMotion.T.clioThink.spring, CGFloat(now - voice.thinkAt)) : 0
        let diameter = voice.screen == .card ? A.orbDiameter : A.listenDiameter + (A.orbDiameter - A.listenDiameter) * think
        let wv = t > 0 && !HPMotion.reduceMotion ? P.dropSpring.value(from: 0, to: 1, velocity: 0, t: t).v : 0   // 動效包：水滴的速度（拉長用）
        let bead = drawClioOrb(g, now, w: w, diameter: diameter, from: P.islandFrom ?? Shell.pillRect(0),
                               busy: s.phase == .thinking || s.phase == .streaming || voice.screen == .thinking, speed: wv)
        // 聆聽中：右上 14 px 橘色麥克風點（跟 iOS 的錄音指示同一個語言）
        if voice.screen == .listening || ClioTalkController.shared.voice.loop.micOpen {
            let c = Screen.cornerCapsuleCenter(.topRight, width: 88, height: 88)
            g.setFillColor(HPTokens.orange.cgColor); g.fillEllipse(in: CGRect(x: c.x - 7, y: c.y - 7, width: 14, height: 14))
        }
        if voice.screen != .card { drawClioListening(g, now, voice, top: bead.maxY); return }

        let ink = HPTokens.label, gray = HPTokens.secondary, bubble = HPTokens.fill
        let left = A.textLeft, right = A.textRight, width = right - left
        let busy = s.phase == .thinking || s.phase == .streaming
        let orbHit: CGRect? = bead.insetBy(dx: -14, dy: -14)   // 點珠＝用說的問

        // 回答的進場：白幕停 0.4 s 才開始；之後每行晚 0.03 s、卡片晚 0.1 s、按鈕晚 0.3 s
        let key = "\(s.phase)|\(s.answer.prefix(24))|\(s.confirm ?? "")|\(s.error ?? "")"
        // 影片 v1：21.626 開始轉白、21.81 全白、22.21 第一行出現 → 打開後 0.58 s
        if key != P.revealKey { P.revealKey = key; P.revealAt = P.demo != nil ? P.openedAt + P.hold : max(now, P.openedAt + P.hold) }
        let rt = CGFloat(HPMotion.frozen("cliodrop").map { $0 - P.hold } ?? (now - P.revealAt))
        var lineIndex = 0
        func lineP() -> CGFloat { defer { lineIndex += 1 }; return P.progress(P.lineSpring, rt - 0.03 * CGFloat(lineIndex)) }

        // 第一行基線（官方大寫頂 154）；上一輪、問題泡泡在它上面多佔的空間往下推
        var baseline = A.firstBaseline
        // 頂端：上一輪縮成一行
        if let prev = s.previous, !prev.isEmpty {
            let f = HPType.sf(HPType.Size.list, .regular)
            let line = Self.clipped(prev + " ▸", f, width)
            let yy = baseline - 20   // 珠下緣 124 之下留空
            drawRevealed(g, lineP(), CGRect(x: left, y: yy - 44, width: width, height: 60)) { c in self.drawLeft(c, line, font: f, x: left, y: yy, color: gray) }
            baseline += 54
        }
        // 你說的話：官方的回答畫面不顯示問題，只在還沒有回答時（在想、出錯）留著右邊灰泡泡
        if !s.question.isEmpty, s.answer.isEmpty || s.phase == .error {
            let f = HPType.sf(44, .regular)
            let line = Self.clipped(s.question, f, 720 - 64)
            let bw = Typo.width(line, f) + 64
            let r = CGRect(x: right - bw, y: baseline - 52, width: bw, height: 92)
            HPAX.note(g, r, .text, String(format: L("a11y.clio.question", "你问：%@"), s.question))   // 2.0 P05
            drawRevealed(g, lineP(), r) { c in
                c.setFillColor(bubble.cgColor)
                c.addPath(CGPath(roundedRect: r, cornerWidth: 46, cornerHeight: 46, transform: nil)); c.fillPath()
                self.drawLeft(c, line, font: f, x: r.minX + 32, y: r.midY + 15, color: ink)
            }
            baseline = r.maxY + 34 + 50
        }

        // 一段話先講結論（重點詞 **粗體**）；其餘每行「日期：內容 · 時間」→ 日期分區標題＋膠囊列
        var headline = ""
        var details: [String] = []
        switch s.phase {
        case .error: headline = s.error ?? ""
        case .thinking where s.answer.isEmpty: headline = ""
        case .idle where s.answer.isEmpty: headline = L("clio.empty", "想知道什么，或要做什么？")   // 第五輪：空狀態
        default:
            let body = s.phase == .confirm ? s.confirm ?? "" : s.answer
            let lines = body.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            headline = lines.first ?? ""
            details = Array(lines.dropFirst())
        }
        // 第五輪：確認時物件卡就是那份草稿，不再另外排資料列（念出來的照舊是完整的那句）
        if s.phase == .confirm, let h = s.handoff {
            details = []
            if h.kind == .message { headline = L("clio.confirm.message", "要传这则信息吗？") }
        }
        var lastBaseline = baseline - A.lineHeight
        if headline.isEmpty && busy {
            // 還沒有字：三個點像波一樣依次亮起
            for i in 0..<3 {
                let wv = max(0, sin((now * 1.1 - Double(i) * 0.18) * 2 * .pi))
                g.setFillColor(gray.withAlphaComponent(0.25 + 0.6 * CGFloat(wv * wv)).cgColor)
                g.fillEllipse(in: CGRect(x: left + 4 + CGFloat(i) * 52, y: baseline - 30 - CGFloat(wv * wv) * 6, width: 30, height: 30))
            }
            lastBaseline = baseline
        } else if !headline.isEmpty {
            let size = HPType.Size.answer
            // 2.0 P05：大字時行數照放得下的算（不跑出螢幕底；念的時候照樣念全文）
            let fit = max(2, Int((1024 - A.actionsBottom - 150 - baseline) / (A.lineHeight * HPType.textScale)) + 1)
            let maxLines = min(details.isEmpty ? 9 : 3, fit)
            HPAX.note(g, CGRect(x: left, y: baseline - 60 * HPType.textScale, width: width,
                                height: CGFloat(HPType.richWrap(headline, size: size, width: width, maxLines: maxLines).count) * A.lineHeight * HPType.textScale),
                      .text, headline)   // 2.0 P05：回答讓 VoiceOver 念（重點詞的 ** 拿掉）
            for l in HPType.richWrap(headline, size: size, width: width, maxLines: maxLines) {
                let yy = baseline
                drawRevealed(g, lineP(), CGRect(x: left, y: yy - 60, width: width, height: 80)) { c in
                    HPComponents.drawRich(c, self, l, size: size, x: left, y: yy, color: ink)
                }
                lastBaseline = baseline
                baseline += A.lineHeight * HPType.textScale   // 2.0 P05：大字時行距跟著放大
            }
        }
        let cardsAt = rt - 0.1 - 0.03 * CGFloat(max(0, lineIndex - 1))
        var y = lastBaseline   // 現在排到哪：上一段字的基線，或上一條膠囊列的下緣
        var afterRow = false
        let calendar = s.source == ClioToolGroup.calendar.source
        let hf = HPType.sf(HPType.Size.answerHeader, .semibold)
        for (i, d) in details.prefix(4).enumerated() {
            let (label, value) = Self.splitDetail(d)
            let row = Self.splitRow(value)
            let p = P.progress(P.lineSpring, cardsAt - 0.03 * CGFloat(i))
            if let label {
                let hb = y + (afterRow ? A.headerAfterRow : A.headerAfterText)
                HPAX.note(g, CGRect(x: A.headerLeft, y: hb - 40, width: width, height: 54), .heading, label)   // 2.0 P05：日期分區標題也念
                drawRevealed(g, p, CGRect(x: A.headerLeft, y: hb - 40, width: width, height: 54), blur: false) { c in
                    self.drawLeft(c, Self.clipped(label, hf, width), font: hf, x: A.headerLeft, y: hb, color: ink)
                }
                y = hb + A.rowAfterHeader
            } else {
                y += afterRow ? 20 : 40
            }
            let timed = calendar && row.trailing.map { $0.contains { $0.isNumber } } == true
            let style: HPComponents.CapsuleRowStyle = !calendar ? .plain : timed ? .timed : .allDay
            let h = HPComponents.capsuleRowHeight(title: row.title, subtitle: timed ? row.trailing : nil, trailing: timed ? nil : row.trailing,
                                                  width: 1024 - 2 * A.rowInset)   // 2.0 P05：預設 113／135，大字時跟著換行長高
            guard y < 1024 else { break }
            let r = CGRect(x: A.rowInset, y: y, width: 1024 - 2 * A.rowInset, height: h)
            drawRevealed(g, p, r, blur: false) { c in
                HPComponents.capsuleRow(c, self, r, title: row.title, subtitle: timed ? row.trailing : nil, trailing: timed ? nil : row.trailing, style: style)
            }
            y = r.maxY
            afterRow = true
        }
        // 第五輪：交給 App 的物件卡（內文或最後一列底下）；來源晶片排在它後面，模型照舊最後
        if let h = s.handoff, !(headline.isEmpty && busy) {
            let top = afterRow ? y + 30 : y + 50
            let r = CGRect(x: A.rowInset, y: top, width: 1024 - 2 * A.rowInset, height: h.detail.isEmpty ? 140 : 176)
            if r.maxY < 1024 - A.actionsBottom - 88 || s.phase != .confirm {
                drawRevealed(g, P.progress(P.lineSpring, cardsAt), r, blur: false) { c in self.drawClioHandoffCard(c, h, top: top) }
                y = r.maxY - 19
                afterRow = true
            }
        }
        // 來源晶片（「Wikipedia」「+3」）＋回答的模型：內文（或最後一列）底下；再下面是圖片卡
        var chipTitles: [String] = []
        if let first = s.sources.first { chipTitles.append(first); if s.sources.count > 1 { chipTitles.append("+\(s.sources.count - 1)") } }
        else if let src = s.source { chipTitles.append(src) }
        if s.phase != .error, !s.model.isEmpty { chipTitles.append(s.model) }
        if !(headline.isEmpty && busy), !chipTitles.isEmpty {
            let cy = afterRow ? y + 40 : y + A.chipAfterText
            let cp = P.progress(P.lineSpring, cardsAt)
            if cy < 1024 {
                drawRevealed(g, cp, CGRect(x: left, y: cy, width: width, height: A.chipHeight), blur: false) { c in
                    var cx = left - 1
                    for t in chipTitles { cx = HPComponents.sourceChip(c, self, x: cx, y: cy, t).maxX + A.chipGap }
                }
            }
            y = cy + A.chipHeight
            if s.demoImage {
                let r = CGRect(x: A.rowInset, y: y + A.cardAfterChips, width: 1024 - 2 * A.rowInset, height: 1024 - (y + A.cardAfterChips) + 60)
                drawRevealed(g, P.progress(P.lineSpring, cardsAt - 0.03), r, blur: false) { c in self.drawClioDemoImage(c, r) }
            }
        }

        // 跟進的膠囊（高 88：點得到）：浮在最底的系統玻璃（控制層蓋在內容上，照 iOS 的浮動工具列），置中；主要動作染藍、白字
        var buttons: [(ClioTalkPanel.Chip, CGRect)] = orbHit.map { [(.listen, $0)] } ?? []
        let cf = HPType.sf(HPType.Size.button + 4, .semibold)
        let bp = P.progress(P.lineSpring, rt - CGFloat(HPMotion.T.clioButtonDelay))   // 按鈕晚 0.3 s，玻璃 materialize（不是淡入）
        // 狀態說明（在想、要你說「好」、出錯、跟進倒數）：已經有回答時不佔位（「留下」鈕本身就說明回答是暫時的）
        var status: String?
        switch s.phase {
        case .thinking: status = s.note ?? L("clio.status.thinking", "正在想…")
        case .streaming: status = L("clio.status.answering", "正在回答…")
        case .confirm: status = L("clio.status.confirm", "你说「好」才会做")
        case .error: status = L("clio.status.error", "没有完成")
        case .idle: status = s.answer.isEmpty ? (ClioTalkController.keyMissing ? L("clio.status.noModel", "还没连接模型 · 到「设置 › ClioTalk」接上") : L("clio.status.ready", "按住 F5 或点这里问")) : s.kept ? L("clio.status.kept", "已留下 · 存在这台 Mac") : nil
        }
        if let left = voice.followUp { status = String(format: L("clio.status.followUp", "还在听…（%d 秒）"), left) }
        else if let n = voice.notice, s.phase != .thinking, s.phase != .streaming { status = n }
        let chipsTop = 1024 - A.actionsBottom - 88 - (status == nil ? 0 : 64)
        // 2.0 P04：想的時候「停止」鈕前面轉圈（busy 狀態；標籤仍是「停止」，因為點它就是取消）
        let busyLead: CGFloat = 46
        var items = ClioTalkPanel.chips(for: s).map { ($0.0, $0.1, Typo.width($0.1, cf) + 72 + ($0.0 == .stop ? busyLead : 0)) }
        // 第四輪（使用者決定 #1）：已經有回答時畫面完全照官方——只有 👀 珠＋內容，沒有按鈕；
        // 「留下」「想深一點」用說的、點珠＝繼續問。第一次出現回答時底部淡淡一行提示一次（ClioAnswerCommands.swift）
        var hint: String?
        if s.phase == .idle, !s.answer.isEmpty {
            items = []
            let showHint = ClioTalkPanel.demo != nil ? !OfficialDemo.on && ClioTalkPanel.demo != "cyanotype" : ClioAnswerCommand.hint(for: s.answer)
            if status == nil, showHint { hint = ClioAnswerCommand.hintText }
        }
        var x = 512 - (items.map(\.2).reduce(0, +) + CGFloat(max(0, items.count - 1)) * 20) / 2
        for (chip, title, cw) in items {
            let r = CGRect(x: x, y: chipsTop, width: cw, height: 88)
            let primary = chip == .ok
            let busyChip = chip == .stop
            HPGlass.addCapsule(r, tint: primary ? HPTokens.blue : nil, interactive: true, presence: bp) { [weak self] c in
                if busyChip { HPComponents.spinner(c, in: CGRect(x: r.minX + 36, y: r.midY - 16, width: 32, height: 32), ink: HPGlass.ink) }
                self?.drawLeft(c, title, font: cf, x: r.minX + 36 + (busyChip ? busyLead : 0), y: r.midY + 14, color: primary ? .white : HPGlass.ink)
            }
            buttons.append((chip, r))
            x = r.maxX + 20
        }
        HPGlass.flush(g, face: self, now: now)
        ClioTalkPanel.buttons = buttons

        // 一次性的語音提示：淡淡一行、置中，不帶點點（內容在它上面照樣排滿）
        if let hint {
            let hf = HPType.fitted(hint, size: HPType.Size.caption, weight: .medium, maxWidth: 1024 - 2 * A.rowInset - 40)
            let tw = Typo.width(hint, hf)
            g.saveGState(); g.setAlpha(bp)
            let band = CGRect(x: 0, y: 1024 - A.actionsBottom - 70, width: 1024, height: A.actionsBottom + 70)
            // 底下若有內容：先鋪一條往上淡掉的底色，字才讀得到
            let cs = CGColorSpace(name: CGColorSpace.sRGB)
            let fade = CGGradient(colorsSpace: cs, colors: [HPTokens.Assistant.bg.withAlphaComponent(0).cgColor, HPTokens.Assistant.bg.withAlphaComponent(0.92).cgColor] as CFArray, locations: [0, 0.6])!
            g.drawLinearGradient(fade, start: CGPoint(x: 0, y: band.minY), end: CGPoint(x: 0, y: band.maxY), options: [])
            drawLeft(g, hint, font: hf, x: 512 - tw / 2, y: 1024 - A.actionsBottom - 14, color: HPTokens.tertiary)
            g.restoreGState()
        }
        // 最底一行狀態（沒有底色條；點點＋次要字，置中）
        guard let status else { return }
        g.saveGState(); g.setAlpha(bp)
        let dotColor = s.phase == .error ? HPTokens.red : HPTokens.purple
        let sf = HPType.sf(HPType.Size.secondary + 2, .semibold)
        let tw = Typo.width(status, sf)
        let total = 24 + 18 + tw, by = 1024 - A.actionsBottom - 18
        HPAX.note(g, CGRect(x: 512 - total / 2, y: by - sf.ascender - 8, width: total, height: sf.ascender + 24), .text, status)   // 2.0 P05
        let pulse = busy || voice.followUp != nil ? 0.6 + 0.4 * CGFloat(abs(sin(now * 2.2))) : 1
        g.setFillColor(dotColor.withAlphaComponent(pulse).cgColor)
        g.fillEllipse(in: CGRect(x: 512 - total / 2, y: by - 12 - sf.capHeight / 2, width: 24, height: 24))
        drawLeft(g, status, font: sf, x: 512 - total / 2 + 42, y: by, color: HPTokens.secondary)
        g.restoreGState()
    }

    /// 第三輪：👀 膠囊變成助理的珠。w 0…1：從 from（錶面上的眼睛膠囊或頂端藥丸）走到官方珠的位置、收成直徑 diameter 的正圓，
    /// 膠囊的年代材質淡出、黑色玻璃珠淡入；眼睛一直是同一對 👀，只跟著縮放。回傳珠最後的框（點它＝用說的問）
    @discardableResult
    func drawClioOrb(_ g: CGContext, _ now: Double, w: CGFloat, diameter: CGFloat, from cap: CGRect, busy: Bool, speed: CGFloat = 0) -> CGRect {
        let A = HPTokens.Assistant.self
        let breathe: CGFloat = busy && !HPMotion.reduceMotion ? 1 + 0.035 * CGFloat(sin(now * 4)) : 1   // 在想：珠輕輕地呼吸
        let d = diameter * breathe
        let target = CGRect(x: A.orbCenter.x - d / 2, y: A.orbTop + (diameter - d) / 2, width: d, height: d)
        // 動效包：減少動態效果時不移動——膠囊在原地淡掉、珠在終點淡入
        let still = HPMotion.reduceMotion
        var r = still ? target : Shell.lerp(cap, target, w)
        if !still, w < 0.999 { r = HPDrip.stretch(r, velocity: speed) }   // 在飛的時候沿運動方向拉長一點，停下來正圓（Mark View R3）
        var path = CGPath(roundedRect: r, cornerWidth: min(r.width, r.height) / 2, cornerHeight: min(r.width, r.height) / 2, transform: nil)
        // 動效包（ClioTalk drip union）：膠囊留在原處、被水滴拉走而縮小；兩者還近的時候長出一段頸子（smooth union），拉開就斷
        let look = capsuleLook() == .system ? .black : capsuleLook()
        let rest = still ? .zero : HPDrip.residual(cap, w: w)
        if !still, w < 0.999, rest.width > 2, let u = HPDrip.union(rest, r, merge: HPDrip.merge) { path = u }
        if w < 0.999 {
            g.saveGState(); g.setAlpha(1 - w); g.beginTransparencyLayer(auxiliaryInfo: nil)
            if still { drawCapsuleBody(g, cap, look: look, animating: true) } else {
                drawCapsuleBody(g, r, look: look, animating: true)
                if rest.width > 2 {   // 留在原處的那一截＋頸子：同一個年代材質
                    drawCapsuleBody(g, rest, look: look, animating: true)
                    g.saveGState(); g.addPath(path); g.clip(); drawCapsuleBody(g, rest.union(r), look: look, animating: true); g.restoreGState()
                }
            }
            g.endTransparencyLayer(); g.restoreGState()
        }
        HPComponents.assistantOrb(g, r, shape: path, alpha: w)
        // 眼睛：膠囊上的大小（高 ÷ 156）→ 珠裡的大小（直徑 103 時 0.5，跟頂端藥丸一樣大）
        let k0 = cap.height / 156, k1 = 0.5 * d / A.orbDiameter
        let k = k0 + (k1 - k0) * w
        let bf = blinkFactor(now)
        for side: CGFloat in [-1, 1] { drawEye(g, cx: r.midX + side * cur.sep * k, cy: r.midY, side: side, blinkF: bf, k: k) }
        let eyes = r.insetBy(dx: -12, dy: -10)
        islandRectBuilding = islandRectBuilding.map { $0.union(eyes) } ?? eyes
        return CGRect(x: A.orbCenter.x - diameter / 2, y: A.orbTop, width: diameter, height: diameter)
    }

    /// 示範用的圖片卡（--cliotalk-demo cyanotype）：我們自己畫的藍曬圖——普魯士藍底、白色植物線條。不是任何真實照片
    func drawClioDemoImage(_ g: CGContext, _ r: CGRect) {
        g.saveGState()
        g.addPath(continuousRoundedRect(r, radius: HPTokens.Assistant.cardRadius)); g.clip()
        let cs = CGColorSpace(name: CGColorSpace.sRGB)
        let grad = CGGradient(colorsSpace: cs, colors: [srgb(0x0D3278).cgColor, srgb(0x0B3984).cgColor, srgb(0x0A3076).cgColor] as CFArray, locations: [0, 0.5, 1])!
        g.drawLinearGradient(grad, start: CGPoint(x: r.minX, y: r.minY), end: CGPoint(x: r.maxX, y: r.maxY), options: [])
        g.setStrokeColor(NSColor(white: 1, alpha: 0.8).cgColor); g.setLineCap(.round)
        var seed: UInt64 = 0x9E3779B97F4A7C15
        func rnd() -> CGFloat { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return CGFloat(seed >> 33) / CGFloat(UInt64(1) << 31) }
        for i in 0..<9 {
            let bx = r.minX + 60 + CGFloat(i) * (r.width - 120) / 8, by = r.maxY
            g.setLineWidth(2 + rnd() * 2)
            g.move(to: CGPoint(x: bx, y: by))
            g.addCurve(to: CGPoint(x: bx + (rnd() - 0.5) * 160, y: r.minY + 30 + rnd() * 80),
                       control1: CGPoint(x: bx + (rnd() - 0.5) * 120, y: by - 80), control2: CGPoint(x: bx + (rnd() - 0.5) * 200, y: r.minY + 120))
            g.strokePath()
        }
        g.restoreGState()
    }

    /// 一段內容由模糊到清晰、從下面浮上來一點點（p 0…1）；p＝1 直接畫
    func drawRevealed(_ g: CGContext, _ p: CGFloat, _ rect: CGRect, blur: Bool = true, _ body: @escaping (CGContext) -> Void) {
        guard p > 0.005 else { return }
        if p >= 0.995 || HPMotion.reduceMotion {
            g.saveGState(); if p < 0.995 { g.setAlpha(p) }; body(g); g.restoreGState(); return
        }
        let sc = renderPixelScale, pad: CGFloat = 24
        let box = rect.insetBy(dx: -pad, dy: -pad)
        let w = Int((box.width * sc).rounded(.up)), h = Int((box.height * sc).rounded(.up))
        guard w > 2, h > 2 else { return }
        var img = makeImage(w, h) { c in c.scaleBy(x: sc, y: sc); c.translateBy(x: -box.minX, y: -box.minY); body(c) }
        if blur {
            let ci = CIImage(cgImage: img)
            let out = ci.clampedToExtent().applyingGaussianBlur(sigma: Double((1 - p) * 10 * sc)).cropped(to: ci.extent)
            img = Face.ciContext.createCGImage(out, from: ci.extent) ?? img
        }
        g.saveGState(); g.setAlpha(p)
        drawUpright(g, img, in: box.offsetBy(dx: 0, dy: (1 - p) * 10))
        g.restoreGState()
    }

    /// 中英混排折行：英文詞、數字不拆，漢字一個一個排；放不下的最後一行截「…」
    static func clioWrap(_ s: String, _ font: NSFont, _ width: CGFloat, maxLines: Int) -> [String] {
        if Typo.width(s, font) <= width { return [s] }
        var tokens: [String] = [], word = ""
        for ch in s {
            if ch.isASCII && !ch.isWhitespace { word.append(ch); continue }
            if !word.isEmpty { tokens.append(word); word = "" }
            tokens.append(String(ch))
        }
        if !word.isEmpty { tokens.append(word) }
        var lines: [String] = [], cur = ""
        for t in tokens {
            let next = cur + t
            if Typo.width(next, font) <= width || cur.isEmpty { cur = next }
            else {
                // 2.0: 行尾不留開引號、「›」這類要跟著下一個字的符號（l10n-ignore）
                var carry = "", gap = ""
                while cur.last == " " { cur.removeLast(); gap = " " }
                while let last = cur.last, "「『（《“‘›(".contains(last), cur.count > 1 { carry = String(last) + carry; cur.removeLast() }   // l10n-ignore
                if !carry.isEmpty { carry += gap }
                lines.append(cur.trimmingCharacters(in: .whitespaces)); cur = carry + (t == " " ? "" : t)
            }
        }
        if !cur.isEmpty { lines.append(cur) }
        if lines.count > maxLines {
            let rest = lines[(maxLines - 1)...].joined()
            lines = Array(lines[..<(maxLines - 1)]) + [clipped(rest, font, width)]
        }
        return lines
    }

    /// 膠囊列的內容「標題 · 時間或 all-day」→（標題, 右邊／第二行）；沒有「 · 」就只有標題
    static func splitRow(_ s: String) -> (title: String, trailing: String?) {
        guard let r = s.range(of: " · ", options: .backwards), r.lowerBound > s.startIndex else { return (s, nil) }
        let t = String(s[r.upperBound...]).trimmingCharacters(in: .whitespaces)
        return (String(s[..<r.lowerBound]).trimmingCharacters(in: .whitespaces), t.isEmpty ? nil : t)
    }

    /// 「周二 10月27日：生日」→（标签, 内容）；沒有分隔就整行當內容
    static func splitDetail(_ s: String) -> (String?, String) {
        for sep in ["：", ": "] {
            if let r = s.range(of: sep), r.lowerBound > s.startIndex {
                let a = String(s[..<r.lowerBound]).trimmingCharacters(in: .whitespaces)
                let b = String(s[r.upperBound...]).trimmingCharacters(in: .whitespaces)
                if !b.isEmpty, a.count <= 24 { return (a, b) }
            }
        }
        return (nil, s)
    }
}
