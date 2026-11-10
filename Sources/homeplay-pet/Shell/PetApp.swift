// 2.0 的 App：每個 App 畫在同一張 1024² 螢幕畫布上（跟錶面同一條 Core Graphics 路），外殼負責開關、過場、頂端藥丸。
// 新的 App（音樂、訊息、ClioTalk…）只要實作 PetApp、在 AppRegistry.all 裡換掉佔位那一格。

import AppKit

/// App 圖示：底色＋一個 SF Symbol（白色），跟 HomeView 主畫面的圖示一樣是圓角方塊
struct AppIcon {
    var color: NSColor
    var symbol: String
    var glyph: NSColor = .white
    /// 2.0: 舊欄位（第四輪起圖示一律是 HPIcons 自己畫的，不再讀這個路徑的系統圖示；留著讓 App 照樣編得過）
    var system: String? = nil
    /// 2.0: 會跟著日期變的圖示（行事曆：星期＋日期）
    var calendarDate = false
    /// 2.0 Web App：抓到的圖示（已裁成方的、正向）；有就直接用它（Shell/WebApps）
    var image: CGImage? = nil
}

/// 頂端藥丸要長成的 Live Activity
struct LiveActivity {
    enum Kind { case timer, music, message, assistant, call, iphone, alarm, weather }   // 2.0 #10：call＝FaceTime 通話（綠色）；iphone＝來自配對 iPhone 的即時動態；alarm＝鬧鐘響鈴／貪睡（link＝ring／snooze）；weather＝快下雨了（link＝開始時間的 epoch 秒，收起時記住是哪一場）
    var kind: Kind
    var title: String
    var detail: String          // 計時器：剩餘時間；音樂：演出者
    var accent: NSColor
    var progress: Double?       // 0…1
    var appID: String           // 點一下打開哪個 App
    var symbol: String? = nil   // 右邊的圖示（nil：音樂的波形）
    var link: String? = nil     // 2.0 P03：點了帶到哪一件事（訊息：對話的 chat ROWID／"demo"；計時器：那一組的 id）
    /// 這一則活動的身分（展開、命中、8 小時、數字動畫都用它）：自家 App 一個 App 一則，就是 appID；
    /// iPhone 轉來的全部共用 mirroringAppID，要加上各自的 id，不然兩則同時在時點第二則展開的是第一則
    var uid: String { kind == .iphone ? "\(appID)#\(link ?? "")" : appID }
}

protocol PetApp: AnyObject {
    var id: String { get }
    /// 主畫面上的名字（已本地化）
    var title: String { get }
    var icon: AppIcon { get }
    /// 還沒做好：主畫面照樣有一格，打開是「即將推出」
    var isPlaceholder: Bool { get }
    /// rect 永遠是整個螢幕（0,0,1024,1024，左上原點）；畫面要留出頂端藥丸（y < 130）與左上關閉鈕
    func render(into g: CGContext, face: Face, rect: CGRect, now: Double)
    /// 每幀叫；要重畫回 true
    func tick(_ now: Double) -> Bool
    /// 點在畫布座標 p；吃掉回 true
    func handleTap(_ p: CGPoint, face: Face, now: Double) -> Bool
    /// 長按（按住超過 0.5 秒再放開）在畫布座標 p；吃掉回 true
    func handleLongPress(_ p: CGPoint, face: Face, now: Double) -> Bool
    /// 滾輪／觸控板（往上為正）；吃掉回 true
    func handleScroll(_ dy: CGFloat, now: Double) -> Bool
    /// 觸控板橫滑（往右為正，照 NSEvent.scrollingDeltaX）；吃掉回 true。不實作＝橫滑照舊交給外殼（預設不吃）
    func handleScrollX(_ dx: CGFloat, now: Double) -> Bool
    /// 打開前叫：回 true＝自己處理掉了（例如打開設定視窗），外殼不切到 App 畫面
    func launch(face: Face) -> Bool
    /// 有正在進行的事就回一個 Live Activity（頂端藥丸）
    func liveActivity(face: Face, now: Double) -> LiveActivity?
    /// 每次打開時叫（重置捲動位置之類）
    func didOpen(now: Double)
    /// 外殼左上角的關閉鈕要不要畫（App 自己有返回鈕的畫面可以關掉它）
    var showsCloseButton: Bool { get }
    /// 2.0: 右上角畫小字時間（右上有自己按鈕的 App 關掉）
    var showsClock: Bool { get }
    /// 2.0 R1：左上玻璃圓鈕的符號——App 根頁 ✕（"xmark"），子頁 ‹（"chevron.left"，App 自己回）
    var backSymbol: String { get }
    /// Esc／↓ 先問 App：回 true＝App 自己退一層（例如對話頁回列表），外殼不關 App
    func handleBack(now: Double) -> Bool
    /// 2.0 depth：App 不在畫面上了（不管是按返回、閒置回錶面、點 Live Activity、ClioTalk 開別的 App）：關相機、停錄音之類
    func didClose()
    /// 2.0 home-3：遠看（提案原則 1）——人在遠處時整個 App 換成這一句話（外殼統一畫，Shell/FarGlance.swift）；nil＝沒有遠看版
    func farGlance(face: Face, now: Double) -> FarGlance?
}

