import AppKit
import SwiftUI
import CoreImage

// 2.0 閒置裝置：設定「iPhone 與 iPad」一頁（稿：hv-design/project/IdlePairing.dc.html），系統的分組表單。
// 開關（預設關）→ 裝置（每台：串流狀態、上次的位址、顯示個人內容、移除）→ 新增裝置（QR＋配對碼，10 分鐘失效）→ 一段照實寫的說明。
// 裝置名字是裝置自己報的（只去掉控制字元），畫面上註明；打開「顯示個人內容」時照實警告：同網路的人有機會冒充它。

final class RemotePaneModel: ObservableObject {
    @Published var enabled = RemoteStore.enabled
    @Published var devices: [RemoteDevice] = []
    @Published var connected: Set<String> = []
    @Published var code: [UInt8]?
    @Published var expires: Double?
    @Published var urls: [String] = []
    private var observer: Any?
    private var timer: Timer?

    init() {
        observer = NotificationCenter.default.addObserver(forName: RemoteServer.changed, object: nil, queue: .main) { [weak self] _ in self?.refresh() }
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.tickExpiry() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }
    deinit { if let observer { NotificationCenter.default.removeObserver(observer) }; timer?.invalidate() }

    func refresh() {
        enabled = RemoteStore.enabled
        devices = RemoteStore.shared.all
        connected = Set(RemoteServer.shared.connected.keys)
        urls = RemoteServer.urls()
        code = RemoteStore.shared.pairingSecret
        expires = code == nil ? nil : RemoteStore.shared.pairingExpires
        if enabled, code == nil { newCode() }
    }

    func setEnabled(_ on: Bool) {
        RemoteStore.enabled = on
        RemoteServer.shared.apply(enabled: on)
        refresh()
    }

    func newCode() {
        guard RemoteStore.enabled else { return }
        code = RemoteStore.shared.newPairing()
        expires = RemoteStore.shared.pairingExpires
    }

    private func tickExpiry() {
        guard enabled else { return }
        let live = RemoteStore.shared.pairingSecret
        if live != code { code = live; expires = live == nil ? nil : RemoteStore.shared.pairingExpires }
        objectWillChange.send()
    }

    /// QR 裡的網址：第一個（.local）＋ #p=配對碼（# 後面不會送到伺服器）
    var pairURL: String? {
        guard let code, let base = urls.first else { return nil }
        return base + "#p=" + RemoteCrypto.encode(code)
    }

    var minutesLeft: Int { max(0, Int(((expires ?? 0) - Date().timeIntervalSince1970) / 60 + 0.99)) }
}

enum QRCode {
    static func image(_ text: String) -> NSImage? {
        guard let f = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        f.setValue(Data(text.utf8), forKey: "inputMessage")
        f.setValue("M", forKey: "inputCorrectionLevel")
        guard let out = f.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)),
              let cg = CIContext().createCGImage(out, from: out.extent) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: out.extent.width / 2, height: out.extent.height / 2))
    }
}

struct RemoteDevicesPane: View {
    @StateObject private var m = RemotePaneModel()
    @State private var removing: RemoteDevice?

