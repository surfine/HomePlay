import AppKit
import SwiftUI

// 设置的分页：系统的分组表单（Form + .grouped）当骨架，写法学 WindowShade——
// 页首一段会动的两格插画＋一行字；每一行＝SF Symbol＋名字＋最多一行副标题＋控件；说不完的进行尾 ⓘ 小气泡，不堆说明段落。

/// 页首：两格插画＋一行说明（可带 ⓘ），放在第一组设置的 header 里（没有卡片底）
struct IllustrationHeader: View {
    let scene: IllusScene
    let note: String
    var info: String? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack { IllustrationStage(scene: scene).id(scene).transition(.blurFade) }
                .animation(.easeOut(duration: 0.2), value: scene)
                .padding(.horizontal, -10)   // header 本身内缩 10 pt：插画两边要和下面的卡片切齐
            HStack(spacing: 6) {
                Text(note).font(.callout).foregroundStyle(.secondary)
                if let info { InfoButton(info) }
            }
        }
        .textCase(nil)
        .padding(.bottom, 8)
    }
}

/// 页尾：右对齐的按钮
struct FooterButtons<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        HStack(spacing: 10) { Spacer(minLength: 0); content }
            .padding(.top, 6)
            .padding(.trailing, -10)   // footer 内缩 10 pt：按钮右缘和卡片右缘切齐（系统设置的「进阶…」也是这样）
    }
}

/// 只有文字、没有控件的一行（包进 LabeledContent，第二行才会排成副标题）；可带符号与 ⓘ
struct InfoRow: View {
    let title: String
    var subtitle: String? = nil
    var symbol: String? = nil
    var tint: Color = .gray
    var info: String? = nil
    var body: some View {
        LabeledContent {
            if let info { InfoButton(info) }
        } label: { RowLabel(title: title, subtitle: subtitle, symbol: symbol, tint: tint) }
    }
}

/// 标题＋灰色副标题（放在 Toggle／Picker／LabeledContent 的 label 里）；给了 symbol 就在前面放一个彩色圆角方块
struct RowLabel: View {
    let title: String
    var subtitle: String? = nil
    var symbol: String? = nil
    var tint: Color = .gray
    var body: some View {
        if let symbol {
            Label {
                Text(title)
                if let subtitle { Text(subtitle) }
            } icon: {
                SymbolTile(symbol: symbol, tint: tint)
            }
        } else {
            Text(title)
            if let subtitle { Text(subtitle) }
        }
    }
}

struct GeneralPane: View {
    @EnvironmentObject var m: SettingsModel
    private let tint = SettingsSection.general.tint
    var body: some View {
        Form {
            Section {
                Toggle(isOn: Binding(get: { m.loginItem }, set: { _ in m.perform("menuLoginItem") })) {
                    RowLabel(title: L("settings.loginItem", "登录时打开 HomePlay"),
                             subtitle: m.loginAvailable ? nil : L("settings.loginItem.needsApp", "打包成 App 后可用"), symbol: "power", tint: tint)
                }.disabled(!m.loginAvailable)
                Toggle(isOn: Binding(get: { m.alwaysOnTop }, set: { m.app?.setAlwaysOnTop($0); m.refresh() })) {
                    RowLabel(title: L("settings.alwaysOnTop", "窗口置顶"), subtitle: L("settings.alwaysOnTop.sub", "全屏 App 在前面时自动让开"), symbol: "pin.fill", tint: tint)
                }
                Picker(selection: Binding(get: { m.language }, set: { m.perform("menuLanguage:", $0 == "system" ? nil : $0) })) {
                    Text(L("settings.language.system", "跟随系统")).tag("system")
                    Divider()
                    Text("English").tag(PetLanguage.en.rawValue)
                    Text("简体中文").tag(PetLanguage.zhHans.rawValue)
                    Text("繁體中文").tag(PetLanguage.zhHant.rawValue)
                } label: {
                    RowLabel(title: L("settings.language", "语言"), symbol: "globe", tint: tint)
                }
                // 连续的值用滑杆：滑块旁边显示现在的大小（占默认大小的百分比）；两端标「小／大」
                ValueSlider(title: L("settings.size", "大小"), subtitle: L("settings.size.sub", "也可以双指张合，或 ⌘+ ⌘−"), symbol: "arrow.up.left.and.arrow.down.right", tint: tint,
                            value: Binding(get: { m.petWidth }, set: { m.app?.setPetWidth($0); m.petWidth = $0 }),
                            range: Double(Pet.minWidth)...Double(Pet.maxWidth),
                            minLabel: L("settings.size.small", "小"), maxLabel: L("settings.size.large", "大")) {
                    "\(Int(($0 / Double(Pet.defaultWidth) * 100).rounded()))%"
                }
            } header: {
                IllustrationHeader(scene: .onTop, note: L("settings.general.heroBody", "陪你待在桌面上"))
            }
            Section {
                Toggle(isOn: Binding(get: { m.nowPlayingOn }, set: { _ in m.perform("menuNowPlaying") })) {
                    RowLabel(title: L("prefs.nowPlaying", "Mac 正在播放"), subtitle: L("settings.nowPlaying.sub", "CarPlay 播放时优先显示 iPhone"), symbol: "music.note", tint: .pink)
                }
                // 2.0 #8：歌词（LRCLIB）；默认开
                ToggleRow(title: L("settings.lyrics", "歌词"), subtitle: L("settings.lyrics.short", "跟着歌显示同步歌词"), symbol: "quote.bubble.fill", tint: .pink,
                          info: L("settings.lyrics.sub", "依序向 LRCLIB、酷狗、QQ 音乐查同步歌词：只送歌名、歌手和长度，存在这台 Mac 上"),
                          isOn: Binding(get: { LyricsStore.enabled }, set: { LyricsStore.enabled = $0; m.refresh() }))
                Toggle(isOn: Binding(get: { m.calendarOn && m.permissions[.calendar] == .granted }, set: { _ in m.perform("menuCalendarToggle") })) {
                    RowLabel(title: L("prefs.calendar.on", "读取日历"),
                             subtitle: m.permissions[.calendar] == .granted ? L("settings.calendar.sub", "显示下一个行程")
                                                                            : L("settings.calendar.needsPerm", "先在「权限」里允许"),
                             symbol: "calendar", tint: .red)
                }.disabled(m.permissions[.calendar] != .granted)
            } header: {
                Text(L("settings.sources", "表盘上的数据"))
            } footer: {
                FooterButtons {
                    Button(L("menu.sayHello", "打个招呼")) { m.perform("menuSayHello") }   // 2.0 hello
                    Button(L("settings.rerunSetup", "重新设置")) {   // 2.0 首次設定再走一次（Setup/SetupFlow.swift）
                        m.app?.view.wakeFromPosterForGuide(); SetupFlow.start(); m.app?.view.face.forceDirty = true
                    }
                }
            }
            LiveActivitySettingsSection()   // 2.0 P03：每個 App 的 Live Activity 開關、訊息「顯示預覽」（Shell/LiveActivityStack.swift）
        }
        .formStyle(.grouped)
    }
}

