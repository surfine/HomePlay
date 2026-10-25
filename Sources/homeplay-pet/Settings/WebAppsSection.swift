import AppKit
import SwiftUI

// 2.0 Web App：設定 › 權限 › Web App。每個 Web App 各自的相機、麥克風、位置、通知（詢問／允許／拒絕，可以隨時收回），
// 清除它自己的網站資料、刪除整個 Web App（docs/plans/webapps.md）。

final class WebAppsModel: ObservableObject {
    @Published var apps: [WebApp] = WebAppStore.shared.apps
    init() { WebAppStore.shared.onChange = { [weak self] in self?.apps = WebAppStore.shared.apps } }
    func set(_ a: WebApp, _ p: WebAppPermission, _ v: String) {
        WebAppStore.shared.update(a.uuid) { $0.permissions[p.rawValue] = v == "ask" ? nil : v }
        if let w = WebAppRuntimes.existing(a.uuid), let n = WebAppStore.shared.app(uuid: a.uuid) { w.installShims(n) }   // 通知的狀態下一頁生效
    }
    func person(_ a: WebApp) -> String? {
        let reg = PeopleRegistry.shared
        guard reg.people.count > 1, let p = a.person.flatMap({ reg.person($0) }) ?? reg.owner else { return nil }
        return p.name
    }
}

struct WebAppsSection: View {
    @StateObject private var m = WebAppsModel()
    @State private var expanded: Set<String> = SnapshotPrivacy.active ? Set(WebAppStore.shared.apps.prefix(1).map(\.uuid)) : []
    @State private var clearing: WebApp?

    var body: some View {
        Section {
            if m.apps.isEmpty {
                InfoRow(title: L("webapp.settings.none", "还没有 Web App"), subtitle: L("webapp.settings.none.sub", "在 Safari 里点地址栏或按住它，选「添加到主屏幕」。"))
            }
            ForEach(m.apps, id: \.uuid) { a in
                DisclosureGroup(isExpanded: Binding(get: { expanded.contains(a.uuid) }, set: { if $0 { expanded.insert(a.uuid) } else { expanded.remove(a.uuid) } })) {
                    Toggle(isOn: Binding(get: { a.shared }, set: { v in WebAppStore.shared.update(a.uuid) { $0.shared = v } })) {
                        RowLabel(title: L("webapp.settings.shared", "家人也能打开"), subtitle: L("webapp.settings.shared.sub", "例如家庭看板：认出来的家人都能打开；访客仍然不行"))
                    }
                    ForEach(WebAppPermission.allCases, id: \.self) { p in
                        Picker(selection: Binding(get: { a.permissions[p.rawValue] ?? "ask" }, set: { m.set(a, p, $0) })) {
                            Text(L("webapp.settings.ask", "询问")).tag("ask")
                            Text(L("webapp.settings.allow", "允许")).tag("allow")
                            Text(L("webapp.settings.deny", "拒绝")).tag("deny")
                        } label: {
                            Label(p.title, systemImage: p.symbol)
                        }
                    }
                    LabeledContent {
                        HStack(spacing: 8) {
                            Button(L("webapp.settings.clear", "清除网站数据…")) { clearing = a }
                            Button(L("webapp.settings.delete", "删除 Web App…"), role: .destructive) { WebAppEditor.confirmDelete(a) }
                        }
                    } label: {
                        RowLabel(title: L("webapp.settings.data", "网站数据"), subtitle: L("webapp.settings.data.sub", "登录、Cookie、离线内容只留在这个 Web App 里"))
                    }
                } label: {
                    HStack(spacing: 10) {
                        if let img = WebAppStore.shared.icon(a.uuid) ?? WebAppIcons.monogram(a) {
                            Image(nsImage: NSImage(cgImage: img, size: NSSize(width: 28, height: 28)))
                                .resizable().frame(width: 28, height: 28).clipShape(RoundedRectangle(cornerRadius: 6.5, style: .continuous))
                        }
                        VStack(alignment: .leading, spacing: 1) {
                            Text(a.name)
                            Text([a.host, m.person(a)].compactMap { $0 }.joined(separator: " · ")).font(.callout).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        } header: {
            Text(L("webapp.settings.header", "Web App"))
        } footer: {
            Text(L("webapp.settings.footer", "每个 Web App 都有自己的网站数据和权限，跟 Safari、跟其他 Web App 分开。只有添加它的人认出来时才能打开。"))
                .foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
        }
        .confirmationDialog(String(format: L("webapp.settings.clear.title", "要清除“%@”的网站数据吗？"), clearing?.name ?? ""),
                            isPresented: Binding(get: { clearing != nil }, set: { if !$0 { clearing = nil } })) {
            Button(L("webapp.settings.clear.ok", "清除"), role: .destructive) {
                if let a = clearing { WebAppRuntimes.drop(a.uuid); WebAppData.clear(a.uuid) {} }
                clearing = nil
            }
        } message: {
            Text(L("webapp.settings.clear.body", "会退出登录、删掉离线内容；Web App 本身和它的权限留着。"))
        }
    }
}
