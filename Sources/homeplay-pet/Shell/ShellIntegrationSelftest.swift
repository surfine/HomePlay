// 2.0 整合的 --selftest：個人內容的門（真值表）、訊息送出一定要先確認（App 的確認卡與 ClioTalk 的 messages_send）、
// 新訊息 Live Activity 的隱私字、建議回覆的解析、照名字找對話。全部離線：不碰真的 chat.db、不送 AppleScript、不連網。

import Foundation

enum ShellIntegrationSelftest {
    private static func wait(_ body: @escaping () async -> Void) {
        let sem = DispatchSemaphore(value: 0)
        Task.detached { await body(); sem.signal() }
        sem.wait()
    }

    static func run(_ check: (Bool, String) -> Void) {
        gate(check); replyFlow(check); activity(check); clioMessages(check); helpers(check)
        PhotoPick.selftest(check); Round6Selftest.run(check); LiveActivitySelftest.run(check); DepthSelftest.run(check)   // 第六輪：照片小工具、主畫面照官方、ClioTalk 名字與城市、1988 選單、Bit1 文字位置；P03 Live Activity
        HomeAppearanceSelftest.run(check); PersonHome.selftest(check); HomeWidgetsSelftest.run(check); SBModelSelftest.run(check); SBBoardSelftest.run(check); FacePagingSelftest.run(check)   // P02：主畫面外觀、每人主畫面、小工具圖庫
        CCModelSelftest.run(check); CCSystem.selftest(check)   // 2.0 cc：控制中心的模組版面、每人一份、專注模式解析、訪客的門
    }

    // MARK: 個人內容的門

    private static func gate(_ check: (Bool, String) -> Void) {
        typealias I = PersonalGate.Inputs
        func allow(_ i: I) -> Bool { PersonalGate.allowed(i) }
        check(allow(I()), "門：沒開認人、沒選人＝主人在用")
        check(!allow(I(guestMode: true)), "門：訪客模式一律關")
        check(!allow(I(guestMode: true, recognitionActive: true, viewer: .owner("o"))), "門：訪客模式連主人在也關")
        check(!allow(I(hintIsOwner: false)) && allow(I(hintIsOwner: true)), "門：沒開認人時「換人」選別人就關、選主人照開")
        check(allow(I(recognitionActive: true, viewer: .owner("o"))), "門：認人開著、眼前是主人＝開")
        for v: Viewer in [.nobody, .guest, .known("k")] {
            check(!allow(I(recognitionActive: true, viewer: v)), "門：認人開著、眼前不是主人（\(v)）＝關")
        }
        check(!allow(I(recognitionActive: true, viewer: .owner("o"), contradictsOwner: true)), "門：有不像主人的證據＝關")
        check(!allow(I(recognitionActive: true, viewer: .owner("o"), requirePhone: true, phonePresent: nil))
              && allow(I(recognitionActive: true, viewer: .owner("o"), requirePhone: true, phonePresent: true)), "門：要求 iPhone 時不知道在不在就關")   // l10n-ignore：selftest 斷言
        check(allow(I(recognitionActive: true, viewer: .owner("o"), hintIsOwner: false)), "門：認人開著時「換人」只是提示，不影響")
        // P09：認出的家人看鎖定頁＝寫「只開給主人」，不是叫家人盯著螢幕等一個不會來的「認出主人」；其他原因照舊
        check(PersonalGate.lockReason(I(recognitionActive: true, viewer: .known("k")), followOn: true) == .family
              && PersonalGate.locks("calendar", I(recognitionActive: true, viewer: .known("k"))), "門：認出的家人＝個人 App 鎖，鎖定頁寫「只開給主人」")   // l10n-ignore：selftest 斷言
        check(PersonalGate.lockReason(I(recognitionActive: true, viewer: .guest), followOn: true) == .look
              && PersonalGate.lockReason(I(recognitionActive: true, viewer: .nobody), followOn: true) == .look
              && PersonalGate.lockReason(I(recognitionActive: true, viewer: .owner("o")), followOn: false) == .followOff
              && PersonalGate.lockReason(I(guestMode: true, recognitionActive: true, viewer: .known("k")), followOn: true) == .guestMode
              && PersonalGate.lockReason(I(remoteGuest: true), followOn: true) == .remoteGuest
              && PersonalGate.lockReason(I(hintIsOwner: false), followOn: true) == .hint, "門：鎖定頁的其他原因照舊")   // l10n-ignore：selftest 斷言

        let owner = Person(id: "o", name: "Aaron", colorIndex: 0, isOwner: true), kid = Person(id: "k", name: "Bo", colorIndex: 2, isOwner: false)
        let people = [owner, kid]
        let saved = PersonalGate.hint
        defer { PersonalGate.hint = saved }
        PersonalGate.hint = nil
        check(PersonalGate.avatarPerson(I(), people: people, owner: owner)?.id == "o", "頭像：沒開認人＝主人")
        check(PersonalGate.avatarPerson(I(guestMode: true), people: people, owner: owner) == nil, "頭像：訪客模式＝訪客")
        check(PersonalGate.avatarPerson(I(recognitionActive: true, viewer: .known("k")), people: people, owner: owner)?.id == "k", "頭像：認出家人＝家人")
        check(PersonalGate.avatarPerson(I(recognitionActive: true, viewer: .guest), people: people, owner: owner) == nil, "頭像：認不出＝訪客")
        PersonalGate.hint = "k"
        check(PersonalGate.avatarPerson(I(), people: people, owner: owner)?.id == "k"
              && PersonalGate.avatarPerson(I(recognitionActive: true, viewer: .owner("o")), people: people, owner: owner)?.id == "o", "頭像：換人提示只在沒開認人時顯示")   // l10n-ignore：selftest 斷言
        check(PersonalGate.personalApps == ["calendar", "reminders", "messages", "facetime", "findmy"], "門：鎖住日曆、提醒事項、訊息、FaceTime、尋找")
        check(ClioToolGroup.allCases.filter(\.isPersonal) == [.calendar, .reminders, .messages, .home, .calls], "門：ClioTalk 的個人工具是日曆、提醒事項、訊息、家庭、電話")

        // ClioTalk 的設定快照：訪客時不送個人工具
        let cached = PersonalGate.cached
        defer { PersonalGate.cached = cached }
        PersonalGate.cached = false
        check(ClioSettings.config.tools.isDisjoint(with: [.calendar, .reminders, .messages]), "門：訪客時 ClioTalk 拿不到個人工具")
        check(!ClioToolGroup.messages.defaultOn && ClioToolGroup.calendar.defaultOn, "設定：「信息」同意預設關")
    }

