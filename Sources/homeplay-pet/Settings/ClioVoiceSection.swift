import AppKit
import AVFoundation
import SwiftUI

// 2.0 P10（HV-NEWS-38）：設定 › ClioTalk 的「聲音」一段：這台 Mac 裝好的系統聲音（介面語言那一種）＋試聽＋語速。
// 系統的分組表單，跟其他段一樣；個人聲音要你按「使用個人聲音…」才去問系統。

final class ClioVoiceModel: ObservableObject {
    @Published var options: [ClioVoiceOption] = []
    @Published var selected: String?          // nil＝自動
    @Published var rate = ClioSpeechVoices.rate
    @Published var personal = ClioSpeechVoices.personalStatus
    @Published var previewing = false
    private let synth = AVSpeechSynthesizer()
    private var delegate: PreviewDelegate?
    let lang = ClioSpeechVoices.interfaceLanguage

    func refresh() {
        options = ClioSpeechVoices.options(ClioSpeechVoices.installed(), lang: lang)
        selected = ClioSpeechVoices.resolve(ClioSpeechVoices.selected(for: lang), in: options)
        personal = ClioSpeechVoices.personalStatus
    }

    func choose(_ id: String?) {
        selected = id
        ClioSpeechVoices.setSelected(id, for: lang)
        preview()
    }

    func setRate(_ r: Float) { rate = ClioSpeechVoices.clampRate(r); ClioSpeechVoices.rate = rate }

    func preview() {
        synth.stopSpeaking(at: .immediate)
        let u = AVSpeechUtterance(string: L("clio.voice.sample", "你好，我是 ClioTalk。要我帮你开一个计时器吗？"))
        u.voice = selected.flatMap(AVSpeechSynthesisVoice.init(identifier:)) ?? ClioSpeaker.voice(for: lang)
        u.rate = rate
        let d = PreviewDelegate { [weak self] in self?.previewing = false }
        delegate = d; synth.delegate = d
        previewing = true
        synth.speak(u)
    }
    func stopPreview() { synth.stopSpeaking(at: .immediate); previewing = false }

    func askPersonal() { ClioSpeechVoices.requestPersonal { [weak self] in self?.refresh() } }

    func label(_ o: ClioVoiceOption) -> String {
        var s = o.name
        if o.personal { s += " · " + L("clio.voice.personal", "个人声音") }
        else if o.quality == 2 { s += " · " + L("clio.voice.premium", "高品质") }
        else if o.quality == 1 { s += " · " + L("clio.voice.enhanced", "增强") }
        if lang.hasPrefix("en"), o.language != lang, let region = Locale(identifier: o.language).region?.identifier {
            s += " (" + (L10n.language.locale.localizedString(forRegionCode: region) ?? region) + ")"
        }
        return s
    }
}

private final class PreviewDelegate: NSObject, AVSpeechSynthesizerDelegate {
    let done: () -> Void
    init(_ done: @escaping () -> Void) { self.done = done }
    func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish u: AVSpeechUtterance) { DispatchQueue.main.async(execute: done) }
    func speechSynthesizer(_ s: AVSpeechSynthesizer, didCancel u: AVSpeechUtterance) { DispatchQueue.main.async(execute: done) }
}

struct ClioVoiceSection: View {
    @StateObject private var m = ClioVoiceModel()

    var body: some View {
        Section {
            Picker(selection: Binding(get: { m.selected ?? "" }, set: { m.choose($0.isEmpty ? nil : $0) })) {
                Text(L("clio.voice.auto", "自动（这台 Mac 上最好的）")).tag("")
                if !m.options.isEmpty { Divider() }
                ForEach(m.options) { Text(m.label($0)).tag($0.id) }
            } label: {
                RowLabel(title: L("clio.voice.title", "声音"),
                         subtitle: m.options.isEmpty ? L("clio.voice.none", "这台 Mac 还没有这种语言的声音") : L("clio.voice.sub", "这台 Mac 已装好的系统声音"))
            }
            LabeledContent {
                Slider(value: Binding(get: { Double(m.rate) }, set: { m.setRate(Float($0)) }),
                       in: Double(ClioSpeechVoices.rateRange.lowerBound)...Double(ClioSpeechVoices.rateRange.upperBound)) {
                    EmptyView()
                } minimumValueLabel: {
                    Image(systemName: "tortoise").accessibilityLabel(L("clio.rate.slow", "慢"))
                } maximumValueLabel: {
                    Image(systemName: "hare").accessibilityLabel(L("clio.rate.fast", "快"))
                } onEditingChanged: { editing in if !editing { m.preview() } }
                .frame(width: 220)
            } label: {
                Text(L("clio.rate", "语速"))
            }
            if let p = m.personal, p != .authorized {
                LabeledContent {
                    Button(L("clio.voice.personal.ask", "使用个人声音…")) { m.askPersonal() }.disabled(p == .denied)
                } label: {
                    RowLabel(title: L("clio.voice.personal", "个人声音"),
                             subtitle: p == .denied ? L("clio.voice.personal.denied", "已拒绝 · 到「系统设置 › 辅助功能 › 个人声音」允许 HomePlay")
                                                    : L("clio.voice.personal.sub", "用你自己录的声音念回答；声音留在这台 Mac"))
                }
            }
        } header: {
            Text(L("clio.section.voice", "朗读"))
        } footer: {
            FooterButtons {
                Button(m.previewing ? L("clio.voice.stop", "停止") : L("clio.voice.preview", "试听")) { m.previewing ? m.stopPreview() : m.preview() }
                Button(L("clio.voice.more", "下载更多声音…")) {
                    if let u = URL(string: "x-apple.systempreferences:com.apple.Accessibility-Settings.extension?SpokenContent") { NSWorkspace.shared.open(u) }
                }
            }
        }
        .onAppear { m.refresh() }
    }
}
