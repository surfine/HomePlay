import AppKit
import SwiftUI

// 來電卡：接收器把 iAP2 0x4155（通話狀態）轉成 `{"type":"call",...}`、0x4158（電信商與訊號）轉成
// `{"type":"cellular",...}`。桌寵在通話期間顯示一張浮在桌寵下緣的小卡（接聽／拒接、通話中可掛斷），
// 按鍵經接收器送 CarPlay 電話 HID。卡是獨立的子視窗：CarPlay 畫面蓋在錶面上時也看得到、點得到。

/// 接收器送來的通話狀態（只存狀態，不存譯好的字）
struct PhoneCallInfo: Equatable {
    enum State: String { case idle, ringing, dialing, active, held }

    var state: State = .idle
    var name: String?
    var number: String?
    var incoming = false
    var uuid: String?

    static func parse(_ json: String) -> PhoneCallInfo? {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              obj["type"] as? String == "call",
              let state = (obj["state"] as? String).flatMap(State.init(rawValue:)) else { return nil }
        var out = PhoneCallInfo()
        out.state = state
        out.name = (obj["name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        out.number = (obj["number"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        out.incoming = obj["incoming"] as? Bool ?? false
        out.uuid = obj["uuid"] as? String
        return out
    }

    var showsCard: Bool { state != .idle }
    /// 來電響鈴：卡片給接聽／拒接，並把 CarPlay 叫到前面
    var isIncomingRing: Bool { state == .ringing }

    var actions: [PhoneCallAction] { isIncomingRing ? [.decline, .answer] : (showsCard ? [.hangUp] : []) }

    /// 卡片大字：聯絡人名字 > 號碼 > 「未知來電」
    var title: String {
        name ?? number ?? L("call.unknownCaller", "未知号码")
    }

    /// 卡片小字：狀態；有名字又有號碼時把號碼也帶上
    func subtitle(carrier: String?) -> String {
        let phase: String
        switch state {
        case .ringing: phase = L("call.state.ringing", "来电")
        case .dialing: phase = L("call.state.dialing", "正在拨号…")
        case .active: phase = L("call.state.active", "通话中")
        case .held: phase = L("call.state.held", "通话保持中")
        case .idle: phase = ""
        }
        var parts = [phase]
        if name != nil, let number { parts.append(number) }
        if state == .ringing, let carrier, !carrier.isEmpty { parts.append(carrier) }
        return parts.joined(separator: " · ")
    }
}

enum PhoneCallAction: String {
    case answer, decline, hangUp = "hangup"

    var label: String {
        switch self {
        case .answer: return L("call.answer", "接听")
        case .decline: return L("call.decline", "拒接")
        case .hangUp: return L("call.hangUp", "挂断")
        }
    }
    var symbol: String { self == .answer ? "phone.fill" : "phone.down.fill" }
    var tint: Color { self == .answer ? Color(nsColor: .systemGreen) : Color(nsColor: .systemRed) }
}

/// 0x4158 轉來的電信商與訊號（0–5 格）
struct CellularInfo: Equatable {
    var carrier: String?
    var signal: Int?

    static func parse(_ json: String) -> CellularInfo? {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              obj["type"] as? String == "cellular" else { return nil }
        return CellularInfo(carrier: (obj["carrier"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                            signal: (obj["signal"] as? NSNumber)?.intValue)
    }
}

/// F5 按住說話：桌寵有三個來源（CGEventTap、全域 keyDown 監聽、Carbon 熱鍵）可能同時報同一下，
/// 重複的按下與放開在這裡吸收；按住超過 `maxHold` 秒自動放開，免得漏掉放開讓手機一直聽。
struct SiriHoldKey: Equatable {
    static let maxHold: Double = 30
    private(set) var held = false
    private(set) var downAt = 0.0

    /// 真的是一次新的按下才回 true
    mutating func press(now: Double) -> Bool {
        guard !held else { return false }
        held = true; downAt = now
        return true
    }

    /// 真的有按著才回 true
    mutating func release() -> Bool {
        guard held else { return false }
        held = false
        return true
    }

    func overdue(now: Double) -> Bool { held && now - downAt >= Self.maxHold }
}

// MARK: - 卡片

final class PhoneCallCardModel: ObservableObject {
    @Published var call = PhoneCallInfo()
    @Published var carrier: String?
    var onAction: ((PhoneCallAction) -> Void)?
}

struct PhoneCallCardView: View {
    @ObservedObject var model: PhoneCallCardModel

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "phone.fill")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .background(Circle().fill(Color(nsColor: .systemGreen)))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.call.title)
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(1)
                Text(model.call.subtitle(carrier: model.carrier))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            ForEach(model.call.actions, id: \.rawValue) { action in
                Button { model.onAction?(action) } label: {
                    Image(systemName: action.symbol)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 36, height: 36)
                        .background(Circle().fill(action.tint))
                }
                .buttonStyle(.plain)
                .help(action.label)
                .accessibilityLabel(action.label)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(width: 320)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
            .strokeBorder(Color.primary.opacity(0.08)))
    }
}

/// 浮在桌寵下緣的來電卡（子視窗：跟著桌寵移動；不搶焦點）
final class PhoneCallCard {
    let model = PhoneCallCardModel()
    private var panel: NSPanel?

    var isVisible: Bool { panel?.isVisible ?? false }

    func show(attachedTo parent: NSWindow) {
        let p = panel ?? makePanel()
        panel = p
        let size = p.contentView?.fittingSize ?? NSSize(width: 320, height: 60)
        p.setContentSize(size)
        // 預設蓋在桌寵下緣、水平置中；下方放不下（貼螢幕底）就放到上緣
        let f = parent.frame
        let visible = (parent.screen ?? NSScreen.main)?.visibleFrame ?? f
        var origin = NSPoint(x: f.midX - size.width / 2, y: f.minY + 12)
        if origin.y < visible.minY { origin.y = f.maxY - size.height - 12 }
        origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - size.width - 8)
        p.setFrameOrigin(origin)
        if p.parent !== parent {
            p.parent?.removeChildWindow(p)
            parent.addChildWindow(p, ordered: .above)
        }
        p.orderFront(nil)
    }

    func hide() {
        guard let p = panel else { return }
        p.parent?.removeChildWindow(p)
        p.orderOut(nil)
    }

    private func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 320, height: 60),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        p.isReleasedWhenClosed = false
        p.hidesOnDeactivate = false
        let host = NSHostingView(rootView: PhoneCallCardView(model: model))
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        p.contentView = host
        return p
    }
}