    // MARK: 訊息：送出前一定要確認

    private static func replyFlow(_ check: (Bool, String) -> Void) {
        var f = MessagesReplyFlow()
        check(f.answer(true) == nil && f.state == .idle, "訊息：沒念回來就按「好」不會送")
        check(!f.propose("   ") && f.state == .idle, "訊息：空白不出確認卡")
        f.propose("好啊")   // l10n-ignore：測試樣本
        check(f.state == .confirming("好啊") && f.showsCard, "訊息：先出確認卡")   // l10n-ignore：測試樣本
        check(f.answer(false) == nil && f.state == .idle, "訊息：取消就不送")
        f.propose("在路上了")   // l10n-ignore：測試樣本
        check(f.answer(true) == "在路上了" && f.state == .sending("在路上了"), "訊息：按「好」才交出要送的字")   // l10n-ignore：測試樣本
        check(!f.propose("x") && f.answer(true) == nil, "訊息：送出中不能再擬、不能再按")
        f.finish(.unconfirmed)
        check(f.state == .done(.unconfirmed), "訊息：查不到就照實說「可能已送出」")
        f.dismiss()
        check(f.state == .idle, "訊息：收起結果")
        // 送出這一層：沒帶 confirmed 一律不送（同步回 .notConfirmed，不碰 AppleScript）
        var got: MessagesSendResult?
        MessagesSender.send(text: "hi", to: .chat(guid: "selftest"), confirmed: false) { got = $0 }
        check(got == .notConfirmed, "訊息：MessagesSender 沒有 confirmed 就不送")
        let rb = MessagesReadback.text(name: "B", body: " see you ")
        check(rb.contains("B") && rb.contains("see you") && !rb.contains(" see you "), "訊息：確認句帶名字與內文")
    }

    // MARK: Live Activity 的隱私字

    private static func activity(_ check: (Bool, String) -> Void) {
        let open = MessagesActivityText.text(name: "Bo", preview: "dinner at 7?", allowed: true)
        check(open.title == "Bo" && open.detail == "dinner at 7?", "Live Activity：主人在看＝名字＋預覽")
        let hidden = MessagesActivityText.text(name: "Bo", preview: "dinner at 7?", allowed: false)
        check(hidden.detail == L("msg.activity.new", "新信息") && !hidden.title.contains("Bo") && !hidden.detail.contains("dinner"), "Live Activity：不是主人只寫「新信息」")
    }

    // MARK: ClioTalk 的 messages_send：跟加提醒同一個確認閘門