struct AppearancePane: View {
    @EnvironmentObject var m: SettingsModel
    private let tint = SettingsSection.appearance.tint
    private var facingNote: String {
        m.viewMode == .auto ? L("settings.facing.note", "自动朝向屏幕中央")
            : m.viewMode == .wall ? L("settings.facing.wallNote", "只有屏幕，贴墙正对前方")
            : L("settings.facing.frontNote", "始终正对前方")
    }
    var body: some View {
        Form {
            Section {
                Picker(selection: Binding(get: { m.viewMode }, set: { m.app?.view.setViewMode($0); m.refresh() })) {
                    Text(L("settings.facing.auto", "自动")).tag(ViewMode.auto)
                    Text(L("settings.facing.front", "正面固定")).tag(ViewMode.front)
                    Text(L("settings.facing.wall", "挂墙")).tag(ViewMode.wall)
                } label: {
                    RowLabel(title: L("settings.facing", "朝向"), symbol: "scope", tint: .blue)
                }.pickerStyle(.segmented).fixedSize()
                LabeledContent {
                    ControlGroup {
                        Button(L("menu.view.front", "正面")) { m.perform("menuViewFront") }
                        Button(L("menu.view.side", "侧面")) { m.perform("menuViewSide") }
                        Button(L("menu.view.back", "背面")) { m.perform("menuViewBack") }
                        Button(L("menu.view.top", "俯视")) { m.perform("menuViewAbove") }
                    }.fixedSize()
                } label: {
                    RowLabel(title: L("settings.angle", "视角"), symbol: "cube.fill", tint: .blue)
                }.disabled(m.viewMode == .wall)   // 挂墙贴在墙上，不换视角
                // 2.0 P06：從右鍵選單搬來的視角控制
                Toggle(isOn: Binding(get: { m.touring }, set: { _ in m.perform("menuTour") })) {
                    RowLabel(title: L("settings.orbit", "自动环绕"), symbol: "rotate.3d", tint: .blue)
                }.disabled(m.viewMode == .wall)
            } header: {
                IllustrationHeader(scene: m.viewMode == .auto ? .facing : .facingFront, note: facingNote)
            } footer: {
                FooterButtons { Button(L("menu.resetAngle", "回正")) { m.perform("menuResetOrientation") }.disabled(m.viewMode == .wall) }
            }
            Section {
                Picker(selection: Binding(get: { m.finish }, set: { m.perform("menuFinish:", $0.rawValue) })) {
                    ForEach(Finish.allCases, id: \.self) { Text($0.title).tag($0) }
                } label: {
                    RowLabel(title: L("settings.finish", "配色"), symbol: "paintpalette.fill", tint: .orange)
                }
            }
            faceSection
            PosterLibrarySection()    // 多臉：多張海報外觀（Settings/PosterLibrarySection.swift）
            Section {
                Picker(selection: Binding(get: { m.capsule }, set: { v in
                    capsuleMaterialSetting = v; UserDefaults.standard.set(v.rawValue, forKey: CapsuleMaterial.defaultsKey)
                    m.app?.view.face.forceDirty = true; m.refresh()
                })) {
                    ForEach(CapsuleMaterial.allCases, id: \.self) { Text($0.title).tag($0) }
                } label: {
                    RowLabel(title: L("settings.capsule", "胶囊"),
                             subtitle: m.capsuleLocked ? L("settings.capsule.locked", "这个表盘用它那个年代的样子")
                                                       : L("settings.capsule.short", "装着 👀 的那颗；自动＝跟着年代"),
                             symbol: "capsule.fill", tint: tint)
                }
                .disabled(m.capsuleLocked)
                LabeledContent {
                    Button(L("clockLook.edit", "编辑…")) { m.perform("menuClockLook:") }.disabled(!m.clockLookApplies)
                } label: {
                    RowLabel(title: L("settings.clockLook", "字体与颜色"),
                             subtitle: m.clockLookApplies ? L("clockLook.subtitle", "岛表盘和照片表盘的大时间")
                                                          : L("clockLook.unavailable", "只用于岛（2026）和照片表盘"),
                             symbol: "paintbrush.pointed.fill", tint: tint)
                }
            }
            HomeAppearanceSection()   // 2.0 P02：主畫面外觀（Settings/HomeAppearanceSection.swift）
            LookSection()             // HomeView 對齊 WP2：12 種 Look 挑選器（Settings/DisplaySection.swift）
            DisplaySection()          // HomeView 對齊 WP3：熄屏與環境海報（Settings/DisplaySection.swift）
            SharedAlbumsSection()     // 2.0 P10：共享相簿當照片來源（Settings/SharedAlbumsSection.swift）
            ScreenAccessibilitySection()   // 2.0 P05：畫面文字大小、用鍵盤操作畫面
        }
        .formStyle(.grouped)
    }

