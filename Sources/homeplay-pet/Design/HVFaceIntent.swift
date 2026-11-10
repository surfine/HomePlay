// 錶面切換的 App Intents（固件對齊：HomeView 的 PosterKit 有「查目前海報／切到某張」的職責，
// rushmore_strings.txt：「Returns the currently active Poster Extension」「Navigating to face %ld」）。
// HomePlay 的「臉」是 12 個 FaceStyle；這裡把 lineup 做成 AppEnum，Shortcuts／Siri 可以直接切。
import AppIntents
import Foundation

extension FaceStyle {
    /// 目前記住的錶面（偏好裡的；沒有就用島）
    static var currentRaw: String { UserDefaults.standard.string(forKey: FaceStyle.defaultsKey) ?? FaceStyle.island.rawValue }
}

enum HVFaceChoice: String, AppEnum {
    case island, photos, modular, analog, flow, weather, calendar, growth, black, system6, world, cluster

    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Watch Face")
    static var caseDisplayRepresentations: [HVFaceChoice: DisplayRepresentation] = [
        .island: "Island", .photos: "Photos", .modular: "Modular", .analog: "Typograph",
        .flow: "Flow", .weather: "Weather", .calendar: "Calendar", .growth: "Companion",
        .black: "Black", .system6: "System 6", .world: "World", .cluster: "Instruments",
    ]
}

/// 切到指定錶面。實際套用走既有的一條路：PetView.setFaceStyle（會寫偏好、換畫面、眨眼）。
struct SwitchFaceIntent: AppIntent {
    static var title: LocalizedStringResource = "Switch HomePlay Face"
    static var description = IntentDescription("Switch the face shown on HomePlay.")
    static var openAppWhenRun: Bool = false

    @Parameter(title: "Face") var face: HVFaceChoice

    init() {}
    init(face: HVFaceChoice) { self.face = face }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        await MainActor.run {
            NotificationCenter.default.post(name: .homePlaySwitchFace, object: face.rawValue)
        }
        return .result(dialog: "Switched to \(face.rawValue).")
    }
}

/// 查目前是哪一張（固件：「Returns the currently active Poster Extension」）。
struct CurrentFaceIntent: AppIntent {
    static var title: LocalizedStringResource = "Get Current HomePlay Face"
    static var description = IntentDescription("Returns the face HomePlay is showing.")
    static var openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let name = await MainActor.run { FaceStyle.currentRaw }
        return .result(value: name, dialog: "HomePlay is showing \(name).")
    }
}

struct HVAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: SwitchFaceIntent(),
                    phrases: ["Switch face in \(.applicationName)", "切換 \(.applicationName) 的錶面"],   // l10n-ignore：App Shortcut 觸發語（系統層，之後再本地化）
                    shortTitle: "Switch Face", systemImageName: "applewatch")
    }
}
