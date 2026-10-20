// 桌寵的介面語言。規矩照 WindowShade（Core/WSL10n.swift、Core/InterfaceLanguage.swift、docs/copy-guide.md）：
// - 簡體中文是源語言：程式裡寫 L("鍵", "简体原文")，譯文在 Resources/Localizable.xcstrings（en / zh-Hans / zh-Hant 三份齊全）；
// - tooling/check-localizable.py 在提交前查鍵齊全、程式裡的簡體原文和目錄一致；
// - 語言 = 使用者在右鍵「語言」裡選的那個，沒選就跟系統首選語言；切換立即生效，不用重開。
// SwiftPM 把 .xcstrings 編成 Bundle.module 裡的 <語言>.lproj；這裡直接開那一份，不讓系統替這個行程挑語言。
import Foundation

enum PetLanguage: String, CaseIterable {
    case en, zhHans = "zh-Hans", zhHant = "zh-Hant"

    static let defaultsKey = "interfaceLanguage"

    /// 使用者選過的語言；nil＝跟隨系統。
    static var chosen: PetLanguage? {
        get { UserDefaults.standard.string(forKey: defaultsKey).flatMap(PetLanguage.init(rawValue:)) }
        set { UserDefaults.standard.set(newValue?.rawValue, forKey: defaultsKey) }
    }

    /// 系統首選語言對到三種之一：繁體地區（Hant、TW、HK、MO）→ 繁中，其他中文 → 簡中，其餘 → 英文。
    static func fromSystem(_ preferred: [String] = Locale.preferredLanguages) -> PetLanguage {
        for id in preferred {
            let l = id.lowercased()
            guard l.hasPrefix("zh") else { if l.hasPrefix("en") { return .en }; continue }
            if l.contains("hant") || l.hasSuffix("-tw") || l.hasSuffix("-hk") || l.hasSuffix("-mo") { return .zhHant }
            return .zhHans
        }
        return .en
    }

    /// 日期、星期用的地區格式。
    var locale: Locale {
        switch self {
        case .en: return Locale(identifier: "en_US")
        case .zhHans: return Locale(identifier: "zh_Hans_CN")
        case .zhHant: return Locale(identifier: "zh_Hant_TW")
        }
    }

    /// 選單裡顯示的名字：每種語言用它自己的寫法，誰看到都認得出來。
    var nativeName: String {
        switch self {
        case .en: return "English"
        case .zhHans: return "简体中文"
        case .zhHant: return "繁體中文"
        }
    }
}

enum L10n {
    /// 目前語言。啟動時由 --lang（快照用，不記住）/ 偏好 / 系統決定；右鍵選單切換時改它。
    nonisolated(unsafe) static var language: PetLanguage = launchOverride ?? PetLanguage.chosen ?? .fromSystem() {
        didSet { bundle = Self.loadBundle(language) }
    }
    private static var launchOverride: PetLanguage? {
        let a = CommandLine.arguments
        guard let i = a.firstIndex(of: "--lang"), i + 1 < a.count else { return nil }
        return PetLanguage(rawValue: a[i + 1])
    }
    nonisolated(unsafe) private static var bundle: Bundle? = loadBundle(language)

    /// SwiftPM 的資源包。不用 Bundle.module：它只找 .app 根目錄和建置資料夾的絕對路徑，找不到就 fatalError。
    /// 打包成 .app（tooling/make-app.sh）時在 Contents/Resources；swift build 時在執行檔旁邊。都沒有就退回原文。
    private static let resources: Bundle? = {
        let name = "HomePlay_homeplay-pet.bundle"
        let candidates = [
            Bundle.main.resourceURL?.appendingPathComponent(name),
            Bundle.main.executableURL?.resolvingSymlinksInPath().deletingLastPathComponent().appendingPathComponent(name),
        ]
        return candidates.lazy.compactMap { $0 }.compactMap(Bundle.init(url:)).first
    }()

    private static func loadBundle(_ l: PetLanguage) -> Bundle? {
        resources?.url(forResource: l.rawValue, withExtension: "lproj").flatMap(Bundle.init(url:))
    }

    /// 查譯文；目錄裡沒有就退回程式裡的簡體原文（check-localizable.py 會擋住這種情況進提交）。
    static func text(_ key: String, _ source: String) -> String {
        guard let bundle else { return source }
        let v = bundle.localizedString(forKey: key, value: "\u{1}", table: nil)
        return v == "\u{1}" ? source : v
    }
}

/// 介面文字一律走這裡：L("menu.enterCarPlay", "进入 CarPlay")。帶參數的用 String(format: L(...), ...)。
@inline(__always) func L(_ key: String, _ source: String) -> String { L10n.text(key, source) }
