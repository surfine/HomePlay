import AppKit
import SwiftUI

// 设置窗口（⌘,）：系统标准的工具栏分页外观，各页用 SwiftUI。
// 状态与动作全部接回原有实现（AppDelegate / PetView 的菜单动作），不另存一份，免得两边不一致。

/// 设置窗口读写的那些状态。窗口打开、取得焦点时、以及每 1.5 秒刷新一次（权限状态会在系统设置里被改）。
final class SettingsModel: ObservableObject {
    weak var app: AppDelegate?
    @Published var section = SettingsSection(rawValue: UserDefaults.standard.string(forKey: SettingsSection.key) ?? "") ?? .general {
        didSet { UserDefaults.standard.set(section.rawValue, forKey: SettingsSection.key) }
    }

    @Published var loginItem = false
    @Published var loginAvailable = false
    @Published var autoConnect = false
    @Published var carVideo = CarVideoSetting.allowed
    @Published var cornerStyle = ConcentricCorners.style
    @Published var cornerInset = ConcentricCorners.appliedInset
    @Published var alwaysOnTop = true
    @Published var language = "system"
    @Published var calendarOn = false
    @Published var nowPlayingOn = false

    @Published var finish = Finish.starlight
    @Published var faceStyle = FaceStyle.island
    @Published var capsule = CapsuleMaterial.auto
    @Published var clockStyle = ClockStyle.bold
    @Published var islandBackground = IslandBackground.daytime
    @Published var era = Era.y2026
    @Published var typographMaterial = TypographMaterial.flat
    @Published var system6Layout = System6Layout.finder
    /// 這個錶面用自己年代的島身（System 6 系列、島的 1988／2002）：膠囊設定在這裡不作用
    var capsuleLocked: Bool { [.system6, .alarmClock, .about].contains(faceStyle) || (faceStyle == .island && era != .y2026) }
    /// 「字體與顏色」只作用在 2026 的島與照片錶面
    var clockLookApplies: Bool { (faceStyle == .island && era == .y2026) || faceStyle == .photos }
    @Published var viewMode = ViewMode.auto
    @Published var touring = false   // 2.0 P06: 自動環繞（從右鍵選單搬來）

    @Published var phones: [CarPlayPhoneBook.Phone] = []
    @Published var currentPhone: String?

    @Published var gazeFollow = false
    @Published var followDegrees = 25.0
    @Published var gazePitch = 2.5
    @Published var roomLight = false
    @Published var petWidth = Double(Pet.defaultWidth)

    @Published var permissions: [PermissionKind: PermissionStatus] = [:]

    func refresh() {
        guard let app else { return }
        let s = app.settingsSnapshot()
        loginItem = s.loginItem; loginAvailable = s.loginAvailable
        autoConnect = s.autoConnect; alwaysOnTop = s.alwaysOnTop
        carVideo = CarVideoSetting.allowed
        cornerStyle = ConcentricCorners.style
        cornerInset = ConcentricCorners.appliedInset
        language = PetLanguage.chosen?.rawValue ?? "system"
        calendarOn = CalendarSource.enabled; nowPlayingOn = NowPlayingPoller.enabled
        finish = s.finish; faceStyle = s.faceStyle; viewMode = s.viewMode; touring = app.view?.touring ?? false; capsule = capsuleMaterialSetting
        if let f = app.view?.face { clockStyle = f.clockStyle == .thin ? .bold : f.clockStyle; islandBackground = f.background; era = f.era; typographMaterial = f.typographMaterial; system6Layout = f.system6Layout }
        phones = CarPlayPhoneBook.phones; currentPhone = CarPlayPhoneBook.current
        gazeFollow = s.gazeFollow; followDegrees = s.followDegrees; gazePitch = s.gazePitch; roomLight = s.roomLight; petWidth = s.petWidth
        var p: [PermissionKind: PermissionStatus] = [:]
        for k in PermissionKind.allCases { p[k] = PermissionCenter.status(k) }
        permissions = p
    }

