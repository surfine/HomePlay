// 動效包：--screen-png 出 30 fps 逐格（--frames N）。
// 用法：HOMEPLAY_ANIM=appopen:0 HOMEPLAY_SHELL_MORPH=calendar .build/release/homeplay-pet --screen-png out.png --frames 12
//   → out-000.png … out-011.png；每格把凍結的時鐘（HOMEPLAY_ANIM 裡每一個名字）往後推 1/30 s，外殼照常 tick 一次再畫。
// 打斷測試：再加 HOMEPLAY_REVERSE=秒（凍結時鐘走到那一刻反向，MotionValue.sample）。減少動態效果：HOMEPLAY_REDUCE_MOTION=1。
// 只拍螢幕平面（不經 RealityKit），跟官方影格並排對照用；不寫偏好、不碰網路。

import AppKit

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
            let img = face.render(now)
            ms.append((CACurrentMediaTime() - r0) * 1000)
            if timeOnly && i < count - 1 { continue }   // 2.0 faceglass：HOMEPLAY_FRAMES_TIME=1 只量每幀的 render（不寫檔，最後一張照寫）
            let path = base + String(format: "-%03d.png", i)
            try? NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        }
        if timeOnly, ms.count > 2 {
            let warm = ms.dropFirst(2).sorted()
            log(String(format: "frames render ms: first %.1f, median %.1f, p90 %.1f, mean %.1f (n=%d)", ms[0], warm[warm.count / 2], warm[min(warm.count - 1, warm.count * 9 / 10)], warm.reduce(0, +) / Double(warm.count), warm.count))
        }
        log("frames \(count) @\(Int(fps)) fps -> \(base)-NNN.png")
    }
}
