// 食譜的三條入口：把網址拖到桌寵上、在食譜 App 裡按 ⌘V、右鍵「從剪貼簿開啟食譜」。
// 都只認 http／https 網址（拖進來的檔案、純文字裡沒有網址的一律不理）。

import AppKit

extension RecipesApp {
    /// 剪貼簿／拖放板裡的第一個 http(s) 網址
    static func url(from pb: NSPasteboard) -> URL? {
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: false]) as? [URL],
           let u = urls.first(where: { isWeb($0) }) { return u }
        if let s = pb.string(forType: .string) { return url(fromText: s) }
        return nil
    }

    /// 一段文字裡的第一個網址（純網址、或夾在句子裡的）
    static func url(fromText s: String) -> URL? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if let u = URL(string: t), isWeb(u) { return u }
        guard let det = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return nil }
        let ns = t as NSString
        for m in det.matches(in: t, range: NSRange(location: 0, length: ns.length)) {
            if let u = m.url, isWeb(u) { return u }
        }
        return nil
    }

    private static func isWeb(_ u: URL) -> Bool {
        guard let s = u.scheme?.lowercased(), s == "http" || s == "https" else { return false }
        return u.host?.isEmpty == false
    }

    /// 從剪貼簿開（食譜 App 裡的按鈕用）。沒有網址就提示一下
    static func openFromPasteboard(_ pb: NSPasteboard, face: Face) {
        guard let u = url(from: pb) else {
            RecipesApp.shared.showError(L("recipe.notURL", "剪贴板里没有网址"), face: face)
            return
        }
        RecipesApp.shared.open(u, face: face)
    }
}

extension PetView {
    /// 打開食譜 App 並載入網址。CarPlay 畫面在時外殼不接手
    func recipeOpen(_ url: URL) {
        guard !showingVideo, !carVideo.active else { return }
        Shell.lastActive = CACurrentMediaTime()
        RecipesApp.shared.open(url, face: face)
        if Shell.nav.screen != .app("recipes") { shellOpenApp("recipes") }
        face.forceDirty = true
    }

    /// 右鍵選單「從剪貼簿開啟食譜」
    @objc func menuRecipeFromClipboard() {
        guard let u = RecipesApp.url(from: .general) else {
            if !showingVideo, !carVideo.active {
                RecipesApp.shared.showError(L("recipe.notURL", "剪贴板里没有网址"), face: face)
                if Shell.nav.screen != .app("recipes") { shellOpenApp("recipes") }
            }
            return
        }
        recipeOpen(u)
    }

    /// 食譜 App 開著時的 ⌘V（ShellInput.shellKeyDown 呼叫）
    func recipePaste() -> Bool {
        guard Shell.nav.screen == .app("recipes"), Shell.nav.overlay == .none else { return false }
        RecipesApp.openFromPasteboard(.general, face: face)
        return true
    }

    // MARK: 拖放（registerForDraggedTypes 在 recipeRegisterDrag，開機時呼叫一次）

    func recipeRegisterDrag() { registerForDraggedTypes([.URL, .string]) }

    /// main.swift 的 PetView 把 draggingEntered／performDragOperation 轉到這兩個
    func recipeDragEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        RecipesApp.url(from: sender.draggingPasteboard) != nil && !showingVideo && !carVideo.active ? .copy : []
    }
    func recipePerformDrag(_ sender: NSDraggingInfo) -> Bool {
        guard let u = RecipesApp.url(from: sender.draggingPasteboard) else { return false }
        recipeOpen(u)
        return true
    }
}