    /// 走菜单同一条路（PetView 的 @objc 动作），之后刷新
    func perform(_ selector: String, _ represented: Any? = nil) {
        app?.settingsPerform(selector, represented)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.refresh() }
    }
}

/// 侧边栏的分页（顺序＝显示顺序）；上次看到哪一页会记住
enum SettingsSection: String, CaseIterable, Identifiable {
    case general, appearance, gestures, carplay, cliotalk, camera, people, devices, permissions   // 2.0：ClioTalk、people＝家人、devices＝iPhone 與 iPad（網頁串流）
    var id: String { rawValue }
    static let key = "HomePlaySettingsSection"
    var title: String {
        switch self {
        case .general: return L("settings.general", "通用")
        case .appearance: return L("settings.appearance", "外观")
        case .gestures: return L("settings.gestures", "手势")
        case .carplay: return L("settings.carplay", "CarPlay")
        case .cliotalk: return L("settings.cliotalk", "ClioTalk")
        case .camera: return L("settings.camera", "相机")
        case .people: return L("settings.people", "家人")
        case .devices: return L("settings.devices", "iPhone 与 iPad")
        case .permissions: return L("settings.permissions", "权限")
        }
    }
    /// 侧边栏符号：线条版，跟 WindowShade 一样由 source list 染成强调色
    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .appearance: return "circle.lefthalf.filled"
        case .gestures: return "hand.point.up.left"
        case .carplay: return "car"
        case .cliotalk: return "bubble.left.and.text.bubble.right"
        case .camera: return "camera"
        case .people: return "person.2"
        case .devices: return "ipad.and.iphone"
        case .permissions: return "hand.raised"
        }
    }
    /// 搜索用：这一页里每一行的标题（按当前语言）
    private var keywordKeys: [String] {
        switch self {
        case .general: return ["settings.loginItem", "settings.alwaysOnTop", "settings.language", "settings.size", "prefs.nowPlaying", "settings.lyrics", "prefs.calendar.on", "prefs.hints"]
        case .appearance: return ["settings.facing", "settings.angle", "settings.finish", "settings.face"]
        case .gestures: return ["settings.gesture.pinch.title", "settings.gesture.slide.title", "settings.gesture.three.title", "settings.gesture.force.title",
                                "settings.gesture.liveSlide", "settings.gesture.reset", "settings.gesture.apart", "settings.gesture.overview", "settings.gesture.keys"]
        case .carplay: return ["prefs.plugConnect", "menu.iphone", "menu.pairNewPhone", "menu.wifiPassword", "handoff.header"]   // 2.0 promo
        case .cliotalk: return ["clio.provider", "clio.key", "clio.fast", "clio.deep", "clio.section.data", "clio.cap", "clio.speak", "clio.f5", "clio.clear"]
        case .camera: return ["settings.follow.title", "settings.followRange", "settings.followPitch", "settings.roomLight.title"]
        case .people: return ["people.pane.recognize", "people.pane.family", "people.pane.addTitle", "people.pane.deleteAll"]
        case .devices: return ["remote.enable", "remote.section.devices", "remote.section.add", "remote.device.personal"]
        case .permissions: return ["settings.perm.camera", "settings.perm.mic", "settings.perm.input", "settings.perm.automation", "settings.perm.calendar"]
        }
    }
    func matches(_ query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return true }
        return ([title] + keywordKeys.map { L10n.text($0, "") }).contains { $0.localizedCaseInsensitiveContains(q) }
    }
}

/// 无边框桌宠 App 没有标准的「关闭窗口」菜单：⌘W、Esc 在这里自己处理。
final class SettingsPanelWindow: NSWindow {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "w" { performClose(nil); return true }
        return super.performKeyEquivalent(with: event)
    }
    override func cancelOperation(_ sender: Any?) { performClose(nil) }
}

