import AppKit
import Combine
import RealityKit
import simd
import SwiftUI

// 設定的示範舞台：縮小的即時 3D 機身（機身、錶面與桌布、相機三頁；手勢頁仍是兩格插畫）。
// 規則（設計稿「示範舞台的規則」）：平常是靜止的；改一個值，機身用 300–450 ms 的彈簧示範那個變化一次、可被下一次打斷；
// 視窗被蓋住或換到沒有舞台的分頁就停止並釋放 3D；「減少動態效果」直接顯示結果。
// 做法跟桌寵的「按需 3D」同一招（PetView）：ARView 只在要動的那幾拍掛在視圖裡；停下來就拍一張凍結幀蓋上、
// 把 ARView 卸下（Darwin 27 實測只有卸下才會讓 RealityKit 停止每秒 60 次更新）。
// 機身是自己的一份 HomeViewModel（同一個 USDZ，配色、掛牆照設定）；螢幕貼的是桌寵現在那張錶面。

/// 舞台上的機身要擺成什麼樣子
struct BodyStagePose: Equatable {
    var yaw: Float = 0.52          // 鏡頭繞機身轉的角度（跟桌寵的預設一樣）
    var pitch: Float = 0.26
    var wall = false
    var zoom: Float = 1            // 越大越近（跟著「大小」）
    var finish: Finish = .starlight

    static let front = BodyStagePose(yaw: 0, pitch: 0.12)
}

struct BodyStage: NSViewRepresentable {
    var pose: BodyStagePose
    /// 相機頁：游標在舞台上移動時，機身轉過來看它（左右幅度、俯仰幅度，度）；nil＝不跟
    var follow: (degrees: Double, pitch: Double)? = nil
    /// 錶面換了：加一，舞台重新貼一次桌寵現在的錶面
    var screenToken = 0
    var height: CGFloat = 220
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeNSView(context: Context) -> BodyStageView {
        let v = BodyStageView()
        v.setAccessibilityElement(true)
        v.setAccessibilityRole(.image)
        v.setAccessibilityLabel(L("settings.stage.a11y", "机身示范"))
        update(v)
        return v
    }
    func updateNSView(_ v: BodyStageView, context: Context) { update(v) }
    private func update(_ v: BodyStageView) {
        v.reduceMotion = reduceMotion
        v.follow = follow.map { (Float($0.degrees * .pi / 180), Float($0.pitch * .pi / 180)) }
        v.setPose(pose)
        if v.screenToken != screenToken { v.screenToken = screenToken; v.refreshScreen() }
    }
    static func dismantleNSView(_ v: BodyStageView, coordinator: ()) { v.teardown() }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: BodyStageView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 520, height: height)
    }
}

final class BodyStageView: NSView {
    var reduceMotion = false
    var follow: (Float, Float)?
    var screenToken = 0

    private var target = BodyStagePose()
    private var hasPose = false
    /// 彈簧的現值與速度：鏡頭（yaw、pitch、zoom）與機身轉向（aimYaw、aimPitch）
    private var cur = SIMD4<Float>(0.52, 0.26, 1, 0), vel = SIMD4<Float>(repeating: 0)
    private var aimTarget = SIMD2<Float>(0, 0), aim = SIMD2<Float>(0, 0), aimVel = SIMD2<Float>(0, 0)

