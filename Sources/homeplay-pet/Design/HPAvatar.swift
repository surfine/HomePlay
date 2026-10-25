// HPDS 第四輪：👀 人物頭像——我們自己畫的頭像（取代官方的 Memoji，不用任何官方素材）。
// 彩色圓底＋肩膀＋臉型＋髮型＋膚色，眼睛是 👀 的樣子（白色圓眼、深色瞳孔一起看向一邊）。
// 每個家人都有一個（預設照他的配色序號從 presets 挑一個）；認臉（家人）設定頁可以改，或改用聯絡人照片（只有主人：Contacts 裡的「我」）。
// 用在：主畫面右上、認臉進度環、「換人」小卡、認出誰在看的問候卡、設定裡的家人列表。
// 出圖：homeplay-pet --avatars-png out.png（全部預設＋各個選項一張）。

import AppKit
import SwiftUI

enum HPAvatar {
    struct Style: Codable, Equatable, Hashable, Sendable {
        var background: Int   // backgrounds
        var skin: Int         // skins
        var hair: Int         // Hair.rawValue
        var hairColor: Int    // hairColors
        var face: Int         // FaceShape.rawValue
    }
    enum Hair: Int, CaseIterable { case short, long, bun, curly, buzz, bob, none }
    enum FaceShape: Int, CaseIterable { case round, oval, soft }

    // MARK: 選項（色都是我們配的）
    static let backgrounds: [UInt32] = [0xF6B26B, 0x8EC5FF, 0x9FDDA8, 0xF7A8C8, 0xC3B1F5, 0xF6D776, 0x7FD6CF, 0xFF9C8A]
    static let skins: [UInt32] = [0xFBE0C8, 0xF4C9A3, 0xE0A97E, 0xC68863, 0x9A6444, 0x6E452E]
    static let hairColors: [UInt32] = [0x2B2220, 0x5A3A26, 0x9B6A3C, 0xD9AE62, 0xB4472E, 0x8D8D93, 0x5B4FC4]

    static func backgroundName(_ i: Int) -> String {
        [L("avatar.bg.orange", "橙色"), L("avatar.bg.blue", "蓝色"), L("avatar.bg.green", "绿色"), L("avatar.bg.pink", "粉色"),
         L("avatar.bg.purple", "紫色"), L("avatar.bg.yellow", "黄色"), L("avatar.bg.teal", "青色"), L("avatar.bg.coral", "珊瑚色")][wrap(i, 8)]
    }
    static func skinName(_ i: Int) -> String {
        [L("avatar.skin.1", "很浅"), L("avatar.skin.2", "浅"), L("avatar.skin.3", "中等"), L("avatar.skin.4", "偏深"),
         L("avatar.skin.5", "深"), L("avatar.skin.6", "很深")][wrap(i, 6)]
    }
    static func hairName(_ h: Hair) -> String {
        switch h {
        case .short: return L("avatar.hair.short", "短发")
        case .long: return L("avatar.hair.long", "长发")
        case .bun: return L("avatar.hair.bun", "丸子头")
        case .curly: return L("avatar.hair.curly", "卷发")
        case .buzz: return L("avatar.hair.buzz", "平头")
        case .bob: return L("avatar.hair.bob", "波波头")
        case .none: return L("avatar.hair.none", "光头")
        }
    }
    static func hairColorName(_ i: Int) -> String {
        [L("avatar.hairColor.black", "黑色"), L("avatar.hairColor.brown", "棕色"), L("avatar.hairColor.chestnut", "栗色"),
         L("avatar.hairColor.blonde", "金色"), L("avatar.hairColor.red", "红色"), L("avatar.hairColor.gray", "灰色"),
         L("avatar.hairColor.violet", "紫色")][wrap(i, 7)]
    }
    static func faceName(_ f: FaceShape) -> String {
        switch f {
        case .round: return L("avatar.face.round", "圆脸")
        case .oval: return L("avatar.face.oval", "瓜子脸")
        case .soft: return L("avatar.face.soft", "方圆脸")
        }
    }