final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    static var shared: SettingsWindowController?
    let model: SettingsModel
    private var timer: Timer?

    static func show(app: AppDelegate, pane: SettingsSection? = nil) {
        let c = shared ?? SettingsWindowController(app: app)
        shared = c
        c.model.refresh()
        if let pane { c.model.section = pane }
        NSApp.activate(ignoringOtherApps: true)
        c.showWindow(nil)
        c.window?.makeKeyAndOrderFront(nil)
        c.startTimer()
    }

    private init(app: AppDelegate) {
        let model = SettingsModel()
        model.app = app
        self.model = model
        let host = NSHostingController(rootView: SettingsRoot().environmentObject(model))
        let w = SettingsPanelWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 680),
                                    styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                    backing: .buffered, defer: false)
        w.title = L("settings.title", "设置")
        w.contentViewController = host
        w.minSize = NSSize(width: 820, height: 580)
        w.toolbarStyle = .unified
        w.titlebarAppearsTransparent = true     // 标题栏和分组表单的底色连成一片（系统设置同款）
        w.titlebarSeparatorStyle = .none
        w.isReleasedWhenClosed = false
        w.tabbingMode = .disallowed
        w.level = .floating + 1          // 桌宠是浮动窗口：设置要在它上面
        w.setContentSize(NSSize(width: 900, height: 680))
        w.center()
        w.setFrameAutosaveName("HomePlay.Settings.v2")   // 版面改成 900×680：换新名字，旧的 800×600 记录不再套用
        // 截图验收：HOMEPLAY_SETTINGS_H=高度（点）把窗口拉高，一页看全
        if let h = ProcessInfo.processInfo.environment["HOMEPLAY_SETTINGS_H"].flatMap(Double.init) {
            w.setContentSize(NSSize(width: 900, height: h)); w.center()
        }
        super.init(window: w)
        w.delegate = self
    }
    required init?(coder: NSCoder) { fatalError() }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in self?.model.refresh() }
    }
    func windowDidBecomeKey(_ notification: Notification) { model.refresh() }
    func windowWillClose(_ notification: Notification) { timer?.invalidate(); timer = nil }
}

/// 侧边栏＋内容：原生 source list（单色线条图示，跟 WindowShade 一样）＋搜索；
/// 标题栏「HomePlay 设置」，副标题是当前分页；内容是各页自己的分组表单（Form 自己滚动）。
struct SettingsRoot: View {
    @EnvironmentObject var m: SettingsModel
    @State private var query = ""
    private var visible: [SettingsSection] { SettingsSection.allCases.filter { $0.matches(query) } }

    var body: some View {
        NavigationSplitView {
            List(visible, selection: Binding(get: { m.section }, set: { if let s = $0 { m.section = s } })) { s in
                // 图示一律 14 pt、放在 20 pt 宽的同一栏里置中：车子和手一样宽，文字左缘对齐成一条线
                Label {
                    Text(s.title)
                } icon: {
                    Image(systemName: s.symbol).font(.system(size: 14, weight: .regular)).frame(width: 20, alignment: .center)
                }
                .tag(s)
            }
            .overlay { if visible.isEmpty { ContentUnavailableView.search(text: query) } }   // 2.0 depth：搜不到時照系統設定寫「沒有結果」
            .searchable(text: $query, placement: .sidebar, prompt: L("settings.search", "搜索"))
            .onChange(of: query) { _, _ in
                if let first = visible.first, !visible.contains(m.section) { m.section = first }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 260)
        } detail: {
            Group {
                switch m.section {
                case .general: GeneralPane()
                case .appearance: AppearancePane()
                case .gestures: GesturesPane()
                case .carplay: CarPlayPane()
                case .cliotalk: ClioTalkPane()
                case .camera: CameraPane()
                case .people: PeoplePane()
                case .devices: RemoteDevicesPane()
                case .permissions: PermissionsPane()
                }
            }
            .id(m.section)
            .defaultScrollAnchor(ProcessInfo.processInfo.environment["HOMEPLAY_SETTINGS_BOTTOM"] != nil ? .bottom : .top)   // 截图：从底部看
            .navigationTitle(L("settings.windowTitle", "HomePlay 设置"))
            .navigationSubtitle(m.section.title)
        }
    }
}
