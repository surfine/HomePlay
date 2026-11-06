// 表情／錶面風格／電池／相片牆等臉部資料模型（含 AxisLock）——自 main.swift 拆出。
import Accelerate
import AppKit
import ApplicationServices
import AVFoundation
import Metal
import RealityKit
import Combine
import simd
import VideoToolbox
import CoreMedia
import CoreImage
import ImageIO
import IOKit.ps
import IOKit.hid
import Carbon.HIToolbox
import Network
import EventKit
import ServiceManagement
import Security

enum Expression: String, CaseIterable {
    case idle, happy, love, wink, thinking, annoyed, surprised, worried, sleepy, asleep
    /// 舊名（快照腳本、官網素材）：好奇併進待機（靠近時眼珠本來就跟著游標）；專注拆成「思考」（等待）與「不耐煩」（連點）
    init?(name: String) {
        switch name {
        case "curious": self = .idle
        case "focus": self = .annoyed
        default: self.init(rawValue: name)
        }
    }
}

struct FaceParams: Equatable {
    var cw: CGFloat = 420, ch: CGFloat = 156                    // 胶囊
    var rx: CGFloat = 31, ry: CGFloat = 45, sep: CGFloat = 36   // 眼白半径、两眼中心离中线（照 👀 emoji：高寬比 1.45、微微分开）
    var top: CGFloat = 0, bot: CGFloat = 0, tilt: CGFloat = 0   // 上下眼皮遮住的比例、眼皮往外斜（弧度；正＝內角往上、難過，負＝內角往下、不耐煩）
    var ltop: CGFloat = 0                                       // 只壓左眼的上眼皮（思考時一高一低，像挑起一邊眉）
    var smile: CGFloat = 0                                      // 笑眼：眼白下缘切成弯月
    var pdx: CGFloat = -13, pdy: CGFloat = 6, ps: CGFloat = 1   // 眼珠位移、缩放
    var blush: CGFloat = 0, dim: CGFloat = 0                    // 脸颊红晕、屏幕变暗

    static func of(_ e: Expression) -> FaceParams {
        var p = FaceParams()
        switch e {
        // 十種剪影各不相同：只看外形（眼白輪廓＋眼珠位置）也分得出來
        case .idle, .wink: break                                                         // 👀 原樣；靠近時眼珠跟著游標
        case .happy: p.smile = 1; p.ps = 0; p.blush = 0.6                                 // ^^ 彎月
        case .love: p.ps = 1.25; p.pdx = 0; p.pdy = 2; p.blush = 1                        // 心形瞳孔＋紅暈
        case .thinking: p.ltop = 0.34; p.pdx = 15; p.pdy = -11; p.ps = 0.92               // 眼珠飄到右上、左眼皮壓低：「嗯……」
        case .annoyed: p.top = 0.42; p.tilt = -0.42; p.ry = 42; p.pdx = 0; p.pdy = 6; p.ps = 0.9   // 上眼皮往內壓成 V，扁一點
        case .surprised: p.rx = 34; p.ry = 56; p.sep = 40; p.ps = 0.5; p.pdx = 0; p.pdy = 0; p.cw = 470; p.ch = 184   // 瞪大、眼珠縮小、膠囊撐大
        case .worried: p.top = 0.26; p.tilt = 0.42; p.pdx = 0; p.pdy = 16                 // 內角往上的八字眉，眼珠往下
        case .sleepy: p.top = 0.6; p.bot = 0.08; p.pdx = 0; p.pdy = 12; p.ps = 0.95        // 眼皮平平地垂到一半多
        case .asleep: p.top = 0; p.pdx = 0; p.pdy = 14; p.dim = 0.45
        }
        return p
    }

    private static let keys: [WritableKeyPath<FaceParams, CGFloat>] =
        [\.cw, \.ch, \.rx, \.ry, \.sep, \.top, \.bot, \.tilt, \.ltop, \.smile, \.pdx, \.pdy, \.ps, \.blush, \.dim]

    /// 每个参数往 t 靠近 a（0..1），差得够小就直接贴上。返回有没有变。
    mutating func approach(_ t: FaceParams, _ a: CGFloat) -> Bool {
        var changed = false
        for k in Self.keys where self[keyPath: k] != t[keyPath: k] {
            let d = t[keyPath: k] - self[keyPath: k]
            self[keyPath: k] = abs(d) < 0.01 ? t[keyPath: k] : self[keyPath: k] + d * a
            changed = true
        }
        return changed
    }
}

// MARK: - 錶面样式、电量、照片（照「HomePlay 屏幕介面稿」）