    private static func clioMessages(_ check: (Bool, String) -> Void) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("shell-selftest-\(UUID().uuidString)")
        let suite = "shell.selftest.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let look = ClioMessagesTools.lookUpNames
        ClioMessagesTools.lookUpNames = false
        defer { try? FileManager.default.removeItem(at: dir); defaults.removePersistentDomain(forName: suite); ClioMessagesTools.lookUpNames = look }
        let cfg = ClioConfig(provider: .anthropic, fastModel: "claude-haiku-5-5", deepModel: "claude-opus-5-5", autoEscalate: false,
                             tools: Set(ClioToolGroup.allCases), monthlyCap: 0)
        let tools = ClioRecordingTools()
        let p = ClioScriptedProvider([
            .events([.toolCall(id: "m1", name: "messages_send", json: #"{"contact":"Bo","text":"Running late"}"#), .done(stopReason: "tool_use")]),
            .events([.textDelta("OK, not sent."), .done(stopReason: "end_turn")]),
            .events([.toolCall(id: "m2", name: "messages_send", json: #"{"contact":"Bo","text":"Running late"}"#), .done(stopReason: "tool_use")]),
            .events([.textDelta("Sent."), .done(stopReason: "end_turn")]),
        ])
        let e = ClioEngine(store: ClioHistoryStore(dir: dir), runner: tools, ledger: ClioLedger(defaults: defaults), config: { cfg },
                           makeProvider: { _ in p }, onSnapshot: { _ in })
        var snap = ClioSnapshot()
        wait { await e.send("tell Bo I'm running late"); snap = await e.snapshot }
        check(snap.phase == .confirm && snap.confirm?.contains("Running late") == true && snap.confirm?.contains("Bo") == true && tools.ran.isEmpty,
              "ClioTalk：messages_send 先念回來、還沒送")   // l10n-ignore：selftest 斷言
        wait { await e.confirm(false); snap = await e.snapshot }
        check(tools.ran.isEmpty && snap.answer == "OK, not sent.", "ClioTalk：取消就不送")
        wait { await e.send("try again"); await e.confirm(true); snap = await e.snapshot }
        check(tools.ran == ["messages_send"] && snap.answer == "Sent.", "ClioTalk：說「好」才送")
        check(ClioToolCatalog.spec("messages_send")?.needsConfirmation == true && ClioToolCatalog.spec("messages_read_recent")?.needsConfirmation == false,
              "ClioTalk：送出要確認、讀不用")   // l10n-ignore：selftest 斷言
        check(!ClioToolCatalog.specs([.calendar], provider: .anthropic, includeEscalate: false).contains { $0.name.hasPrefix("messages_") }, "ClioTalk：沒開「信息」不送訊息工具")
        check(ClioMessagesTools.outcome(.unconfirmed, to: "Bo").isError && ClioMessagesTools.outcome(.sent, to: "Bo").content.hasPrefix("Sent"),
              "ClioTalk：送出結果照實回報")   // l10n-ignore：selftest 斷言
    }

    // MARK: 小工具

    private static func helpers(_ check: (Bool, String) -> Void) {
        check(ClioReplySuggest.parse("1. Sure!\n- On my way\n\"Later\"\nSure!\n\n") == ["Sure!", "On my way", "Later"], "建議回覆：去編號、去引號、去重複")
        check(ClioReplySuggest.parse(String(repeating: "x", count: 40)).isEmpty, "建議回覆：太長的丟掉")
        func conv(_ title: String, _ handle: String) -> MsgConversation {
            MsgConversation(rowID: 1, guid: "g-\(title)", chatIdentifier: handle, title: title, participants: [handle], isGroup: false,
                            lastText: "", lastDate: Date(), lastIsFromMe: false, lastHasAttachments: false, unread: 0)
        }
        let convs = [conv("Bo Chen", "+886 912-345-678"), conv("Bob", "bob@example.com"), conv("[Family]", "chat1")]
        check(ClioMessagesTools.match("bob", in: convs).map(\.title) == ["Bob"], "找對話：名字完全相同優先")
        check(ClioMessagesTools.match("bo", in: convs).count == 2, "找對話：只含一部分＝多個候選，要問")
        check(ClioMessagesTools.match("0912 345 678", in: convs).map(\.title) == ["Bo Chen"], "找對話：號碼也找得到")
        check(ClioMessagesTools.match("family", in: convs).map(\.title) == ["[Family]"] && ClioMessagesTools.match("", in: convs).isEmpty, "找對話：去掉方括號；空字串不找")
    }
}
