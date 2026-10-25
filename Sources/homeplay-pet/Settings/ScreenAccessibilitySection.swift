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
                         subtitle: L("settings.textSize.sub", "ClioTalk 的回答、列表和胶囊列跟着变大，放不下就换行"))
            }
            Toggle(isOn: Binding(get: { keyboard }, set: { keyboard = $0; HPAccessibilitySettings.keyboardNavigation = $0 })) {
                RowLabel(title: L("settings.keyboardNav", "键盘导航"),
                         subtitle: L("settings.keyboardNav.sub", "方向键移动、Return 打开、Esc 返回；系统「键盘导航」打开时也会启用"))
            }
        } header: {
            Text(L("settings.a11y", "辅助功能"))
        }
    }
}