    /// 12 個預設組合（彼此都不一樣）
    static let presets: [Style] = [
        Style(background: 0, skin: 1, hair: Hair.short.rawValue, hairColor: 1, face: FaceShape.round.rawValue),
        Style(background: 1, skin: 0, hair: Hair.long.rawValue, hairColor: 3, face: FaceShape.oval.rawValue),
        Style(background: 2, skin: 3, hair: Hair.curly.rawValue, hairColor: 0, face: FaceShape.soft.rawValue),
        Style(background: 3, skin: 2, hair: Hair.bun.rawValue, hairColor: 0, face: FaceShape.round.rawValue),
        Style(background: 4, skin: 4, hair: Hair.buzz.rawValue, hairColor: 0, face: FaceShape.soft.rawValue),
        Style(background: 5, skin: 1, hair: Hair.bob.rawValue, hairColor: 4, face: FaceShape.oval.rawValue),
        Style(background: 6, skin: 5, hair: Hair.short.rawValue, hairColor: 0, face: FaceShape.round.rawValue),
        Style(background: 7, skin: 0, hair: Hair.long.rawValue, hairColor: 1, face: FaceShape.oval.rawValue),
        Style(background: 1, skin: 2, hair: Hair.none.rawValue, hairColor: 5, face: FaceShape.soft.rawValue),
        Style(background: 3, skin: 3, hair: Hair.curly.rawValue, hairColor: 6, face: FaceShape.round.rawValue),
        Style(background: 4, skin: 1, hair: Hair.bob.rawValue, hairColor: 0, face: FaceShape.round.rawValue),
        Style(background: 2, skin: 0, hair: Hair.short.rawValue, hairColor: 5, face: FaceShape.oval.rawValue),
    ]

    static func wrap(_ i: Int, _ n: Int) -> Int { ((i % n) + n) % n }

    /// 這個人的頭像樣式：自己選過的，不然照配色序號挑預設（每個人一開始就不一樣）
    static func style(for p: Person) -> Style { p.avatar ?? presets[wrap(p.colorIndex * 2 + (p.isOwner ? 0 : 1), presets.count)] }

    // MARK: 畫（左上原點、y 往下的畫布）