    /// 表盘与它自己的选项（和右键选单同一份动作）
    @ViewBuilder private var faceSection: some View {
        Section {
            Picker(selection: Binding(get: { m.faceStyle }, set: { m.perform("menuStyle:", $0.rawValue) })) {
                ForEach(FaceStyle.lineup, id: \.self) { Text($0.title).tag($0) }
            } label: {
                RowLabel(title: L("settings.face", "表盘"), symbol: "clock.fill", tint: tint)
            }
            if m.faceStyle == .island {   // 島錶面自己的三個選項（和右鍵選單「島錶面」同一份動作）
                Picker(selection: Binding(get: { m.clockStyle }, set: { m.perform("menuIslandClock:", $0.rawValue) })) {
                    ForEach(ClockStyle.allCases.filter { $0 != .thin }, id: \.self) { Text($0.title).tag($0) }
                } label: { RowLabel(title: L("island.clock", "时钟样式"), symbol: "clock.badge.fill", tint: tint) }
                Picker(selection: Binding(get: { m.islandBackground }, set: { m.perform("menuIslandBackground:", $0.rawValue) })) {
                    ForEach(IslandBackground.choices(for: m.era), id: \.self) { Text($0.title).tag($0) }
                } label: { RowLabel(title: L("island.bg", "背景"), symbol: "photo.fill", tint: tint) }
                Picker(selection: Binding(get: { m.era }, set: { m.perform("menuIslandEra:", $0.rawValue) })) {
                    ForEach(Era.allCases, id: \.self) { Text($0.title).tag($0) }
                } label: { RowLabel(title: L("island.era", "年代"), symbol: "clock.arrow.circlepath", tint: tint) }
            }
            if m.faceStyle == .analog {   // Typograph 的材質
                Picker(selection: Binding(get: { m.typographMaterial }, set: { m.perform("menuTypographMaterial:", $0.rawValue) })) {
                    ForEach(TypographMaterial.allCases, id: \.self) { Text($0.title).tag($0) }
                } label: { RowLabel(title: L("typograph.material", "Typograph 材质"), symbol: "square.stack.3d.up.fill", tint: tint) }
            }
            if m.faceStyle == .system6 {   // System 6 的版式
                Picker(selection: Binding(get: { m.system6Layout }, set: { m.perform("menuSystem6Layout:", $0.rawValue) })) {
                    ForEach(System6Layout.allCases, id: \.self) { Text($0.title).tag($0) }
                } label: { RowLabel(title: L("system6.layout", "System 6 版式"), symbol: "macwindow", tint: tint) }
            }
            if m.faceStyle == .cluster {   // 儀表的版式
                Picker(selection: Binding(get: { m.clusterLayout }, set: { m.perform("menuClusterLayout:", $0.rawValue) })) {
                    ForEach(ClusterLayout.allCases, id: \.self) { Text($0.title).tag($0) }
                } label: { RowLabel(title: L("cluster.layout", "仪表版式"), symbol: "gauge.with.dots.needle.67percent", tint: tint) }
            }
            if m.faceStyle == .photos || (m.faceStyle == .island && m.islandBackground == .photo) {
                LabeledContent {
                    Button(L("prefs.photoFolder", "照片文件夹…")) { m.perform("menuPhotoFolder") }
                } label: { RowLabel(title: L("settings.photos", "照片"), symbol: "photo.on.rectangle", tint: tint) }
            }
        } header: {
            Text(L("settings.face", "表盘"))
        }
    }
}

/// 手势：依输入方式分段（鼠标／触控板／触控），每种手势一行「符号＋名字＋一行说明」；
/// 指标停在哪一行（或点哪一行），页首就播那一个手势。语法照 docs/plans/gestures.md 二：
/// 屏幕上的拖动只归画面，转身体只拖机身；回主屏幕以「👀 往下拉」为主。
struct GesturesPane: View {
    @EnvironmentObject var m: SettingsModel
    @State private var input = ProcessInfo.processInfo.environment["HOMEPLAY_SETTINGS_GESTURE"]
        .flatMap { $0.split(separator: ":").dropFirst().first.flatMap { IntroInput(rawValue: String($0)) } } ?? IntroGuide.input
    // 截图验收：HOMEPLAY_SETTINGS_GESTURE=种类（可加 :输入方式）直接选中那一行
    @State private var selected: GestureKind = ProcessInfo.processInfo.environment["HOMEPLAY_SETTINGS_GESTURE"]
        .flatMap { GestureKind(rawValue: String($0.split(separator: ":")[0])) } ?? .home
    @State private var hoverIntent: Task<Void, Never>?
    private let tint = SettingsSection.gestures.tint