    var body: some View {
        Form {
            Section {
                Toggle(isOn: Binding(get: { m.enabled }, set: { m.setEnabled($0) })) {
                    RowLabel(title: L("remote.enable", "让 iPhone、iPad 显示 HomePlay"),
                             subtitle: m.enabled && RemoteServer.shared.listenFailed ? L("remote.listenFailed", "现在连不进来：连接端口被别的程序占着。关掉再打开试试")
                                                                                     : L("remote.enable.sub", "同一个 Wi‑Fi 里的设备才看得到这台 Mac"))
                }
            }

            Section {
                if m.devices.isEmpty {
                    InfoRow(title: L("remote.noDevices", "还没有设备"))
                }
                ForEach(m.devices, id: \.id) { d in
                    LabeledContent {
                        HStack(spacing: 12) {
                            Toggle(L("remote.device.personal", "显示个人内容"), isOn: Binding(
                                get: { d.personal },
                                set: { RemoteServer.shared.setPersonal(d.id, $0); m.refresh() }))
                                .toggleStyle(.switch).controlSize(.small)
                                .help(L("remote.device.personal.help", "信息、照片、日历、提醒、FaceTime；只给你自己的设备打开"))
                            Button(L("remote.device.remove", "移除…"), role: .destructive) { removing = d }
                        }
                    } label: {
                        RowLabel(title: d.name, subtitle: status(d))
                            .help(L("remote.device.nameNote", "名称是这台设备自己报的，不一定是真的"))
                    }
                    if d.personal {
                        Label(L("remote.device.personal.warning", "网页版走的是一般 http：同一个 Wi‑Fi 里有心人可能冒充这台设备，看到你的个人内容。只在你信任的家庭网络里打开。"),
                              systemImage: "exclamationmark.triangle.fill")
                            .font(.callout).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                    }
                }
                if let r = RemoteServer.lastAutoRevoked {
                    Label(String(format: L("remote.autoRevoke.body", "「%@」同时从两个网络地址连进来，可能有人复制了它的密钥。要继续用请重新配对。"), r.name),
                          systemImage: "exclamationmark.shield.fill")
                        .font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                }
            } header: {
                Text(L("remote.section.devices", "设备"))
            }

            if m.enabled {
                Section {
                    HStack(alignment: .center, spacing: 18) {
                        if let u = m.pairURL, let img = QRCode.image(u) {
                            Image(nsImage: img).interpolation(.none).resizable().frame(width: 132, height: 132)
                                .accessibilityLabel(L("remote.add.qr", "配对用的 QR 码"))
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            Text(L("remote.add.body", "用 iPhone／iPad 的相机扫这个码，在 Safari 打开网页版；或者在网页上输入配对码。"))
                                .fixedSize(horizontal: false, vertical: true)
                            if let c = m.code {
                                Text(RemoteCrypto.display(c)).font(.system(.title3, design: .monospaced).weight(.semibold)).textSelection(.enabled)
                                Text(String(format: L("remote.add.expires", "码里有一次性密码，%d 分钟后失效。"), m.minutesLeft))
                                    .font(.callout).foregroundStyle(.secondary)
                            } else {
                                Text(L("remote.add.expired", "这个码已失效")).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                    LabeledContent {
                        VStack(alignment: .trailing, spacing: 2) {
                            ForEach(m.urls, id: \.self) { Text($0).textSelection(.enabled).foregroundStyle(.secondary) }
                        }
                    } label: {
                        Text(L("remote.add.address", "网址"))
                    }
                } header: {
                    Text(L("remote.section.add", "新增设备"))
                } footer: {
                    FooterButtons { Button(L("remote.add.new", "产生新的码")) { m.newCode() } }
                }
            }

            Section {
            } footer: {
                Text(L("remote.footer", "串流的设备要这台 Mac 醒着。画面只在家里的网络里传，而且加密；没配对的设备什么都看不到。访客设备看不到信息、照片、日历这些个人内容。"))
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .formStyle(.grouped)
        .onAppear { m.refresh() }
        .confirmationDialog(String(format: L("remote.remove.title", "移除「%@」？"), removing?.name ?? ""), isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button(L("remote.remove.confirm", "移除"), role: .destructive) {
                if let d = removing { RemoteServer.shared.revoke(d.id) }
                removing = nil; m.refresh()
            }
        } message: {
            Text(L("remote.remove.message", "这台设备会断线，要再显示 HomePlay 得重新配对。"))
        }
    }

    private func status(_ d: RemoteDevice) -> String {
        var parts: [String] = []
        if m.connected.contains(d.id) { parts.append(L("remote.device.live", "串流 · 已连接")) }
        else if let t = d.lastSeen {
            let rel = RelativeDateTimeFormatter()
            rel.unitsStyle = .short
            parts.append(String(format: L("remote.device.last", "串流 · 上次 %@"), rel.localizedString(for: Date(timeIntervalSince1970: t), relativeTo: Date())))
        } else { parts.append(L("remote.device.never", "串流 · 还没连过")) }
        if let ip = d.lastIP { parts.append(String(format: L("remote.device.ip", "来自 %@"), ip)) }
        parts.append(L("remote.device.nameSource", "名称由设备提供"))
        return parts.joined(separator: " · ")
    }
}
