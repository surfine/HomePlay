// 快照用的示範資料：--messages-demo list|thread|rich|group|confirm|compose|dictate|emoji|fda|nodb 把畫面蓋在錶面上，不碰真訊息；
// 加 --app messages 時改由外殼裡的訊息 App 用同一份資料畫（confirm＝送出確認卡、dictate＝聽寫中、emoji＝表情面板）。
// 2.0 imsg：thread 是官方影片 v1 01:37.5 那一幕（「C u at 7:20???」、🫶 大表情＋已送達、時間分隔、OMW＋↺ 重播）；
// rich 是家人群組的照片、Tapback、語音訊息、連結預覽；group 是同一個群組的已編輯、回覆串、已讀、撤回。照片與預覽圖是程式畫的漸層，不是誰的照片。

import AppKit

enum MessagesDemo {
    nonisolated(unsafe) static var mode: String?

    static let modes = ["list", "thread", "rich", "group", "confirm", "compose", "dictate", "emoji", "fda", "nodb"]

    /// 示範的「現在」：今天 07:21（男友 7:21 按門鈴）
    static var now: Date { Calendar.current.date(bySettingHour: 7, minute: 21, second: 0, of: Date()) ?? Date() }
    static func at(_ dayOffset: Int, _ h: Int, _ m: Int) -> Date {
        let d = Calendar.current.date(byAdding: .day, value: dayOffset, to: now) ?? now
        return Calendar.current.date(bySettingHour: h, minute: m, second: 0, of: d) ?? d
    }

    static func model(_ mode: String) -> MessagesScreenModel? {
        guard modes.contains(mode) else { return nil }
        switch mode {
        case "list", "fda", "nodb": return .list(list(mode))
        case "compose": return .compose(compose())
        case "rich": return .thread(rich())
        case "group": return .thread(rich(replies: true))
        default: return .thread(scene())
        }
    }

    static var friend: String { L("msg.demo.friendB", "[朋友 B]") }

    static func list(_ mode: String = "list") -> MessagesListModel {
        let ago = { (d: Int, h: Int, m: Int) in MessagesScreen.timeLabel(at(d, h, m), now: now) }
        return MessagesListModel(
            pins: [.init(id: "m", name: L("msg.demo.mom", "[妈妈]"), initial: "M", unread: false),
                   .init(id: "f", name: L("msg.demo.family", "[家人群组]"), initial: L("msg.demo.familyInitial", "家"), unread: true)],
            rows: [.init(id: "r1", name: friend, last: L("msg.demo.omw", "在路上了"), time: ago(0, 7, 12), unread: true, initials: ["B"]),
                   .init(id: "r2", name: L("msg.demo.colleagueC", "[同事 C]"), last: L("msg.demo.slides", "简报我放在共享文件夹了"), time: ago(-1, 18, 30), unread: false, initials: ["C"]),
                   .init(id: "r3", name: L("msg.demo.building", "[社区服务处]"), last: L("msg.demo.parcel", "您有一个包裹，请到前台领取"), time: ago(-3, 15, 2), unread: false, initials: ["S"]),
                   .init(id: "r4", name: L("msg.demo.dad", "[爸爸]"), last: L("msg.audio", "语音信息"), time: ago(-5, 20, 41), unread: false, initials: ["D"])],
            access: mode == "fda" ? .needsFullDiskAccess : mode == "nodb" ? .noDatabase : .available)
    }

    private static func msg(_ row: Int64, _ text: String, me: Bool, _ date: Date, from: String = "b") -> MsgMessage {
        MsgMessage(rowID: row, guid: "G\(row)", chatRowID: 1, text: text, date: date, isFromMe: me, senderHandle: me ? "" : from,
                   service: "iMessage", isEdited: false, attachments: [], tapbacks: [])
    }

    /// 官方影片那一幕
    static func scene() -> MessagesThreadModel {
        let a = msg(1, L("msg.demo.scene1", "好呀，就这么定了。"), me: true, at(-1, 22, 10))
        var b = msg(2, L("msg.demo.scene2", "7:20 见？？？"), me: false, at(-1, 22, 11))
        b.tapbacks = [MsgTapback(kind: .love, fromMe: true, handle: "", emoji: nil)]
        var c = msg(3, "🫶", me: true, at(-1, 22, 12)); c.isDelivered = true
        var d = msg(4, L("msg.demo.omw", "在路上了"), me: false, at(0, 7, 12)); d.effect = "com.apple.messages.effect.CKHeartEffect"
        let items = MessagesThreadBuilder.items([a, b, c, d], isGroup: false, name: { _ in friend }, now: now)
        return MessagesThreadModel(title: friend, items: items, chips: ClioReplySuggest.fixed)
    }

