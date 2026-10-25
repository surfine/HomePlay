// 2.0 App 平台（docs/plans/webapps.md）：內建 App、Web App、將來的宣告式外掛共用的「App 提供者」。
//
// 內建 App 照舊在 AppRegistry.all（靜態）；其他來源實作 AppProvider、登記在 AppProviders.all。外殼只問提供者這幾件事：
// 有哪些 App（每人一份）、認不認得這個 id、是不是個人內容、現在鎖不鎖、長按選單多哪幾列、ClioTalk 叫得出哪些名字、背景還有誰在忙。
// 外掛只能是「manifest＋網頁」（跟 Web App 同一個沙盒）；這一層不載入任何原生程式碼。

import AppKit

/// 長按選單裡提供者自己加的一列（verb 回到 perform）
struct AppMenuRow: Equatable {
    var verb: String
    var title: String
    var symbol: String
    var destructive = false
}

protocol AppProvider: AnyObject {
    /// 這位觀眾的主畫面與 App 資料庫上，這個來源有哪些 App
    func apps(viewer: String?) -> [PetApp]
    /// 認得這個 id 就回 App（不分人：存檔清理、深連結用；開不開得了另外問 locks）
    func app(_ id: String) -> PetApp?
    /// 個人內容：訪客、遠端訪客的裝置看不到
    func isPersonal(_ id: String) -> Bool
    /// 現在要不要鎖起來（外殼畫「需要主人」）
    func locks(_ id: String) -> Bool
    /// 主畫面長按選單多的列
    func menuRows(_ id: String, canEdit: Bool) -> [AppMenuRow]
    func perform(_ id: String, verb: String)
    /// ClioTalk「打開 ⟨名字⟩」比對用的名字（App 的 title 之外）
    func spokenNames(_ id: String) -> [String]
    /// 背景還有事的 App（例如還在播的 Web App）：頂端藥丸也要問它們的 liveActivity
    func backgroundApps() -> [PetApp]
}

extension AppProvider {
    func isPersonal(_ id: String) -> Bool { true }
    func menuRows(_ id: String, canEdit: Bool) -> [AppMenuRow] { [] }
    func perform(_ id: String, verb: String) {}
    func spokenNames(_ id: String) -> [String] { [] }
    func backgroundApps() -> [PetApp] { [] }
}

enum AppProviders {
    /// 登記處（順序＝主畫面與資料庫裡排在內建 App 之後的順序）
    nonisolated(unsafe) static var all: [AppProvider] = [WebAppProvider.shared]

    static func app(_ id: String) -> PetApp? {
        for p in all { if let a = p.app(id) { return a } }
        return nil
    }
    static func apps(viewer: String?) -> [PetApp] { all.flatMap { $0.apps(viewer: viewer) } }
    static func provider(of id: String) -> AppProvider? { all.first { $0.app(id) != nil } }
    static func isPersonal(_ id: String) -> Bool { provider(of: id)?.isPersonal(id) ?? false }
    static func locks(_ id: String) -> Bool { provider(of: id)?.locks(id) ?? false }
    static func menuRows(_ id: String, canEdit: Bool) -> [AppMenuRow] { provider(of: id)?.menuRows(id, canEdit: canEdit) ?? [] }
    static func perform(_ id: String, verb: String) { provider(of: id)?.perform(id, verb: verb) }
    /// 頂端藥丸：背景還在忙的（不在 AppRegistry.all 裡的）
    static var backgroundApps: [PetApp] { all.flatMap { $0.backgroundApps() } }
    /// 頂端藥丸要問的（不在 AppRegistry.all 裡）：開著的那一個＋背景在忙的，不重複
    static var activityApps: [PetApp] {
        var out = backgroundApps
        if case .app(let id) = Shell.nav.screen, let a = app(id), !out.contains(where: { $0.id == id }) { out.append(a) }
        return out
    }

    /// 打開（走外殼同一條路：過場、Live Activity、門都照舊）
    static func open(_ id: String) { (NSApp.delegate as? AppDelegate)?.view?.shellOpenApp(id) }

    // MARK: ClioTalk 的「打開 ⟨App⟩」

    /// 這位觀眾現在叫得出的 App（內建＋提供者）：id → 名字們
    static func spokenCatalog(viewer: String?) -> [(id: String, names: [String])] {
        var out: [(String, [String])] = AppRegistry.all.filter { !AppRegistry.hidden.contains($0.id) }.map { ($0.id, [$0.title, $0.id]) }
        for a in apps(viewer: viewer) { out.append((a.id, [a.title] + (provider(of: a.id)?.spokenNames(a.id) ?? []))) }
        return out
    }
    /// 比對（純函數）：先整個名字一樣，再來「說的話包含名字」（取最長的名字，免得「音樂」吃掉「Apple 音樂」），最後名字包含說的話
    static func match(_ spoken: String, in catalog: [(id: String, names: [String])]) -> String? {
        func norm(_ s: String) -> String { s.lowercased().folding(options: [.diacriticInsensitive, .widthInsensitive], locale: nil).filter { $0.isLetter || $0.isNumber } }
        let q = norm(spoken)
        guard !q.isEmpty else { return nil }
        let flat = catalog.flatMap { c in c.names.map { (c.id, norm($0)) } }.filter { !$0.1.isEmpty }
        if let hit = flat.first(where: { $0.1 == q }) { return hit.0 }
        if let hit = flat.filter({ q.contains($0.1) && $0.1.count >= 2 }).max(by: { $0.1.count < $1.1.count }) { return hit.0 }
        if q.count >= 2, let hit = flat.filter({ $0.1.contains(q) }).min(by: { $0.1.count < $1.1.count }) { return hit.0 }
        return nil
    }
}

enum AppProviderSelftest {
    static func run(_ check: (Bool, String) -> Void) {
        let cat: [(id: String, names: [String])] = [("music", ["音乐", "music"]), ("web.a", ["Apple Music", "music.apple.com"]), ("web.b", ["购物清单", "Groceries"]), ("safari", ["Safari", "safari"])]   // l10n-ignore：selftest 樣本
        check(AppProviders.match("音乐", in: cat) == "music" && AppProviders.match("Apple Music", in: cat) == "web.a" && AppProviders.match("open apple music please", in: cat) == "web.a",
              "App 平台：ClioTalk 叫名字，整個一樣先、包含取最長")   // l10n-ignore：selftest 訊息
        check(AppProviders.match("groceries", in: cat) == "web.b" && AppProviders.match("购物清单", in: cat) == "web.b" && AppProviders.match("天气", in: cat) == nil && AppProviders.match("  ", in: cat) == nil,
              "App 平台：Web App 叫得出名字，叫不出的不亂開")   // l10n-ignore：selftest 訊息
        check(AppProviders.app("music") == nil && AppRegistry.app("music") != nil && AppRegistry.app("web.nope") == nil,
              "App 平台：內建 App 不走提供者、不認得的 id 不會變出 App")   // l10n-ignore：selftest 訊息
    }
}
