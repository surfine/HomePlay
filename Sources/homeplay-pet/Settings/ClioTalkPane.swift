import AppKit
import SwiftUI

// 設定「ClioTalk」一頁：照 BYOK.dc.html，系統的分組表單。
// 用哪家 → 金鑰（SecureField，只存鑰匙圈，畫面只顯示末四碼）＋檢查 → 平常／難一點的模型 → 自動升級；
// 可以用的資料（每組工具一個同意開關）；每月上限、這個月用了多少、朗讀、F5、清除對話紀錄；最後一段照實寫隱私。

final class ClioPaneModel: ObservableObject {
    enum KeyState: Equatable { case none, saved, checking, ok(String?), invalid, network, other(String) }

    @Published var provider = ClioSettings.provider
    @Published var keyField = ""
    @Published var keyState = KeyState.none
    @Published var storedHint: String?
    @Published var fast = ""
    @Published var deep = ""
    @Published var spent = 0.0
    @Published var turns = 0
    @Published var onDeviceStatus = ""
    @Published var lmStatus: LMStatus?     // 2.0: nil＝正在檢查

    func refresh() {
        provider = ClioSettings.provider
        fast = ClioSettings.fastModel(provider)
        deep = ClioSettings.deepModel(provider)
        let stored = provider.needsKey ? ClioKeychain.load(provider) : nil
        storedHint = stored.map(ClioKeychain.masked)
        if keyState == .none || keyState == .saved { keyState = stored == nil ? .none : .saved }
        let l = ClioLedger()
        spent = l.spent(); turns = l.turns()
        onDeviceStatus = ClioOnDevice.status
        if provider == .lmStudio { refreshLM() }
    }

    /// 2.0: 只讀地問 LM Studio 現在的狀況（不啟動、不載入；要用時才由 ClioTalk 叫它起來）
    func refreshLM() {
        lmStatus = nil
        Task {
            let s = await LMStudio.status()
            await MainActor.run { self.lmStatus = s }
        }
    }

    func setProvider(_ p: ClioProviderID) {
        ClioSettings.provider = p
        keyField = ""; keyState = .none
        refresh()
    }

    /// 存進鑰匙圈（輸入了新的）再打便宜的唯讀端點檢查
    func check() {
        let p = provider
        let typed = keyField.trimmingCharacters(in: .whitespacesAndNewlines)
        if !typed.isEmpty { ClioKeychain.save(typed, for: p); keyField = "" }
        guard let key = ClioKeychain.load(p) else { keyState = .none; return }
        storedHint = ClioKeychain.masked(key)
        keyState = .checking
        Task {
            let r = await ClioKeyChecker.check(p, key: key)
            await MainActor.run {
                guard self.provider == p else { return }
                switch r {
                case .ok(let d): self.keyState = .ok(d)
                case .invalid: self.keyState = .invalid
                case .network: self.keyState = .network
                case .other(let s): self.keyState = .other(s)
                }
            }
        }
    }

    func removeKey() {
        ClioKeychain.delete(provider)
        keyState = .none; storedHint = nil
    }
}

struct ClioTalkPane: View {
    @StateObject private var m = ClioPaneModel()
    @State private var confirmClear = false
    @State private var tools: [ClioToolGroup: Bool] = Dictionary(uniqueKeysWithValues: ClioToolGroup.allCases.map { ($0, ClioSettings.toolOn($0)) })
    @State private var autoEscalate = ClioSettings.autoEscalate
    @State private var cap = ClioSettings.monthlyCap
    @State private var speak = ClioSettings.speak
    @State private var f5 = ClioSettings.f5OpensClioTalk
    @State private var followUp = ClioSettings.followUpListening
    @State private var shareNameCity = ClioSettings.shareNameAndCity

    private func providerName(_ p: ClioProviderID) -> String {
        switch p {
        case .anthropic: return "Anthropic"
        case .deepseek: return "DeepSeek"
        case .lmStudio: return L("clio.provider.lmStudio", "这台 Mac（LM Studio）")
        case .onDevice: return L("clio.provider.onDevice", "Apple Intelligence")
        }
    }

    private let tint = SettingsSection.cliotalk.tint