    /// 家人群組：照片、語音、連結、Tapback（rich）；已編輯、回覆、已讀、撤回（replies）
    static func rich(replies: Bool = false) -> MessagesThreadModel {
        installImages()
        let names = ["mom": L("msg.demo.mom", "[妈妈]"), "dad": L("msg.demo.dad", "[爸爸]"), "sis": L("msg.demo.sister", "[姐姐]")]
        var p = msg(10, "", me: false, at(-1, 21, 3), from: "mom")
        p.attachments = [MsgAttachment(rowID: -1, path: "", mimeType: "image/heic", name: "IMG.heic", uti: "public.heic", isSticker: false, bytes: 0)]
        var n = msg(11, L("msg.demo.night", "晚安～明天见"), me: false, at(-1, 21, 3), from: "mom")
        n.tapbacks = [MsgTapback(kind: .love, fromMe: true, handle: "", emoji: nil), MsgTapback(kind: .emoji, fromMe: false, handle: "dad", emoji: "🥰")]
        var v = msg(12, "", me: false, at(-1, 21, 5), from: "dad"); v.isAudioMessage = true
        v.attachments = [MsgAttachment(rowID: -2, path: "", mimeType: "audio/x-caf", name: "Audio Message.caf", uti: "com.apple.coreaudio-format", isSticker: false, bytes: 0)]
        var l = msg(13, "https://www.apple.com/apple-homeview/", me: true, at(-1, 20, 40))
        l.link = MsgLink(url: "https://www.apple.com/apple-homeview/", title: L("msg.demo.linkTitle", "认识 HomeView：在家享受娱乐、管理家居的新方式"), site: "apple.com", imageIndex: 0)
        l.attachments = [MsgAttachment(rowID: -3, path: "", mimeType: "image/png", name: "preview.png", uti: "public.png", isSticker: false, bytes: 0)]
        var k = msg(14, L("msg.demo.keys", "谁拿了我的钥匙？"), me: false, at(0, 7, 5), from: "sis"); k.isEdited = true
        var r = msg(15, L("msg.demo.bowl", "在门口的碗里"), me: true, at(0, 7, 6)); r.replyToGUID = "G14"; r.isDelivered = true; r.dateRead = at(0, 7, 7)
        var u = msg(16, "", me: false, at(0, 7, 8), from: "mom"); u.isUnsent = true
        let msgs = replies ? [l, k, r, u] : [l, p, n, v]
        let items = MessagesThreadBuilder.items(msgs, isGroup: true, name: { names[$0] }, now: now)
        return MessagesThreadModel(title: L("msg.demo.family", "[家人群组]"), items: items, chips: ClioReplySuggest.fixed, isGroup: true,
                                   image: { ref, _ in MessagesMedia.demoImages[ref.id] }, audioSeconds: { _ in 7 })
    }

    static func compose() -> MessagesComposeModel {
        MessagesComposeModel(recipient: nil, query: "",
                             suggestions: [.init(id: "r1", name: friend, detail: L("msg.to.recent", "最近的对话"), initials: "B"),
                                           .init(id: "m", name: L("msg.demo.mom", "[妈妈]"), detail: L("msg.to.recent", "最近的对话"), initials: "M"),
                                           .init(id: "c1", name: L("msg.demo.colleagueC", "[同事 C]"), detail: L("msg.to.contact", "通讯录"), initials: "C"),
                                           .init(id: "c2", name: L("msg.demo.dad", "[爸爸]"), detail: L("msg.to.contact", "通讯录"), initials: "D")])
    }