    struct Gesture: Identifiable {
        let kind: GestureKind, symbol: String, title: String, how: String
        var id: String { kind.rawValue }
    }

    /// 这种输入方式的每一行（名字＝结果，副标题＝手怎么动）
    static func gestures(_ i: IntroInput) -> [Gesture] {
        let drag = i == .touch
        var rows: [Gesture] = [
            Gesture(kind: .home, symbol: "house.fill", title: L("settings.gesture.home", "回主屏幕"),
                    how: drag ? L("settings.gesture.home.touch", "从 👀 往下拉；点一下 👀 也行") : L("settings.gesture.home.drag", "从 👀 往下拖；按一下 👀 也行")),
            Gesture(kind: .switcher, symbol: "square.stack.fill", title: L("settings.gesture.switcher", "App 切换器"),
                    how: drag ? L("settings.gesture.switcher.touch", "从 👀 往下拉，停一下") : L("settings.gesture.switcher.drag", "从 👀 往下拖，停一下")),
            Gesture(kind: .control, symbol: "switch.2", title: L("settings.gesture.control", "控制中心"),
                    how: drag ? L("settings.gesture.control.touch", "从右上角往下拉") : L("settings.gesture.control.drag", "从右上角往下拖")),
        ]
        switch i {
        case .mouse: rows.append(Gesture(kind: .page, symbol: "arrow.left.and.right", title: L("settings.gesture.page", "换页、换表盘"), how: L("settings.gesture.page.mouse", "在屏幕上左右拖，或滚动滚轮")))
        case .trackpad: rows.append(Gesture(kind: .page, symbol: "arrow.left.and.right", title: L("settings.gesture.page", "换页、换表盘"), how: L("settings.gesture.page.trackpad", "双指左右滑")))
        case .touch: rows.append(Gesture(kind: .page, symbol: "arrow.left.and.right", title: L("settings.gesture.page", "换页、换表盘"), how: L("settings.gesture.page.touch", "在屏幕上左右滑")))
        }
        switch i {
        case .mouse: rows.append(Gesture(kind: .carDrag, symbol: "map.fill", title: L("settings.gesture.carDrag", "在 CarPlay 里拖动"), how: L("settings.gesture.carDrag.mouse", "CarPlay 显示时在屏幕上拖")))
        case .trackpad: rows.append(Gesture(kind: .carDrag, symbol: "map.fill", title: L("settings.gesture.carDrag", "在 CarPlay 里拖动"), how: L("settings.gesture.liveSlide", "CarPlay 显示时在屏幕上双指滑")))
        case .touch: rows.append(Gesture(kind: .carDrag, symbol: "map.fill", title: L("settings.gesture.carDrag", "在 CarPlay 里拖动"), how: L("settings.gesture.carDrag.touch", "CarPlay 显示时在屏幕上拖")))
        }
        rows.append(Gesture(kind: .back, symbol: "chevron.backward", title: L("settings.gesture.back", "返回"),
                            how: drag ? L("settings.gesture.back.touch", "从左缘往右滑") : L("settings.gesture.back.drag", "从左缘往右拖")))
        rows.append(Gesture(kind: .hold, symbol: "square.grid.2x2.fill", title: L("settings.gesture.hold", "表盘总览、图标选单"),
                            how: i == .touch ? L("settings.gesture.hold.touch", "在屏幕上长按") : L("settings.gesture.hold.mouse", "在屏幕上按住")))
        switch i {
        case .mouse:
            rows += [Gesture(kind: .turn, symbol: "arrow.trianglehead.2.counterclockwise.rotate.90", title: L("settings.gesture.turn", "转身体"), how: L("settings.gesture.turn.drag", "拖机身，不是拖屏幕")),
                     Gesture(kind: .front, symbol: "arrow.uturn.backward", title: L("settings.gesture.front", "转回正面"), how: L("settings.gesture.front.mouse", "按两下机身")),
                     Gesture(kind: .resize, symbol: "plus.magnifyingglass", title: L("settings.gesture.resize", "放大缩小"), how: L("settings.gesture.resize.mouse", "⌘+ ⌘−，或按住 ⌥ 滚动")),
                     Gesture(kind: .move, symbol: "macwindow.on.rectangle", title: L("settings.gesture.moveWindow", "搬窗口"), how: L("settings.gesture.move.mouse", "按住 ⌘ 拖")),
                     Gesture(kind: .carplay, symbol: "car.fill", title: L("settings.gesture.carplay", "进出 CarPlay"), how: L("settings.gesture.carplay.space", "按空格键")),
                     Gesture(kind: .menu, symbol: "list.bullet", title: L("settings.gesture.menu", "选单"), how: L("settings.gesture.menu.mouse", "在机身上按右键"))]
        case .trackpad:
            rows += [Gesture(kind: .rotate, symbol: "arrow.trianglehead.2.counterclockwise.rotate.90", title: L("settings.gesture.turn", "转身体"), how: L("settings.gesture.turn.rotate", "双指旋转，或拖机身")),
                     Gesture(kind: .front, symbol: "arrow.uturn.backward", title: L("settings.gesture.front", "转回正面"), how: L("settings.gesture.front.touch", "点两下机身")),
                     Gesture(kind: .resize, symbol: "plus.magnifyingglass", title: L("settings.gesture.resize", "放大缩小"), how: L("settings.gesture.resize.pinch", "双指张合")),
                     Gesture(kind: .move, symbol: "macwindow.on.rectangle", title: L("settings.gesture.moveWindow", "搬窗口"), how: L("settings.gesture.move.three", "三指拖移，CarPlay 显示时也行")),
                     Gesture(kind: .carplay, symbol: "car.fill", title: L("settings.gesture.carplay", "进出 CarPlay"), how: L("settings.gesture.carplay.force", "用力按屏幕（重按）")),
                     Gesture(kind: .menu, symbol: "list.bullet", title: L("settings.gesture.menu", "选单"), how: L("settings.gesture.menu.trackpad", "双指点按机身")),
                     Gesture(kind: .apart, symbol: "square.3.layers.3d.down.right", title: L("settings.gesture.apart.title", "拆开看看"), how: L("settings.gesture.apart.how", "双指轻点两下；再点两下组回来"))]
        case .touch:
            rows += [Gesture(kind: .turn, symbol: "arrow.trianglehead.2.counterclockwise.rotate.90", title: L("settings.gesture.turn", "转身体"), how: L("settings.gesture.turn.touch", "单指拖机身，不是拖屏幕")),
                     Gesture(kind: .front, symbol: "arrow.uturn.backward", title: L("settings.gesture.front", "转回正面"), how: L("settings.gesture.front.touch", "点两下机身")),
                     Gesture(kind: .resize, symbol: "plus.magnifyingglass", title: L("settings.gesture.resize", "放大缩小"), how: L("settings.gesture.resize.pinch", "双指张合")),
                     Gesture(kind: .move, symbol: "macwindow.on.rectangle", title: L("settings.gesture.moveWindow", "搬窗口"), how: L("settings.gesture.move.base", "拖底座")),
                     Gesture(kind: .menu, symbol: "list.bullet", title: L("settings.gesture.menu", "选单"), how: L("settings.gesture.menu.touch", "在机身上按住"))]
        }
        return rows
    }

