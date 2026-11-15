// 動效包：--screen-png 出 30 fps 逐格（--frames N）。
// 用法：HOMEPLAY_ANIM=appopen:0 HOMEPLAY_SHELL_MORPH=calendar .build/release/homeplay-pet --screen-png out.png --frames 12
//   → out-000.png … out-011.png；每格把凍結的時鐘（HOMEPLAY_ANIM 裡每一個名字）往後推 1/30 s，外殼照常 tick 一次再畫。
// 打斷測試：再加 HOMEPLAY_REVERSE=秒（凍結時鐘走到那一刻反向，MotionValue.sample）。減少動態效果：HOMEPLAY_REDUCE_MOTION=1。
// 只拍螢幕平面（不經 RealityKit），跟官方影格並排對照用；不寫偏好、不碰網路。

import AppKit

/// 閘門計帳（回歸 #14 結案、handoff 2026-11-10 W0）：限速的臉不能拿「沒套限速的單幀成本」直接比預算——
/// 照它自己的重畫頻率攤成 60Hz 下的每幀平均：該重畫的幀算成本、被跳過的算 0。
/// flow 有人靠近時 10fps（Face.flowRedrawsPerSecond＝tickFlowFace 的節流）：一秒 60 幀裡 10 幀重畫，每幀平均＝單幀 × 10/60。
/// 沒有限速的臉每幀都重畫，數字不變。verify.sh 的 flow 預算只讀這個攤提後的數字，預算同樣 20ms（不是放寬）。
enum FrameBudget {
    static let displayHz = 60.0
    static func amortizedMS(_ singleFrameMS: Double, redrawsPerSecond: Double) -> Double {
        singleFrameMS * min(displayHz, max(0, redrawsPerSecond)) / displayHz   // 重畫頻率高於顯示頻率＝每幀都畫，不放大
    }
}

