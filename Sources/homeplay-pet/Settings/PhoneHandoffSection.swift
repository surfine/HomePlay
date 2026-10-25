import AppKit
import SwiftUI

// 2.0 promo：設定 › CarPlay ›「從 iPhone 傳網頁」。照實說是怎麼觸發的（不是官方那種「靠近就跳」的 Handoff）：
// 通用剪貼板＝在 iPhone 上拷貝網址；捷徑＝分享表單裡選「傳到 HomePlay」。兩個都預設關。

final class PhoneHandoffModel: ObservableObject {
    @Published var clipboard = HandoffSettings.clipboard
    @Published var shortcut = HandoffSettings.shortcut
    @Published var token = ""
    @Published var state = HandoffServer.shared.state

    init() {
        if shortcut { token = HandoffToken.grouped(HandoffToken.current) }
        HandoffServer.shared.onStateChange = { [weak self] in self?.state = HandoffServer.shared.state }
    }
    func setClipboard(_ on: Bool) { HandoffSettings.clipboard = on; clipboard = on }
    func setShortcut(_ on: Bool) {
        HandoffSettings.shortcut = on; shortcut = on
        token = on ? HandoffToken.grouped(HandoffToken.current) : ""
        state = HandoffServer.shared.state
    }
    func newToken() { token = HandoffToken.grouped(HandoffToken.regenerate()) }
    func copy(_ s: String) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(s, forType: .string) }
}

struct PhoneHandoffSection: View {
    @StateObject private var m = PhoneHandoffModel()

    var body: some View {
        Section {
            Toggle(isOn: Binding(get: { m.clipboard }, set: { m.setClipboard($0) })) {
                RowLabel(title: L("handoff.clipboard", "在 iPhone 上拷贝网址"),
                         subtitle: L("handoff.clipboard.sub", "通用剪贴板：同一个 Apple 账户、iPhone 在附近时，拷贝的网址会在桌宠上打开"))
            }
            Toggle(isOn: Binding(get: { m.shortcut }, set: { m.setShortcut($0) })) {
                RowLabel(title: L("handoff.shortcut", "从分享菜单传到 HomePlay"),
                         subtitle: L("handoff.shortcut.sub", "iPhone 上用一个快捷指令，经同一个 Wi‑Fi 传过来，要带配对码"))
            }
            if m.shortcut {
                LabeledContent {
                    HStack(spacing: 8) {
                        Text(HandoffServer.address).font(.callout.monospaced()).textSelection(.enabled)
                        Button(L("handoff.copy", "拷贝")) { m.copy(HandoffServer.address) }
                    }
                } label: {
                    RowLabel(title: L("handoff.address", "网址"), subtitle: m.state == "failed" ? L("handoff.failed", "打不开这个端口：可能被别的 App 占用了") : nil)
                }
                LabeledContent {
                    HStack(spacing: 8) {
                        Text(m.token).font(.callout.monospaced()).textSelection(.enabled)
                        Button(L("handoff.copy", "拷贝")) { m.copy(m.token.replacingOccurrences(of: "-", with: "")) }
                        Button(L("handoff.newCode", "换一组…")) { m.newToken() }
                    }
                } label: {
                    RowLabel(title: L("handoff.code", "配对码"), subtitle: L("handoff.code.sub", "只存在钥匙串里；换一组后，旧的快捷指令要改"))
                }
                InfoRow(title: L("handoff.steps.title", "在 iPhone 上做一个快捷指令"),
                        subtitle: L("handoff.steps", "1. 新建快捷指令，打开「在共享表单中显示」，接收「URL」。\n2. 加「获取 URL 内容」：上面的网址，方法 POST，标头 Authorization 填「Bearer 配对码」，请求体 JSON：url ＝ 快捷指令输入。\n3. 在 Safari 里点分享 → 这个快捷指令。"))
            }
        } header: {
            Text(L("handoff.header", "从 iPhone 传网页"))
        } footer: {
            Text(L("handoff.footer", "不是 Apple 的「接力」：Mac 上接力只交给默认浏览器。网页在桌宠上打开，是食谱就直接进「开始烹饪」。"))
                .font(.footnote).foregroundStyle(.secondary)
        }
    }
}
