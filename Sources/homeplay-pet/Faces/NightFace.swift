// 2.0 逼真化第二輪 R12：暗處的錶面——黑底紅線稿（照官方影片／StandBy 的夜間模式：整面變成單色暗紅，亮的筆畫留下、暗的沉成黑）。
// 「暗處」＝房間光很暗（開了「房間光線」時相機估的強度 < 0.5），或控制中心的「夜間」手動打開（Shell.lowLight）。
// 第四輪：拿掉 22–6 點的時間備援（鏡頭關著就不自動進夜間）；主畫面的小工具與 Live Activity 一起轉紅。
// 錶面畫完、疊任何東西之前整面換色；👀 眼睛膠囊那一塊從原圖貼回來，眼睛永遠是原本的樣子。床頭夜灯本來就是紅的，不動。
// 快照：--night（手動夜間，不存偏好）。

import AppKit
import CoreImage

extension Face {
    var nightRed: Bool {
        guard style != .bedside || Shell.nav.screen == .home, !FaceOverview.active, !Onboarding.active else { return false }
        return nightRedActive
    }
    /// 夜間紅色開著沒（不管錶面種類）：Live Activity、小工具的強調色用
    var nightRedActive: Bool {
        if Shell.appearanceForced && !Theme.dark && !Shell.manualNight { return false }
        return Shell.lowLight(self)
    }
    /// 2.0 P07：這一格錶面在夜間自己畫黑底紅（Modular），不經下面的「亮度→紅」整面映射；
    /// 錶面上後畫的膠囊內容（計時器、正在播放、Live Activity）要直接用 HPTokens.Night 的顏色。
    /// 只看「錶面本身正在畫」：主畫面蓋著的時候（shellCoversFace）內容不是 Modular 的，照常走映射。
    var nightOwnPalette: Bool { nightRed && style == .modular && !shellCoversFace }

    func drawNightFace(_ g: CGContext) {
        guard nightRed else { return }
        if nightOwnPalette { return }   // 2.0 P07：Modular 夜間自畫黑底亮紅（Faces/ModularFace.swift），不再整面換色（也省一次整面讀回）
        guard let shot = g.makeImage() else { return }
        let ci = CIImage(cgImage: shot)
        // 亮度 → 暗紅（Rec.709 亮度），再壓一下中間調：背景沉成黑，只剩亮的線與字
        let lum = ci.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 0.2126, y: 0.7152, z: 0.0722, w: 0),
            "inputGVector": CIVector(x: 0.2126 * 0.10, y: 0.7152 * 0.10, z: 0.0722 * 0.10, w: 0),
            "inputBVector": CIVector(x: 0.2126 * 0.07, y: 0.7152 * 0.07, z: 0.0722 * 0.07, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1)])
            .applyingFilter("CIGammaAdjust", parameters: ["inputPower": 1.8])
        guard let red = Face.ciContext.createCGImage(lum, from: ci.extent) else { return }
        let full = CGRect(x: 0, y: 0, width: 1024, height: 1024)
        g.saveGState()
        g.setFillColor(NSColor.black.cgColor); g.fill(full)
        g.setAlpha(0.92)   // 紅也不要太亮（夜裡不刺眼）
        drawUpright(g, red, in: full)
        g.restoreGState()
        // 眼睛膠囊：原圖貼回來
        if let eyes = shellCoversFace ? LiveActivityStack.homeKeep : (liveT > 0.02 && !Self.timerInTile.contains(style) ? LiveActivityStack.faceKeep : nil) {
            // 2.0 P03：長開的 Live Activity（主畫面與錶面）只貼回兩隻眼睛：膠囊、倒數、圓環、小藥丸、大卡全部轉紅（spec4 #3）
            g.saveGState(); g.addPath(eyes); g.clip(); drawUpright(g, shot, in: full); g.restoreGState()
        } else if let keep = shellCoversFace ? Shell.nightKeep : nil {
            // 長開的 Live Activity：只貼回眼睛那一段（內容跟著轉紅）
            g.saveGState(); g.clip(to: keep); drawUpright(g, shot, in: full); g.restoreGState()
        } else if let ir = islandRectBuilding {
            let ch = ir.height / 1.9, cw = max(ch, ir.width - 1.2 * ch)
            let cap = CGRect(x: ir.midX - cw / 2, y: ir.midY - ch / 2, width: cw, height: ch).insetBy(dx: -2, dy: -2)
            g.saveGState()
            g.addPath(CGPath(roundedRect: cap, cornerWidth: cap.height / 2, cornerHeight: cap.height / 2, transform: nil)); g.clip()
            drawUpright(g, shot, in: full)
            g.restoreGState()
        }
    }
}
