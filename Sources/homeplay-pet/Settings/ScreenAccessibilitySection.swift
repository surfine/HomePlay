// 2.0 P05：設定 › 輔助使用——畫面文字大小、用鍵盤操作畫面（Design/HPAccessibility.swift）、一律顯示頂端把手（Shell/HomeHandle.swift）、觸覺回饋（Shell/PointerInput.swift）。

import SwiftUI

struct ScreenAccessibilitySection: View {
    @State private var size = HPAccessibilitySettings.textSize
    @State private var keyboard = HPAccessibilitySettings.keyboardNavigationSetting
    @State private var alwaysHandle = HomeHandle.alwaysShow
    @State private var haptics = PointerHaptics.enabled

    var body: some View {
        Section {
            Picker(selection: Binding(get: { size }, set: { size = $0; HPAccessibilitySettings.textSize = $0 })) {
                Text(L("settings.textSize.default", "默认")).tag(0)
                Text(L("settings.textSize.large", "大")).tag(1)
                Text(L("settings.textSize.xlarge", "特大")).tag(2)
            } label: {
                RowLabel(title: L("settings.textSize", "屏幕文字大小"),
                         subtitle: L("settings.textSize.short", "回答、列表和胶囊跟着变大"))
            }
            .settingsRow("settings.textSize")
            ToggleRow(title: L("settings.keyboardNav", "键盘导航"), subtitle: L("settings.keyboardNav.short", "用 Tab 和方向键操作画面"), symbol: "",
                      info: L("settings.keyboardNav.sub", "Tab 或方向键叫出焦点框，方向键移动，Return 或空格打开，Esc 返回；系统「键盘导航」打开时也会启用"),
                      isOn: Binding(get: { keyboard }, set: { keyboard = $0; HPAccessibilitySettings.keyboardNavigation = $0 }))
                .settingsRow("settings.keyboardNav")
            ToggleRow(title: L("settings.alwaysHandle", "一律显示把手"), subtitle: L("settings.alwaysHandle.short", "顶端的主屏幕把手不自动隐藏"), symbol: "",
                      info: L("settings.alwaysHandle.sub", "把手平常在换画面后显示 2 秒，光标或手指靠近顶端中间时也会出现。打开后一直显示。隐藏时照样可以从顶端往下拉。"),
                      isOn: Binding(get: { alwaysHandle }, set: { alwaysHandle = $0; HomeHandle.alwaysShow = $0 }))
                .settingsRow("settings.alwaysHandle")
            ToggleRow(title: L("settings.haptics", "触觉反馈"), subtitle: L("settings.haptics.short", "用触控板拖动越过界线时轻震一下"), symbol: "",
                      info: L("settings.haptics.sub", "只在三个地方：把手下拉到「松开就回主屏幕」的位置、编辑主屏幕时图标进到格子里、桌宠放大或缩小到极限。需要支持力度触控的触控板。"),
                      isOn: Binding(get: { haptics }, set: { haptics = $0; PointerHaptics.enabled = $0 }))
                .settingsRow("settings.haptics")
        }
    }
}