    /// 每一组资料的细节（原本写在每一行的第二行，太长，收进 ⓘ）
    private var dataDetails: String {
        [L("clio.tool.home.note", "控制配件与场景、看摄像头；开锁、开车库门前会先念给你听"),
         L("clio.tool.apps.note", "按名字打开 App 和 Web App；访客打不开个人的"),
         L("clio.tool.web.note", "Anthropic 用它自己的搜索；DeepSeek 与本机模型用 DeepSeek 的搜索 API")].map { "· " + $0 }.joined(separator: "\n")
    }

    private func toolSymbol(_ g: ClioToolGroup) -> (String, Color) {
        switch g {
        case .calendar: return ("calendar", .red)
        case .reminders: return ("checklist", .orange)
        case .music: return ("music.note", .pink)
        case .weatherTime: return ("cloud.sun.fill", .blue)
        case .webSearch: return ("safari.fill", .blue)
        case .messages: return ("message.fill", .green)
        case .home: return ("house.fill", .orange)
        case .calls: return ("phone.fill", .green)
        case .apps: return ("square.grid.2x2.fill", .indigo)
        }
    }

    var body: some View {
        Form {
            Section {
                Picker(selection: Binding(get: { m.provider }, set: { m.setProvider($0) })) {
                    ForEach(ClioProviderID.allCases, id: \.self) { Text(providerName($0)).tag($0) }
                } label: {
                    RowLabel(title: L("clio.provider", "用哪家的模型"), symbol: "cpu.fill", tint: tint)
                }
                .pickerStyle(.menu)
                if m.provider.needsKey {
                    LabeledContent {
                        HStack(spacing: 8) {
                            SecureField("", text: $m.keyField,
                                        prompt: Text(m.storedHint.map { String(format: L("clio.key.replace", "已保存 %@ · 输入新的替换"), $0) } ?? L("clio.key.prompt", "粘贴 API 密钥")))
                                .labelsHidden()
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 230)
                                .onSubmit { m.check() }
                            Button(L("clio.key.check", "检查")) { m.check() }
                                .disabled(m.keyState == .checking || (m.keyField.isEmpty && m.storedHint == nil))
                        }
                    } label: {
                        RowLabel(title: L("clio.key", "API 密钥"), subtitle: keyLine, symbol: "key.fill", tint: tint)
                    }
                    Picker(selection: Binding(get: { m.fast }, set: { ClioSettings.setFastModel($0, m.provider); m.refresh() })) {
                        ForEach(m.provider.fastChoices, id: \.self) { Text(modelLabel($0)).tag($0) }
                    } label: { RowLabel(title: L("clio.fast", "平常回答"), symbol: "hare.fill", tint: tint) }
                    Picker(selection: Binding(get: { m.deep }, set: { ClioSettings.setDeepModel($0, m.provider); m.refresh() })) {
                        ForEach(m.provider.deepChoices, id: \.self) { Text(modelLabel($0)).tag($0) }
                    } label: { RowLabel(title: L("clio.deep", "难一点的问题"), symbol: "brain.head.profile.fill", tint: tint) }
                    Toggle(isOn: Binding(get: { autoEscalate }, set: { autoEscalate = $0; ClioSettings.autoEscalate = $0 })) {
                        RowLabel(title: L("clio.autoEscalate", "遇到难题时自动切换"),
                                 subtitle: L("clio.autoEscalate.sub", "也可以直接说「想深一点」"), symbol: "arrow.up.forward.circle.fill", tint: tint)
                    }
                } else if m.provider == .lmStudio {
                    LabeledContent {
                        HStack(spacing: 10) {
                            InfoButton(L("clio.lm.note", "ClioTalk 连到这台 Mac 上的 LM Studio，用你载入的模型回答，不需要密钥。LM Studio 没开会试着叫它起来；没有载入模型时会挑一个载入。模型要支持工具才能控制家里，否则只能聊天。"))
                            Button(L("clio.lm.recheck", "重新检查")) { m.refreshLM() }.disabled(m.lmStatus == nil)
                        }
                    } label: {
                        RowLabel(title: L("clio.lm.title", "LM Studio"), subtitle: lmLine, symbol: "desktopcomputer", tint: tint)
                    }
                } else {
                    InfoRow(title: L("clio.onDevice.title", "Apple Intelligence"), subtitle: m.onDeviceStatus, symbol: "apple.intelligence", tint: tint)
                }
            } header: {
                IllustrationHeader(scene: .clio, note: L("clio.demoNote", "按住 F5 说话，用你自己的模型回答"),
                                   info: L("clio.worldview", "ClioTalk 不替你发声：用你名义送出的，先念给你听、你说「好」才做。回答是暂时的，说「留下」才存。模型用你自己的，能在这台 Mac 上就在这台 Mac 上。"))
            } footer: {
                if m.provider.needsKey {
                    FooterButtons {
                        if m.storedHint != nil { Button(L("clio.key.remove", "移除密钥")) { m.removeKey() } }
                        Link(m.provider == .anthropic ? L("clio.key.getAnthropic", "申请 Anthropic 密钥…") : L("clio.key.getDeepSeek", "申请 DeepSeek 密钥…"),
                             destination: URL(string: m.provider == .anthropic ? "https://platform.claude.com/" : "https://platform.deepseek.com/api_keys")!)
                    }
                } else if m.provider == .lmStudio, m.lmStatus == .notInstalled {
                    FooterButtons { Link(L("clio.lm.download", "下载 LM Studio…"), destination: URL(string: "https://lmstudio.ai/")!) }
                }
            }

            Section {
                // 2.0 第六輪（使用者決定 #2）：每輪送「名（不送姓）＋大約城市」；關掉只影響雲端模型
                ToggleRow(title: L("clio.shareNameCity", "分享我的名字与城市"), subtitle: L("clio.shareNameCity.short", "回答才叫得出你、知道你在哪"),
                          symbol: "person.text.rectangle.fill", tint: .blue,
                          info: L("clio.shareNameCity.sub", "每次问的时候附上你的名（不含姓）和大概的城市，回答才叫得出你、知道你在哪；这台 Mac 上的模型不受影响"),
                          isOn: Binding(get: { shareNameCity }, set: { shareNameCity = $0; ClioSettings.shareNameAndCity = $0 }))
                ForEach(ClioToolGroup.allCases, id: \.self) { g in
                    Toggle(isOn: Binding(get: { tools[g] ?? g.defaultOn }, set: { tools[g] = $0; ClioSettings.setTool(g, $0) })) {
                        RowLabel(title: g.title, subtitle: g.note, symbol: toolSymbol(g).0, tint: toolSymbol(g).1)
                    }
                    .disabled(m.provider == .onDevice)   // 2.0 depth：DeepSeek 也有網頁搜尋了（ClioWebSearch），這一組要能關
                }
            } header: {
                SectionTitle(title: L("clio.section.data", "ClioTalk 可以用的资料"),
                             info: m.provider == .onDevice ? L("clio.data.onDeviceNote", "用 Apple Intelligence 时不使用这些资料")
                                                           : L("clio.data.note", "只有回答需要时才读取，只送那几笔；加行程、加提醒、发信息之前会先念给你听，你说「好」才做") + "\n\n" + dataDetails)
            }

            ClioVoiceSection()   // 2.0 P10：聲音與語速（Settings/ClioVoiceSection.swift）

            Section {
                LabeledContent {
                    HStack(spacing: 4) {
                        Text("US$").foregroundStyle(.secondary)
                        TextField("", value: Binding(get: { cap }, set: { cap = max(0, $0); ClioSettings.monthlyCap = cap }),
                                  format: .number.precision(.fractionLength(0...2)))
                            .textFieldStyle(.roundedBorder).frame(width: 70).multilineTextAlignment(.trailing)
                    }
                } label: {
                    RowLabel(title: L("clio.cap", "每月最多花"), subtitle: L("clio.cap.sub", "到了就先不回答；0 表示不限"), symbol: "dollarsign.circle.fill", tint: .green)
                }
                InfoRow(title: L("clio.usage", "这个月用了"),
                        subtitle: String(format: L("clio.usage.short", "约 US$%.2f · %d 轮"), m.spent, m.turns), symbol: "chart.bar.fill", tint: .green,
                        info: L("clio.usage.note", "这是估算，以账单为准"))
                Toggle(isOn: Binding(get: { speak }, set: { speak = $0; ClioSettings.speak = $0 })) {
                    RowLabel(title: L("clio.speak", "念出回答"), subtitle: L("clio.speak.sub", "一句一句念；点「停止」就停"), symbol: "speaker.wave.2.fill", tint: tint)
                }
                Toggle(isOn: Binding(get: { f5 }, set: { f5 = $0; ClioSettings.f5OpensClioTalk = $0 })) {
                    RowLabel(title: L("clio.f5", "F5 叫 ClioTalk"), subtitle: L("clio.f5.short", "CarPlay 直播时 F5 仍给 Siri"), symbol: "mic.fill", tint: tint)
                }
                ToggleRow(title: L("clio.followUp", "回答完再听 8 秒"), subtitle: L("clio.followUp.short", "不用再按 F5 就能接着问"), symbol: "ear.fill", tint: tint,
                          info: L("clio.followUp.sub", "不用再按 F5 就能接着问；声音只在这台 Mac 上转成文字"),
                          isOn: Binding(get: { followUp }, set: { followUp = $0; ClioSettings.followUpListening = $0 }))
                InfoRow(title: L("clio.privacy.title", "资料送到哪里"), subtitle: L("clio.privacy.short", "直接送到你选的公司"), symbol: "hand.raised.fill", tint: .blue,
                        info: L("clio.privacy", "你问的话和回答时用到的资料（例如那几笔日历），会直接从这台 Mac 送到你选的公司，按它的条款处理；这和 Apple 的私有云计算不一样。密钥只存在这台 Mac 的钥匙串，HomePlay 不会传给任何人。选「Apple Intelligence」就完全不联网，但只有它打开时能用，回答也比较简短。选「这台 Mac（LM Studio）」时对话留在这台 Mac，用你载入的模型回答；只有开着「网页搜索」又有 DeepSeek 密钥时，搜索词才会送给 DeepSeek。"))
            } footer: {
                FooterButtons { Button(L("clio.clear", "清除对话纪录…")) { confirmClear = true } }
            }
        }
        .formStyle(.grouped)
        .onAppear { m.refresh() }
        .confirmationDialog(L("clio.clear.title", "清除对话纪录？"), isPresented: $confirmClear) {
            Button(L("clio.clear.confirm", "清除"), role: .destructive) { ClioTalkController.shared.clearHistory(); m.refresh() }
        } message: {
            Text(L("clio.clear.message", "这台 Mac 上的 ClioTalk 对话和留下的回答都会删除"))
        }
    }

    private var lmLine: String {
        switch m.lmStatus {
        case nil: return L("clio.key.checking", "正在检查…")
        case .notInstalled?: return L("clio.lm.status.notInstalledShort", "没有找到 LM Studio")
        case .serverOff?: return L("clio.lm.status.offShort", "没开，问问题时会自动启动")
        case .noModels?: return L("clio.lm.status.noModelShort", "在运行，但还没有模型")
        case .idle?: return L("clio.lm.status.idleShort", "在运行，问的时候自动载入模型")
        case let .ready(name, tools)?:
            return String(format: tools ? L("clio.lm.status.readyShort", "● 可以用 · %@") : L("clio.lm.status.readyChatShort", "● %@ · 只能聊天"), name)
        }
    }

    private var keyLine: String {
        switch m.keyState {
        case .none: return L("clio.key.none", "还没有密钥")
        case .saved: return L("clio.key.saved", "存在这台 Mac 的钥匙串")
        case .checking: return L("clio.key.checking", "正在检查…")
        case .ok(let d): return L("clio.key.okShort", "● 可以用") + (d.map { " · " + $0 } ?? "")
        case .invalid: return L("clio.key.invalid", "密钥无效或已过期")
        case .network: return L("clio.key.network", "连不上，稍后再检查")
        case .other(let s): return s
        }
    }

    private func modelLabel(_ id: String) -> String {
        switch id {
        case "claude-haiku-5-5": return ClioModels.displayName(id) + L("clio.model.fastest", "（最快）")
        case "claude-fable-5-1": return ClioModels.displayName(id) + L("clio.model.slowest", "（最慢、最贵）")
        default: return ClioModels.displayName(id)
        }
    }
}