    private var arView: ARView?
    private var model: HomeViewModel?
    private var camera: Entity?
    private var updateSub: Cancellable?
    private var updates = 0
    private var tick: Timer?
    private var lastStep = CACurrentMediaTime()
    private var stillSince: Double?
    private var freezing = false
    private var pendingBuild = false
    private var occlusionObserver: Any?
    private let still = NSImageView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        still.imageScaling = .scaleProportionallyUpOrDown
        still.autoresizingMask = [.width, .height]
        still.frame = bounds
        addSubview(still)
    }
    required init?(coder: NSCoder) { fatalError() }

    /// 舞台不接滑鼠點擊（底下的 ARView 也不要吃到）；游標位置用 tracking area 看
    override func hitTest(_ point: NSPoint) -> NSView? { super.hitTest(point) != nil ? self : nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let o = occlusionObserver { NotificationCenter.default.removeObserver(o); occlusionObserver = nil }
        guard let w = window else { teardown(); return }
        occlusionObserver = NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: w, queue: .main) { [weak self] _ in
            self?.occlusionChanged()
        }
        occlusionChanged()
    }
    private var onScreen: Bool { window?.occlusionState.contains(.visible) ?? false }
    private func occlusionChanged() {
        if onScreen { buildSoon() } else { teardown() }   // 被蓋住：停止並釋放 3D，留著最後一張凍結幀
    }

    func setPose(_ p: BodyStagePose) {
        guard !hasPose || p != target else { return }
        let first = !hasPose
        let oldFinish = target.finish, oldWall = target.wall
        target = p; hasPose = true
        if first { cur = SIMD4(p.yaw, p.pitch, p.zoom, 0); vel = .zero }
        if let model {
            if oldFinish != p.finish { model.apply(finish: p.finish) }
            if oldWall != p.wall { model.setWall(p.wall) }
        }
        // 視角差半圈以上走最近的那一邊（背面 ⇄ 正面不繞一大圈）
        let full = 2 * Float.pi
        target.yaw = cur.x + remainder(target.yaw - cur.x, full)
        animate()
    }

    func refreshScreen() {
        guard let model, let img = Self.petScreen() else { return }
        model.setScreen(img)
        animate()
    }
    private static func petScreen() -> CGImage? { (NSApp.delegate as? AppDelegate)?.view?.model.lastScreenImage }

    // MARK: 建立與釋放

    private func buildSoon() {
        guard arView == nil, !pendingBuild else { return }
        pendingBuild = true
        DispatchQueue.main.async { [weak self] in   // 下一拍才載 USDZ：頁面先畫出來
            guard let self else { return }
            self.pendingBuild = false
            if self.onScreen { self.build() }
        }
    }

    private func build() {
        guard arView == nil else { return }
        let m = HomeViewModel()
        let v = ARView(frame: bounds)
        v.autoresizingMask = [.width, .height]
        v.environment.background = .color(.clear)
        if let studio = QuickLookIBL.studio { v.environment.lighting.resource = studio }
        v.__nonARKitDevices = true
        v.__disableComposition = true
        let anchor = AnchorEntity(world: .zero)
        anchor.addChild(m.holder)
        let fill = DirectionalLight()   // 跟桌寵同一盞背光，側面和背板才不會黑掉
        fill.light.intensity = 2000
        fill.light.color = NSColor(calibratedRed: 1.0, green: 0.97, blue: 0.92, alpha: 1)
        fill.look(at: SIMD3<Float>(0, 9, 2), from: SIMD3<Float>(0, 30, -100), relativeTo: nil)
        anchor.addChild(fill)
        v.scene.addAnchor(anchor)
        let cam: Entity? = v.scene.__defaultCamera
        if let cam {
            var pc = cam.components[PerspectiveCameraComponent.self] ?? PerspectiveCameraComponent()
            pc.fieldOfViewInDegrees = 24; pc.near = 1; pc.far = 600
            cam.components.set(pc)
        }
        camera = cam
        m.apply(finish: target.finish)
        if target.wall { m.setWall(true) }
        if let img = Self.petScreen() { m.setScreen(img) }
        updateSub = v.scene.subscribe(to: SceneEvents.Update.self) { [weak self] _ in self?.updates += 1 }
        arView = v; model = m
        cur = SIMD4(target.yaw, target.pitch, target.zoom, 0); vel = .zero
        applyPose()
        animate()
    }

    func teardown() {
        tick?.invalidate(); tick = nil
        updateSub?.cancel(); updateSub = nil
        arView?.scene.anchors.removeAll()
        arView?.removeFromSuperview()
        arView = nil; model = nil; camera = nil
        freezing = false; stillSince = nil
        still.isHidden = false
    }

    // MARK: 動一次、停下來凍結

    /// 有變化：掛回 ARView、開始走彈簧；凍結幀先蓋著，等第 3 次 Update（第一幀確定上屏）才讓開
    private func animate() {
        guard let v = arView else { return }
        if reduceMotion { cur = SIMD4(target.yaw, target.pitch, target.zoom, 0); vel = .zero; aim = follow == nil ? .zero : aimTarget; aimVel = .zero }
        if v.superview == nil {
            v.frame = bounds
            addSubview(v, positioned: .below, relativeTo: still)
            updates = 0
        }
        freezing = false; stillSince = nil
        guard tick == nil else { return }
        lastStep = CACurrentMediaTime()
        let t = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.step() }
        RunLoop.main.add(t, forMode: .common)
        tick = t
    }

    private func step() {
        let now = CACurrentMediaTime()
        let dt = Float(min(0.05, max(0, now - lastStep))); lastStep = now
        // 臨界附近的彈簧（響應 0.38 s，阻尼比 0.9）：300–450 ms 到位，中途換目標照現在的速度接著走
        let k = (2 * Float.pi / 0.38) * (2 * Float.pi / 0.38), c = 2 * 0.9 * k.squareRoot()
        let goal = SIMD4(target.yaw, target.pitch, target.zoom, 0)
        let n = max(1, Int((dt * 120).rounded(.up))), h = dt / Float(n)
        for _ in 0..<n {
            vel += ((goal - cur) * k - vel * c) * h; cur += vel * h
            aimVel += ((aimTarget - aim) * k - aimVel * c) * h; aim += aimVel * h
        }
        let settled = simd_length(goal - cur) < 0.002 && simd_length(vel) < 0.01 && simd_length(aimTarget - aim) < 0.002 && simd_length(aimVel) < 0.01
        if settled { cur = goal; vel = .zero; aim = aimTarget; aimVel = .zero }
        applyPose()
        if updates >= 3 { still.isHidden = true }
        guard settled, updates >= 3 else { return }
        if stillSince == nil { stillSince = now }
        if let s = stillSince, now - s > 0.12 { freeze() }
    }

    private func applyPose() {
        guard let model, let camera else { return }
        model.setAim(yaw: aim.x)
        model.setRig(pitch: aim.y, yaw: 0)
        let wall = target.wall
        let yaw = wall ? 0 : cur.x, pitch = wall ? 0 : cur.y
        let focus = wall ? HomeViewModel.wallScreenCenter : SIMD3<Float>(0, 8.6, 1.8)
        let fitH: Float = wall ? 16.6 : 22
        let aspect = Float(max(1, bounds.width) / max(1, bounds.height))
        let d = (fitH / 2) / tanf(12 * .pi / 180) * max(1, 0.86 / aspect) / max(0.5, cur.z)
        camera.position = focus + SIMD3<Float>(sinf(yaw) * cosf(pitch) * d, sinf(pitch) * d, cosf(yaw) * cosf(pitch) * d)
        camera.orientation = simd_quatf(angle: yaw, axis: SIMD3<Float>(0, 1, 0)) * simd_quatf(angle: -pitch, axis: SIMD3<Float>(1, 0, 0))
    }

    /// 停下來了：拍下這一幀蓋上，卸下 ARView（RealityKit 停止更新）
    private func freeze() {
        guard !freezing, let v = arView else { return }
        freezing = true
        v.snapshot(saveToHDR: false) { [weak self] img in
            guard let self, self.freezing, let v = self.arView else { return }
            if let img { self.still.image = img }
            self.still.isHidden = false
            v.removeFromSuperview()
            self.tick?.invalidate(); self.tick = nil
            self.freezing = false
        }
    }

    // MARK: 相機頁：游標＝你，機身轉過來看你

    private var tracking: NSTrackingArea?
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let t = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(t); tracking = t
    }
    override func mouseMoved(with event: NSEvent) {
        guard let (deg, pitch) = follow, !reduceMotion else { return }   // 減少動態效果：不跟，直接是結果（正對前方）
        let p = convert(event.locationInWindow, from: nil)
        let dx = Float(max(-0.5, min(0.5, p.x / max(1, bounds.width) - 0.5)))
        let dy = Float(max(-0.5, min(0.5, p.y / max(1, bounds.height) - 0.5)))
        aimTarget = SIMD2(dx * 2 * deg, -dy * 2 * pitch)
        animate()
    }
    override func mouseExited(with event: NSEvent) {
        guard aimTarget != .zero else { return }
        aimTarget = .zero
        animate()
    }
}
