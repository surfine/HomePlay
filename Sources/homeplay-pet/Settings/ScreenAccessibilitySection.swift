// 2.0 P05：設定 › 外觀 的「輔助使用」一段——畫面文字大小、用鍵盤操作畫面（Design/HPAccessibility.swift）。

import SwiftUI

struct ScreenAccessibilitySection: View {
    @State private var size = HPAccessibilitySettings.textSize
    @State private var keyboard = HPAccessibilitySettings.keyboardNavigationSetting

    var body: some View {
        Section {
            Picker(selection: Binding(get: { size }, set: { size = $0; HPAccessibilitySettings.textSize = $0 })) {
                Text(L("settings.textSize.default", "默认")).tag(0)
                Text(L("settings.textSize.large", "大")).tag(1)
                Text(L("settings.textSize.xlarge", "特大")).tag(2)
            } label: {
                RowLabel(title: L("settings.textSize", "屏幕文字大小"),
                         subtitle: L("settings.textSize.short", "回答、列表和胶囊跟着变大"), symbol: "a.magnify", tint: .blue)
            }
            ToggleRow(title: L("settings.keyboardNav", "键盘导航"), subtitle: L("settings.keyboardNav.short", "用 Tab 和方向键操作画面"), symbol: "keyboard.fill", tint: .blue,
                      info: L("settings.keyboardNav.sub", "Tab 或方向键叫出焦点框，方向键移动，Return 或空格打开，Esc 返回；系统「键盘导航」打开时也会启用"),
                      isOn: Binding(get: { keyboard }, set: { keyboard = $0; HPAccessibilitySettings.keyboardNavigation = $0 }))
        } header: {
            Text(L("settings.a11y", "辅助功能"))
        }
    }
}
