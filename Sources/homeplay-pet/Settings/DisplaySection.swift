// HomeView 對齊 WP3：設定 › 外觀 › 顯示（官方「Turn Off Display」與「Ambient」對應項）。
// 20 秒是實測選項；「自動」＝房間暗/沒人看就睡、有人在留在海報。
import SwiftUI

struct DisplaySection: View {
    @EnvironmentObject var m: SettingsModel
    @State private var sleepAfter: Double? = DisplaySettings.sleepAfter
    @State private var ambient = DisplaySettings.ambientEnabled

    var body: some View {
        Section {
            Picker(selection: Binding(get: { sleepAfter }, set: { v in
                sleepAfter = v; DisplaySettings.sleepAfter = v
            })) {
                Text(L("settings.display.auto", "自动")).tag(Double?.none)
                Text(L("settings.display.20s", "20 秒后")).tag(Double?.some(20))
                Text(L("settings.display.60s", "60 秒后")).tag(Double?.some(60))
                Text(L("settings.display.never", "永不")).tag(Double?.some(3600))
            } label: {
                RowLabel(title: L("settings.display.sleep", "熄屏"),
                         subtitle: L("settings.display.sleep.sub", "无人交互回到表盘后，再过多久调暗"))
            }
            Toggle(L("settings.display.ambient", "环境海报"), isOn: Binding(get: { ambient }, set: { v in
                ambient = v; DisplaySettings.ambientEnabled = v
            }))
        } header: {
            Text(L("settings.display.title", "显示"))
        } footer: {
            Text(L("settings.display.footer", "照 HomeView：闲置回表盘后进入环境海报，之后熄屏；有人靠近会亮回来，点一下直接回到之前画面。"))
        }
    }
}

// HomeView 對齊 WP2（拍板 2026-11-05 補 UI）：設定 › 外觀 › Look——官方 12 種海報主題挑選器。
// 每顆以 Look 的四層 token 畫成迷你海報預覽（底色＋numerals 大數字＋secondary/accent 角標）。
struct LookSection: View {
    @EnvironmentObject var m: SettingsModel
    @State private var look = HPLook.current.name

    private let cols = [GridItem(.adaptive(minimum: 108, maximum: 128), spacing: 10)]

    var body: some View {
        Section {
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHGrid(rows: cols, spacing: 10) {
                    ForEach(HVTruth.looks, id: \.name) { l in
                        lookTile(l)
                    }
                }
                .padding(.vertical, 2)
            }
            .frame(height: 148)
        } header: {
            Text(L("settings.look.title", "Look（表盘主题）"))
        } footer: {
            Text(L("settings.look.footer", "照 HomeView 的 12 种表盘主题：大数字与着色建议跟着换。"))
        }
    }

    @ViewBuilder
    private func lookTile(_ l: HVTruth.Look) -> some View {
        let selected = look == l.name
        Button {
            look = l.name; HPLook.select(l.name); m.app?.view.face.forceDirty = true
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 14)
                    .fill(Color(nsColor: l.background_color))
                VStack(spacing: 2) {
                    Text("10:09")
                        .font(.system(size: 26, weight: .medium))
                        .foregroundStyle(Color(nsColor: l.numerals_color))
                    Text(l.name)
                        .font(.system(size: 10))
                        .foregroundStyle(Color(nsColor: l.secondary_color))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
            }
            .frame(width: 108, height: 128)
            .overlay {
                if selected {
                    RoundedRectangle(cornerRadius: 14)
                        .strokeBorder(Color(nsColor: l.accent_color), lineWidth: 3)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(l.name)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