    /// 键盘：哪种输入方式都一样
    private var keyRows: [(symbol: String, title: String, how: String)] {
        [("space", L("settings.gesture.key.carplay", "CarPlay ⇄ 主屏幕"), L("settings.gesture.key.carplay.how", "空格键，跟 👀 同一条路")),
         ("arrow.left.arrow.right", L("settings.gesture.key.pages", "换页、换表盘"), L("settings.gesture.key.pages.how", "← →")),
         ("arrow.up.arrow.down", L("settings.gesture.key.levels", "进一层、退一层"), L("settings.gesture.key.levels.how", "↑ 主屏幕与资源库，↓ 或 Esc 退回")),
         ("switch.2", L("settings.gesture.control", "控制中心"), L("settings.gesture.key.control.how", "C")),
         ("mic.fill", L("settings.gesture.key.clio", "ClioTalk"), L("settings.gesture.key.clio.how", "按住 F5 说话")),
         ("cube.fill", L("settings.gesture.key.angles", "视角"), L("settings.gesture.key.angles.how", "1–4")),
         ("car.fill", L("settings.gesture.key.knob", "CarPlay 的旋钮"), L("settings.gesture.key.knob.how", "方向键、Tab、Return、Esc"))]
    }

    var body: some View {
        Form {
            Section {
                Picker(selection: Binding(get: { input }, set: { v in input = v; withAnimation(.easeOut(duration: 0.2)) { selected = .home } })) {
                    Text(L("intro.input.mouse", "鼠标")).tag(IntroInput.mouse)
                    Text(L("intro.input.trackpad", "触控板")).tag(IntroInput.trackpad)
                    Text(L("settings.gestures.tab.touch", "触控")).tag(IntroInput.touch)
                } label: { EmptyView() }
                .pickerStyle(.segmented).labelsHidden()
                .frame(maxWidth: .infinity)
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            } header: {
                IllustrationHeader(scene: .gesture(selected, input), note: L("settings.gestures.rule", "屏幕上的拖动归画面，拖机身才转身体"))
            }
            Section {
                ForEach(Self.gestures(input)) { g in
                    LabeledContent {
                        Image(systemName: "play.circle.fill")
                            .foregroundStyle(Color.accentColor)
                            .opacity(selected == g.kind ? 1 : 0)
                    } label: {
                        RowLabel(title: g.title, subtitle: g.how, symbol: g.symbol, tint: tint)
                    }
                    .contentShape(Rectangle())
                    .onHover { inside in
                        // 停 80 ms 才换：指标从上往下扫过时不会一路换好几段
                        hoverIntent?.cancel()
                        guard inside else { return }
                        hoverIntent = Task { @MainActor in
                            try? await Task.sleep(nanoseconds: 80_000_000)
                            if !Task.isCancelled { pick(g.kind) }
                        }
                    }
                    .onTapGesture { hoverIntent?.cancel(); pick(g.kind) }
                    .accessibilityAddTraits(selected == g.kind ? [.isButton, .isSelected] : .isButton)
                }
            }
            Section {
                ForEach(keyRows, id: \.title) { r in
                    InfoRow(title: r.title, subtitle: r.how, symbol: r.symbol, tint: .gray)
                }
            } header: {
                Text(L("settings.gesture.keys", "键盘"))
            }
            IntroGuideSection()   // 開場手勢引導：重看、依照的輸入方式、新手勢提示（Intro/IntroGuide.swift）
        }
        .formStyle(.grouped)
    }

