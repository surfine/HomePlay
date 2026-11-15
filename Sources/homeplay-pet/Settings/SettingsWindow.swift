import AppKit
import SwiftUI

// 设置窗口（⌘,）：照系统设置——玻璃侧栏（彩色方块＋分组）、搜索列出符合的行、工具栏的上一页／下一页、右箭头进下一层。
// 状态与动作全部接回原有实现（AppDelegate / PetView 的菜单动作），不另存一份，免得两边不一致。

/// 设置窗口读写的那些状态。窗口打开、取得焦点时、以及每 1.5 秒刷新一次（权限状态会在系统设置里被改）。
final class SettingsModel: ObservableObject {
    weak var app: AppDelegate?
    @Published var section = SettingsSection(rawValue: UserDefaults.standard.string(forKey: SettingsSection.key) ?? "") ?? .general {
        didSet { UserDefaults.standard.set(section.rawValue, forKey: SettingsSection.key) }
    }
    /// 这一页推进去的下一层（右箭头的行）；截图验收：HOMEPLAY_SETTINGS_PATH=faceOptions 直接开在那一层
    @Published var path: [SettingsSub] = ProcessInfo.processInfo.environment["HOMEPLAY_SETTINGS_PATH"].flatMap(SettingsSub.init(rawValue:)).map { [$0] } ?? []
    /// 搜索跳过去的那一行：闪一下、卷到看得见（flashToken 每跳一次加一，同一行再点也会再闪）
    @Published var flash: String?
    @Published private(set) var flashToken = 0

    /// 上一页／下一页：跟系统设置一样记的是「去过的地方」（分页＋下一层），不是只有下一层
    struct Place: Equatable { var section: SettingsSection; var path: [SettingsSub] }
    @Published private(set) var backStack: [Place] = []
    @Published private(set) var forwardStack: [Place] = []

    @Published var loginItem = false
    @Published var loginAvailable = false
    @Published var autoConnect = false
    @Published var carVideo = CarVideoSetting.allowed
    @Published var callGain = 6.0
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
    @Published var clusterLayout = ClusterLayout.a
    /// 這個錶面用自己年代的島身（System 6 系列、島的 1988／2002）：膠囊設定在這裡不作用
    var capsuleLocked: Bool { [.system6, .alarmClock, .about].contains(faceStyle) || (faceStyle == .island && era != .y2026) }
    /// 「字體與顏色」只作用在 2026 的島與照片錶面
    var clockLookApplies: Bool { (faceStyle == .island && era == .y2026) || faceStyle == .photos }
    /// 這張錶面有沒有自己的選項（有才出現「這張錶面的選項」那一行）
    var faceHasOptions: Bool {
        [.island, .analog, .system6, .cluster, .photos].contains(faceStyle)
    }
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
        callGain = (UserDefaults.standard.object(forKey: "HomePlayCallGainDb") as? Double) ?? 6
        cornerStyle = ConcentricCorners.style
        cornerInset = ConcentricCorners.appliedInset
        language = PetLanguage.chosen?.rawValue ?? "system"
        calendarOn = CalendarSource.enabled; nowPlayingOn = NowPlayingPoller.enabled
        finish = s.finish; faceStyle = s.faceStyle; viewMode = s.viewMode; touring = app.view?.touring ?? false; capsule = capsuleMaterialSetting
        if let f = app.view?.face { clockStyle = f.clockStyle == .thin ? .bold : f.clockStyle; islandBackground = f.background; era = f.era; typographMaterial = f.typographMaterial; system6Layout = f.system6Layout; clusterLayout = f.clusterLayout }
        phones = CarPlayPhoneBook.phones; currentPhone = CarPlayPhoneBook.current
        gazeFollow = s.gazeFollow; followDegrees = s.followDegrees; gazePitch = s.gazePitch; roomLight = s.roomLight; petWidth = s.petWidth
        var p: [PermissionKind: PermissionStatus] = [:]
        for k in PermissionKind.allCases { p[k] = PermissionCenter.status(k) }
        permissions = p
    }

    /// 通话音量：和媒体分开，存 UserDefaults 并即时送给接收器。
    func setCallGain(_ db: Double) {
        callGain = db
        UserDefaults.standard.set(db, forKey: "HomePlayCallGainDb")
        app?.sendCallGain(db)
    }

    /// 走菜单同一条路（PetView 的 @objc 动作），之后刷新
    func perform(_ selector: String, _ represented: Any? = nil) {
        app?.settingsPerform(selector, represented)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.refresh() }
    }

    // MARK: 去哪一页（侧栏、右箭头、搜索结果都走这里，才记得住上一页）

    func go(_ s: SettingsSection, _ p: [SettingsSub] = []) {
        let here = Place(section: section, path: path), there = Place(section: s, path: p)
        guard here != there else { return }
        backStack.append(here); forwardStack.removeAll()
        apply(there)
    }
    func goBack() {
        guard let p = backStack.popLast() else { return }
        forwardStack.append(Place(section: section, path: path)); apply(p)
    }
    func goForward() {
        guard let p = forwardStack.popLast() else { return }
        backStack.append(Place(section: section, path: path)); apply(p)
    }
    private func apply(_ p: Place) {
        if section != p.section { section = p.section }
        if path != p.path { path = p.path }
    }

    /// 搜索结果：跳到那一页（在下一层就推进去），那一行闪一下
    func reveal(_ r: SettingsSearchRow) {
        go(r.section, r.sub.map { [$0] } ?? [])
        flash = r.key
        flashToken += 1
        let token = flashToken
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { [weak self] in
            guard let self, self.flashToken == token else { return }
            withAnimation(.easeOut(duration: 0.35)) { self.flash = nil }
        }
    }
}