    /// 程式畫的示範圖（漸層＋幾何），不是任何人的照片
    static func installImages() {
        guard MessagesMedia.demoImages.isEmpty else { return }
        MessagesMedia.demoImages[-1] = makeImage(640, 480) { g in
            let cs = CGColorSpace(name: CGColorSpace.sRGB)
            let grad = CGGradient(colorsSpace: cs, colors: [srgb(0xffb36b).cgColor, srgb(0xff5e7e).cgColor, srgb(0x6a4cc7).cgColor] as CFArray, locations: [0, 0.55, 1])!
            g.drawLinearGradient(grad, start: CGPoint(x: 0, y: 480), end: CGPoint(x: 0, y: 0), options: [])
            g.setFillColor(srgb(0xfff2c4).cgColor); g.fillEllipse(in: CGRect(x: 380, y: 150, width: 120, height: 120))
            g.setFillColor(srgb(0x2b2347).cgColor)   // 畫布左上原點：山在下面
            g.move(to: CGPoint(x: 0, y: 480)); g.addLine(to: CGPoint(x: 0, y: 330)); g.addLine(to: CGPoint(x: 170, y: 210)); g.addLine(to: CGPoint(x: 300, y: 310))
            g.addLine(to: CGPoint(x: 450, y: 180)); g.addLine(to: CGPoint(x: 640, y: 350)); g.addLine(to: CGPoint(x: 640, y: 480)); g.fillPath()
        }
        MessagesMedia.demoImages[-3] = makeImage(760, 400) { g in
            let cs = CGColorSpace(name: CGColorSpace.sRGB)
            let grad = CGGradient(colorsSpace: cs, colors: [srgb(0xeef3f8).cgColor, srgb(0xd6e2ee).cgColor] as CFArray, locations: [0, 1])!
            g.drawLinearGradient(grad, start: CGPoint(x: 0, y: 400), end: CGPoint(x: 0, y: 0), options: [])
            let dev = CGRect(x: 250, y: 70, width: 260, height: 260)
            g.setFillColor(srgb(0xfbfbfd).cgColor); g.addPath(continuousRoundedRect(dev, radius: 46)); g.fillPath()
            g.setFillColor(srgb(0x1c1c1e).cgColor); g.addPath(continuousRoundedRect(dev.insetBy(dx: 14, dy: 14), radius: 34)); g.fillPath()
            g.setFillColor(srgb(0x8fd18a).cgColor); g.addPath(CGPath(roundedRect: CGRect(x: 330, y: 230, width: 100, height: 34), cornerWidth: 17, cornerHeight: 17, transform: nil)); g.fillPath()
        }
    }

    /// 錶面畫完之後蓋上去（Face 的畫布：1024、左上原點）
    static func draw(_ g: CGContext) {
        // 只有明講 --messages-demo 才蓋在錶面上；快照隱私閘（SnapshotPrivacy）也會設 mode＝list，那只是「訊息 App 用示範資料」
        guard let mode, CommandLine.arguments.contains("--messages-demo"), !Shell.nav.screen.coversFace, let m = model(mode) else { return }   // 外殼裡打開了訊息 App：由 App 自己畫
        MessagesScreen.render(m, in: g, rect: CGRect(x: 0, y: 0, width: 1024, height: 1024))
    }

    /// --messages-probe：對真的 chat.db 跑一遍讀取路徑，只印筆數（不印任何內容）
    static func probe() -> Never {
        let access = MessagesAccess.check()
        log("messages probe: access \(access)")
        guard let store = MessagesStore.openDefault() else { log("messages probe: open failed"); exit(1) }
        let convs = store.conversations(limit: 20)
        let msgs = convs.prefix(5).flatMap { store.messages(chat: $0.rowID, limit: 40) }
        let atts = msgs.flatMap(\.attachments)
        log("messages probe: \(convs.count) conversations, \(convs.filter(\.isGroup).count) groups, \(convs.reduce(0) { $0 + $1.unread }) unread, \(msgs.count) messages in first 5, maxRowID>0: \(store.maxRowID() > 0)")
        // 2.0 imsg：豐富欄位只印筆數
        log("messages probe: empty-body \(msgs.filter { $0.text.isEmpty && $0.attachments.isEmpty && !$0.isUnsent }.count), unsent \(msgs.filter(\.isUnsent).count), edited \(msgs.filter(\.isEdited).count), replies \(msgs.filter { $0.replyToGUID != nil }.count), links \(msgs.filter { $0.link != nil }.count) (titled \(msgs.filter { $0.link?.title.isEmpty == false }.count)), effects \(msgs.filter { $0.effect != nil }.count), audio \(msgs.filter(\.isAudioMessage).count), tapbacks \(msgs.reduce(0) { $0 + $1.tapbacks.count }), delivered \(msgs.filter(\.isDelivered).count), read \(msgs.filter { $0.dateRead != nil }.count)")
        log("messages probe: attachments \(atts.count), readable \(atts.filter { MessagesMedia.allowed($0.path) && FileManager.default.fileExists(atPath: $0.path) }.count), images \(atts.filter(\.isImage).count), videos \(atts.filter(\.isVideo).count), audio \(atts.filter(\.isAudio).count), stickers \(atts.filter(\.isSticker).count), focus \(MessagesFocus.active)")
        exit(0)
    }
}