    static func draw(_ g: CGContext, _ r: CGRect, _ st: Style) {
        let s = r.width
        func p(_ fx: CGFloat, _ fy: CGFloat) -> CGPoint { CGPoint(x: r.minX + s * fx, y: r.minY + s * fy) }
        func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect { CGRect(x: r.minX + s * x, y: r.minY + s * y, width: s * w, height: s * h) }
        let bg = srgb(backgrounds[wrap(st.background, backgrounds.count)])
        let skin = srgb(skins[wrap(st.skin, skins.count)])
        let hairC = srgb(hairColors[wrap(st.hairColor, hairColors.count)])
        let hair = Hair(rawValue: st.hair) ?? .short
        let shape = FaceShape(rawValue: st.face) ?? .round
        let cs = CGColorSpace(name: CGColorSpace.sRGB)
        let shade = skin.blended(withFraction: 0.18, of: srgb(0x7A3B1E)) ?? skin
        g.saveGState()
        g.addEllipse(in: r); g.clip()
        // 底：同色上亮下深
        let top = bg.blended(withFraction: 0.25, of: .white) ?? bg
        let grad = CGGradient(colorsSpace: cs, colors: [top.cgColor, bg.cgColor] as CFArray, locations: [0, 1])!
        g.drawLinearGradient(grad, start: p(0.5, 0), end: p(0.5, 1), options: [])

        // 臉的框
        let head: CGRect
        switch shape {
        case .round: head = rect(0.27, 0.22, 0.46, 0.5)
        case .oval: head = rect(0.29, 0.2, 0.42, 0.53)
        case .soft: head = rect(0.265, 0.23, 0.47, 0.48)
        }
        let headPath: CGPath = shape == .soft ? continuousRoundedRect(head, radius: head.width * 0.36)
            : CGPath(ellipseIn: head, transform: nil)

        // 後面的頭髮（長髮、波波頭、丸子頭的髻）
        g.setFillColor(hairC.cgColor)
        switch hair {
        case .long:
            g.addPath(continuousRoundedRect(CGRect(x: head.minX - s * 0.06, y: head.minY - s * 0.02, width: head.width + s * 0.12, height: head.height * 1.18), radius: s * 0.2)); g.fillPath()
        case .bob:
            g.addPath(continuousRoundedRect(CGRect(x: head.minX - s * 0.055, y: head.minY - s * 0.03, width: head.width + s * 0.11, height: head.height * 0.92), radius: s * 0.2)); g.fillPath()
        case .bun:
            g.fillEllipse(in: CGRect(x: head.midX - s * 0.1, y: head.minY - s * 0.16, width: s * 0.2, height: s * 0.2))
        default: break
        }

        // 肩膀（衣服：底色的深一階）＋脖子
        let shirt = bg.blended(withFraction: 0.35, of: srgb(0x1C1C3A)) ?? bg
        g.setFillColor(shirt.cgColor)
        g.addPath(continuousRoundedRect(rect(0.14, 0.78, 0.72, 0.5), radius: s * 0.26)); g.fillPath()
        g.setFillColor(shade.cgColor)
        g.addPath(continuousRoundedRect(rect(0.425, 0.64, 0.15, 0.17), radius: s * 0.05)); g.fillPath()
        // 耳朵
        g.setFillColor(skin.cgColor)
        for side: CGFloat in [-1, 1] {
            let ex = head.midX + side * head.width * 0.5
            g.fillEllipse(in: CGRect(x: ex - s * 0.045, y: head.midY - s * 0.02, width: s * 0.09, height: s * 0.11))
        }
        // 臉：上亮下帶一點暖
        g.saveGState(); g.addPath(headPath); g.clip()
        let fg = CGGradient(colorsSpace: cs, colors: [(skin.blended(withFraction: 0.12, of: .white) ?? skin).cgColor, skin.cgColor] as CFArray, locations: [0, 1])!
        g.drawLinearGradient(fg, start: CGPoint(x: head.midX, y: head.minY), end: CGPoint(x: head.midX, y: head.maxY), options: [])
        g.restoreGState()

        // 前面的頭髮
        g.setFillColor(hairC.cgColor)
        switch hair {
        case .short, .long, .bob, .bun:
            // 瀏海：頭頂一頂帽子形，往一邊斜
            let cap = CGMutablePath()
            cap.move(to: CGPoint(x: head.minX - s * 0.012, y: head.minY + head.height * 0.42))
            cap.addCurve(to: CGPoint(x: head.midX, y: head.minY - s * 0.035),
                         control1: CGPoint(x: head.minX - s * 0.02, y: head.minY + head.height * 0.05), control2: CGPoint(x: head.minX + head.width * 0.18, y: head.minY - s * 0.035))
            cap.addCurve(to: CGPoint(x: head.maxX + s * 0.012, y: head.minY + head.height * 0.42),
                         control1: CGPoint(x: head.maxX - head.width * 0.18, y: head.minY - s * 0.035), control2: CGPoint(x: head.maxX + s * 0.02, y: head.minY + head.height * 0.05))
            cap.addCurve(to: CGPoint(x: head.minX + head.width * 0.36, y: head.minY + head.height * 0.2),
                         control1: CGPoint(x: head.maxX - head.width * 0.1, y: head.minY + head.height * 0.22), control2: CGPoint(x: head.minX + head.width * 0.6, y: head.minY + head.height * 0.26))
            cap.addCurve(to: CGPoint(x: head.minX - s * 0.012, y: head.minY + head.height * 0.42),
                         control1: CGPoint(x: head.minX + head.width * 0.2, y: head.minY + head.height * 0.18), control2: CGPoint(x: head.minX + head.width * 0.05, y: head.minY + head.height * 0.3))
            cap.closeSubpath()
            g.addPath(cap); g.fillPath()
        case .curly:
            for i in 0..<9 {
                let a = CGFloat.pi * (1.05 + CGFloat(i) / 8 * 0.9)
                let c = CGPoint(x: head.midX + cos(a) * head.width * 0.5, y: head.minY + head.height * 0.36 + sin(a) * head.height * 0.42)
                g.fillEllipse(in: CGRect(x: c.x - s * 0.085, y: c.y - s * 0.085, width: s * 0.17, height: s * 0.17))
            }
        case .buzz:
            g.saveGState(); g.addPath(headPath); g.clip()
            g.setFillColor(hairC.withAlphaComponent(0.85).cgColor)
            g.fillEllipse(in: CGRect(x: head.minX - s * 0.02, y: head.minY - head.height * 0.25, width: head.width + s * 0.04, height: head.height * 0.55))
            g.restoreGState()
        case .none: break
        }

        // 👀：兩顆白色圓眼、深色瞳孔一起看向右下（emoji 的樣子），細細的描邊
        let eyeY = head.minY + head.height * 0.56, eyeW = s * 0.105, eyeH = s * 0.13
        for side: CGFloat in [-1, 1] {
            let cx = head.midX + side * s * 0.085
            let e = CGRect(x: cx - eyeW / 2, y: eyeY - eyeH / 2, width: eyeW, height: eyeH)
            g.setFillColor(NSColor.white.cgColor); g.fillEllipse(in: e)
            g.setStrokeColor(srgb(0x3A2A20, 0.35).cgColor); g.setLineWidth(max(0.6, s * 0.006)); g.strokeEllipse(in: e)
            let pr = eyeW * 0.30
            g.setFillColor(srgb(0x2A1A12).cgColor)
            g.fillEllipse(in: CGRect(x: e.midX + eyeW * 0.12 - pr, y: e.midY + eyeH * 0.12 - pr, width: pr * 2, height: pr * 2))
        }
        // 嘴：小小的笑
        let m = CGMutablePath()
        m.move(to: CGPoint(x: head.midX - s * 0.045, y: head.minY + head.height * 0.8))
        m.addQuadCurve(to: CGPoint(x: head.midX + s * 0.045, y: head.minY + head.height * 0.8), control: CGPoint(x: head.midX, y: head.minY + head.height * 0.86))
        g.addPath(m); g.setStrokeColor(srgb(0x8A3B2A, 0.8).cgColor); g.setLineWidth(max(0.8, s * 0.016)); g.setLineCap(.round); g.strokePath()
        g.restoreGState()
    }