/// 侧边栏的分页（顺序＝显示顺序，groups 是侧栏的分组）；上次看到哪一页会记住。
/// 名称：系统设置里有同名、意思也一样的才用系统的（通用、显示器、辅助功能、家人、隐私与安全性），其余用自己的。
enum SettingsSection: String, CaseIterable, Identifiable {
    case general, body, display, accessibility
    case faces, homeScreen
    case gestures, cliotalk, camera
    case carplay, devices, home      // home＝家庭（捷徑）
    case people, permissions         // permissions＝隱私權與安全性（rawValue 沿用，--open-settings 與舊偏好照舊）
    var id: String { rawValue }
    static let key = "HomePlaySettingsSection"
    static let groups: [[SettingsSection]] = [[.general, .body, .display, .accessibility], [.faces, .homeScreen],
                                              [.gestures, .cliotalk, .camera], [.carplay, .devices, .home], [.people, .permissions]]
    /// 舊的「外觀」入口（右鍵選單「外觀設定…」）：朝向、視角、大小都搬到「機身」
    static var appearance: SettingsSection { .body }

    var title: String {
        switch self {
        case .general: return L("settings.general", "通用")
        case .body: return L("settings.body", "机身")
        case .display: return L("settings.displays", "显示器")
        case .accessibility: return L("settings.a11y", "辅助功能")
        case .faces: return L("settings.faces", "表盘与墙纸")
        case .homeScreen: return L("settings.home.section", "主屏幕")
        case .gestures: return L("settings.gestures", "手势")
        case .cliotalk: return L("settings.cliotalk", "ClioTalk")
        case .camera: return L("settings.camera", "相机")
        case .carplay: return L("settings.carplay", "CarPlay")
        case .devices: return L("settings.devices", "iPhone 与 iPad")
        case .home: return L("settings.home", "家庭")
        case .people: return L("settings.people", "家人")
        case .permissions: return L("settings.privacySecurity", "隐私与安全性")
        }
    }
    /// 头部卡那一句话（有示范舞台的四页不用）
    var line: String {
        switch self {
        case .general: return L("settings.general.line", "HomePlay 什么时候出现、用哪种语言，以及表盘上可以显示哪些数据。")
        case .body: return L("settings.body.line", "机身的配色、大小和摆放。")
        case .display: return L("settings.displays.line", "屏幕多亮、什么时候暗下来。")
        case .accessibility: return L("settings.a11y.line", "让屏幕上的字更大、用键盘操作屏幕，或让顶端的把手一直显示。")
        case .faces: return L("settings.faces.line", "表盘、主题和墙纸。")
        case .homeScreen: return L("settings.homeScreen.line", "App 和小组件的外观，以及主屏幕上会出现什么。")
        case .gestures: return L("settings.gestures.line", "在屏幕和机身上怎么操作。")
        case .cliotalk: return L("settings.cliotalk.line", "按住 F5 说话。这里决定谁来回答、它能用哪些数据、怎么跟你说话。")
        case .camera: return L("settings.camera.line", "跟随你转头，以及房间光线。")
        case .carplay: return L("settings.carplay.line", "用力按一下屏幕，就是 iPhone 的 CarPlay。这里管哪一部 iPhone、怎么连。")
        case .devices: return L("settings.devices.line", "让其他设备显示 HomePlay，或把网页传给它。")
        case .home: return L("settings.home.line", "用「捷径」控制家里的配件。")
        case .people: return L("settings.people.line", "HomePlay 认得出谁在看，让每个人看到自己的那一份。")
        case .permissions: return L("settings.privacy.line", "HomePlay 用到哪些权限，以及什么数据会离开这台 Mac。")
        }
    }
    /// 只有这四页的页首是示范舞台（其余是头部卡）
    var hasStage: Bool { [.body, .faces, .gestures, .camera].contains(self) }
    /// 侧边栏符号：系统设置那样的彩色圆角方块＋白色实心符号（同一个尺寸，文字左缘对齐）
    var symbol: String {
        switch self {
        case .general: return "gearshape.fill"
        case .body: return "display"
        case .display: return "sun.max.fill"
        case .accessibility: return "accessibility"
        case .faces: return "clock.fill"
        case .homeScreen: return "square.grid.2x2.fill"
        case .gestures: return "hand.point.up.left.fill"
        case .cliotalk: return "bubble.left.and.text.bubble.right.fill"
        case .camera: return "camera.fill"
        case .carplay: return "car.fill"
        case .devices: return "ipad.and.iphone"
        case .home: return "house.fill"
        case .people: return "person.2.fill"
        case .permissions: return "hand.raised.fill"
        }
    }
    /// 方块的颜色（照设计稿的色票）
    var tint: Color {
        switch self {
        case .general: return Color(hex: 0x8e8e93)
        case .body: return Color(hex: 0x5e6b78)
        case .display: return Color(hex: 0x0a84ff)
        case .accessibility: return Color(hex: 0x0a6cff)
        case .faces: return Color(hex: 0x2c2c2e)
        case .homeScreen: return Color(hex: 0x34aadc)
        case .gestures: return Color(hex: 0x30b0c7)
        case .cliotalk: return Color(hex: 0xaf52de)
        case .camera: return Color(hex: 0x5856d6)
        case .carplay: return Color(hex: 0x34c759)
        case .devices: return Color(hex: 0x32ade6)
        case .home: return Color(hex: 0xff9f0a)
        case .people: return Color(hex: 0xff375f)
        case .permissions: return Color(hex: 0x0a6cff)
        }
    }
}