    private func pick(_ k: GestureKind) {
        guard k != selected else { return }
        withAnimation(.easeOut(duration: 0.2)) { selected = k }
    }
}

struct CarPlayPane: View {
    @EnvironmentObject var m: SettingsModel
    private let tint = SettingsSection.carplay.tint
    /// 圆角：副标题只写一句（一行放得下），完整说明与这台 iPhone 的内收量放进 ⓘ
    private var cornerShort: String {
        switch m.cornerStyle {
        case .concentric: return L("settings.corners.concentric.short", "与机身同心，壁纸铺满")
        case .balanced: return L("settings.corners.balanced.short", "介于同心与最大之间")
        case .maximize: return L("settings.corners.maximize.short", "只避开圆角，画面最大")
        }
    }
    private var cornerNote: String {
        let what: String
        switch m.cornerStyle {
        case .concentric: what = L("settings.corners.concentric.sub", "图标和 Dock 与机身同心，壁纸铺满")
        case .balanced: what = L("settings.corners.balanced.sub", "介于同心与最大画面之间")
        case .maximize: what = L("settings.corners.maximize.sub", "只避开机身圆角，画面最大")
        }
        guard let px = m.cornerInset else { return what }
        return what + String(format: L("settings.corners.inset", "（这台 iPhone 每边内收 %d px）"), px)
    }
    var body: some View {
        Form {
            Section {
                ToggleRow(title: L("prefs.plugConnect", "后台自动连接"), subtitle: L("prefs.plugConnect.short", "开机后在后台等 iPhone"), symbol: "antenna.radiowaves.left.and.right", tint: tint,
                          info: L("prefs.plugConnect.sub", "开机在后台等待 iPhone；插线一次，之后无线自动连"),
                          isOn: Binding(get: { m.autoConnect }, set: { _ in m.perform("menuAgentToggle") }))
                Toggle(isOn: Binding(get: { m.carVideo }, set: { m.app?.setCarVideoAllowed($0); m.refresh() })) {
                    RowLabel(title: L("settings.carVideo", "在 CarPlay 播放视频"), subtitle: L("settings.carVideo.sub", "Mac 不会移动，视为一直停着"), symbol: "play.rectangle.fill", tint: tint)
                }
                LabeledContent {
                    Picker("", selection: Binding(get: { m.callGain }, set: { m.setCallGain($0) })) {
                        ForEach([0.0, 3, 6, 9, 12, 15], id: \.self) { db in
                            Text(String(format: "+%d dB", Int(db))).tag(db)
                        }
                    }
                    .pickerStyle(.menu).labelsHidden().fixedSize()
                } label: {
                    RowLabel(title: L("settings.callVolume", "通话音量"), subtitle: L("settings.callVolume.sub", "与媒体音量分开；默认 +6 dB"), symbol: "phone.fill", tint: tint)
                }
                LabeledContent {
                    HStack(spacing: 10) {
                        InfoButton(cornerNote)
                        Picker("", selection: Binding(get: { m.cornerStyle }, set: { v in
                            ConcentricCorners.style = v
                            m.refresh()
                            // 接收器每秒看一次設定、立刻重開會話；稍後再讀一次它算好的內收量
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { m.refresh() }
                        })) {
                            ForEach(ConcentricCorners.Style.allCases, id: \.self) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.segmented).labelsHidden().fixedSize()
                    }
                } label: {
                    RowLabel(title: L("settings.corners", "圆角"), subtitle: cornerShort, symbol: "app.fill", tint: tint)
                }
                LabeledContent {
                    Button(L("settings.airplay.open", "打开设置…")) { AirPlayWatch.openSettings() }
                } label: {
                    RowLabel(title: L("settings.airplay", "用 AirPlay 投到这台 Mac"), subtitle: L("settings.airplay.sub", "任何 App 都行，包括 Apple TV+"), symbol: "airplayvideo", tint: tint)
                }
            } header: {
                IllustrationHeader(scene: .charge, note: L("settings.carplay.note", "插线一次，之后无线"))
            }
            Section {
                if m.phones.isEmpty {
                    InfoRow(title: L("settings.noPhonesTitle", "还没有 iPhone"), subtitle: L("settings.noPhones.sub", "用数据线连一次就会记住"), symbol: "iphone", tint: .gray)
                }
                ForEach(m.phones, id: \.address) { phone in
                    let current = m.currentPhone.map { CarPlayPhoneBook.normalize($0) == CarPlayPhoneBook.normalize(phone.address) } ?? false
                    LabeledContent {
                        RowMenu {
                            if !current { Button(L("settings.usePhone", "使用")) { m.perform("menuUsePhone:", phone.address) } }
                            Button(L("settings.forget", "忘记…"), role: .destructive) { m.perform("menuForgetPhone:", phone.address) }
                        }
                    } label: {
                        RowLabel(title: phone.name.isEmpty ? phone.address : phone.name,
                                 subtitle: current ? L("settings.phone.current", "正在使用") : nil, symbol: "iphone", tint: current ? tint : .gray)
                    }
                }
            } header: {
                Text(L("menu.iphone", "iPhone"))
            } footer: {
                FooterButtons {
                    Button(L("menu.pairNewPhone", "配对新 iPhone…")) { m.perform("menuPairNewPhone") }
                    Button(L("settings.restorePhones", "恢复已忘记的…")) { m.perform("menuRestorePhones") }
                    Button(L("menu.wifiPassword", "Wi-Fi 设置…")) { m.perform("menuWiFiPassword") }
                }
            }
            PhoneHandoffSection()   // 2.0 promo：從 iPhone 傳網頁（Settings/PhoneHandoffSection.swift）
            SelfShareSection()      // CarPlay 連著時傳到 iPhone 改走訊息傳給自己：選帳號（Settings/SelfShareSection.swift）
        }
        .formStyle(.grouped)
    }
}