/// 錶面样式：滚轮或 ← → 换，像 Apple Watch 的数字表冠
enum FaceStyle: String, CaseIterable {
    // 順序＝滾輪換錶面的順序（稿：docs/design-drafts/faces-v3/artifact）
    case island, photos, modular, analog, flow, weather, calendar, homeModular, embossed, growth, black, bedside, system6, alarmClock, about, pocket, cluster
    var title: String {
        switch self {
        case .island: return L("face.style.island", "岛")
        case .photos: return L("face.style.photos", "照片")
        case .modular: return L("face.style.modular", "模块")
        case .analog: return L("face.style.analog", "Typograph")
        case .flow: return "Flow"
        case .pocket: return L("face.style.pocket", "岛的口袋")
        case .growth: return L("face.style.growth", "陪伴的痕迹")
        case .system6: return "System 6"
        case .bedside: return L("face.style.bedside", "床头夜灯")
        case .weather: return L("face.style.weather", "天气")
        case .calendar: return L("face.style.calendar", "日历")
        case .homeModular: return L("face.style.homeModular", "家庭模块")
        case .embossed: return L("face.style.embossed", "浮雕指针")
        case .black: return L("face.style.black", "黑色")
        case .alarmClock: return "System 6 · Alarm Clock"   // 復古系列維持英文（史實），名稱前綴分組
        case .about: return "System 6 · About"
        case .cluster: return L("face.style.cluster", "仪表")
        }
    }
    /// 陣容（滾輪、總覽、選單、設定都用這份）：十一款（最後一款是儀表，三種版式）。Pocket 併進 Modular、床頭夜燈併進「黑」的夜間（稿：faces-v3），
    /// 浮雕指針成了 Typograph 的「材質」、Alarm Clock／About 成了 System 6 的「版式」，Home Modular 不再列出（要開發簽名的小幫手）；
    /// 程式都還留著，舊的偏好讀進來時換成新的那款（見 inLineup、migratedOptions）
    static var lineup: [FaceStyle] {
        allCases.filter { ![.pocket, .bedside, .homeModular, .embossed, .alarmClock, .about].contains($0) }
    }
    var inLineup: FaceStyle {
        switch self {
        case .pocket, .homeModular: return .modular
        case .bedside: return .black
        case .embossed: return .analog
        case .alarmClock, .about: return .system6
        default: return self
        }
    }
    /// 舊錶面搬進新選項：回傳要一併設成的材質／版式
    var migratedOptions: (material: TypographMaterial?, layout: System6Layout?) {
        switch self {
        case .embossed: return (.embossed, nil)
        case .alarmClock: return (nil, .alarmClock)
        case .about: return (nil, .about)
        default: return (nil, nil)
        }
    }
    /// 往后（d > 0）或往前换一个，头尾相接
    func next(_ d: Int) -> FaceStyle {
        let all = Self.lineup, i = all.firstIndex(of: inLineup)!
        return all[((i + d) % all.count + all.count) % all.count]
    }
    static let defaultsKey = "HomePlayFaceStyle"
}

/// Typograph 的材質：平面（原樣）或浮雕（原「浮雕指針」錶面）
enum TypographMaterial: String, CaseIterable {
    case flat, embossed
    static let defaultsKey = "HomePlayTypographMaterial"
    var title: String {
        switch self {
        case .flat: return L("typograph.material.flat", "平面")
        case .embossed: return L("typograph.material.embossed", "浮雕")
        }
    }
}

/// System 6 的版式：Finder 桌面（原樣）、Alarm Clock、About This Macintosh
enum System6Layout: String, CaseIterable {
    case finder, alarmClock, about
    static let defaultsKey = "HomePlaySystem6Layout"
    var title: String {
        switch self {
        case .finder: return "Finder"
        case .alarmClock: return "Alarm Clock"   // 復古系列維持英文（史實）
        case .about: return "About"
        }
    }
}

/// 快照專用：命令行強行指定材質／版式（不寫 UserDefaults）；儀表的版式在 Faces/ClusterFace.swift
nonisolated(unsafe) var faceOptionSnapshotOverride: (material: TypographMaterial?, layout: System6Layout?) = (nil, nil)

