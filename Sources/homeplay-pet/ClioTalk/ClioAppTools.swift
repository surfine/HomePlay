// 2.0 App 平台：ClioTalk 的「打開 ⟨App⟩」——內建 App 與這個人的 Web App 都叫得出（Shell/AppPlatform/AppProvider.swift）。
// 開 App 不是替你發聲，不用確認；門照舊：訪客、認不出的人叫不開個人的 App 與 Web App（只回「需要主人」，不念出別人的 App 名單）。

import AppKit

enum ClioAppTools {
    static func run(input: [String: Any]) async -> ClioToolResult {
        let name = (input["name"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return await MainActor.run { open(name) }
    }

    @MainActor static func open(_ name: String) -> ClioToolResult {
        func fail(_ s: String) -> ClioToolResult { ClioToolResult(content: s, isError: true, source: .apps) }
        guard !name.isEmpty else { return fail("Say which app to open.") }
        let cat = AppProviders.spokenCatalog(viewer: PersonHome.viewerID)
        guard let id = AppProviders.match(name, in: cat), let app = AppRegistry.app(id) else {
            let names = cat.filter { !PersonalGate.locks($0.id) }.compactMap(\.names.first).prefix(30).joined(separator: ", ")
            return fail("There is no app called \"\(name)\" on this desk pet. Apps you can open: \(names).")
        }
        if PersonalGate.locks(id) { return fail("\(app.title) is personal; it opens only when its owner is recognized. It was not opened.") }
        AppProviders.open(id)
        return ClioToolResult(content: "\(app.title) is open on the desk pet screen.", source: .apps)
    }
}
