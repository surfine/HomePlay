// 2.0 第五輪 B：頭像從哪裡來（使用者 2026-10-25：「不能用 Memoji 的話就用聯絡人頭像或者當前用戶的 Apple Account 頭像」）。
//
// 預設（「自動」）順序：
// 1) 這台 Mac 目前使用者的帳號頭像（系統設定 › 使用者與群組那張，登入 Apple 帳號時跟 Apple 帳號同步）：
//    Collaboration.framework 的 CBUserIdentity(posixUID:authority:).image（公開 API，不用權限）；
// 2) 聯絡人裡「我」的照片（只在已經允許讀聯絡人時讀，不為了頭像跳權限框；MeCard）；
// 3) Apple 式灰色漸層縮寫圓（跟「聯絡人」App 沒照片時一樣）。
// 👀 人物頭像不再是預設：在認臉（家人）設定裡選「👀 頭像」才用。認出的人不是 Mac 使用者時：他選的 👀 頭像，沒選就縮寫。
// 快照（Face.demoData）不讀帳號頭像與聯絡人照片：截圖裡不會出現真的照片。

import AppKit
import Collaboration

/// 使用者在設定裡選的頭像來源
enum AvatarSource: String, Codable, CaseIterable, Sendable {
    case automatic   // 帳號頭像 → 聯絡人「我」→ 縮寫（非主人：縮寫）
    case contact     // 聯絡人「我」的照片（只有主人；讀不到就照「自動」往下）
    case eyes        // 👀 人物頭像（Design/HPAvatar.swift）
}

/// 實際畫出來的是哪一種
enum AvatarResolved: Equatable, Sendable { case account, meCard, eyes, monogram }

enum AvatarResolver {
    /// 真值表（純函數，selftest 直接測）
    static func resolve(isOwner: Bool, source: AvatarSource, hasAccount: Bool, hasMeCard: Bool) -> AvatarResolved {
        switch source {
        case .eyes: return .eyes
        case .contact where isOwner && hasMeCard: return .meCard
        case .contact, .automatic:
            guard isOwner else { return .monogram }
            if hasAccount { return .account }
            if hasMeCard { return .meCard }
            return .monogram
        }
    }

    /// 名字的縮寫：拉丁字母取名＋姓的頭一個字母（「Erica Lee」→「EL」），其他文字照系統的縮寫規則（中文取名字）；最多 2 個字
    static func initials(_ name: String) -> String {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty else { return "?" }
        let f = PersonNameComponentsFormatter()
        f.style = .abbreviated
        if let c = f.personNameComponents(from: n) {
            let s = f.string(from: c).trimmingCharacters(in: .whitespaces)
            if !s.isEmpty { return String(s.prefix(2)).uppercased() }
        }
        return String(n.prefix(1)).uppercased()
    }
}

/// 這台 Mac 目前使用者的帳號頭像（背景讀一次、快取；讀不到就是 nil）
enum AccountPicture {
    nonisolated(unsafe) static var image: CGImage?
    nonisolated(unsafe) private static var asked = false
    /// 快照、示範、設定截圖：不讀真的照片（截圖裡不會出現本人照片）
    static var blocked: Bool {
        Face.demoData || OfficialDemo.on || ["--snapshot", "--screen-png", "--avatar-editor-png", "--open-settings"].contains { CommandLine.arguments.contains($0) }
    }
    static func load(_ done: @escaping () -> Void) {
        guard !asked, !blocked else { return }
        asked = true
        DispatchQueue.global(qos: .utility).async {
            guard let id = CBUserIdentity(posixUID: getuid(), authority: CBIdentityAuthority.default()),
                  let ns = id.image,
                  let cg = ns.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
            DispatchQueue.main.async { image = cg; done() }
        }
    }
}

extension Person {
    /// 沒選過＝自動；第四輪存的 useContactPhoto＝聯絡人照片
    var effectiveAvatarSource: AvatarSource { avatarSource ?? (useContactPhoto == true ? .contact : .automatic) }
    /// 現在畫得出來的是哪一種（主執行緒；照片還沒讀到時先是下一種，讀到再重畫）
    var resolvedAvatar: AvatarResolved {
        AvatarResolver.resolve(isOwner: isOwner, source: effectiveAvatarSource,
                               hasAccount: AccountPicture.image != nil, hasMeCard: MeCard.photo != nil)
    }
    var avatarPhoto: CGImage? {
        switch resolvedAvatar {
        case .account: return AccountPicture.image
        case .meCard: return MeCard.photo
        default: return nil
        }
    }
}

/// Apple 式縮寫圓：上淺下深的灰色漸層＋白字（量自 iOS 27「聯絡人」沒照片的頭像：#A5AAB6 → #858A96）
enum Monogram {
    static let top: UInt32 = 0xA5AAB6, bottom: UInt32 = 0x858A96
    /// 左上原點、y 往下的畫布
    static func draw(_ g: CGContext, _ r: CGRect, initials: String) {
        g.saveGState()
        g.addEllipse(in: r); g.clip()
        let grad = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [srgb(top).cgColor, srgb(bottom).cgColor] as CFArray, locations: [0, 1])!
        g.drawLinearGradient(grad, start: CGPoint(x: r.midX, y: r.minY), end: CGPoint(x: r.midX, y: r.maxY), options: [])
        let size = r.height * (initials.count > 1 ? 0.40 : 0.46)
        let font = HPType.sf(size, .medium)
        let w = Typo.width(initials, font)
        drawText(g, initials, font: font, x: r.midX - w / 2, baseline: r.midY + size * 0.355, color: .white)
        g.restoreGState()
    }
    static func image(initials: String, px: Int) -> CGImage? {
        makeImage(px, px) { g in draw(g, CGRect(x: 0, y: 0, width: px, height: px), initials: initials) }
    }
    private static func drawText(_ g: CGContext, _ s: String, font: NSFont, x: CGFloat, baseline: CGFloat, color: NSColor) {
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: Typo.attributes(font, color: color, kern: nil)))
        g.saveGState(); g.translateBy(x: x, y: baseline); g.scaleBy(x: 1, y: -1)
        g.textPosition = .zero; CTLineDraw(line, g); g.restoreGState()
    }
}
