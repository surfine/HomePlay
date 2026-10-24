import AppKit
import SwiftUI

// 设置的六个分页：系统的分组表单（Form + .grouped）当骨架，写法学 WindowShade——
// 一页一组插画＋一行说明；每行标题＋一句很短的副标题；不放图标、不堆说明段落。

/// 页首：两格插画＋一行说明，放在第一组设置的 header 里（没有卡片底）
struct IllustrationHeader: View {
    let scene: IllusScene
    let note: String
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack { IllustrationStage(scene: scene).id(scene).transition(.blurFade) }
                .animation(.easeOut(duration: 0.2), value: scene)
                .padding(.horizontal, -10)   // header 本身内缩 10 pt：插画两边要和下面的卡片切齐
            Text(note).font(.callout).foregroundStyle(.secondary)
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

/// 只有文字、没有控件的一行（包进 LabeledContent，第二行才会排成副标题）
struct InfoRow: View {
    let title: String
    var subtitle: String? = nil
    var body: some View {
        LabeledContent { EmptyView() } label: { RowLabel(title: title, subtitle: subtitle) }
    }
}

/// 标题＋灰色副标题（放在 Toggle／Picker／LabeledContent 的 label 里）
struct RowLabel: View {
    let title: String
    var subtitle: String? = nil
    var body: some View {
        Text(title)
        if let subtitle { Text(subtitle) }
    }
}

struct GeneralPane: View {
    @EnvironmentObject var m: SettingsModel
    var body: some View {
        Form {
            Section {
                Toggle(isOn: Binding(get: { m.loginItem }, set: { _ in m.perform("menuLoginItem") })) {
                    RowLabel(title: L("settings.loginItem", "登录时打开 HomePlay"),
                             subtitle: m.loginAvailable ? nil : L("settings.loginItem.needsApp", "打包成 App 后可用"))
                }.disabled(!m.loginAvailable)
                Toggle(isOn: Binding(get: { m.alwaysOnTop }, set: { m.app?.setAlwaysOnTop($0); m.refresh() })) {
                    RowLabel(title: L("settings.alwaysOnTop", "窗口置顶"), subtitle: L("settings.alwaysOnTop.sub", "全屏 App 在前面时自动让开"))
                }
                Picker(L("settings.language", "语言"), selection: Binding(get: { m.language }, set: { m.perform("menuLanguage:", $0 == "system" ? nil : $0) })) {
                    Text(L("settings.language.system", "跟随系统")).tag("system")
                    Divider()
                    Text("English").tag(PetLanguage.en.rawValue)
                    Text("简体中文").tag(PetLanguage.zhHans.rawValue)
                    Text("繁體中文").tag(PetLanguage.zhHant.rawValue)
                }
                // 连续的值用滑杆：滑块的位置就是现在的大小；两端标「小／大」
                Slider(value: Binding(get: { m.petWidth }, set: { m.app?.setPetWidth($0); m.petWidth = $0 }),
                       in: Double(Pet.minWidth)...Double(Pet.maxWidth)) {
                    RowLabel(title: L("settings.size", "大小"), subtitle: L("settings.size.sub", "也可以双指张合，或 ⌘+ ⌘−"))
                } minimumValueLabel: {
                    Text(L("settings.size.small", "小"))   // 照系统设置「轨迹速度」两端写「慢／快」的做法
                } maximumValueLabel: {
                    Text(L("settings.size.large", "大"))
                }
            } header: {
                IllustrationHeader(scene: .onTop, note: L("settings.general.heroBody", "陪你待在桌面上"))
            }
            Section {
                Toggle(isOn: Binding(get: { m.nowPlayingOn }, set: { _ in m.perform("menuNowPlaying") })) {
                    RowLabel(title: L("prefs.nowPlaying", "Mac 正在播放（Music/Spotify）"), subtitle: L("settings.nowPlaying.sub", "CarPlay 播放时优先显示 iPhone"))
                }
                Toggle(isOn: Binding(get: { m.calendarOn && m.permissions[.calendar] == .granted }, set: { _ in m.perform("menuCalendarToggle") })) {
                    RowLabel(title: L("prefs.calendar.on", "读取日历"),
                             subtitle: m.permissions[.calendar] == .granted ? L("settings.calendar.sub", "显示下一个行程")
                                                                            : L("settings.calendar.needsPerm", "先在「权限」里允许"))
                }.disabled(m.permissions[.calendar] != .granted)
            } header: {
                Text(L("settings.sources", "表盘上的数据"))
            } footer: {
                FooterButtons { Button(L("prefs.hints", "再看一次操作提示")) { m.perform("menuShowHints") } }
            }
        }
        .formStyle(.grouped)
    }
}

struct AppearancePane: View {
    @EnvironmentObject var m: SettingsModel
    var body: some View {
        Form {
            Section {
                Picker(L("settings.facing", "朝向"), selection: Binding(get: { m.viewMode }, set: { m.app?.view.setViewMode($0); m.refresh() })) {
                    Text(L("settings.facing.auto", "自动")).tag(ViewMode.auto)
                    Text(L("settings.facing.front", "正面固定")).tag(ViewMode.front)
                }.pickerStyle(.segmented).fixedSize()
                LabeledContent(L("settings.angle", "视角")) {
                    ControlGroup {
                        Button(L("menu.view.front", "正面")) { m.perform("menuViewFront") }
                        Button(L("menu.view.side", "侧面")) { m.perform("menuViewSide") }
                        Button(L("menu.view.back", "背面")) { m.perform("menuViewBack") }
                        Button(L("menu.view.top", "俯视")) { m.perform("menuViewAbove") }
                    }.fixedSize()
                }
            } header: {
                IllustrationHeader(scene: m.viewMode == .front ? .facingFront : .facing,
                                   note: m.viewMode == .auto ? L("settings.facing.note", "自动朝向屏幕中央") : L("settings.facing.frontNote", "始终正对前方"))
            }
            Section {
                Picker(L("settings.finish", "配色"), selection: Binding(get: { m.finish }, set: { m.perform("menuFinish:", $0.rawValue) })) {
                    ForEach(Finish.allCases, id: \.self) { Text($0.title).tag($0) }
                }
            }
            Section {
                Picker(L("settings.face", "表盘"), selection: Binding(get: { m.faceStyle }, set: { m.perform("menuStyle:", $0.rawValue) })) {
                    ForEach(FaceStyle.lineup, id: \.self) { Text($0.title).tag($0) }
                }
                if m.faceStyle == .island {   // 島錶面自己的三個選項（和右鍵選單「島錶面」同一份動作）
                    Picker(L("island.clock", "时钟样式"), selection: Binding(get: { m.clockStyle }, set: { m.perform("menuIslandClock:", $0.rawValue) })) {
                        ForEach(ClockStyle.allCases.filter { $0 != .thin }, id: \.self) { Text($0.title).tag($0) }
                    }
                    Picker(L("island.bg", "背景"), selection: Binding(get: { m.islandBackground }, set: { m.perform("menuIslandBackground:", $0.rawValue) })) {
                        ForEach(IslandBackground.choices(for: m.era), id: \.self) { Text($0.title).tag($0) }
                    }
                    Picker(L("island.era", "年代"), selection: Binding(get: { m.era }, set: { m.perform("menuIslandEra:", $0.rawValue) })) {
                        ForEach(Era.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                }
                if m.faceStyle == .analog {   // Typograph 的材質（和右鍵選單同一份動作）
                    Picker(L("typograph.material", "Typograph 材质"), selection: Binding(get: { m.typographMaterial }, set: { m.perform("menuTypographMaterial:", $0.rawValue) })) {
                        ForEach(TypographMaterial.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                }
                if m.faceStyle == .system6 {   // System 6 的版式
                    Picker(L("system6.layout", "System 6 版式"), selection: Binding(get: { m.system6Layout }, set: { m.perform("menuSystem6Layout:", $0.rawValue) })) {
                        ForEach(System6Layout.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                }
                if m.faceStyle == .photos || (m.faceStyle == .island && m.islandBackground == .photo) {
                    LabeledContent(L("settings.photos", "照片")) {
                        Button(L("prefs.photoFolder", "照片文件夹…")) { m.perform("menuPhotoFolder") }
                    }
                }
            } header: {
                Text(L("settings.face", "表盘"))
            }
            Section {
                Picker(selection: Binding(get: { m.capsule }, set: { v in
                    capsuleMaterialSetting = v; UserDefaults.standard.set(v.rawValue, forKey: CapsuleMaterial.defaultsKey)
                    m.app?.view.face.forceDirty = true; m.refresh()
                })) {
                    ForEach(CapsuleMaterial.allCases, id: \.self) { Text($0.title).tag($0) }
                } label: {
                    RowLabel(title: L("settings.capsule", "胶囊"),
                             subtitle: m.capsuleLocked ? L("settings.capsule.locked", "这个表盘用它那个年代的样子")
                                                       : L("settings.capsule.sub", "装着 👀 的那颗；自动＝跟着表盘的年代"))
                }
                .disabled(m.capsuleLocked)
                LabeledContent {
                    Button(L("clockLook.edit", "编辑…")) { m.perform("menuClockLook:") }.disabled(!m.clockLookApplies)
                } label: {
                    RowLabel(title: L("clockLook.title", "字体与颜色"),
                             subtitle: m.clockLookApplies ? L("clockLook.subtitle", "岛表盘和照片表盘的大时间")
                                                          : L("clockLook.unavailable", "只用于岛（2026）和照片表盘"))
                }
            }
        }
        .formStyle(.grouped)
    }
}

/// 手势：分段（触控板／机身与键盘）；指标停在哪一行，插画就换成那一段从头播。
struct GesturesPane: View {
    @State private var tab = 0
    @State private var selected: IllusScene = .pinch
    @State private var hoverIntent: Task<Void, Never>?

    private struct Gesture: Identifiable {
        let scene: IllusScene, title: String, subtitle: String
        var id: String { scene.rawValue }
    }
    private var gestures: [Gesture] {
        [Gesture(scene: .pinch, title: L("settings.gesture.pinch.title", "缩放"), subtitle: L("settings.gesture.pinch", "双指张合")),
         Gesture(scene: .slide, title: L("settings.gesture.slide.title", "转动机身"), subtitle: L("settings.gesture.slide", "在机身上双指一起滑")),
         Gesture(scene: .three, title: L("settings.gesture.three.title", "搬窗口"), subtitle: L("settings.gesture.three", "三指拖移，CarPlay 显示时也行")),
         Gesture(scene: .force, title: L("settings.gesture.force.title", "进入 CarPlay"), subtitle: L("settings.gesture.force", "重按屏幕"))]
    }

    var body: some View {
        Form {
            Section {
                Picker("", selection: $tab) {
                    Text(L("settings.gestures.tab.trackpad", "触控板")).tag(0)
                    Text(L("settings.gestures.tab.body", "机身与键盘")).tag(1)
                }
                .pickerStyle(.segmented).labelsHidden()
                .frame(maxWidth: .infinity)
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            } header: {
                IllustrationHeader(scene: selected, note: L("settings.gestures.intro", "两指同向是滑动，相向或相背是捏合"))
            }
            if tab == 0 {
                Section {
                    ForEach(gestures) { g in
                        LabeledContent {
                            Image(systemName: "play.circle.fill")
                                .foregroundStyle(Color.accentColor)
                                .opacity(selected == g.scene ? 1 : 0)
                        } label: {
                            RowLabel(title: g.title, subtitle: g.subtitle)
                        }
                        .contentShape(Rectangle())
                        .onHover { inside in
                            // 停 80 ms 才换：指标从上往下扫过时不会一路换三段
                            hoverIntent?.cancel()
                            guard inside else { return }
                            hoverIntent = Task { @MainActor in
                                try? await Task.sleep(nanoseconds: 80_000_000)
                                if !Task.isCancelled { pick(g.scene) }
                            }
                        }
                        .onTapGesture { hoverIntent?.cancel(); pick(g.scene) }
                        .accessibilityAddTraits(selected == g.scene ? [.isButton, .isSelected] : .isButton)
                    }
                }
            } else {
                Section {
                    InfoRow(title: L("settings.gesture.liveSlide", "CarPlay 显示时在屏幕上双指滑"), subtitle: L("settings.gesture.liveSlide.sub", "在 CarPlay 里拖动"))
                    InfoRow(title: L("settings.gesture.reset", "双击机身"), subtitle: L("settings.gesture.reset.sub", "角度回正"))
                    InfoRow(title: L("settings.gesture.apart", "两指轻点两下"), subtitle: L("settings.gesture.apart.sub", "拆开看看，再点两下组回来"))
                    InfoRow(title: L("settings.gesture.overview", "长按屏幕"), subtitle: L("settings.gesture.overview.sub", "打开表盘总览"))
                    InfoRow(title: L("settings.gesture.scroll", "滚轮或 ← →"), subtitle: L("settings.gesture.scroll.sub", "换表盘"))
                    InfoRow(title: L("settings.gesture.keys", "键盘"), subtitle: L("settings.gesture.keys.sub", "空格暂停/继续 · F5 Siri · 1–4 视角"))
                }
            }
        }
        .formStyle(.grouped)
    }

    private func pick(_ scene: IllusScene) {
        guard scene != selected else { return }
        withAnimation(.easeOut(duration: 0.2)) { selected = scene }
    }
}

struct CarPlayPane: View {
    @EnvironmentObject var m: SettingsModel
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
                Toggle(isOn: Binding(get: { m.autoConnect }, set: { _ in m.perform("menuAgentToggle") })) {
                    RowLabel(title: L("prefs.plugConnect", "后台自动连接"), subtitle: L("prefs.plugConnect.sub", "开机在后台等待 iPhone；插线一次，之后无线自动连"))
                }
                Toggle(isOn: Binding(get: { m.carVideo }, set: { m.app?.setCarVideoAllowed($0); m.refresh() })) {
                    RowLabel(title: L("settings.carVideo", "在 CarPlay 播放视频"), subtitle: L("settings.carVideo.sub", "Mac 不会移动，视为一直停着"))
                }
                LabeledContent {
                    Picker("", selection: Binding(get: { m.cornerStyle }, set: { v in
                        ConcentricCorners.style = v
                        m.refresh()
                        // 接收器每秒看一次設定、立刻重開會話；稍後再讀一次它算好的內收量
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { m.refresh() }
                    })) {
                        ForEach(ConcentricCorners.Style.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                } label: {
                    RowLabel(title: L("settings.corners", "圆角"), subtitle: cornerNote)
                }
                LabeledContent {
                    Button(L("settings.airplay.open", "打开设置…")) { AirPlayWatch.openSettings() }
                } label: {
                    RowLabel(title: L("settings.airplay", "用 AirPlay 投到这台 Mac"), subtitle: L("settings.airplay.sub", "任何 App 都行，包括 Apple TV+"))
                }
            } header: {
                IllustrationHeader(scene: .charge, note: L("settings.carplay.note", "插线一次，之后无线"))
            }
            Section {
                if m.phones.isEmpty {
                    InfoRow(title: L("settings.noPhonesTitle", "还没有 iPhone"), subtitle: L("settings.noPhones.sub", "用数据线连一次就会记住"))
                }
                ForEach(m.phones, id: \.address) { phone in
                    let current = m.currentPhone.map { CarPlayPhoneBook.normalize($0) == CarPlayPhoneBook.normalize(phone.address) } ?? false
                    LabeledContent {
                        HStack(spacing: 8) {
                            if !current { Button(L("settings.usePhone", "使用")) { m.perform("menuUsePhone:", phone.address) } }
                            Button(L("settings.forget", "忘记…")) { m.perform("menuForgetPhone:", phone.address) }
                        }
                    } label: {
                        RowLabel(title: phone.name.isEmpty ? phone.address : phone.name,
                                 subtitle: current ? L("settings.phone.current", "正在使用") : nil)
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
        }
        .formStyle(.grouped)
    }
}

struct CameraPane: View {
    @EnvironmentObject var m: SettingsModel
    var body: some View {
        Form {
            Section {
                Toggle(isOn: Binding(get: { m.gazeFollow }, set: { _ in m.app?.toggleGazeFollow(); m.refresh() })) {
                    RowLabel(title: L("settings.follow.title", "跟随我"), subtitle: L("settings.follow.sub", "CarPlay 显示时也会转向你"))
                }
                Slider(value: Binding(get: { m.followDegrees }, set: { m.app?.setFollowDegrees($0); m.followDegrees = $0 }), in: 10...25, step: 5) {
                    Text(L("settings.followRange", "转向幅度"))
                } minimumValueLabel: { Text("10°") } maximumValueLabel: { Text("25°") }
                    .disabled(!m.gazeFollow)
                Slider(value: Binding(get: { m.gazePitch }, set: { let v = ($0 * 2).rounded() / 2; m.app?.view.setGazePitch(CGFloat(v)); m.gazePitch = v }), in: 0...8) {
                    Text(L("settings.followPitch", "俯仰幅度"))
                } minimumValueLabel: { Text("0°") } maximumValueLabel: { Text("8°") }
                    .disabled(!m.gazeFollow)
            } header: {
                IllustrationHeader(scene: .follow, note: L("settings.follow.note", "只认人脸位置，不录制、不上传"))
            }
            Section {
                Toggle(isOn: Binding(get: { m.roomLight }, set: { _ in m.app?.toggleRoomLight(); m.refresh() })) {
                    RowLabel(title: L("settings.roomLight.title", "房间光线"), subtitle: L("settings.roomLight.note", "机身反光跟着房间变"))
                }
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
        }
    }
    private func summary(_ k: PermissionKind) -> String {
        switch k {
        case .camera: return L("settings.perm.camera.sub", "跟随你转头、配合房间光线")
        case .microphone: return L("settings.perm.mic.sub", "按住 F5 跟 Siri 说话、CarPlay 通话")
        case .inputMonitoring: return L("settings.perm.input.sub", "在任何 App 里按 F5 都能叫 Siri")
        case .automation: return L("settings.perm.automation.sub", "显示「音乐」或 Spotify 正在播放的歌")
        case .calendar: return L("settings.perm.calendar.sub", "在模块表盘上显示下一个行程")
        }
    }
    var body: some View {
        Form {
            Section {
                ForEach(PermissionKind.allCases, id: \.self) { k in
                    LabeledContent {
                        switch m.permissions[k] ?? .notDetermined {
                        case .granted:
                            Label(L("settings.perm.granted", "已允许"), systemImage: "checkmark.circle.fill")
                                .labelStyle(.titleAndIcon).foregroundStyle(.secondary)
                        case .notDetermined:
                            Button(L("settings.perm.allow", "允许…")) { m.app?.withPermission(k) { _ in m.refresh() } }
                        case .denied:
                            Button(L("perm.openSettings", "打开系统设置")) { PermissionCenter.openSettings(k) }
                        }
                    } label: {
                        RowLabel(title: name(k), subtitle: summary(k))
                    }
                }
            } footer: {
                Text(L("settings.perm.footer", "系统询问前，桌宠会先说明用途")).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .formStyle(.grouped)
    }
}