struct CameraPane: View {
    @EnvironmentObject var m: SettingsModel
    private let tint = SettingsSection.camera.tint
    var body: some View {
        Form {
            Section {
                Toggle(isOn: Binding(get: { m.gazeFollow }, set: { _ in m.app?.toggleGazeFollow(); m.refresh() })) {
                    RowLabel(title: L("settings.follow.title", "跟随我"), subtitle: L("settings.follow.sub", "CarPlay 显示时也会转向你"), symbol: "person.crop.square.fill", tint: tint)
                }
                ValueSlider(title: L("settings.followRange", "转向幅度"), symbol: "arrow.left.and.right", tint: tint,
                            value: Binding(get: { m.followDegrees }, set: { m.app?.setFollowDegrees($0); m.followDegrees = $0 }),
                            range: 10...25, step: 5, minLabel: "10°", maxLabel: "25°") { "\(Int($0))°" }
                    .disabled(!m.gazeFollow)
                ValueSlider(title: L("settings.followPitch", "俯仰幅度"), symbol: "arrow.up.and.down", tint: tint,
                            value: Binding(get: { m.gazePitch }, set: { let v = ($0 * 2).rounded() / 2; m.app?.view.setGazePitch(CGFloat(v)); m.gazePitch = v }),
                            range: 0...8, step: 0.5, minLabel: "0°", maxLabel: "8°") { String(format: "%.1f°", $0) }
                    .disabled(!m.gazeFollow)
            } header: {
                IllustrationHeader(scene: .follow, note: L("settings.follow.note", "只认人脸位置，不录制、不上传"))
            }
            Section {
                Toggle(isOn: Binding(get: { m.roomLight }, set: { _ in m.app?.toggleRoomLight(); m.refresh() })) {
                    RowLabel(title: L("settings.roomLight.title", "房间光线"), subtitle: L("settings.roomLight.note", "机身反光跟着房间变"), symbol: "lightbulb.fill", tint: .yellow)
                }
            }
        }
        .formStyle(.grouped)
    }
}

/// 家庭（B 方案，2026-10-26）：沒有小幫手時用 macOS 捷徑的家庭動作。
/// HomeKit 的權利只跟著 App Store 的 provisioning profile，Developer ID 版拿不到，
/// 所以這裡只管理「捷徑名稱」與執行；配件清單、即時狀態都不會有。怎麼建捷徑由頁首的動畫示範，不再列文字步驟。
struct HomePane: View {
    @EnvironmentObject var m: SettingsModel
    @State private var name = HomeShortcut.name
    private let tint = SettingsSection.home.tint

    var body: some View {
        Form {
            Section {
                LabeledContent {
                    TextField("", text: $name, prompt: Text(L("settings.home.name.prompt", "例：回家")))
                        .labelsHidden().frame(width: 200)
                        .onChange(of: name) { _, v in HomeShortcut.name = v; m.refresh() }
                } label: {
                    RowLabel(title: L("settings.home.name", "捷径名称"), subtitle: L("settings.home.name.sub", "跟「捷径」App 里的名字一样"), symbol: "house.fill", tint: tint)
                }
            } header: {
                IllustrationHeader(scene: .shortcut, note: L("settings.home.demoNote", "在「捷径」加「控制家庭」，再把名字填进来"),
                                   info: L("settings.home.note", "HomePlay 不能直接读 HomeKit，所以用捷径代替。执行时会切到捷径 App；这里没有配件清单，也没有即时状态。"))
            } footer: {
                FooterButtons {
                    Button(L("settings.home.openApp", "打开捷径 App")) { HomeShortcut.openApp() }
                    Button(L("settings.home.test", "测试执行")) { HomeShortcut.run() }
                        .disabled(!HomeShortcut.isSet)
                }
            }
            Section {
                InfoRow(title: L("settings.home.helper.title", "HomePlay Home 小帮手"),
                        subtitle: HomeLink.helperInstalled ? L("settings.home.helper.onShort", "已安装，优先使用") : L("settings.home.helper.offShort", "未安装"),
                        symbol: "puzzlepiece.extension.fill", tint: .gray,
                        info: HomeLink.helperInstalled ? L("settings.home.helper.on", "已安装：会优先使用小帮手，配件直接出现在家庭 App。")
                                                       : L("settings.home.helper.off", "未安装：公开版没有小帮手（HomeKit 只给 App Store 版）。"))
            }
        }
        .formStyle(.grouped)
    }
}