    /// 一張頭像圖（給 SwiftUI 與快取用）
    static func image(_ st: Style, px: Int) -> CGImage? {
        makeImage(px, px) { g in draw(g, CGRect(x: 0, y: 0, width: px, height: px), st) }
    }

    /// 出圖：12 個預設＋各個髮型、臉型（--avatars-png）
    static func writeSheet(_ path: String) {
        let px = 160, gap = 24
        var styles = presets
        for h in Hair.allCases { styles.append(Style(background: h.rawValue, skin: 2, hair: h.rawValue, hairColor: 1, face: 0)) }
        for f in FaceShape.allCases { styles.append(Style(background: 6, skin: f.rawValue * 2, hair: 0, hairColor: 0, face: f.rawValue)) }
        let cols = 6, rows = (styles.count + cols - 1) / cols
        let img = makeImage(cols * (px + gap) + gap, rows * (px + gap) + gap) { g in
            g.setFillColor(NSColor.white.cgColor); g.fill(CGRect(x: 0, y: 0, width: 10000, height: 10000))
            for (i, st) in styles.enumerated() {
                draw(g, CGRect(x: gap + (i % cols) * (px + gap), y: gap + (i / cols) * (px + gap), width: px, height: px), st)
            }
        }
        try? NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
}

// MARK: - 誰的頭像：帳號頭像、聯絡人照片、👀 人物或縮寫（第五輪：來源見 People/AvatarSources.swift）

extension Person {
    /// 這個人現在用照片（帳號頭像或聯絡人「我」）
    var showsContactPhoto: Bool { avatarPhoto != nil }
}

extension Face {
    /// 畫一個家人的頭像（圓，r 是外框）：帳號頭像 → 聯絡人照片 → 縮寫；選了 👀 才畫 👀 人物
    func drawPersonAvatar(_ g: CGContext, _ person: Person, in r: CGRect) {
        if person.isOwner, !Face.demoData {
            AccountPicture.load { [weak self] in self?.forceDirty = true }
            MeCard.load { [weak self] in self?.forceDirty = true }
        }
        if let photo = person.avatarPhoto {
            g.saveGState(); g.addEllipse(in: r); g.clip()
            let s = max(r.width / CGFloat(photo.width), r.height / CGFloat(photo.height))
            let w = CGFloat(photo.width) * s, h = CGFloat(photo.height) * s
            g.interpolationQuality = .high
            drawUpright(g, photo, in: CGRect(x: r.midX - w / 2, y: r.midY - h / 2, width: w, height: h))
            g.restoreGState()
            return
        }
        if person.resolvedAvatar == .eyes { HPAvatar.draw(g, r, HPAvatar.style(for: person)); return }
        Monogram.draw(g, r, initials: AvatarResolver.initials(person.name))
    }
}

/// SwiftUI 的頭像（設定頁）
struct HPAvatarView: View {
    let style: HPAvatar.Style
    var size: CGFloat = 30
    var body: some View {
        let px = Int(size * 2)
        if let img = HPAvatar.image(style, px: px) {
            Image(decorative: img, scale: 2).resizable().frame(width: size, height: size)
        } else {
            Circle().fill(.secondary).frame(width: size, height: size)
        }
    }
}
