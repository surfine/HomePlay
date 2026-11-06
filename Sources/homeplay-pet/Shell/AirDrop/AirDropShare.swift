// 桌寵傳到手機：照片、網頁、食譜的 AirDrop 分享鈕。用系統公開的分享服務（NSSharingService .sendViaAirDrop），
// 點了會跳出系統的 AirDrop 選人視窗。送什麼：照片錶面＝正在看的那張原檔；照片小工具＝畫面上那張（圖庫的內容只在記憶體，送出的是 PNG 圖片）；
// Safari＝目前網址；食譜＝原網址（沒有網址的剪貼簿食譜就送文字）。實際送出的動作可換（自檢用假的，不跳視窗）。

import AppKit

enum AirDropShare {
    /// 真正去呼叫系統分享服務；自檢換成假的。回 false＝這台 Mac 沒有 AirDrop 服務或送不出
    nonisolated(unsafe) static var perform: ([Any]) -> Bool = { items in
        guard !CCSystem.demo, let s = NSSharingService(named: .sendViaAirDrop), s.canPerform(withItems: items) else { return false }
        s.perform(withItems: items)
        return true
    }

    @discardableResult
    static func send(_ items: [Any]) -> Bool {
        guard !items.isEmpty else { return false }
        return perform(items)
    }

    // MARK: 要送的東西（純函數，自檢驗）

    static func items(photoFile: URL?) -> [Any] { photoFile.map { [$0] } ?? [] }
    static func items(image: CGImage?) -> [Any] {
        guard let image else { return [] }
        return [NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))]
    }
    /// 只送 http／https 網頁（about:blank、檔案網址不送）
    static func items(page: URL?) -> [Any] {
        guard let u = page, ["http", "https"].contains(u.scheme?.lowercased() ?? "") else { return [] }
        return [u]
    }
    static func items(recipe r: Recipe?) -> [Any] {
        guard let r else { return [] }
        if let s = r.sourceURL, let u = URL(string: s), !items(page: u).isEmpty { return [u] }
        var parts = [r.title]
        if !r.ingredients.isEmpty { parts.append(r.ingredients.map { "• \($0)" }.joined(separator: "\n")) }
        if !r.steps.isEmpty { parts.append(r.steps.enumerated().map { "\($0.offset + 1). \($0.element.text)" }.joined(separator: "\n")) }
        return [parts.joined(separator: "\n\n")]
    }

    /// 分享鈕的符號與無障礙名稱
    /// AirDrop 的官方符號名是 "airdrop"，但這個符號目前不在公開的系統符號裡（NSImage 取不到）：取得到就用，取不到退成相近的電波符號
    static let symbol: String = NSImage(systemSymbolName: "airdrop", accessibilityDescription: nil) != nil ? "airdrop" : "dot.radiowaves.up.forward"
    static var title: String { L("airdrop.share", "通过 AirDrop 发送") }
}
