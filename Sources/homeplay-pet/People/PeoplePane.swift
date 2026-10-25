import AppKit
import SwiftUI

// 设置里的「家人」页：系统的分组表单（Form + .grouped），写法跟其他几页一致。
// 状态来自 PeopleRegistry（名册＋模板）和 WhoIsLooking（录脸）；这个页面不碰任何脸部数据的内容，只看「有没有」。

/// 设置页读的名册快照（主线程）。
final class PeopleModel: ObservableObject {
    static let shared = PeopleModel()
    @Published var people: [Person] = PeopleRegistry.shared.people
    @Published var faceData: [String: PeopleRegistry.FaceDataState] = [:]
    @Published var recognize = WhoIsLooking.recognitionEnabled
    @Published var followOn = false

    func refresh() {
        if SnapshotPrivacy.active {   // 快照、示範出圖不讀真的名冊（SnapshotPrivacy）：兩個示範的人
            people = [Person(id: "demo-owner", name: "Erica", colorIndex: 3, isOwner: true),     // l10n-ignore：示範人名（跟 --demo-official 同一位）
                      Person(id: "demo-family", name: "Marco", colorIndex: 0, isOwner: false)]   // l10n-ignore：示範人名
            faceData = ["demo-owner": .enrolled, "demo-family": .none]
            recognize = WhoIsLooking.recognitionEnabled
            return
        }
        let r = PeopleRegistry.shared
        people = r.people
        faceData = Dictionary(uniqueKeysWithValues: r.people.map { ($0.id, r.faceDataState($0.id)) })
        recognize = WhoIsLooking.recognitionEnabled
    }
}

/// 录脸进度（给设置页的那一行用）。
final class PeopleEnrollmentState: ObservableObject {
    static let shared = PeopleEnrollmentState()
    @Published var personID: String?
    @Published var progress = 0.0
    @Published var message: String?

    func begin(personID: String) {
        self.personID = personID; self.progress = 0; self.message = nil
    }
    func update(phase: FaceEnrollmentFlow.Phase, progress: Double, asksToTurn: Bool) {
        self.progress = progress
    }
    func finish(phase: FaceEnrollmentFlow.Phase) {
        personID = nil
        switch phase {
        case .saved: message = L("people.pane.saved", "录好了")
        case .ended(.cancelled): message = nil
        case .ended(.timedOut): message = L("people.enroll.timedOut", "没录到")
        case .ended(.cameraLost): message = L("people.enroll.cameraLost", "用不了相机")
        default: message = L("people.enroll.failed", "没存成功")
        }
        PeopleModel.shared.refresh()
    }
}

struct PeopleAvatar: View {
    let person: Person
    var size: CGFloat = 30
    var body: some View {
        // 2.0 第五輪：帳號頭像 → 聯絡人「我」→ 灰色縮寫；選了 👀 才是 👀 人物（People/AvatarSources.swift）
        if let photo = person.avatarPhoto {
            Image(decorative: photo, scale: 1).resizable().scaledToFill().frame(width: size, height: size).clipShape(Circle())
        } else if person.resolvedAvatar == .eyes {
            HPAvatarView(style: HPAvatar.style(for: person), size: size)
        } else if let img = Monogram.image(initials: AvatarResolver.initials(person.name), px: Int(size * 2)) {
            Image(decorative: img, scale: 2).resizable().frame(width: size, height: size)
        }
    }
}

/// 2.0 第四輪／第五輪：換頭像（系統的分組表單）：來源（自動＝帳號頭像 → 聯絡人「我」→ 縮寫／聯絡人照片／👀 頭像）；
/// 👀 頭像有 12 種預設、再細調臉型、髮型、髮色、膚色、底色
struct AvatarEditor: View {
    let person: Person
    @Environment(\.dismiss) private var dismiss
    @State private var style: HPAvatar.Style
    @State private var source: AvatarSource
    @State private var photos = 0   // 帳號頭像、聯絡人照片讀到時 +1（重畫預覽）

    init(person: Person) {
        self.person = person
        _style = State(initialValue: HPAvatar.style(for: person))
        _source = State(initialValue: person.effectiveAvatarSource)
    }

