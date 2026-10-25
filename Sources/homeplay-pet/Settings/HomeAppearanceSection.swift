// 2.0 P02：設定 › 外觀 › 主畫面外觀（HIG Widgets 的 Apple HomeView 一節：淺色、深色、透明、著色四選一；著色可以選色）。
// 原生 grouped Form 的一個 Section（跟其他設定頁一樣）；改了就丟掉主畫面靜態層、叫桌寵重畫。

import SwiftUI

struct HomeAppearanceSection: View {
    @EnvironmentObject var m: SettingsModel
    @State private var look = HomeAppearance.current
    @State private var tint = Color(nsColor: HomeAppearance.tintColor)
    @State private var large = SB.largeIcons
    @State private var confirmReset = false

    var body: some View {
        Section {
            Picker(selection: Binding(get: { look }, set: { v in
                look = v; HomeAppearance.set(v); m.app?.view.face.forceDirty = true
            })) {
                ForEach(HomeAppearance.allCases, id: \.self) { a in Label(a.title, systemImage: a.symbol).tag(a) }
            } label: {
                RowLabel(title: L("settings.home.appearance", "主屏幕外观"),
                         subtitle: L("settings.home.appearance.sub", "App 图标和小组件一起换"))
            }
            if look == .tinted {
                ColorPicker(L("settings.home.tint", "着色颜色"), selection: Binding(get: { tint }, set: { c in
                    tint = c; HomeAppearance.setTint(NSColor(c)); m.app?.view.face.forceDirty = true
                }), supportsOpacity: false)
            }
            // 2.0 SpringBoard：大圖示（隱藏名稱，iOS 18 起）與還原這個人的主畫面排列
            Toggle(L("sb.largeIcons", "大图标（隐藏名称）"), isOn: Binding(get: { large }, set: { v in
                large = v; SB.setLargeIcons(v); m.app?.view.face.forceDirty = true
            }))
            Button(L("settings.home.reset", "还原主屏幕排列…")) { confirmReset = true }
                .disabled(!PersonHome.canEdit)
                .confirmationDialog(L("settings.home.reset.title", "要把主屏幕还原成默认排列吗？"), isPresented: $confirmReset) {
                    Button(L("settings.home.reset.ok", "还原"), role: .destructive) { SB.resetLayout(); m.app?.view.face.forceDirty = true }
                    Button(L("sb.cancel", "取消"), role: .cancel) {}
                } message: {
                    Text(L("settings.home.reset.body", "只还原现在这个人的主屏幕：App、小组件、文件夹和页面回到默认，App 都还在 App 资源库里。"))
                }
        } footer: {
            Text(L("settings.home.appearance.note", "每位家人的主屏幕排列各自保存：在主屏幕上按住半秒进入编辑。"))
        }
    }
}
