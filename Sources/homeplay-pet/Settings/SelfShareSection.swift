import AppKit
import SwiftUI

// 設定 › CarPlay ›「傳到 iPhone」：CarPlay 連著時 iPhone 不能用 AirDrop，桌寵改用訊息傳給你自己——這裡選傳到哪個帳號。
// 自動＝chat.db 裡你傳 iMessage 最常用的寄件帳號（要完整磁碟取用權限）；選過就記住。帳號只顯示在這裡，不寫日誌。

final class SelfShareModel: ObservableObject {
    @Published var candidates: [String] = []
    @Published var chosen: String = SelfShare.chosenHandle ?? ""
    @Published var access: MessagesAccess = .available
    /// 背景查完了沒（查完之前不出「自己填」的框，免得閃一下）
    @Published var loaded = false

    init() { reload() }
    /// 查 chat.db 放背景佇列（跟傳給自己的快取同一條佇列），不卡設定視窗
    func reload() {
        let demo = CCSystem.demo
        SelfShareFlow.lookupQueue.async { [weak self] in
            let a: MessagesAccess = demo ? .available : MessagesAccess.check()
            let found = a == .available ? (MessagesStore.openDefault()?.ownHandles() ?? []) : []
            DispatchQueue.main.async {
                guard let self else { return }
                self.access = a
                var c = found
                if !self.chosen.isEmpty, !c.contains(self.chosen) { c.append(self.chosen) }   // 選過、但最近沒用過的帳號也留著
                self.candidates = c
                self.loaded = true
            }
        }
    }
    func choose(_ h: String) { chosen = h; SelfShare.chosenHandle = h.isEmpty ? nil : h }
}

struct SelfShareSection: View {
    @StateObject private var m = SelfShareModel()

    var body: some View {
        Section {
            Picker(selection: Binding(get: { m.chosen }, set: { m.choose($0) })) {
                Text(m.candidates.first.map { String(format: L("selfshare.auto.with", "自动（%@）"), $0) } ?? L("selfshare.auto", "自动")).tag("")
                if !m.candidates.isEmpty { Divider() }
                ForEach(m.candidates, id: \.self) { Text($0).tag($0) }
            } label: {
                RowLabel(title: L("selfshare.account", "传给自己的账户"), subtitle: subtitle)
            }
            .disabled(m.candidates.isEmpty)
            if m.loaded, m.candidates.isEmpty, m.access == .available {   // 「訊息」裡找不到：自己填一次
                TextField(L("selfshare.manual", "电话或电子邮件"), text: Binding(get: { m.chosen }, set: { m.choose($0.trimmingCharacters(in: .whitespaces)) }))
            }
        } header: {
            Text(L("selfshare.header", "传到 iPhone"))
        } footer: {
            VStack(alignment: .trailing, spacing: 6) {
                Text(L("selfshare.footer", "CarPlay 连着时 iPhone 不能用 AirDrop：照片、网页、食谱改用信息传给你自己，传之前会先问一次。"))
                    .font(.footnote).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                if m.access == .needsFullDiskAccess {
                    FooterButtons { Button(L("msg.fda.open", "打开系统设置")) { NSWorkspace.shared.open(MessagesAccess.fullDiskAccessURL) } }
                }
            }
        }
        .onAppear { m.reload() }
    }

    private var subtitle: String? {
        switch m.access {
        case .needsFullDiskAccess: return L("selfshare.needsFDA", "要先允许完全磁盘访问权限")
        case .noDatabase: return L("selfshare.noMessages", "这台 Mac 没有登录“信息”")
        default: return m.loaded && m.candidates.isEmpty ? L("selfshare.none", "还没有用 iMessage 传过信息") : nil
        }
    }
}