    private var preview: Person {
        var p = person; p.avatar = style; p.useContactPhoto = nil; p.avatarSource = source; return p
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    HStack { Spacer(); PeopleAvatar(person: preview, size: 96).id(photos); Spacer() }.padding(.vertical, 6)
                    Picker(L("avatar.source", "头像"), selection: $source) {
                        Text(person.isOwner ? L("avatar.source.auto", "自动") : L("avatar.source.initials", "缩写")).tag(AvatarSource.automatic)
                        if person.isOwner { Text(L("avatar.source.contact", "联系人照片")).tag(AvatarSource.contact) }
                        Text(L("avatar.source.eyes", "👀 头像")).tag(AvatarSource.eyes)
                    }
                    .pickerStyle(.segmented)
                    if person.isOwner, source == .automatic {
                        InfoRow(title: L("avatar.auto.note", "用这台 Mac 的账户头像；没有就用通讯录里“我”的照片，再没有就用名字缩写"))
                    }
                    if source == .contact, MeCard.photo == nil {
                        InfoRow(title: L("avatar.contact.none", "读不到通讯录里“我”的照片，先用账户头像或缩写"))
                    }
                }
                if source == .eyes {
                    Section(L("avatar.presets", "样式")) {
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 6), spacing: 10) {
                            ForEach(Array(HPAvatar.presets.enumerated()), id: \.offset) { _, st in
                                Button { style = st } label: {
                                    HPAvatarView(style: st, size: 40)
                                        .overlay(Circle().stroke(Color.accentColor, lineWidth: st == style ? 2.5 : 0).padding(-3))
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(L("avatar.preset", "头像样式"))
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    Section(L("avatar.customize", "细节")) {
                        Picker(L("avatar.face", "脸型"), selection: $style.face) {
                            ForEach(HPAvatar.FaceShape.allCases, id: \.rawValue) { Text(HPAvatar.faceName($0)).tag($0.rawValue) }
                        }
                        Picker(L("avatar.hair", "发型"), selection: $style.hair) {
                            ForEach(HPAvatar.Hair.allCases, id: \.rawValue) { Text(HPAvatar.hairName($0)).tag($0.rawValue) }
                        }
                        Picker(L("avatar.hairColor", "发色"), selection: $style.hairColor) {
                            ForEach(HPAvatar.hairColors.indices, id: \.self) { Text(HPAvatar.hairColorName($0)).tag($0) }
                        }
                        Picker(L("avatar.skin", "肤色"), selection: $style.skin) {
                            ForEach(HPAvatar.skins.indices, id: \.self) { Text(HPAvatar.skinName($0)).tag($0) }
                        }
                        Picker(L("avatar.background", "底色"), selection: $style.background) {
                            ForEach(HPAvatar.backgrounds.indices, id: \.self) { Text(HPAvatar.backgroundName($0)).tag($0) }
                        }
                    }
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button(L("avatar.cancel", "取消"), role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(L("avatar.done", "完成")) {
                    try? PeopleRegistry.shared.setAvatar(person.id, style: style, source: source)
                    PeopleModel.shared.refresh()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 440, height: 560)
        .onAppear {
            AccountPicture.load { photos += 1 }
            MeCard.load { photos += 1 }
        }
    }
}

struct PeoplePane: View {
    @EnvironmentObject var m: SettingsModel
    @ObservedObject private var model = PeopleModel.shared
    @ObservedObject private var enrollment = PeopleEnrollmentState.shared
    @State private var newName = ""
    @State private var deleting: Person?
    @State private var confirmDeleteAll = false
    @State private var editingAvatar: Person?

    private var canAdd: Bool { model.people.count < PeopleRegistry.maxPeople }

    private func rowSubtitle(_ p: Person) -> String {
        if enrollment.personID == p.id { return L("people.pane.recording", "看着桌宠的屏幕，慢慢转头") }
        switch model.faceData[p.id] ?? .none {
        case .enrolled: return (p.isOwner ? L("people.pane.owner", "主人 · ") : "") + L("people.pane.enrolled", "已录制脸部")
        case .staleModel: return L("people.pane.stale", "识别方式更新了，请重新录制")
        case .none: return (p.isOwner ? L("people.pane.owner", "主人 · ") : "") + L("people.pane.notEnrolled", "还没录制脸部")
        }
    }

    /// 2.0 depth：開著卻還沒有主人的臉可比（沒錄過，或換了模型要重錄）：門其實沒鎖，照實說
    private var ownerUnset: String? {
        guard model.recognize, !PeopleRegistry.shared.matcherInput().contains(where: \.isOwner) else { return nil }
        return PeopleRegistry.shared.hasAnyFaceData ? L("people.pane.recognize.stale", "脸部资料要重新录；录好之前个人内容不会上锁")
                                                    : L("people.pane.recognize.noOwner", "还没录主人的脸；录好之后个人内容才会上锁")
    }

    var body: some View {
        Form {
            Section {
                Toggle(isOn: Binding(get: { model.recognize }, set: { WhoIsLooking.recognitionEnabled = $0; model.refresh() })) {
                    RowLabel(title: L("people.pane.recognize", "认出谁在看"),
                             subtitle: !m.gazeFollow ? L("people.pane.recognize.needsFollow", "需要先在「相机」里打开「跟随我」")
                                : ownerUnset ?? L("people.pane.recognize.sub", "个人内容只给认出的主人看"))
                }
                // P09：照官網用語寫清楚——家人認出來有自己的一份主畫面，個人內容只開給主人，共享的相簿與音樂全家都看得到
                InfoRow(title: L("people.pane.personal", "家人认出后有自己的一份主画面；个人内容（日历、提醒事项、信息、FaceTime）只开给这台 Mac 的主人，共享的相簿与音乐全家都能看"))
            } header: {
                // P09：只宣稱臉部（沒有聲音辨識）；臉部特徵只在本機＝HomeView 用 Secure Exclaves 隔離處理的對應做法
                Text(L("people.pane.note", "只识别脸部，不识别声音；脸部特征只存在这台 Mac，不录制、不上传"))
                    .textCase(nil).font(.callout).foregroundStyle(.secondary).padding(.bottom, 4)
            }

            Section {
                ForEach(model.people) { p in
                    LabeledContent {
                        HStack(spacing: 8) {
                            if enrollment.personID == p.id {
                                ProgressView(value: enrollment.progress).frame(width: 80)
                                Button(L("people.enroll.cancel", "取消")) { WhoIsLooking.shared.cancelEnrollment() }
                            } else {
                                let enrolled = (model.faceData[p.id] ?? .none) != .none
                                Button(enrolled ? L("people.pane.reenroll", "重新录制") : L("people.pane.enroll", "录制脸部")) {
                                    guard let app = m.app else { return }
                                    WhoIsLooking.shared.beginEnrollment(personID: p.id, app: app)
                                }.disabled(enrollment.personID != nil)
                                Button(L("people.pane.avatar", "头像…")) { editingAvatar = p }   // 2.0 第四輪
                                if !p.isOwner {
                                    Button(L("people.pane.delete", "删除…"), role: .destructive) { deleting = p }
                                        .disabled(enrollment.personID != nil)
                                }
                            }
                        }
                    } label: {
                        Label {
                            RowLabel(title: p.name, subtitle: rowSubtitle(p))
                        } icon: {
                            PeopleAvatar(person: p)
                        }
                    }
                }
                if let message = enrollment.message {
                    InfoRow(title: message)
                }
                LabeledContent {
                    HStack(spacing: 8) {
                        TextField("", text: $newName, prompt: Text(L("people.pane.namePrompt", "名字")))
                            .labelsHidden().frame(width: 130).onSubmit(addPerson)
                        Button(L("people.pane.add", "添加"), action: addPerson)
                            .disabled(!canAdd || newName.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                } label: {
                    RowLabel(title: L("people.pane.addTitle", "添加家人"),
                             subtitle: String(format: L("people.pane.limit", "最多 %d 人（现在 %d 人）"), PeopleRegistry.maxPeople, model.people.count))
                }
            } header: {
                Text(L("people.pane.family", "家人"))
            } footer: {
                FooterButtons {
                    Button(L("people.pane.deleteAll", "删除所有脸部数据…"), role: .destructive) { confirmDeleteAll = true }
                        .disabled(!model.faceData.values.contains { $0 != .none } || enrollment.personID != nil)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { model.refresh(); AccountPicture.load { model.refresh() }; MeCard.load { model.refresh() } }   // 第五輪：頭像照片讀到再重畫
        .sheet(item: $editingAvatar) { AvatarEditor(person: $0) }
        .confirmationDialog(deleting.map { String(format: L("people.pane.deleteOne", "删除“%@”？"), $0.name) } ?? "",
                            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible, presenting: deleting) { p in
            Button(L("people.pane.deleteConfirm", "删除"), role: .destructive) {
                try? PeopleRegistry.shared.remove(p.id); deleting = nil; model.refresh()
            }
        } message: { _ in
            Text(L("people.pane.deleteOne.sub", "这个人的名字和脸部数据都会删掉"))
        }
        .confirmationDialog(L("people.pane.deleteAll.title", "删除所有脸部数据？"), isPresented: $confirmDeleteAll, titleVisibility: .visible) {
            Button(L("people.pane.deleteAll.confirm", "全部删除"), role: .destructive) {
                PeopleRegistry.shared.deleteAllFaceData(); model.refresh()
            }
        } message: {
            Text(L("people.pane.deleteAll.sub", "名字会留着，每个人都要重新录制脸部"))
        }
    }

    private func addPerson() {
        guard canAdd, !newName.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        _ = try? PeopleRegistry.shared.add(name: newName)
        newName = ""
        model.refresh()
    }
}

/// 快照：--avatar-editor-png out.png [--dark]——把「換頭像」表單畫進一張圖（離屏視窗，不碰名冊）
enum AvatarEditorSnapshot {
    static func write(_ path: String) {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        if CommandLine.arguments.contains("--dark") { app.appearance = NSAppearance(named: .darkAqua) }
        let demo = Person(id: "demo", name: "Erica", colorIndex: 0, isOwner: true, avatar: HPAvatar.presets[1], avatarSource: .eyes)   // l10n-ignore：示範人名
        let host = NSHostingView(rootView: AvatarEditor(person: demo))
        let w = NSWindow(contentRect: NSRect(x: -3000, y: -3000, width: 440, height: 560), styleMask: [.titled], backing: .buffered, defer: false)
        w.contentView = host
        w.orderFrontRegardless()
        RunLoop.main.run(until: Date().addingTimeInterval(1.0))
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { exit(1) }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        exit(0)
    }
}