enum HPFrames {
    static func run(_ face: Face, out: String, count: Int, fps: Double = 30) {
        let base = out.hasSuffix(".png") ? String(out.dropLast(4)) : out
        let t0 = CACurrentMediaTime()
        // HOMEPLAY_FACE_FLING="x,v"：錶面分頁從跟手放開的那一刻接著走（x＝已經拖了幾成、v＝放手速度，頁／秒），配 HOMEPLAY_ANIM=facepage:0
        if let s = ProcessInfo.processInfo.environment["HOMEPLAY_FACE_FLING"]?.split(separator: ",").compactMap({ Double($0) }), s.count == 2 {
            Face.pageStart = (CGFloat(s[0]), CGFloat(s[1]))
        }
        // HOMEPLAY_TOFACE=1：從現在的外殼畫面回錶面（照片從模糊變清楚），配 HOMEPLAY_ANIM=toface:0
        if ProcessInfo.processInfo.environment["HOMEPLAY_TOFACE"] != nil {
            _ = face.render(t0)
            Shell.nav.screen = .face; Shell.nav.overlay = .none; Face.toFaceDeblur = true; face.beginFaceTransition()
        }
        // HOMEPLAY_FROMFACE=<App id>：從錶面直接進 App（沒有圖示可長；👀 膠囊縮成頂端藥丸，跟 ShellInput 的 .face → .app 同一段），不加 --app/--home
        if let id = ProcessInfo.processInfo.environment["HOMEPLAY_FROMFACE"], AppRegistry.app(id) != nil {
            _ = face.render(t0)
            Shell.captureHomeBackdrop(face.lastFrame)
            if let ir = face.islandRect {
                let ch = ir.height / 1.9, cw = max(ch, ir.width - 1.2 * ch)
                Shell.pillFrom = (CGRect(x: ir.midX - cw / 2, y: ir.midY - ch / 2, width: cw, height: ch), t0)
            }
            Shell.nav.screen = .app(id); Shell.nav.overlay = .none
            AppRegistry.app(id)?.didOpen(now: t0); face.beginFaceTransition()
        }
        // HOMEPLAY_FACE_UP=1：錶面 → 主畫面（霧化過場＋膠囊縮成頂端藥丸，同 ShellInput 的 .up），配 HOMEPLAY_ANIM=homeface:0,pill:0——膠囊下拉過場的 render ms 對照組
        if ProcessInfo.processInfo.environment["HOMEPLAY_FACE_UP"] != nil, Shell.nav.screen == .face {
            _ = face.render(t0)
            Shell.homeHue = Shell.hue(fromFace: face.lastFrame, face: face)
            Shell.captureHomeBackdrop(face.lastFrame)
            if let ir = face.islandRect {
                let ch = ir.height / 1.9, cw = max(ch, ir.width - 1.2 * ch)
                Shell.pillFrom = (CGRect(x: ir.midX - cw / 2, y: ir.midY - ch / 2, width: cw, height: ch), t0)
            }
            Shell.nav.screen = .home; face.beginFaceTransition()
        }
        // HOMEPLAY_LIST_DELETE=1：提醒事項清單（--app reminders --demo-reminders-list）完成第一條，0.9 s 後拿掉——下面的列讓位上來
        if ProcessInfo.processInfo.environment["HOMEPLAY_LIST_DELETE"] != nil {
            _ = face.render(t0)
            let src = ReminderSource.shared
            if let r = src.items.first(where: { !$0.completed && ReminderLogic.matches($0, .today, now: Face.displayDate) }) { src.toggle(r.id, now: t0 - 0.9) }
        }
        let timeOnly = ProcessInfo.processInfo.environment["HOMEPLAY_FRAMES_TIME"] == "1"
        var ms: [Double] = []
        for i in 0..<max(1, count) {
            let dt = Double(i) / fps
            HPMotion.frameOffset = dt
            let now = t0 + dt
            _ = face.tickShell(now, 1 / fps)   // 控制中心、Live Activity、過場的收尾跟著走
            face.forceDirty = true
            let r0 = CACurrentMediaTime()
            let img = CarPlayDemo.render(face, now: now) ?? face.render(now)   // --demo-carplay：CarPlay 畫面上的膠囊逐格
            ms.append((CACurrentMediaTime() - r0) * 1000)
            if timeOnly && i < count - 1 { continue }   // 2.0 faceglass：HOMEPLAY_FRAMES_TIME=1 只量每幀的 render（不寫檔，最後一張照寫）
            let path = base + String(format: "-%03d.png", i)
            try? NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        }
        if timeOnly, ms.count > 2 {
            let warm = ms.dropFirst(2).sorted()
            let med = warm[warm.count / 2]
            log(String(format: "frames render ms: first %.1f, median %.1f, p90 %.1f, mean %.1f (n=%d)", ms[0], med, warm[min(warm.count - 1, warm.count * 9 / 10)], warm.reduce(0, +) / Double(warm.count), warm.count))
            if face.style == .flow {   // 這裡量的是沒套限速的單幀成本；閘門照 tickFlowFace 的 10fps 攤提（verify.sh 的 flow 預算讀這行）
                log(String(format: "frames render ms: flow amortized %.1f (single median %.1f × %.0f/%.0f)",
                           FrameBudget.amortizedMS(med, redrawsPerSecond: Face.flowRedrawsPerSecond), med,
                           Face.flowRedrawsPerSecond, FrameBudget.displayHz))
            }
        }
        log("frames \(count) @\(Int(fps)) fps -> \(base)-NNN.png")
    }
}

// MARK: - selftest

enum HPFramesSelfTest {
    static func run(_ check: (Bool, String) -> Void) {
        // handoff 2026-11-10 W0 的驗收數字：單幀 50ms、10fps 節流 → 8.3ms；16.3ms → 2.7ms
        check(String(format: "%.1f", FrameBudget.amortizedMS(50, redrawsPerSecond: 10)) == "8.3"
              && String(format: "%.1f", FrameBudget.amortizedMS(16.3, redrawsPerSecond: 10)) == "2.7",
              "閘門計帳：限速的臉把單幀成本攤成 60Hz 每幀平均（50ms×10fps→8.3ms；16.3ms→2.7ms）")   // l10n-ignore：selftest 訊息
        check(abs(FrameBudget.amortizedMS(27.4, redrawsPerSecond: FrameBudget.displayHz) - 27.4) < 1e-9
              && abs(FrameBudget.amortizedMS(27.4, redrawsPerSecond: 999) - 27.4) < 1e-9,
              "閘門計帳：沒有限速的臉數字不變（每幀都重畫＝單幀成本，不因頻率高而放大）")   // l10n-ignore
        check(Face.flowRedrawsPerSecond == 10, "閘門計帳：攤提用 tickFlowFace 同一個節流常數（10fps，改節流就跟著改）")   // l10n-ignore
    }
}