/// 下一层（有右箭头的行推进去的页）
enum SettingsSub: String, Hashable {
    case faceOptions, liveActivities, webApps, addDevice
    var title: String {
        switch self {
        case .faceOptions: return L("settings.faceOptions", "这张表盘的选项")
        case .liveActivities: return L("la.settings.header", "实时活动")
        case .webApps: return L("webapp.settings.header", "Web App")
        case .addDevice: return L("remote.section.add", "新增设备")
        }
    }
    var section: SettingsSection {
        switch self {
        case .faceOptions: return .faces
        case .liveActivities, .webApps: return .homeScreen
        case .addDevice: return .devices
        }
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB, red: Double(hex >> 16 & 0xff) / 255, green: Double(hex >> 8 & 0xff) / 255, blue: Double(hex & 0xff) / 255)
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
        if let pane { UserDefaults.standard.set(pane.rawValue, forKey: SettingsSection.key) }   // 新建窗口时第一帧就是这一页
        let c = shared ?? SettingsWindowController(app: app)
        shared = c
        c.model.refresh()
        if let pane, pane != c.model.section { c.model.go(pane) }
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

/// 侧边栏＋内容：系统的侧栏（彩色方块、分组；玻璃由系统画）＋搜索；
/// 搜索时侧栏换成符合的行（标题＋在哪一页），点了跳过去、那一行闪一下；找不到就是系统的「没有结果」。
/// 工具栏：上一页／下一页（系统的工具栏按钮），标题是现在这一页（或下一层）的名字。换分页不做转场。
struct SettingsRoot: View {
    @EnvironmentObject var m: SettingsModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var query = ProcessInfo.processInfo.environment["HOMEPLAY_SETTINGS_SEARCH"] ?? ""   // 截图验收：开着搜索结果
    private var trimmed: String { query.trimmingCharacters(in: .whitespaces) }
    private var results: [SettingsSearchRow] { SettingsSearch.rows(matching: trimmed) }

