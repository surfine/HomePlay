import AppKit
import SwiftUI

// 设置窗口的共用元件。版面本身交给系统的分组表单（SettingsPanes.swift）；这里只剩系统没有的：
// 两格插画舞台、按下缩放的按钮样式、换段的模糊交叉淡化。

enum SettingsMetrics {
    static let panelRadius: CGFloat = 12   // 插画格的圆角，和分组表单的卡片圆角一致
    static let demoCycles = 3
}

/// 插画说明：两格并排（左：手怎么动，线稿；右：HomeView 怎么回应，平涂），借系统设置「触控式轨迹板」的版式。
/// 出现就播 3 轮，第 4 轮播到关键帧停住（不从结尾硬切到关键帧）；悬停或点播放键从关键帧接着播一整轮、回到关键帧。
/// 「减少动态效果」：不自动播、悬停不播，只画关键帧；点播放键是明确要看，照样播一轮。
/// 截图验收：环境变量 HOMEPLAY_DEMO_T=秒（或 key）把所有插画冻结在那一刻。
struct IllustrationStage: View {
    let scene: IllusScene

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var start = Date()
    @State private var stopAt: Double = -1      // 从 start 起播到第几秒停（停在关键帧）；-1＝还没决定
    @State private var playing = false

    private var frozenT: Double? {
        guard let f = ProcessInfo.processInfo.environment["HOMEPLAY_DEMO_T"] else { return nil }
        return f == "key" ? scene.key : Double(f).map { min($0, scene.cycle) }
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            if let f = frozenT {
                panels(f)
            } else {
                TimelineView(.animation(paused: !playing)) { ctx in
                    let elapsed = ctx.date.timeIntervalSince(start)
                    let t = playing && elapsed < stopAt ? elapsed.truncatingRemainder(dividingBy: scene.cycle) : scene.key
                    panels(t)
                }
            }
            // 播放键只在「减少动态效果」时出现（平时指标滑过插画就会重播，按钮只会压在图上）
            if frozenT == nil, !playing, reduceMotion {
                Button { play(from: scene.key, until: scene.key + scene.cycle) } label: {
                    Image(systemName: "play.fill").font(.system(size: 9, weight: .semibold))
                        .frame(width: 22, height: 22)
                }
                .modifier(SystemCircleButtonStyle())   // 2.0 glass（P01）：系統按鈕樣式（macOS 26＋是玻璃），不自己鋪 .regularMaterial
                .foregroundStyle(.secondary)
                .padding(8)
                .help(L("settings.demo.play", "再播一次"))
                .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }
        }
        .onHover { inside in
            if inside, !playing, !reduceMotion, frozenT == nil { play(from: scene.key, until: scene.key + scene.cycle) }
        }
        .animation(.easeOut(duration: 0.18), value: playing)
        .onAppear {
            guard frozenT == nil, stopAt < 0, !reduceMotion else { return }
            play(from: 0, until: scene.cycle * Double(SettingsMetrics.demoCycles) + scene.key)
        }
        .task(id: start) {
            guard playing, stopAt > 0 else { return }
            let remaining = stopAt - Date().timeIntervalSince(start)
            if remaining > 0 { try? await Task.sleep(nanoseconds: UInt64(remaining * 1e9)) }
            if !Task.isCancelled { playing = false }
        }
        .accessibilityHidden(true)
    }

    private func panels(_ t: Double) -> some View {
        HStack(spacing: 16) {
            IllusCanvas(t: t) { g, p, t in scene.left(g, p, t) }.panel(outlined: true)    // 浅灰那格要一圈细线跟底色分开
            IllusCanvas(t: t) { g, p, t in scene.right(g, p, t) }.panel(outlined: false)  // 彩色那格不描边，描了反而发硬
        }
    }

    /// 从这一轮的 offset 秒接着播，播到第 until 秒（相对这一轮起点）停
    private func play(from offset: Double, until: Double) {
        start = Date().addingTimeInterval(-offset)
        stopAt = until
        playing = true
    }
}

/// 按下缩一点（0.94，100 ms 缓出），放开弹回
struct PressScaleStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

/// 换一段插画：模糊交叉淡化（两个状态叠在一起时糊一点，眼睛会看成同一个东西在变）
private struct BlurFade: ViewModifier {
    let on: Bool
    func body(content: Content) -> some View { content.opacity(on ? 0 : 1).blur(radius: on ? 6 : 0) }
}
extension AnyTransition {
    static var blurFade: AnyTransition { .modifier(active: BlurFade(on: true), identity: BlurFade(on: false)) }
}

private extension View {
    func panel(outlined: Bool) -> some View {
        aspectRatio(1.6, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: SettingsMetrics.panelRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: SettingsMetrics.panelRadius, style: .continuous)
                .strokeBorder(Color.primary.opacity(outlined ? 0.06 : 0), lineWidth: 0.5))
    }
}

/// 2.0 glass（P01）：小圓鈕用系統的按鈕樣式——macOS 26 起 .glass（系統自己的 Liquid Glass，也會照輔助使用設定換樣子），更舊用 .bordered
struct SystemCircleButtonStyle: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.buttonStyle(.glass).buttonBorderShape(.circle)
        } else {
            content.buttonStyle(.bordered).buttonBorderShape(.circle)
        }
    }
}

/// 2.0 P06（HIG Sliders）：滑桿右邊顯示目前的值（等寬數字），停在上面也有提示；有 step 就畫刻度。
/// 版面是系統分組表單的一行：標題（可帶副標題）在左，滑桿＋數值在右。
struct ValueSlider: View {
    let title: String
    var subtitle: String? = nil
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double? = nil
    let minLabel: String
    let maxLabel: String
    let format: (Double) -> String

    var body: some View {
        LabeledContent {
            HStack(spacing: 8) {
                slider.accessibilityLabel(title).accessibilityValue(format(value))
                Text(format(value)).monospacedDigit().foregroundStyle(.secondary)
                    .frame(minWidth: 44, alignment: .trailing)
            }
        } label: { RowLabel(title: title, subtitle: subtitle) }
        .help(format(value))
    }

    @ViewBuilder private var slider: some View {
        if let step {
            Slider(value: $value, in: range, step: step) { EmptyView() } minimumValueLabel: { Text(minLabel) } maximumValueLabel: { Text(maxLabel) }
        } else {
            Slider(value: $value, in: range) { EmptyView() } minimumValueLabel: { Text(minLabel) } maximumValueLabel: { Text(maxLabel) }
        }
    }
}