extension PetApp {
    var isPlaceholder: Bool { false }
    func tick(_ now: Double) -> Bool { false }
    func handleTap(_ p: CGPoint, face: Face, now: Double) -> Bool { false }
    func handleScroll(_ dy: CGFloat, now: Double) -> Bool { false }
    func handleScrollX(_ dx: CGFloat, now: Double) -> Bool { false }
    func handleLongPress(_ p: CGPoint, face: Face, now: Double) -> Bool { false }
    func launch(face: Face) -> Bool { false }
    func liveActivity(face: Face, now: Double) -> LiveActivity? { nil }
    func didOpen(now: Double) {}
    var showsCloseButton: Bool { true }
    var showsClock: Bool { true }
    var backSymbol: String { "xmark" }
    func handleBack(now: Double) -> Bool { false }
    func didClose() {}
    func farGlance(face: Face, now: Double) -> FarGlance? { nil }
}

/// 主畫面順序就是這份清單的順序（全部 App 頁也照這個順序）
enum AppRegistry {
    static let all: [PetApp] = [
        TimersApp.shared,
        WorldClockApp(),
        AlarmsApp.shared,
        WeatherApp.shared,
        CalendarApp.shared,
        RemindersApp.shared,
        MusicApp(),
        PodcastsApp(),
        SingApp.shared,       // 功能補齊：跟唱（全螢幕跟唱歌詞，沿用 LyricsStore）
        RecipesApp.shared,    // HomeView 對齊 WP5：Now Cooking 獨立 app，不再藏在 Safari 後面
        HomeApp.shared,
        MessagesApp.shared,
        FaceTimeApp.shared,   // 2.0 第四輪 #10
        ContactsApp.shared,   // 功能補齊：通訊錄（一鍵 FaceTime）
        FindMyApp.shared,     // 2.0 P10：尋找、對講、Safari（HV-SPECS-88）
        IntercomApp.shared,
        SafariApp.shared,
        GamesApp.shared,      // 功能補齊：這台 Mac 上的遊戲
        ClioTalkApp.shared,
        CarPlayApp.shared,    // 2026-11-06：CarPlay 是主畫面上的一個 App（Shell/AppSwitcher.swift）
        SettingsApp(),
    ]
    /// 不上主畫面與 App 資料庫的（目前空；食譜已回到獨立 Now Cooking——HomeView 對齊 WP5）
    static let hidden: Set<String> = []
    /// 主畫面、App 資料庫、編輯時能放的 App
    static var visible: [PetApp] { all.filter { !hidden.contains($0.id) } + AppProviders.apps(viewer: PersonHome.viewerID) }   // 2.0 Web App：加上這個人的（Shell/AppPlatform）
    static func app(_ id: String) -> PetApp? { all.first { $0.id == id } ?? AppProviders.app(id) }
}

/// 還沒做的 App：大圖示＋名字＋「即將推出」
final class PlaceholderApp: PetApp {
    let id: String
    private let titleFn: () -> String
    let icon: AppIcon
    var title: String { titleFn() }
    var isPlaceholder: Bool { true }
    init(id: String, title: @escaping () -> String, icon: AppIcon) { self.id = id; self.titleFn = title; self.icon = icon }

    func render(into g: CGContext, face: Face, rect: CGRect, now: Double) {
        g.setFillColor(srgb(0x0b0b0e).cgColor); g.fill(rect)
        let r = CGRect(x: 512 - 120, y: 300, width: 240, height: 240)
        Shell.drawAppIcon(g, face: face, icon: icon, in: r)
        face.drawCentered(g, title, font: Face.rounded(64, weight: .bold), y: 640, color: .white)
        face.drawCentered(g, L("app.comingSoon", "即将推出"), font: Face.rounded(40, weight: .semibold), y: 712,
                          color: NSColor.white.withAlphaComponent(0.55))
    }
}