/// 本机电量（IOKit）。台式机没有电池时回 nil。
enum Battery {
    struct Reading: Equatable { let percent: Int; let charging: Bool; let onAC: Bool }
    static func read() -> Reading? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for ps in list {
            guard let d = IOPSGetPowerSourceDescription(info, ps)?.takeUnretainedValue() as? [String: Any],
                  (d[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType,
                  let cur = d[kIOPSCurrentCapacityKey] as? Int, let max = d[kIOPSMaxCapacityKey] as? Int, max > 0 else { continue }
            return Reading(percent: Int((Double(cur) / Double(max) * 100).rounded()),
                           charging: d[kIOPSIsChargingKey] as? Bool ?? false,
                           onAC: (d[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue)
        }
        return nil
    }
}

/// 照片錶面的照片：读一个文件夹（默认「图片 › HomePlay」）里的照片轮播，一分钟换一张；
/// 30 秒重新扫一次文件夹，加了新照片不用重开。拍摄日期从 EXIF 读，没有就不显示。
final class PhotoShelf {
    let folder: URL
    private var files: [URL] = []
    private var index = -1
    private(set) var current: CGImage?
    private(set) var captionDate: Date?
    /// 拍摄日期，按目前語言在畫面上現排（切換語言不用重新載入照片）
    var caption: String? {
        guard let d = captionDate else { return nil }
        // 这张卡每帧都可能重画，DateFormatter 不能每次都新建（建一次约几十微秒）。
        let lang = L10n.language
        if captionFormatterLocale != lang {
            let f = DateFormatter(); f.locale = lang.locale
            f.dateFormat = DateFormatter.dateFormat(fromTemplate: "yMMMMd", options: 0, locale: lang.locale)
            captionFormatter = f; captionFormatterLocale = lang
        }
        return captionFormatter?.string(from: d)
    }
    private var captionFormatter: DateFormatter?
    private var captionFormatterLocale: PetLanguage?
    private var lastScan = -1e9, lastSwap = -1e9
    static let exts: Set<String> = ["jpg", "jpeg", "png", "heic", "heif", "tif", "tiff"]

    init(folder: URL) { self.folder = folder }
    /// 正在看的那張的檔案（AirDrop 分享用）；還沒有照片就是 nil
    var currentFile: URL? { files.indices.contains(index) && current != nil ? files[index] : nil }
    /// 資料夾剛放進新照片（AirDrop 收到的）：下一幀就重掃，不等 30 秒
    func rescanSoon() { lastScan = -1e9 }
    static var defaultFolder: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Pictures/HomePlay", isDirectory: true)
    }

    /// 有换图（或文件夹从有变无）就回 true
    func tick(_ now: Double) -> Bool {
        var changed = false
        if now - lastScan > 30 {
            lastScan = now
            let found = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
                .filter { Self.exts.contains($0.pathExtension.lowercased()) }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
            if found != files {
                files = found
                if files.isEmpty { if current != nil { current = nil; captionDate = nil; changed = true } }
                else { lastSwap = -1e9 }
            }
        }
        if !files.isEmpty, current == nil || (files.count > 1 && now - lastSwap > 60) {
            lastSwap = now
            index = (index + 1) % files.count
            load(files[index]); changed = true
        }
        return changed
    }

    private func load(_ url: URL) {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { current = nil; return }
        let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                     kCGImageSourceThumbnailMaxPixelSize: 1400,
                                     kCGImageSourceCreateThumbnailWithTransform: true]
        current = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
        captionDate = nil
        if let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
           let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any],
           let raw = exif[kCGImagePropertyExifDateTimeOriginal] as? String {
            let p = DateFormatter(); p.dateFormat = "yyyy:MM:dd HH:mm:ss"
            captionDate = p.date(from: raw)
        }
    }
}

/// 倒数显示：4:59、12:05、1:02:03（无条件进位，最后一秒显示 0:01 不显示 0:00）
func timerClock(_ seconds: Double) -> String {
    let s = Int(seconds.rounded(.up)), h = s / 3600, m = (s % 3600) / 60, r = s % 60
    return h > 0 ? String(format: "%d:%02d:%02d", h, m, r) : String(format: "%d:%02d", m, r)
}

struct AxisLock {
    enum Axis { case pending, horizontal, vertical }
    private(set) var axis: Axis = .pending

    mutating func pass(dx: CGFloat, dy: CGFloat, threshold: CGFloat = 3) -> (dx: CGFloat, dy: CGFloat) {
        if axis == .pending {
            guard abs(dx) > threshold || abs(dy) > threshold else { return (0, 0) }
            axis = abs(dx) >= abs(dy) ? .horizontal : .vertical
        }
        switch axis {
        case .horizontal: return (dx, 0)
        case .vertical: return (0, dy)
        case .pending: return (0, 0)
        }
    }
    mutating func reset() { axis = .pending }
}

/// 视频健康（照 MacPlay videoHealth 的规则）：收到≥3 帧却 2.5 s 没解出一帧 → 重建解码并要关键帧；
/// 重建后每 0.9 s 最多要一次关键帧，8 s 仍没出帧再重建；60 s 内最多重建 3 次、总共 6 次，超过就放弃（断开重连）。
/// 没有新帧进来（静止画面）不算停滞。所有调用都在主线程。
