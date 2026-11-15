import Foundation

// 設定的搜尋：照系統設定——列出符合的「列」（標題＋在哪一頁），點了跳過去、那一列閃一下（SettingsModel.reveal）。
// 每一列用它標題的本地化鍵登記；頁面上同一個鍵用 .settingsRow(鍵) 標出來，ScrollViewReader 才卷得過去。
// 比對標題與副標（目前語言），不分大小寫。

struct SettingsSearchRow: Identifiable {
    let key: String
    let subtitleKey: String?
    let section: SettingsSection
    let sub: SettingsSub?
    var id: String { "\(section.rawValue)/\(sub?.rawValue ?? "")/\(key)" }
    var title: String { L10n.text(key, "") }
    var subtitle: String { subtitleKey.map { L10n.text($0, "") } ?? "" }
    /// 在哪一頁（下一層的寫成「頁 › 下一層」）
    var place: String { sub.map { section.title + " › " + $0.title } ?? section.title }
}

enum SettingsSearch {
    /// 「標題鍵」或「標題鍵|副標鍵」
    private static let index: [(SettingsSection, SettingsSub?, [String])] = [
        (.general, nil, ["settings.loginItem", "settings.alwaysOnTop|settings.alwaysOnTop.sub", "settings.language",
                         "prefs.nowPlaying|settings.nowPlaying.sub", "settings.lyrics|settings.lyrics.short", "prefs.calendar.on|settings.calendar.sub",
                         "settings.intro|settings.intro.sub", "settings.intro.input", "settings.intro.tips"]),
        (.body, nil, ["settings.finish", "settings.size|settings.size.sub", "settings.placement", "settings.facing|settings.facing.note",
                      "settings.angle", "settings.orbit"]),
        (.display, nil, ["settings.brightness", "settings.display.sleep|settings.display.sleep.short", "settings.display.ambient", "settings.look.header"]),
        (.accessibility, nil, ["settings.textSize|settings.textSize.short", "settings.keyboardNav|settings.keyboardNav.short", "settings.alwaysHandle|settings.alwaysHandle.short"]),
        (.faces, nil, ["settings.face", "settings.look.title", "settings.clockLook|clockLook.subtitle", "settings.capsule|settings.capsule.short",
                       "settings.faceOptions", "settings.home.wallpaper|settings.home.wallpaper.short", "settings.posters", "sharedAlbums.title"]),
        (.faces, .faceOptions, ["island.clock", "island.bg", "island.era", "typograph.material", "system6.layout", "cluster.layout", "settings.photos"]),
        (.homeScreen, nil, ["settings.home.appearance|settings.home.appearance.sub", "settings.home.tint", "sb.largeIcons",
                            "settings.home.phoneApps|settings.home.phoneApps.short", "la.settings.header", "webapp.settings.header",
                            "settings.home.resetTitle|settings.home.resetTitle.sub"]),
        (.homeScreen, .liveActivities, ["la.settings.preview|la.settings.preview.short"]),
        (.gestures, nil, ["settings.gesture.home", "settings.gesture.switcher", "settings.gesture.control", "settings.gesture.page",
                          "settings.gesture.carDrag", "settings.gesture.back", "settings.gesture.hold", "settings.gesture.turn",
                          "settings.gesture.front", "settings.gesture.resize", "settings.gesture.moveWindow", "settings.gesture.carplay",
                          "settings.gesture.menu", "settings.gesture.apart.title", "settings.gesture.keys", "settings.gestures.input"]),
        (.cliotalk, nil, ["clio.provider", "clio.key", "clio.fast", "clio.deep", "clio.autoEscalate", "clio.shareNameCity|clio.shareNameCity.short",
                          "clio.section.data", "clio.voice.title", "clio.rate", "clio.voice.personal", "clio.cap|clio.cap.sub", "clio.usage",
                          "clio.speak", "clio.followUp|clio.followUp.short", "clio.privacy.title", "clio.clear"]),
        (.camera, nil, ["settings.follow.title|settings.follow.sub", "settings.followRange", "settings.followPitch", "settings.roomLight.title|settings.roomLight.note"]),
        (.carplay, nil, ["menu.iphone", "menu.pairNewPhone", "menu.wifiPassword", "prefs.plugConnect|prefs.plugConnect.short",
                         "settings.callVolume|settings.callVolume.sub", "settings.carVideo|settings.carVideo.sub", "settings.airplay|settings.airplay.sub",
                         "settings.corners"]),
        (.devices, nil, ["remote.enable|remote.enable.short", "remote.section.devices", "remote.section.add",
                         "handoff.clipboard|handoff.clipboard.short", "handoff.shortcut|handoff.shortcut.short", "handoff.code",
                         "selfshare.account"]),
        (.devices, .addDevice, ["remote.add.mode", "remote.add.address"]),
        (.home, nil, ["settings.home.name|settings.home.demoNote", "settings.home.openApp", "settings.home.test", "settings.home.helper.title"]),
        (.people, nil, ["people.pane.recognize|people.pane.recognize.sub", "people.pane.family", "people.pane.addTitle", "people.pane.deleteAll"]),
        (.permissions, nil, ["settings.perm.camera", "settings.perm.mic", "settings.perm.input|settings.perm.input.short", "settings.perm.automation",
                             "settings.perm.calendar", "settings.perm.photos", "settings.perm.location", "settings.perm.reminders",
                             "settings.privacy.data"]),
    ]

    static let all: [SettingsSearchRow] = index.flatMap { section, sub, keys in
        keys.map { k in
            let parts = k.split(separator: "|").map(String.init)
            return SettingsSearchRow(key: parts[0], subtitleKey: parts.count > 1 ? parts[1] : nil, section: section, sub: sub)
        }
    }

    static func rows(matching query: String) -> [SettingsSearchRow] {
        guard !query.isEmpty else { return [] }
        return all.filter { r in
            !r.title.isEmpty && (r.title.localizedCaseInsensitiveContains(query) || r.subtitle.localizedCaseInsensitiveContains(query))
        }
    }

    /// 自檢：登記的每個鍵都查得到字（改了鍵名忘了改這裡會被抓到）
    static func selftest(_ check: (Bool, String) -> Void) {
        let missing = all.filter { $0.title.isEmpty || ($0.subtitleKey != nil && $0.subtitle.isEmpty) }.map(\.key)
        check(missing.isEmpty, "settings search：登記的列都查得到標題（缺 \(missing.prefix(3))）")
        check(!rows(matching: L10n.text("settings.size", "")).isEmpty, "settings search：用「大小」找得到機身那一列")
    }
}