    var body: some View {
        NavigationSplitView {
            sidebar
                .searchable(text: $query, placement: .sidebar, prompt: L("settings.search", "搜索"))
                .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 260)
        } detail: {
            ScrollViewReader { proxy in
                NavigationStack(path: Binding(get: { m.path }, set: { m.go(m.section, $0) })) {
                    pane(m.section)
                        .navigationTitle(m.section.title)
                        .navigationDestination(for: SettingsSub.self) { sub in
                            subPane(sub)
                                .navigationTitle(sub.title)
                                .navigationBarBackButtonHidden(true)   // 回去用工具栏的上一页（系统设置也是这样）
                        }
                }
                .id(m.section)   // 换分页：内容直接换（和系统设置一样），下一层从这一页的 path 重建
                .defaultScrollAnchor(ProcessInfo.processInfo.environment["HOMEPLAY_SETTINGS_BOTTOM"] != nil ? .bottom : .top)   // 截图：从底部看
                .onChange(of: m.flashToken) { _, _ in
                    guard let key = m.flash else { return }
                    // 等新的一页排好版再卷（换页、推进下一层都要一拍）
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                        if reduceMotion { proxy.scrollTo(key, anchor: .center) }
                        else { withAnimation(.easeInOut(duration: 0.3)) { proxy.scrollTo(key, anchor: .center) } }
                    }
                }
            }
            .toolbar {
                ToolbarItemGroup(placement: .navigation) {
                    ControlGroup {
                        Button { m.goBack() } label: { Label(L("settings.back", "上一页"), systemImage: "chevron.backward") }
                            .disabled(m.backStack.isEmpty)
                            .keyboardShortcut("[", modifiers: .command)
                        Button { m.goForward() } label: { Label(L("settings.forward", "下一页"), systemImage: "chevron.forward") }
                            .disabled(m.forwardStack.isEmpty)
                            .keyboardShortcut("]", modifiers: .command)
                    }
                    .controlGroupStyle(.navigation)
                }
            }
        }
    }

    @ViewBuilder private var sidebar: some View {
        if trimmed.isEmpty {
            List(selection: Binding(get: { m.section }, set: { if let s = $0 { m.go(s) } })) {
                ForEach(SettingsSection.groups.indices, id: \.self) { i in
                    Section {
                        ForEach(SettingsSection.groups[i]) { s in
                            Label { Text(s.title) } icon: { SymbolTile(symbol: s.symbol, tint: s.tint, size: 20) }
                                .tag(s)
                        }
                    }
                }
            }
            .listStyle(.sidebar)
        } else {
            List {
                ForEach(results) { r in
                    Button { m.reveal(r) } label: {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(r.title).foregroundStyle(.primary)
                            Text(r.place).font(.caption).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .listStyle(.sidebar)
            .overlay { if results.isEmpty { ContentUnavailableView.search(text: trimmed) } }
        }
    }

    @ViewBuilder private func pane(_ s: SettingsSection) -> some View {
        switch s {
        case .general: GeneralPane()
        case .body: BodyPane()
        case .display: DisplayPane()
        case .accessibility: AccessibilityPane()
        case .faces: FacesPane()
        case .homeScreen: HomeScreenPane()
        case .gestures: GesturesPane()
        case .cliotalk: ClioTalkPane()
        case .camera: CameraPane()
        case .carplay: CarPlayPane()
        case .devices: RemoteDevicesPane()
        case .home: HomePane()
        case .people: PeoplePane()
        case .permissions: PermissionsPane()
        }
    }

    @ViewBuilder private func subPane(_ sub: SettingsSub) -> some View {
        switch sub {
        case .faceOptions: FaceOptionsPane()
        case .liveActivities: Form { LiveActivitySettingsSection() }.formStyle(.grouped)
        case .webApps: Form { WebAppsSection() }.formStyle(.grouped)
        case .addDevice: AddDevicePane()
        }
    }
}