struct PermissionsPane: View {
    @EnvironmentObject var m: SettingsModel
    private func name(_ k: PermissionKind) -> String {
        switch k {
        case .camera: return L("settings.perm.camera", "相机")
        case .microphone: return L("settings.perm.mic", "麦克风")
        case .inputMonitoring: return L("settings.perm.input", "输入监控")
        case .automation: return L("settings.perm.automation", "自动化（音乐）")
        case .calendar: return L("settings.perm.calendar", "日历")
        case .photos: return L("settings.perm.photos", "照片")
        case .location: return L("settings.perm.location", "定位")
        case .reminders: return L("settings.perm.reminders", "提醒事项")
        }
    }
    private func summary(_ k: PermissionKind) -> String {
        switch k {
        case .camera: return L("settings.perm.camera.short", "跟随你转头、配合房间光线")
        case .microphone: return L("settings.perm.mic.short", "跟 ClioTalk 说话、CarPlay 通话")
        case .inputMonitoring: return L("settings.perm.input.short", "在任何 App 里按 F5 叫 ClioTalk")
        case .automation: return L("settings.perm.automation.short", "显示「音乐」或 Spotify 在播的歌")
        case .calendar: return L("settings.perm.calendar.sub", "在模块表盘上显示下一个行程")
        case .photos: return L("settings.perm.photos.short", "主屏幕的「照片」小组件")
        case .location: return L("settings.perm.location.short", "天气，和无线 CarPlay 的 Wi‑Fi")
        case .reminders: return L("settings.perm.reminders.short", "看清单、点圆圈完成")
        }
    }
    private func symbol(_ k: PermissionKind) -> (String, Color) {
        switch k {
        case .camera: return ("camera.fill", .gray)
        case .microphone: return ("mic.fill", .orange)
        case .inputMonitoring: return ("keyboard.fill", .gray)
        case .automation: return ("music.note", .pink)
        case .calendar: return ("calendar", .red)
        case .photos: return ("photo.fill", .indigo)
        case .location: return ("location.fill", .blue)
        case .reminders: return ("checklist", .orange)
        }
    }
    var body: some View {
        Form {
            Section {
                ForEach(PermissionKind.allCases, id: \.self) { k in
                    LabeledContent {
                        HStack(spacing: 10) {
                            switch m.permissions[k] ?? .notDetermined {
                            case .granted:
                                Label(L("settings.perm.granted", "已允许"), systemImage: "checkmark.circle.fill")
                                    .labelStyle(.titleAndIcon).foregroundStyle(.secondary)
                            case .notDetermined:
                                Button(L("settings.perm.allow", "允许…")) { m.app?.withPermission(k) { _ in m.refresh() } }
                            case .denied:
                                Button(L("perm.openSettings", "打开系统设置")) { PermissionCenter.openSettings(k) }
                            }
                        }
                    } label: {
                        RowLabel(title: name(k), subtitle: summary(k), symbol: symbol(k).0, tint: symbol(k).1)
                    }
                }
            } footer: {
                Text(L("settings.perm.footer", "系统询问前，桌宠会先说明用途")).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            WebAppsSection()   // 2.0 Web App：每個 Web App 的權限與網站資料（Settings/WebAppsSection.swift）
        }
        .formStyle(.grouped)
    }
}

/// 設定 › 手勢：手勢引導（原生分組表單列；2.0 設定改版從「一般」搬來）
struct IntroGuideSection: View {
    @EnvironmentObject var m: SettingsModel
    @State private var input = IntroGuide.setting
    @State private var tips = IntroGuide.newGestureTips
    private let tint = SettingsSection.gestures.tint
    var body: some View {
        Section {
            LabeledContent {
                HStack(spacing: 10) {
                    InfoButton(L("settings.intro.footer", "手势引导也可以从菜单栏的 HomePlay 菜单 ›「手势引导」打开。"))
                    Button(L("settings.intro.replay", "重看…")) { m.perform("menuShowHints") }
                }
            } label: {
                RowLabel(title: L("settings.intro", "手势引导"), subtitle: L("settings.intro.sub", "在桌宠上重新播一次开场的手势说明"), symbol: "play.rectangle.fill", tint: tint)
            }
            Picker(selection: Binding(get: { input }, set: { input = $0; IntroGuide.setting = $0 })) {
                Text(L("settings.intro.auto", "自动")).tag(IntroInputSetting.auto)
                Divider()
                Text(L("intro.input.mouse", "鼠标")).tag(IntroInputSetting.mouse)
                Text(L("intro.input.trackpad", "触控板")).tag(IntroInputSetting.trackpad)
                Text(L("settings.intro.touch", "手指（触控屏幕、Sidecar）")).tag(IntroInputSetting.touch)
            } label: {
                RowLabel(title: L("settings.intro.input", "引导依照的输入方式"), subtitle: L("settings.intro.input.short", "自动＝看你最近用的"), symbol: "hand.point.up.left.fill", tint: tint)
            }
            Toggle(isOn: Binding(get: { tips }, set: { tips = $0; IntroGuide.newGestureTips = $0 })) {
                RowLabel(title: L("settings.intro.tips", "遇到新手势时提示一次"), subtitle: L("settings.intro.tips.sub", "例如第一次把桌宠拖到触控屏幕上"), symbol: "lightbulb.fill", tint: tint)
            }
        } header: {
            Text(L("settings.intro.header", "手势引导"))
        }
    }
}
