import Accelerate
// HomeView 桌宠（自用，不分发）——RealityKit 版（USDZ 原生几何/材质）。
//
// 身体直接用 Apple 的 apple-homeview.usdz（Quick Look 的同一份资产）：几何、材质、网罩、
// 铰链原生；USB-C 母座按 iPhone 18 Pro 的开口比例重建成独立几何。RealityKit 的默认 IBL 就是官图那套高调棚拍光，另补一盏背光托住侧面/背板。
// 屏幕换成我们的脸或 CarPlay 直播；触控 UV 用屏幕平面的单应变换；拆解、配色、追人都保留。
// 屏幕平时是「岛的表情」的脸：黑胶囊里两颗贴在一起的白椭圆，约 4 秒眨一次、偶尔瞄一下；
// 十个表情照「HomeView 表情稿」，被拖、被摸、拆开、深夜、断线都有反应。接上 CarPlay 接收器时屏幕换成直播画面。
//
// 用法：
//   swift build -c release --product homeplay-pet
//   .build/release/homeplay-pet                              # 只有脸
//   .build/release/homeplay-pet --endpoint ws://127.0.0.1:8788  # 屏幕接 CarPlay 接收器
//   .build/release/homeplay-pet --size 260                   # 初始宽度（点）
//   .build/release/homeplay-pet --face happy --snapshot a.png  # 锁定一张脸存快照
// 操作：拖＝转动；⌘拖＝移动窗口；双击＝拆开／组回（直播时双击屏幕算点按，双击身体才拆）；
// 拖右下角＝缩放（锁比例）；空格＝👀（CarPlay ⇄ 主屏幕）；CarPlay 上方向键／Tab／Return／Esc＝车上旋钮；右键＝菜单。
// 触控板：捏合＝放大缩小；两指旋转＝转身体；两指滑＝转动／俯仰；两指轻点两下＝拆开／组回。
// Magic Mouse：单指滑＝转动／俯仰；单指轻点两下＝拆开／组回。普通滚轮＝缩放。

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

func log(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }

/// 診斷日誌的落地點。`appendDiag` 會被事件 tap、相機佇列這些不能等磁碟的地方呼叫，
/// 所以一律丟進這條序列佇列非同步寫；每支檔案超過 1 MB 就輪轉成 `<name>.1`，只留一份舊檔。
private let diagQueue = DispatchQueue(label: "homeplay.diag", qos: .utility)
private let diagDir: URL = HomePlayState.directory
private let diagLimit: UInt64 = 1 << 20
private var diagHandles: [String: FileHandle] = [:]   // 只在 diagQueue 上存取

private func diagHandle(_ name: String) -> FileHandle? {
    if let h = diagHandles[name] { return h }
    try? FileManager.default.createDirectory(at: diagDir, withIntermediateDirectories: true)
    let url = diagDir.appendingPathComponent(name)
    // 日誌只給自己讀寫（0600）：新建就是 0600，舊版留下的 0644 第一次打開時修正
    if !FileManager.default.fileExists(atPath: url.path) {
        FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
    } else {
        chmod(url.path, 0o600)
    }
    guard let h = try? FileHandle(forWritingTo: url) else { return nil }
    h.seekToEndOfFile()
    diagHandles[name] = h
    return h
}

private func diagWrite(_ name: String, _ text: String) {
    guard let data = text.data(using: .utf8), let h = diagHandle(name) else { return }
    let size = h.offsetInFile
    if size > diagLimit {
        // 先關檔再搬：留著的 handle 會指到舊 inode，之後的寫入就丟了。
        try? h.close(); diagHandles[name] = nil
        let url = diagDir.appendingPathComponent(name)
        let old = diagDir.appendingPathComponent(name + ".1")
        try? FileManager.default.removeItem(at: old)
        try? FileManager.default.moveItem(at: url, to: old)
        guard let fresh = diagHandle(name) else { return }
        _ = try? fresh.write(contentsOf: data)
        return
    }
    _ = try? h.write(contentsOf: data)
}

/// 舊版（0.4 之前）把每個按鍵寫進 keys.log：只刪這兩個確切檔名，其他檔不碰。回傳刪了幾個。
@discardableResult
func removeLegacyKeyLogs(in dir: URL) -> Int {
    var removed = 0
    for name in ["keys.log", "keys.log.1"] {
        let url = dir.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: url.path), (try? FileManager.default.removeItem(at: url)) != nil { removed += 1 }
    }
    return removed
}
let legacyKeyLogsKey = "HomePlayLegacyKeyLogsRemoved"

/// 啟動時把 HomePlay 資料夾裡所有日誌（含輪轉的 .1、舊版留下的）收成 0600：
/// receiver.log 有 Wi-Fi 名稱與手機位址，舊版的 keys.log 有按鍵紀錄，都不該給同機其他帳號讀。不刪、不改內容。
func tightenLogPermissions() {
    diagQueue.async {
        // 一次性：刪掉舊版留下的按鍵紀錄（只記一行，不讀內容）
        if !UserDefaults.standard.bool(forKey: legacyKeyLogsKey) {
            if removeLegacyKeyLogs(in: diagDir) > 0 { log("removed legacy keys.log") }
            UserDefaults.standard.set(true, forKey: legacyKeyLogsKey)
        }
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: diagDir.path) else { return }
        for n in names where n.hasSuffix(".log") || n.hasSuffix(".log.1") {
            let path = diagDir.appendingPathComponent(n).path
            if let mode = (try? FileManager.default.attributesOfItem(atPath: path))?[.posixPermissions] as? Int, mode & 0o077 != 0 {
                chmod(path, 0o600)
            }
        }
    }
}
/// 诊断日志：异步追加一行到 Application Support/HomePlay/<name>。
func appendDiag(_ name: String, _ line: String) {
    let text = "[\(Date())] \(line)\n"
    diagQueue.async { diagWrite(name, text) }
}
func srgb(_ hex: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat(hex >> 16 & 0xff) / 255, green: CGFloat(hex >> 8 & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: a)
}

// MARK: - 窗口比例


func arg(_ n: String) -> String? {
    let a = CommandLine.arguments
    if let i = a.firstIndex(of: n), i + 1 < a.count { return a[i + 1] }; return nil
}

if CommandLine.arguments.contains("--home-dump") { runHomeDump() }   // 連 HomePlay Home 幫手，印摘要就結束
if let i = CommandLine.arguments.firstIndex(of: "--home-set"), i + 2 < CommandLine.arguments.count {   // 2.0: 真機驗證寫入
    runHomeSet(name: CommandLine.arguments[i + 1], on: CommandLine.arguments[i + 2] == "on")
}
if CommandLine.arguments.contains("--fetch-official-icons") { runFetchOfficialIcons() }
HPLook.parseSnapshotArgs()   // 快照：--look Slate（官方 12 種 Look 之一，不寫偏好；Shell/HPLook.swift）
if CommandLine.arguments.contains("--poster-list") { print(PosterLibraryStore.listText); exit(0) }   // 多臉：列出每一張（目前那張標 ←）
if let s = arg("--poster-select"), let n = Int(s), PosterLibraryStore.all.indices.contains(n) {   // 快照：選第 n 張，不寫偏好
    PosterConfiguration.snapshotOverride = PosterLibraryStore.all[n]
}
if let s = arg("--poster") { PosterConfiguration.snapshotOverride = PosterConfiguration.parse(s) }   // 快照：--poster 'look=Blue-Orange,typeface=soft' 或 default-color-1…4（海報配置，不寫偏好；Shell/PosterConfiguration.swift）
AppLaunchCounts.parseSnapshotArgs(CommandLine.arguments)   // 快照：--launch-counts timers=9,music=3（App 資料庫的排序依據，不寫偏好；Shell/SpringBoard/SBLibraryCategories.swift）
AppInstallDates.bootstrap(AppRegistry.all.map(\.id))   // 安裝日期：第一次跑這本帳時全部記「早於這本帳」，之後才看到的 App 才算新安裝
AmbientPoster.parseSnapshotArgs(CommandLine.arguments)   // 快照：--ambient-poster weather|photos|clock 強制指定 Ambient 海報（Shell/AmbientPoster.swift）
if AmbientPoster.demo { Shell.ambientSince = CACurrentMediaTime() }   // 快照：--demo-ambient 一開就在 Ambient 海報期（輪播從這一刻起算）
HomeAlerts.demoTrigger(CommandLine.arguments)   // HomeView 對齊 WP5 拍板：--demo-alert leak|smoke|co|co2|security [房間] 觸發警報橫幅（Shell/HomeAlerts.swift）   // 2.0: 抓官網的鬧鐘／計時器／世界時鐘／對講圖示（Shell/OfficialIcons.swift）
if let o = arg("--hpicons-png") { HPIcons.writeSheet(o); exit(0) }   // 2.0 第四輪：自畫圖示排一張（Design/HPIcons.swift）
if let o = arg("--avatars-png") { HPAvatar.writeSheet(o); exit(0) }   // 2.0 第四輪：👀 人物頭像排一張（Design/HPAvatar.swift）
if let o = arg("--avatar-editor-png") { AvatarEditorSnapshot.write(o) }   // 2.0 第四輪：換頭像表單的快照（People/PeoplePane.swift）

if CommandLine.arguments.contains(where: { $0 == "--metrics-json" || $0 == "--metrics-json-pretty" }) { MetricsCLI.run(CommandLine.arguments) }   // 2.0 D1：儀表讀值逐行印 JSON 就結束（Metrics/MetricsSampler.swift）
if CommandLine.arguments.contains("--cliotalk-speech-probe") { ClioSpeechProbe.run() }   // 2.0: 本機聽寫支援哪些語系（不開麥克風）
if let i = CommandLine.arguments.firstIndex(of: "--glass-calibrate"), i + 1 < CommandLine.arguments.count {   // 2.0 glass: 真的 NSGlassEffectView 對我們的玻璃（Design/GlassCalibrate.swift）
    let a = CommandLine.arguments
    if #available(macOS 27.0, *) { GlassCalibrate.run(a[i + 1], what: i + 2 < a.count && !a[i + 2].hasPrefix("--") ? a[i + 2] : "all") }
    print("--glass-calibrate needs macOS 27"); exit(2)
}

if CommandLine.arguments.contains("--probe-desktop-widgets") { DesktopWidgetProbe.run() }   // SideShow 致敬：印出桌面小工具視窗就結束（Shell/DesktopWidgets.swift）
if CommandLine.arguments.contains("--sideshow-serve-test") { SideShowServeTest.run() }   // SideShow：只聽 127.0.0.1、假內容、記憶體名冊，給 curl 驗（SideShow/SideShowSelfTest.swift）
if CommandLine.arguments.contains("--selftest") {
    // 纯函数自检：方屏 uv → 画面坐标（留黑扣掉）
    func near(_ a: (Double, Double)?, _ b: (Double, Double)) -> Bool {
        guard let a else { return false }; return abs(a.0 - b.0) < 1e-9 && abs(a.1 - b.1) < 1e-9
    }
    var ok = true
    func check(_ c: Bool, _ m: String) { if !c { ok = false; log("FAIL \(m)") } }
    check(near(screenToVideo(u: 0.5, v: 0.5, videoW: 1800, videoH: 1360), (0.5, 0.5)), "中心")
    check(near(screenToVideo(u: 0, v: 0.5 - 0.5 * 1360 / 1800, videoW: 1800, videoH: 1360), (0, 0)), "宽画面左上角")
    check(screenToVideo(u: 0.5, v: 0.05, videoW: 1800, videoH: 1360) == nil, "宽画面上方留黑")
    check(near(screenToVideo(u: 1, v: 0.5 + 0.5 * 1360 / 1800, videoW: 1800, videoH: 1360), (1, 1)), "宽画面右下角")
    check(near(screenToVideo(u: 0.5 + 0.5 * 900 / 1200, v: 1, videoW: 900, videoH: 1200), (1, 1)), "直式右下角")
    check(screenToVideo(u: 0.02, v: 0.5, videoW: 900, videoH: 1200) == nil, "直式左边留黑")
    check(near(screenToVideo(u: 0.25, v: 0.75, videoW: 1200, videoH: 1200), (0.25, 0.75)), "正方形原样")
    // 单轴手势锁：起手阈值内不动；判主轴后只走一根轴；重置后重新判
    do {
        var lock = AxisLock()
        check(lock.pass(dx: 2, dy: 1) == (0, 0), "单轴锁：起手抖动不生效")
        check(lock.pass(dx: 10, dy: 3).dx == 10 && lock.pass(dx: 10, dy: 3).dy == 0, "单轴锁：水平主导锁偏航")
        check(lock.pass(dx: 0, dy: 50) == (0, 0), "单轴锁：锁水平后俯仰不动")
        lock.reset()
        check(lock.pass(dx: 2, dy: 30) == (0, 30), "单轴锁：重置后竖直主导锁俯仰")
        check(lock.pass(dx: 40, dy: 0) == (0, 0), "单轴锁：锁竖直后偏航不动")
        lock.reset()
        check(lock.pass(dx: 5, dy: 5).dx == 5 && lock.pass(dx: 5, dy: 5).dy == 0, "单轴锁：平手判水平")
    }
    // 已配对手机清单（右键「使用 iPhone」）：解析、当前勾选、空列表
    do {
        CarPlayPhoneBook.phones = []; CarPlayPhoneBook.current = nil
        let json = #"{"type":"phones","current":"50:3B:70:CB:AE:56","items":[{"address":"50:3B:70:CB:AE:56","name":"Aaron’s iPhone"},{"address":"AA:BB:CC:DD:EE:FF","name":"iPhone 15"}]}"#
        check(CarPlayPhoneBook.apply(json: json), "phones JSON parses")
        check(CarPlayPhoneBook.phones.count == 2, "two paired phones listed")
        check(CarPlayPhoneBook.isCurrent("50-3b-70-cb-ae-56"), "current phone matches across address formats")
        check(!CarPlayPhoneBook.isCurrent("AA:BB:CC:DD:EE:FF"), "other phone is not marked current")
        let entries = CarPlayPhoneBook.menuEntries()
        check(entries.count == 2 && entries[0].title == "Aaron’s iPhone" && entries[0].current
              && !entries[1].current, "menu entries use names and check the current phone")
        check(CarPlayPhoneBook.apply(json: #"{"type":"phones","current":"","items":[]}"#), "empty phone list parses")
        check(CarPlayPhoneBook.phones.isEmpty && CarPlayPhoneBook.current == nil, "empty list clears current")
        check(!CarPlayPhoneBook.apply(json: "not json"), "malformed phones message is ignored")
    }
    // 视频健康
    let h = VideoHealth(now: 0)
    check(h.check(now: 10) == .none, "没收到帧＝静止画面，不算停滞")
    for t in [0.5, 1.0, 1.5] { h.frameReceived(now: t) }
    check(h.check(now: 2) == .none, "2.5 s 内不动作")
    check(h.check(now: 3) == .rebuild, "收 3 帧 2.5 s 没解出 → 重建")
    check(h.check(now: 3.5) == .none && h.check(now: 3.95) == .requestKeyframe, "重建后 0.9 s 才再要关键帧")
    check(h.check(now: 4.2) == .none, "要关键帧限速")
    h.frameDecoded(now: 5)
    check(h.check(now: 20) == .none, "解出帧就恢复正常")
    for t in [28.0, 28.5, 29.0] { h.frameReceived(now: t) }
    check(h.check(now: 30) == .rebuild, "又停滞 → 重建")
    check(h.check(now: 35) == .none, "流停了（5 s 没进帧）＝静止画面，不再动作")
    h.frameReceived(now: 38.5)
    check(h.check(now: 39) == .rebuild, "8 s 仍没出帧、还在进帧 → 再重建")
    h.frameReceived(now: 47.5)
    check(h.check(now: 48) == .giveUp, "60 s 内第 4 次 → 放弃")
    let h2 = VideoHealth(now: 0)
    var acts: [VideoHealth.Action] = []
    for i in 0..<8 { acts.append(h2.decodeError(now: Double(i) * 61)) }
    check(acts.filter { $0 == .rebuild }.count == 6 && acts.last == .giveUp, "总共最多重建 6 次")
    h2.reset(now: 500)
    check(h2.decodeError(now: 501) == .rebuild, "重连后是新的恢复预算，不会立刻又放弃")
    // 主线程被拖动/缩放占住 30 s：判活只认实际收帧/解码时间，不认检查定时器的到达时间
    let h3 = VideoHealth(now: 0)
    for t in stride(from: 0.5, through: 30.0, by: 1.0) {
        h3.frameReceived(now: t); h3.frameDecoded(now: t + 0.08)
    }
    check(h3.check(now: 31) == .none, "主线程卡 30 s、帧仍在解 → 不误判停滞")
    let h4 = VideoHealth(now: 0)
    for t in [29.5, 29.8, 30.0] { h4.frameReceived(now: t) }
    check(h4.check(now: 30.2) == .rebuild, "检查晚到，但最近确有进帧且没解出 → 该重建")
    // 心情：触发对照
    let m = Mood(now: 0)
    check(m.current(now: 1, hour: 14) == .idle, "白天没人碰＝待机")
    check(m.current(now: 10_000, hour: 14) == .idle, "白天闲置再久也不睡")
    check(m.current(now: 179, hour: 23) == .idle && m.current(now: 181, hour: 23) == .sleepy, "夜里闲置 3 分钟困倦")
    check(m.current(now: 481, hour: 2) == .asleep, "再 5 分钟睡着")
    m.activity(now: 500, hour: 2)
    check(m.current(now: 500.2, hour: 2) == .surprised && m.current(now: 500.5, hour: 2) == .idle, "被叫醒：惊讶 0.4 s 再待机")
    m.near = true
    check(m.current(now: 501, hour: 2) == .idle, "游标靠近＝待机（眼珠跟着游标）")
    m.petting(true, now: 510)
    check(m.current(now: 511, hour: 14) == .idle && m.current(now: 511.6, hour: 14) == .happy, "摸头 1.5 s 笑")
    check(m.current(now: 514.1, hour: 14) == .love, "摸满 4 s 爱心")
    m.petting(false, now: 515)
    check(m.current(now: 515.5, hour: 14) == .happy && m.current(now: 515.7, hour: 14) == .idle, "离开再笑 0.6 s")
    check(!(0..<4).map { m.poke(now: 520 + Double($0) * 0.2) }.contains(true) && m.poke(now: 520.9), "1.5 s 内第 5 下＝不耐烦")
    check(m.current(now: 521, hour: 14) == .annoyed, "连点＝不耐烦")
    m.apart = true
    check(m.current(now: 530, hour: 14) == .surprised, "拆开＝惊讶")
    m.apart = false; m.disconnected = true
    check(m.current(now: 530, hour: 23) == .worried, "断线＝担心，优先于睡意")
    m.disconnected = false
    // 脸的参数：插值会收敛到目标
    var fp = FaceParams.of(.idle)
    for _ in 0..<200 { _ = fp.approach(.of(.surprised), 0.2) }
    check(fp == .of(.surprised) && !fp.approach(.of(.surprised), 0.2), "表情插值收敛并停止重画")
    // 錶面切换与倒数显示
    check(FaceStyle.island.next(1) == .photos && FaceStyle.island.next(-1) == FaceStyle.lineup.last! && FaceStyle.lineup.last!.next(1) == .island, "錶面头尾相接")
    check(FaceStyle.lineup.map(\.rawValue) == ["island", "photos", "modular", "analog", "flow", "weather", "world", "calendar", "growth", "black", "system6", "cluster"], "錶面陣容十二款（天氣後面是世界）")
    check(FaceStyle.embossed.inLineup == .analog && FaceStyle.alarmClock.inLineup == .system6 && FaceStyle.about.inLineup == .system6 && FaceStyle.homeModular.inLineup == .modular, "舊錶面搬進新款")
    check(timerClock(299.2) == "5:00" && timerClock(59) == "0:59" && timerClock(0.3) == "0:01" && timerClock(3725) == "1:02:05", "倒数显示")
    let fct = Face(); fct.frozen = true; fct.startTimer(seconds: 2, now: 100)
    var fired = false; fct.onTimerDone = { fired = true }
    _ = fct.tick(101); check(fct.timerActive && !fired, "计时器还没到")
    _ = fct.tick(102.1); check(!fct.timerActive && fired, "计时器到点叫一下")
    // 天氣靜態層：同一段內容「直接畫進主畫布」與「離屏緩存圖再合成」必須逐字節一致（無資料的破折號狀態，確定性）
    do {
        let fw = Face(); fw.frozen = true
        let wd = Date(timeIntervalSince1970: 1_790_000_060), wfull = CGRect(x: 0, y: 0, width: 1024, height: 1024)
        func wpng(_ img: CGImage) -> Data { NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])! }
        let woff = makeImage(512, 512) { c in c.scaleBy(x: 0.5, y: 0.5); fw.drawWeatherStatic(c, nil, wd) }
        let wdirect = makeImage(512, 512) { c in c.scaleBy(x: 0.5, y: 0.5); fw.drawWeatherStatic(c, nil, wd) }
        let wviaCache = makeImage(512, 512) { c in c.scaleBy(x: 0.5, y: 0.5); fw.drawUpright(c, woff, in: wfull) }
        check(wpng(wdirect) == wpng(wviaCache), "天气静态层：缓存合成＝直接画")
    }
    // 壁纸色票：整点对上、之间插值、绕过午夜
    let noon = Face.palette(hour: 12, aqua: false), dayTop = Face.RGB(0x1d4a57)
    check(abs(noon.top.r - dayTop.r) < 1e-6 && abs(noon.top.b - dayTop.b) < 1e-6, "12 点＝白天色票")
    check(abs(Face.palette(hour: 12, aqua: true).top.b - Face.RGB(0x1b4f9c).b) < 1e-6, "G4 白的白天＝Aqua 蓝")
    let mid = Face.palette(hour: 9.5, aqua: false).top.r
    check(mid > min(Face.RGB(0x3a4f7a).r, dayTop.r) && mid < max(Face.RGB(0x3a4f7a).r, dayTop.r), "清晨到白天之间插值")
    let midnight = Face.palette(hour: 3, aqua: false).top.b
    check(midnight > Face.RGB(0x152447).b - 1 && midnight >= min(Face.RGB(0x152447).b, Face.RGB(0x3a4f7a).b) - 1e-6, "午夜后在夜里与清晨之间")
    // 靠近就多显示：展开会收敛
    let fc = Face(); fc.frozen = true; fc.revealTarget = 1
    for i in 0..<120 { _ = fc.tick(1000 + Double(i) / 60) }
    check(fc.reveal == 1, "游标靠近时玻璃卡展开到底")
    // 外观：五种都换得了，铝色是金属、G4 白不是
    let mdl = HomeViewModel()
    for f in Finish.allCases {
        mdl.apply(finish: f)
        let metal = mdl.selftestMetalness
        check(mdl.finish == f && (f == .g4 ? abs(metal) < 1e-6 : abs(metal - 1) < 1e-6), "外观 \(f.rawValue)")
    }
    // 拆開看看：九層錯開（外層先動、兩端到位）、每一件都有網格可挑、正面射進去先打到蓋板玻璃
    let layers = AnatomyLayer.allCases
    check(layers.allSatisfy { $0.progress(0) == 0 && $0.progress(1) == 1 }, "九层组好为 0、拆开为 1")
    check(zip(layers, layers.dropFirst()).allSatisfy { $0.progress(0.5) > $1.progress(0.5) }, "九层外层先动")
    check(AnatomyPart.allCases.allSatisfy { mdl.anatomyAnchor($0) != nil }, "每个零件都挑得到")
    let frontHit = mdl.pickAnatomy(origin: SIMD3<Float>(0, 10.5, 60), direction: SIMD3<Float>(0, 0, -1))?.0
    check(frontHit == .coverGlass, "正面先打到盖板玻璃（\(frontHit?.rawValue ?? "nil")）")
    // 拖底座＝搬窗口：组好时从正面打底座那一截，挑到的是底座零件；打屏幕不算
    let standYs: [Float] = [-1, 0, 1, 2, 3, 4, 5, 6, 7, 8]
    let standHits = standYs.map { mdl.pickAnatomy(origin: SIMD3<Float>(0, $0, 60), direction: SIMD3<Float>(0, 0, -1))?.0 }
    log("selftest stand picks \(zip(standYs, standHits).map { "\($0)=\($1?.rawValue ?? "nil")" }.joined(separator: " "))")
    check(standHits.contains { $0.map { PetView.standAnatomyForTest.contains($0) } ?? false }, "正面打底座挑到底座零件")
    check(!PetView.standAnatomyForTest.contains(frontHit ?? .coverGlass), "屏幕不是底座")
    // 搬位置提示：拖到窗外两次（30 秒内）才提示；拖一点点、隔太久都不算
    do {
        var d = MoveHintDetector()
        check(!d.rotateDragEnded(now: 0, leftWindow: true, travel: 50, width: 220), "搬位置提示：第一次不提示")
        check(!d.rotateDragEnded(now: 5, leftWindow: false, travel: 40, width: 220), "搬位置提示：小幅转动不算")
        check(d.rotateDragEnded(now: 10, leftWindow: false, travel: 400, width: 220), "搬位置提示：30 秒内第二次拖很远就提示")
        check(!d.rotateDragEnded(now: 11, leftWindow: true, travel: 0, width: 220), "搬位置提示：提示后重新计数")
        check(!d.rotateDragEnded(now: 60, leftWindow: true, travel: 0, width: 220), "搬位置提示：隔太久不累计")
    }
    // 舊版按鍵紀錄：只刪 keys.log／keys.log.1，同資料夾其他檔（含名字相近的）都留著
    do {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("homeplay-selftest-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for n in ["keys.log", "keys.log.1", "keys.log.bak", "syskeys.log", "receiver.log"] {
            FileManager.default.createFile(atPath: dir.appendingPathComponent(n).path, contents: Data("x".utf8))
        }
        let removed = removeLegacyKeyLogs(in: dir)
        let left = Set((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
        check(removed == 2 && left == ["keys.log.bak", "syskeys.log", "receiver.log"], "旧按键纪录：只删 keys.log 与 keys.log.1")
        check(removeLegacyKeyLogs(in: dir) == 0, "旧按键纪录：再跑一次什么都不删")
        try? FileManager.default.removeItem(at: dir)
    }
    // Wi-Fi 名称自动补：读得到就送；没卡住不打扰；卡住且没问过才问定位；被拒或问过才手填
    do {
        typealias W = WiFiName
        check(W.decide(receiverKnows: true, readable: "Home", auth: .granted, stuck: true, quiet: false, alreadyAsked: false) == .nothing, "Wi-Fi 名称：接收器已知就不动")
        check(W.decide(receiverKnows: false, readable: "Home", auth: .granted, stuck: false, quiet: true, alreadyAsked: false) == .send("Home"), "Wi-Fi 名称：有权限就悄悄补上")
        check(W.decide(receiverKnows: false, readable: "<redacted>", auth: .denied, stuck: false, quiet: false, alreadyAsked: false) == .nothing, "Wi-Fi 名称：没卡住不弹东西")
        check(W.decide(receiverKnows: false, readable: nil, auth: .notDetermined, stuck: true, quiet: false, alreadyAsked: false) == .askPermission, "Wi-Fi 名称：卡住且没问过才问定位")
        check(W.decide(receiverKnows: false, readable: nil, auth: .notDetermined, stuck: true, quiet: false, alreadyAsked: true) == .manual, "Wi-Fi 名称：问过（选了以后）就手填")
        check(W.decide(receiverKnows: false, readable: nil, auth: .denied, stuck: true, quiet: false, alreadyAsked: false) == .manual, "Wi-Fi 名称：被拒就手填")
        check(W.decide(receiverKnows: false, readable: nil, auth: .granted, stuck: true, quiet: false, alreadyAsked: false) == .manual, "Wi-Fi 名称：允许了却读不到（没连 Wi-Fi）就手填")
        check(W.decide(receiverKnows: false, readable: nil, auth: .notDetermined, stuck: true, quiet: true, alreadyAsked: false) == .nothing, "Wi-Fi 名称：背景挂着不打扰")
        check(W.usable(" Home ") == "Home" && W.usable("<redacted>") == nil && W.usable("") == nil, "Wi-Fi 名称：脱敏占位不算")
    }
    // 连不上的排障卡：每个原因各有标题；40 秒后给插线退路；网络名带进句子；日志只数次数
    do {
        let reasons = ["macFirewall", "localNetwork", "carPlayConsent", "ssidUnknown", "inboundBlocked", "wifiNoConnectBack",
                       "usbNoData", "usbLocked", "usbTrustExpired", "usbNoNetwork"]
        let titles = Set(reasons.map { ConnectHelp.card(reason: $0, ssid: "Home", needsPassword: false, helpElapsed: 0).title })
        check(titles.count == reasons.count, "排障卡：每个原因（无线六个、有线四个）各有标题")
        let early = ConnectHelp.card(reason: "wifiNoConnectBack", ssid: "Home", needsPassword: false, helpElapsed: 5)
        let late = ConnectHelp.card(reason: "wifiNoConnectBack", ssid: "Home", needsPassword: false, helpElapsed: 45)
        check(early.subtitle.contains("Home") && early.hint == nil && late.hint != nil && late.chip != early.chip, "排障卡：40 秒后改给插线与诊断报告")
        check(ConnectHelp.card(reason: nil, ssid: "", needsPassword: true, helpElapsed: 0).hint != nil, "排障卡：旧接收器没给原因也有提示")
        let selftestLog = Substring("[1] 无线：身份自检通过\n[2] 无线：送 0x4301：无线 10.0.0.2\n[3] 无线：手机连入控制口 10.0.0.3\n[4] 无线：会话开始，等画面\n")
        let sum = ConnectHelp.summarizeLog(selftestLog)
        check(sum.contains("start sent 1") && sum.contains("sessions 1") && !sum.contains("10.0.0"), "诊断报告：日志只数次数、不抄地址")
    }
    mdl.apply(1)
    let baseHit = mdl.pickAnatomy(origin: SIMD3<Float>(0, -5.9, 60), direction: SIMD3<Float>(0, 0, -1))?.0
    check(baseHit == .foot, "拆开后最下面是底脚（\(baseHit?.rawValue ?? "nil")）")
    mdl.apply(0)
    // 島錶面选项：坏值退回默认、没照片退回随时段、直排两位数
    check(ClockStyle(rawValue: "bogus") == nil && IslandBackground.photo.effective(hasPhoto: false) == .daytime
          && IslandBackground.solid.effective(hasPhoto: false) == .solid && IslandBackground.photo.effective(hasPhoto: true) == .photo, "島錶面背景：没照片退回随时段")
    let part = Face.clockParts(Calendar.current.date(from: DateComponents(year: 2026, month: 1, day: 1, hour: 9, minute: 5))!)
    check(part.h == "9" && part.m == "05", "直排时钟照系统时制（小时不补零）")
    // 换錶面总览：到头不绕回；弹簧 0.3 s 内到位、不冲过头
    check(FaceOverview.step(0, -1, count: 9) == 0 && FaceOverview.step(8, 1, count: 9) == 8 && FaceOverview.step(3, 1, count: 9) == 4, "总览挪格到头停")
    var sx: CGFloat = 0, sv: CGFloat = 0, over = false
    for _ in 0..<18 { (sx, sv) = FaceOverview.spring(sx, sv, to: 1, dt: 1.0 / 60); if sx > 1.0001 { over = true } }
    check(abs(sx - 1) < 0.03 && !over, "总览弹簧临界阻尼")

    // 正在播放：解析、进度、暂停 30 秒后收起
    let np0 = NowPlayingLogic.parse("playing\t歌\t人\t200,5\t50", durationScale: 1, now: 0)
    check(np0?.title == "歌" && np0?.duration == 200.5 && np0?.playing == true, "正在播放：解析含小数逗号")
    check(NowPlayingLogic.parse("stopped", durationScale: 1, now: 0) == nil, "正在播放：停止＝没有")
    if var np = np0 {
        check(NowPlayingLogic.progress(np, now: 50.25).map { abs($0 - 0.5) < 1e-9 } == true, "正在播放：进度随时间走")
        np.playing = false
        check(NowPlayingLogic.active(np, lastPlayingAt: 0, now: 29) && !NowPlayingLogic.active(np, lastPlayingAt: 0, now: 31), "正在播放：暂停 30 秒后收起")
    }
    // 窗口位置记忆：屏外放弃；部分在屏外钳回；宽度钳进范围
    let scr = [CGRect(x: 0, y: 0, width: 1440, height: 860), CGRect(x: 1440, y: 100, width: 1920, height: 1080)]
    let offScreen = WindowFrameStore.restore([5000, 5000, 300], visible: scr) == nil && WindowFrameStore.restore(nil, visible: scr) == nil && WindowFrameStore.restore([1, 2], visible: scr) == nil
    check(offScreen, "窗口位置：屏外/坏数据放弃")
    let wr = WindowFrameStore.restore([1400, -50, 300], visible: scr)!
    check(wr.width == 300 && abs(wr.height - 300 / Pet.aspect) < 1e-9 && scr[1].contains(wr), "窗口位置：跨屏时钳进重叠最多的那块")
    check(WindowFrameStore.restore([100, 100, 5], visible: scr)!.width == Pet.minWidth && WindowFrameStore.restore([100, 100, 9999], visible: scr)!.width == Pet.maxWidth, "窗口位置：宽度钳进范围")
    // 行事历：挑下一个（定时的优先、已结束的不要、全天垫底）与时间段写法
    let t0 = Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 18, hour: 10, minute: 0))!
    func ev(_ n: String, _ h: Int, _ m: Int, _ eh: Int, _ em: Int, allDay: Bool = false) -> NextEvent {
        NextEvent(title: n, start: Calendar.current.date(bySettingHour: h, minute: m, second: 0, of: t0)!,
                  end: Calendar.current.date(bySettingHour: eh, minute: em, second: 0, of: t0)!, allDay: allDay)
    }
    let evs = [ev("allday", 0, 0, 23, 59, allDay: true), ev("late", 15, 0, 16, 0), ev("past", 8, 0, 9, 0), ev("early", 10, 30, 11, 0)]
    let picked = CalendarLogic.pick(evs, now: t0)?.title == "early" && CalendarLogic.pick([evs[0], evs[2]], now: t0)?.title == "allday" && CalendarLogic.pick([evs[2]], now: t0) == nil
    check(picked, "行事历：挑下一个行程")
    // 行事历：时间段写法（時制照系統：24 小時照舊補零「10:30–11:00」「09:05–18:00」；12 小時帶上午／下午、小時不補零）
    let am = Face.formatter("hmm").amSymbol ?? "AM", pm = Face.formatter("hmm").pmSymbol ?? "PM"
    let rSame = CalendarLogic.range(evs[3]), rCross = CalendarLogic.range(ev("x", 9, 5, 18, 0))
    let ok24 = !Face.uses12Hour && rSame == "10:30–11:00" && rCross == "09:05–18:00"
    let ok12 = Face.uses12Hour && rSame.contains("10:30") && rSame.contains("11:00") && rSame.contains(am)
        && rCross.contains("9:05") && !rCross.contains("09:05") && rCross.contains("6:00") && !rCross.contains("18:00") && rCross.contains(am) && rCross.contains(pm)
    check(ok24 || ok12, "行事历：时间段写法（\(Face.uses12Hour ? 12 : 24) 小时制：\(rSame)、\(rCross)）")
    let tiles4 = CalendarLogic.tile(auth: .notDetermined, on: true, event: nil) == .notConnected && CalendarLogic.tile(auth: .denied, on: true, event: nil) == .denied
        && CalendarLogic.tile(auth: .fullAccess, on: true, event: nil) == .empty && CalendarLogic.tile(auth: .fullAccess, on: false, event: evs[3]) == .notConnected
        && CalendarLogic.tile(auth: .fullAccess, on: true, event: evs[3]) == .event(evs[3])
    check(tiles4, "行事历：四种状态")
    // 连线过场：0.3 秒淡入到 1、淡出到 0
    var oa: CGFloat = 0
    for _ in 0..<18 { oa = CarPlayOverlayState.nextAlpha(oa, target: 1, dt: 1.0 / 60) }
    check(oa == 1, "连线过场 0.3 秒淡入")
    for _ in 0..<18 { oa = CarPlayOverlayState.nextAlpha(oa, target: 0, dt: 1.0 / 60) }
    check(oa == 0, "连线过场 0.3 秒淡出")
    // 手势仲裁：起手决定、整个手势含惯性锁定、捏合让位
    do {
        var a = ScrollArbiter()
        var calls = 0
        let body: () -> GestureTarget = { calls += 1; return .rotate }
        let screen: () -> GestureTarget = { calls += 1; return .carplay }
        var t = a.route(now: 0, began: true, momentum: false, ended: false, momentumEnded: false, dx: 5, dy: 0, pinching: false, classify: body)
        check(t == .rotate && calls == 1, "仲裁：机身起手＝转身体")
        t = a.route(now: 0.02, began: false, momentum: false, ended: false, momentumEnded: false, dx: 5, dy: 0, pinching: false, classify: screen)
        check(t == .rotate && calls == 1, "仲裁：手势中途滑进屏幕仍是转身体（不重判）")
        t = a.route(now: 0.05, began: false, momentum: false, ended: true, momentumEnded: false, dx: 0, dy: 0, pinching: false, classify: screen)
        t = a.route(now: 0.07, began: false, momentum: true, ended: false, momentumEnded: false, dx: 9, dy: 0, pinching: false, classify: screen)
        check(t == .rotate && calls == 1, "仲裁：惯性沿用起手的目标")
        t = a.route(now: 0.09, began: false, momentum: true, ended: false, momentumEnded: true, dx: 0, dy: 0, pinching: false, classify: screen)
        check(t == .rotate && a.target == nil, "仲裁：惯性结束后清锁定")
        t = a.route(now: 0.5, began: false, momentum: true, ended: false, momentumEnded: false, dx: 3, dy: 0, pinching: false, classify: screen)
        check(t == .none, "仲裁：孤立的惯性不开启新手势")
        t = a.route(now: 1.0, began: true, momentum: false, ended: false, momentumEnded: false, dx: 2, dy: 0, pinching: false, classify: screen)
        check(t == .carplay, "仲裁：直播屏幕起手＝CarPlay")
        t = a.route(now: 1.02, began: false, momentum: false, ended: false, momentumEnded: false, dx: 2, dy: 0, pinching: true, classify: body)
        check(t == .none, "仲裁：捏合确认后滑动让位")
        var w = ScrollArbiter()   // 无 phase 的滚轮：间隔 >0.25 s 算新手势
        _ = w.route(now: 0, began: false, momentum: false, ended: false, momentumEnded: false, dx: 1, dy: 0, pinching: false, classify: body)
        t = w.route(now: 0.4, began: false, momentum: false, ended: false, momentumEnded: false, dx: 1, dy: 0, pinching: false, classify: { .none })
        check(t == .none, "仲裁：无 phase 滚轮停顿后重新判定")
        var c = ScrollArbiter()
        _ = c.route(now: 0, began: true, momentum: false, ended: false, momentumEnded: false, dx: 4, dy: 0, pinching: false, classify: body)
        check(!c.committed, "仲裁：小于 12 pt 不算确定在滑")
        _ = c.route(now: 0.02, began: false, momentum: false, ended: false, momentumEnded: false, dx: 10, dy: 0, pinching: false, classify: body)
        check(c.committed, "仲裁：累计超过 12 pt 算确定在滑")
    }
    // 机身朝向：窗口在右朝左、在左朝右；跟随有视差、有 ±25° 夹限；死区不抖；正面固定恒 0；走开 2 s 后回基准
    do {
        let d = Aim.deg
        let right = Aim.baseline(windowMidX: 1.0, screenMidX: 0.5, screenHalfWidth: 0.5)
        let left = Aim.baseline(windowMidX: 0.0, screenMidX: 0.5, screenHalfWidth: 0.5)
        check(right < -17 * d && right > -19 * d && abs(left + right) < 1e-9, "朝向：贴右边约 -18°、左右对称")
        check(Aim.baseline(windowMidX: 0.5, screenMidX: 0.5, screenHalfWidth: 0.5) == 0, "朝向：居中不倾斜")
        check(ViewMode(rawValue: "wall") == .wall && ViewMode.wall.rawValue == "wall" && ViewMode.allCases.count == 3, "朝向：挂墙存取来回一致")
        check(Pet.aspect(for: .wall) < 1 && Pet.aspect(for: .wall) > 0.9 && Pet.aspect(for: .auto) == Pet.standAspect, "挂墙窗口近正方，其它照旧")
        let wc = HomeViewModel.wallScreenCenter
        check(abs(wc.x) < 1e-6 && wc.y > 9.5 && wc.y < 10.6 && wc.z > 4.28, "挂墙：扶正后的屏幕中心在铰链上方、往前")
        check(abs(Aim.followTarget(gazeX: 1, baseline: 0, maxDegrees: 25) - 25 * d) < 1e-9, "朝向：跟随夹在 25°")
        check(Aim.followTarget(gazeX: 0, baseline: right, maxDegrees: 25) < 0, "朝向：人在镜头正前、桌宠在右 → 朝左（视差）")
        var a = Aim(); var t = 0.0
        for _ in 0..<240 { t += 1.0 / 60; _ = a.step(now: t, dt: 1.0 / 60, mode: .auto, following: true, present: true, gazeX: 0.6, baseline: 0, maxDegrees: 25) }
        let settledAt = a.angle
        check(a.settled && settledAt > 15 * d, "朝向：4 秒内落定到人的方向")
        for _ in 0..<60 { t += 1.0 / 60; _ = a.step(now: t, dt: 1.0 / 60, mode: .auto, following: true, present: true, gazeX: 0.63, baseline: 0, maxDegrees: 25) }
        check(abs(a.angle - settledAt) < 1e-6, "朝向：小于 3° 的移动不跟（不抖）")
        var maxV = 0.0, prev = a.angle
        for _ in 0..<60 { t += 1.0 / 60; let x = a.step(now: t, dt: 1.0 / 60, mode: .auto, following: true, present: false, gazeX: 0, baseline: 0, maxDegrees: 25); maxV = max(maxV, abs(x - prev) * 60); prev = x }
        check(abs(a.angle - settledAt) < 0.5 * d, "朝向：人走开先停 2 s")
        for _ in 0..<360 { t += 1.0 / 60; let x = a.step(now: t, dt: 1.0 / 60, mode: .auto, following: true, present: false, gazeX: 0, baseline: 0, maxDegrees: 25); maxV = max(maxV, abs(x - prev) * 60); prev = x }
        check(abs(a.angle) < 0.5 * d, "朝向：之后回到基准")
        check(maxV <= Aim.maxSpeed + 1e-6, "朝向：角速度不超过 70°/s")
        var f = Aim()
        for _ in 0..<120 { t += 1.0 / 60; _ = f.step(now: t, dt: 1.0 / 60, mode: .front, following: true, present: true, gazeX: 1, baseline: right, maxDegrees: 25) }
        check(f.angle == 0, "朝向：正面固定恒为 0")
    }
    // 番茄鐘：專注 → 短休息 ×3，第 4 個專注後長休息，休息後回專注；停止後不再前進
    do {
        var p = Pomodoro()
        check(p.start() == .focus && p.displayRound == 1, "番茄钟：开始＝第 1 轮专注")
        var seq: [PomodoroPhase] = []
        for _ in 0..<8 { if let a = p.advance() { seq.append(a.next) } }
        check(seq == [.shortBreak, .focus, .shortBreak, .focus, .shortBreak, .focus, .longBreak, .focus], "番茄钟：四轮后长休息，再回专注")
        check(p.displayRound == 1, "番茄钟：长休息后轮数归零")
        p.stop()
        check(p.advance() == nil && !p.active, "番茄钟：停止后不再前进")
        check(PomodoroPhase.focus.seconds == 1500 && PomodoroPhase.shortBreak.seconds == 300 && PomodoroPhase.longBreak.seconds == 900, "番茄钟：25／5／15 分钟")
    }
    // 两指类型：同向平移＝滑动；沿连线相向／相背＝捏合（一指不动也算）；扭转＝都不做；没走够＝未定；换手指重来
    do {
        func run(_ a: [(Double, Double)], _ b: [(Double, Double)]) -> TwoFingerKind {
            var c = TwoFingerClassifier(); var k = TwoFingerKind.undecided
            for (p, q) in zip(a, b) { k = c.feed(id0: 7, x0: p.0, y0: p.1, id1: 9, x1: q.0, y1: q.1) }
            return k
        }
        check(run([(0.40, 0.50), (0.40, 0.47)], [(0.55, 0.50), (0.55, 0.47)]) == .scroll, "两指：一起往下＝滑动")
        check(run([(0.40, 0.50), (0.43, 0.505)], [(0.55, 0.50), (0.575, 0.497)]) == .scroll, "两指：一起往右（一指略慢）＝滑动")
        check(run([(0.40, 0.50), (0.385, 0.50)], [(0.55, 0.50), (0.565, 0.50)]) == .pinch, "两指：相背张开＝捏合")
        check(run([(0.40, 0.50), (0.40, 0.50)], [(0.55, 0.50), (0.535, 0.50)]) == .pinch, "两指：一指不动另一指靠近＝捏合")
        check(run([(0.40, 0.50), (0.40, 0.488)], [(0.55, 0.50), (0.55, 0.512)]) == .twist, "两指：扭转＝都不做")
        check(run([(0.40, 0.50), (0.403, 0.50)], [(0.55, 0.50), (0.553, 0.50)]) == .undecided, "两指：没走够 1.5 mm 先不判")
        check(run([(0.40, 0.50), (0.396, 0.486)], [(0.55, 0.50), (0.556, 0.487)]) == .scroll, "两指：往下滑时手指略张开＝还是滑动（不误判成捏合）")   // l10n-ignore
        // 一指不动、另一指移动（2.0 改 2 倍后的回归）：沿连线偏 5°／15°／40° 都是捏合；跟连线差很多（往上下走）是滑动
        check(run([(0.40, 0.50), (0.40, 0.50)], [(0.55, 0.50), (0.535, 0.5013)]) == .pinch
              && run([(0.40, 0.50), (0.40, 0.50)], [(0.55, 0.50), (0.5355, 0.504)]) == .pinch
              && run([(0.40, 0.50), (0.4005, 0.50)], [(0.55, 0.50), (0.535, 0.50)]) == .pinch
              && run([(0.40, 0.50), (0.40, 0.50)], [(0.55, 0.50), (0.5385, 0.4904)]) == .pinch
              && run([(0.40, 0.50), (0.40, 0.50), (0.40, 0.50), (0.40, 0.50)], [(0.55, 0.50), (0.545, 0.50), (0.54, 0.50), (0.535, 0.50)]) == .pinch,
              "两指：一指不动、另一指斜着靠近（偏 5°／15°／40°、慢慢捏）＝捏合")   // l10n-ignore
        check(run([(0.40, 0.50), (0.40, 0.50)], [(0.55, 0.50), (0.552, 0.485)]) == .scroll
              && run([(0.40, 0.50), (0.401, 0.499)], [(0.55, 0.50), (0.55, 0.514)]) == .scroll
              && run([(0.40, 0.50), (0.398, 0.485)], [(0.55, 0.50), (0.555, 0.486)]) == .scroll
              && run([(0.40, 0.50), (0.4, 0.47)], [(0.55, 0.50), (0.553, 0.471)]) == .scroll,
              "两指：上下滑（一指先走、手指略张开）仍是滑动，不误判成捏合")   // l10n-ignore
        var c = TwoFingerClassifier()
        _ = c.feed(id0: 1, x0: 0.4, y0: 0.5, id1: 2, x1: 0.55, y1: 0.5)
        _ = c.feed(id0: 2, x0: 0.565, y0: 0.5, id1: 1, x1: 0.385, y1: 0.5)   // 数组里换位：按 id 配对
        check(c.kind == .pinch, "两指：按手指 id 配对，换位不影响")
        _ = c.feed(id0: 3, x0: 0.4, y0: 0.5, id1: 4, x1: 0.55, y1: 0.5)
        check(c.kind == .undecided, "两指：换了手指就重新判定")
    }
    // 來電卡：接收器 JSON → 卡片狀態與按鍵；F5 按住說話吸收重複的按下／放開
    do {
        let ring = PhoneCallInfo.parse(#"{"incoming":true,"name":"Alice","number":"+491701234567","state":"ringing","type":"call","uuid":"uuid-1"}"#)
        check(ring?.isIncomingRing == true && ring?.title(hidden: false) == "Alice" && ring?.actions == [.decline, .answer], "来电：响铃给拒接＋接听")
        check(ring?.subtitle(carrier: "o2").contains("+491701234567") == true, "来电：有名字时小字带号码")
        let active = PhoneCallInfo.parse(#"{"state":"active","type":"call","number":"110"}"#)
        check(active?.actions == [.hangUp] && active?.title(hidden: false) == "110" && active?.isIncomingRing == false, "来电：通话中只给挂断")
        let idle = PhoneCallInfo.parse(#"{"state":"idle","type":"call"}"#)
        check(idle?.showsCard == false && idle?.actions.isEmpty == true, "来电：idle 收卡")
        check(PhoneCallInfo.parse(#"{"type":"nowplaying"}"#) == nil, "来电：别的消息不解析")
        check(PhoneCallInfo(state: .ringing).title(hidden: false).isEmpty == false, "来电：没名字没号码也有标题")
        // 待決項拍板（2026-11-07）：訪客時只寫「來電」，不露名字、號碼、電信商；接聽／拒接照舊
        if let r = ring {
            let t = r.title(hidden: true), sub = r.subtitle(carrier: "o2", hidden: true)
            check(t == L("call.state.ringing", "来电") && !t.contains("Alice") && sub.isEmpty && r.actions == [.decline, .answer],
                  "来电：访客只显示「来电」，名字号码电信商都不露，接听拒接照旧")   // l10n-ignore
        }
        check(CellularInfo.parse(#"{"carrier":"o2","signal":4,"type":"cellular"}"#) == CellularInfo(carrier: "o2", signal: 4), "电信商与讯号")
        var k = SiriHoldKey()
        check(k.press(now: 0) && !k.press(now: 0.01), "F5：重复的按下只算一次")
        check(!k.overdue(now: 29) && k.overdue(now: 30), "F5：按住 30 秒自动放开")
        check(k.release() && !k.release(), "F5：重复的放开只算一次")
    }
    // CarPlay 圓角：平常的連線原樣直通；學圓角那一次（learning）收到遮罩才縮放
    do {
        let side = 64, r = 40.0
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8, samplesPerPixel: 1,
                                   hasAlpha: false, isPlanar: false, colorSpaceName: .deviceWhite, bytesPerRow: side, bitsPerPixel: 8)!
        for y in 0..<side { for x in 0..<side {
            let dx = max(0, r - (Double(x) + 0.5)), dy = max(0, r - (Double(y) + 0.5))
            rep.bitmapData![y * side + x] = UInt8((max(0, min(1, r - (dx * dx + dy * dy).squareRoot() + 0.5)) * 255).rounded())
        } }
        let png = rep.representation(using: .png, properties: [:])!.base64EncodedString()
        let dev = MTLCreateSystemDefaultDevice()!
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm_srgb, width: 64, height: 64, mipmapped: false)
        d.usage = [.shaderRead]; d.storageMode = .shared
        let src = dev.makeTexture(descriptor: d)!
        let fit = CornerFit.shared
        fit.handle(["type": "cornerMask", "negotiated": false, "learning": false], videoWidth: 1088, device: dev)
        check(fit.apply(src) === src && fit.toVideo(u: 0.01, v: 0.5) != nil, "圆角：平常的连线原样直通")
        fit.handle(["type": "cornerMask", "negotiated": true, "learning": true, "png": png], videoWidth: 1088, device: dev)
        check(fit.scale < 0.95 && fit.apply(src) !== src && fit.toVideo(u: 0.01, v: 0.5) == nil, "圆角：学圆角那一次缩放补黑（k=\(String(format: "%.3f", fit.scale))）")
        fit.handle(["type": "cornerMask", "negotiated": false, "learning": false], videoWidth: 1088, device: dev)
        check(fit.apply(src) === src, "圆角：下一次平常的连线又原样直通")
    }
    do {   // 換手機：同一條 WS 上 ended → started → 幀，要再報一次 live
        let ended = #"{"type":"session","state":"ended"}"#, started = #"{"type":"session","state":"started"}"#
        check(FirstFrameLatch.replay([nil, nil]) == [true, false], "首幀：同一會話只報一次 live")
        check(FirstFrameLatch.replay([nil, ended, started, nil, nil]) == [true, true, false], "首幀：換手機 ended→started 之後的第一幀再報 live")
        check(FirstFrameLatch.replay([nil, started, nil]) == [true, true], "首幀：只收到 started 也重新報 live")
        check(FirstFrameLatch.replay([nil, #"{"type":"nowplaying"}"#, nil]) == [true, false], "首幀：別的文字不重置")
    }
    ShellSelfTest.run(check)   // 2.0: 外殼導覽與多組計時器（Shell/ShellNav.swift）
    HomeAppSelfTest.run(check)   // 2.0: 家庭 App（Shell/HomeAppModel.swift）
    HomeShortcut.selftest(check)   // B 方案：捷徑深連結（Shell/HomeShortcut.swift）
    GlassSelfTest.run(check)   // 2.0 glass: 玻璃的形狀辨識、融合遮罩（Design/GlassCalibrate.swift）
    HPAccessibilitySelfTest.run(check)   // 2.0 glass: WCAG 對比（Design/HPAccessibility.swift）
    ClioSelftest.run(check)   // 2.0: ClioTalk（ClioTalk/ClioSelftest.swift）
    for f in MessagesSelftest.run() { check(false, f) }   // 2.0: 訊息資料層（Messages/MessagesSelftest.swift）
    peopleSelftest(check)   // 2.0: 谁在看（People/PeopleSelftest.swift）
    ProductShot.selftest(check); DeviceFinish.selftest(check)   // 2.0 device
    HelloSelfTest.run(check); HelloProduct.selftest(check)   // 2.0 hello（Hello/）
    ShellAccessibility.selftest(check)   // 2.0: P05 畫出來的螢幕的輔助使用（Shell/ShellAccessibility.swift）
    GridSelftest.run(check)   // 10-grid: 網格與對齊合約的版面自檢（Design/GridSelftest.swift）
    ShellIntegrationSelftest.run(check)   // 2.0: 個人內容的門、訊息確認、Live Activity 隱私（Shell/ShellIntegrationSelftest.swift）
    RemoteSelftest.run(check)   // 2.0 idle: 網頁串流的配對、加密、區網、撤銷（Remote/RemoteSelftest.swift）
    PromoSelfTest.run(check)   // 2.0 promo：Handoff、烹飪、宣傳片時間軸（Shell/Apps/PromoDemo.swift）
    log(ok ? "selftest OK" : "selftest FAIL"); exit(ok ? 0 : 1)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
delegate.endpoint = arg("--endpoint")
if let s = arg("--size"), let w = Double(s) { delegate.initialWidth = max(Pet.minWidth, min(Pet.maxWidth, CGFloat(w))); delegate.sizeGiven = true }
if CommandLine.arguments.contains("--apart") { delegate.initialApart = true }
if let s = arg("--apart-t"), let t = Double(s) { delegate.initialApartT = CGFloat(max(0, min(1, t))) }
if let s = arg("--part") { delegate.initialPart = AnatomyPart(rawValue: s) }   // 例：--part logicBoard
if CommandLine.arguments.contains("--dark") { NSApplication.shared.appearance = NSAppearance(named: .darkAqua) }   // 快照：深色外观
if let s = arg("--yaw"), let y = Double(s) { delegate.initialYaw = CGFloat(y) }
if let s = arg("--pitch"), let y = Double(s) { delegate.initialPitch = CGFloat(y) }
delegate.snapshotPath = arg("--snapshot")
delegate.snapshotGlancePath = arg("--snapshot-glance")
delegate.snapshotBlinkPath = arg("--snapshot-blink")
if let s = arg("--snapshot-at"), let t = Double(s) { delegate.snapshotDelay = max(0.3, t) }   // 拍开机 hello 用
if let s = arg("--bench"), let t = Double(s) { delegate.benchSeconds = max(1, t) }
if let s = arg("--view") { delegate.initialView = s }   // 除錯：front|side|back|above，走選單同一條路   // 效能基準：跑 N 秒後印統計並結束
if let s = arg("--style") {
    guard let st = FaceStyle(rawValue: s) else {
        log("--style 只认：\(FaceStyle.allCases.map(\.rawValue).joined(separator: " "))"); exit(2)
    }
    // 舊腳本的 --style embossed／alarmClock／about：換成併進去的那款，並設好對應的選項
    let mig = st.migratedOptions
    if let m = mig.material { faceOptionSnapshotOverride.material = m }
    if let l = mig.layout { faceOptionSnapshotOverride.layout = l }
    delegate.faceStyle = CommandLine.arguments.contains("--style-raw") ? st : st.inLineup   // 2.0: 第三輪快照：不在陣容裡的舊款（homeModular）也拍得到
}
if arg("--demo-worldclock") == "face" { delegate.faceStyle = .world }   // 快照用：「世界」錶面（城市見 Shell/Apps/AppDemoFlags.swift）
if let s = arg("--typograph-material") {   // 快照用：flat embossed
    guard let m = TypographMaterial(rawValue: s) else { log("--typograph-material 只认：flat embossed"); exit(2) }
    faceOptionSnapshotOverride.material = m
}
if let s = arg("--system6-layout") {   // 快照用：finder alarmClock about
    guard let l = System6Layout(rawValue: s) else { log("--system6-layout 只认：finder alarmClock about"); exit(2) }
    faceOptionSnapshotOverride.layout = l
}
if let s = arg("--cluster-layout") {   // 快照用：a b c
    guard let l = ClusterLayout(rawValue: s) else { log("--cluster-layout 只认：a b c"); exit(2) }
    clusterLayoutSnapshotOverride = l
}
if let s = arg("--cluster-state") {   // 快照用：normal memory thermal battery disk offline
    guard let st = ClusterState(rawValue: s) else { log("--cluster-state 只认：normal memory thermal battery disk offline"); exit(2) }
    clusterStateSnapshotOverride = st
}
if CommandLine.arguments.contains("--cluster-live") { clusterSnapshotLive = true }   // 快照用：儀表不用設計稿的示範值，取兩次真讀值
if let s = arg("--clock") { islandSnapshotOverride.clock = ClockStyle(rawValue: s) }
if let s = arg("--numeral-glass") {   // 實驗：大數字玻璃 sdf|system（Faces/GlyphGlass.swift；同隱藏偏好 HomePlayNumeralGlass）
    guard let m = NumeralGlassMode(rawValue: s) else { log("--numeral-glass 只认：sdf system"); exit(2) }
    NumeralGlassMode.override = m
}
if let s = arg("--clock-look") { ClockLook.snapshotOverride = ClockLook.parse(s) }   // 快照用：字体与颜色   // 快照用：島錶面时钟样式 bold thin stacked compact
if let s = arg("--bg") { islandSnapshotOverride.bg = IslandBackground(rawValue: s) }     // daytime flow photo solid black
if let s = arg("--era") { islandSnapshotOverride.era = ["1988": Era.y1988, "2002": .y2002, "2026": .y2026][s] }
if let s = arg("--capsule"), let m = CapsuleMaterial(rawValue: s) { capsuleMaterialSetting = m }   // 快照用：auto black smoke glass
if CommandLine.arguments.contains("--increase-contrast") { HPAccessibility.forceIncreaseContrast = true }   // 快照用：增加對比（同 HOMEPLAY_INCREASE_CONTRAST=1，不碰系統設定）
if let s = arg("--siri") { SiriOrbState.snapshotPhase = s }   // 快照用：listen | think
if arg("--snapshot") != nil || arg("--screen-png") != nil || ProcessInfo.processInfo.environment["HOMEPLAY_DEMO"] != nil { Face.demoData = true }   // 快照：Home Modular 用示範資料
// 快照：眼睛固定張開。眨眼是由執行時鐘決定的，控制中心的模糊背景會跟著每幀不同——金幀永遠對不上（2026-11-09 實測）。
if arg("--screen-png") != nil { Face.blinkOverride = 1 }
if let s = arg("--timer"), let t = Double(s) { delegate.timerSeconds = t }   // 快照用：开一个 t 秒的计时器
if let s = arg("--music") { delegate.musicTest = s; NowPlayingPoller.disabled = true }   // 快照用：固定一个「正在播放」
if CommandLine.arguments.contains("--connecting") { CarPlayOverlayState.forced = true }
if CommandLine.arguments.contains("--pairing-code") {   // 快照用：插線配對的數字比對那一格
    CarPlayOverlayState.bluetoothPairing = true; CarPlayOverlayState.pairPhase = "confirm"; CarPlayOverlayState.pairCode = "482913"
    CarPlayOverlayState.pairDeadline = CACurrentMediaTime() + 27; CarPlayOverlayState.forced = true
}
if CommandLine.arguments.contains("--wifi-help") {   // 快照用：手機報了可用卻沒從 Wi-Fi 連回
    CarPlayOverlayState.wifiHelp = true; CarPlayOverlayState.forced = true
}
if let r = arg("--connect-reason") {   // 快照用：排障卡（macFirewall localNetwork carPlayConsent ssidUnknown inboundBlocked wifiNoConnectBack）
    CarPlayOverlayState.wifiHelp = true; CarPlayOverlayState.forced = true
    CarPlayOverlayState.connectReason = r; CarPlayOverlayState.helpSSID = arg("--help-ssid") ?? ""
    CarPlayOverlayState.helpSince = CACurrentMediaTime() - (arg("--help-age").flatMap(Double.init) ?? 0)   // --help-age 45：40 秒後的那一格
}
if CommandLine.arguments.contains("--pairing-no-response") {   // 快照用：叫不到手機
    CarPlayOverlayState.bluetoothPairFailed = true; CarPlayOverlayState.pairFailReason = "noResponse"; CarPlayOverlayState.forced = true
}
if CommandLine.arguments.contains("--pairing-success") {   // 快照用：配對成功那一格（綠色滿環）
    CarPlayOverlayState.forced = true; CarPlayOverlayState.snapshotPaired = true
}
if CommandLine.arguments.contains("--pairing") { CarPlayOverlayState.needsPairing = true; CarPlayOverlayState.forced = true }   // 快照用：强制显示连线中过场
if CommandLine.arguments.contains("--pairing-success") { CarPlayOverlayState.pairingSucceededAt = CACurrentMediaTime(); CarPlayOverlayState.forced = true }   // 快照用：刚配对成功
if let s = arg("--pair-host") { CarPlayOverlayState.pairingHost = s }   // 快照用：蓝牙配对卡上的 Mac 名称
if CommandLine.arguments.contains("--onboarding") { Onboarding.forced = true }   // 快照用：强制显示第一次的操作提示
if let s = arg("--demo-onboarding") {   // 2.0 快照用：首次設定的某一頁（假資料，不讀也不寫偏好；Setup/SetupFlow.swift）
    guard let p = SetupPage(rawValue: s) else { log("--demo-onboarding 只认：welcome language permissions carplay look done"); exit(2) }
    SetupFlow.demo = p; SetupFlow.active = true; SetupFlow.page = p; SetupFlow.refreshPermissions(force: true)
}
if let s = arg("--demo-intro") {   // 2.0 快照用：手勢引導的某一頁＋輸入方式（--demo-intro home,touch；不讀也不寫偏好；Intro/IntroGuide.swift）
    let parts = s.split(separator: ",").map(String.init)
    guard let p = IntroPage(rawValue: parts[0]), parts.count < 2 || IntroInput(rawValue: parts[1]) != nil else {
        log("--demo-intro 只认：welcome home switcher control swipe pet more[,mouse|trackpad|touch]"); exit(2)
    }
    IntroGuide.demo = p; IntroGuide.demoInput = parts.count > 1 ? IntroInput(rawValue: parts[1]) : nil
    Onboarding.forced = true; Onboarding.active = true; IntroGuide.begin()
}
if CommandLine.arguments.contains("--intro-hint") { IntroHint.forced = true }   // 快照用：升級提示卡（配 --home）
if let s = arg("--event") { delegate.eventTest = s; CalendarSource.disabled = true }   // 快照用：固定一个「下一个行程」
if CommandLine.arguments.contains("--banner") { delegate.showBanner = true }   // 快照用：显示「时间到了」横幅
if CommandLine.arguments.contains("--messages-probe") { MessagesDemo.probe() }
if CommandLine.arguments.contains("--photos-probe") { PhotosWidgetSource.probe(); exit(0) }   // 2.0: 照片小工具只印筆數（Shell/PhotosWidget.swift）   // 2.0: 只印筆數的讀取路徑自檢
if let s = arg("--messages-demo") {   // 2.0: 快照用：訊息畫面（list|thread|fda|nodb），示範資料
    guard MessagesDemo.model(s) != nil else { log("--messages-demo 只认：list thread confirm fda nodb"); exit(2) }
    MessagesDemo.mode = s
}
// 2.0 隱私：任何快照／示範出圖一律不讀真的訊息與聯絡人（截圖可能被存檔、比對或公開）
if SnapshotPrivacy.active, MessagesDemo.mode == nil { MessagesDemo.mode = "list" }
if CommandLine.arguments.contains("--hello") { delegate.forceHello = true }     // 快照用：强制开机写 hello
if CommandLine.arguments.contains("--overview") { FaceOverview.forced = true }   // 快照用：长按换錶面总览
delegate.photosDir = arg("--photos")
if let s = arg("--hour"), let h = Double(s) { delegate.hourOverride = max(0, min(23.99, h)) }
if let s = arg("--pointer") {   // 快照用：固定好奇时眼珠方向，例如 0,0
    let v = s.split(separator: ",").compactMap { Double($0) }
    if v.count == 2 { Face.pointerOverride = CGPoint(x: max(-1, min(1, v[0])), y: max(-1, min(1, v[1]))) }
}
if let s = arg("--permission"), let k = PermissionKind(rawValue: s) {   // 快照：权限说明卡（--perm-state intro|waiting|granted|denied）
    PermissionPrimer.forced = true; PermissionPrimer.kind = k
    switch arg("--perm-state") ?? "intro" {
    case "waiting": PermissionPrimer.phase = .waiting
    case "granted": PermissionPrimer.phase = .granted
    case "denied": PermissionPrimer.phase = .denied
    default: PermissionPrimer.phase = .intro
    }
}
if CommandLine.arguments.contains("--people-demo") { PeopleOverlay.demoGreeting = true }   // 快照（2.0）：个人问候「早安，名字」
if CommandLine.arguments.contains("--people-demo-enroll") {   // 快照（2.0）：录脸引导，--people-demo-progress 0…1
    PeopleOverlay.demoEnroll = true
    if let v = arg("--people-demo-progress").flatMap(Double.init) { PeopleOverlay.demoProgress = max(0, min(1, v)) }
}
if let s = arg("--window-x"), let v = Double(s) { PetView.windowXOverride = max(0, min(1, v)) }   // 快照：窗口横向位置 0…1
// 快照／基准默认当作窗口居中：官网和文档的产品图不该因为拍照时窗口落在哪而歪
else if arg("--snapshot") != nil || arg("--bench") != nil { PetView.windowXOverride = 0.5 }
if let s = arg("--view-mode"), let m = ViewMode(rawValue: s) { ViewMode.override = m }
if let s = arg("--gaze") {      // 快照用：模拟追人样本，例如 1,0（右）或 -1,0（左）
    let v = s.split(separator: ",").compactMap { Double($0) }
    if v.count == 2 { delegate.gazeTest = (CGFloat(max(-1, min(1, v[0]))), CGFloat(max(-1, min(1, v[1])))) }
}
if let s = arg("--time") {      // 快照用：固定屏幕上的时间，例如 23:12（夜里的氛围图才合理）
    let v = s.split(separator: ":").compactMap { Int($0) }
    if v.count >= 2 { snapshotDateOverride = Calendar.current.date(bySettingHour: v[0], minute: v[1], second: v.count > 2 ? v[2] : 0, of: Date()) }   // 也收 H:mm:ss（停走秒針）
}
if OfficialDemo.on { snapshotDateOverride = OfficialDemo.date(time: arg("--time")) }   // 2.0: 官方原圖的日期（2026-04-01 星期三 10:09）
if CommandLine.arguments.contains("--near") { delegate.forceNear = true }
if let s = arg("--finish") {
    guard let f = Finish(rawValue: s) else {
        log("--finish 只认：\(Finish.allCases.map(\.rawValue).joined(separator: " "))"); exit(2)
    }
    delegate.finish = f
}
if let s = arg("--face") {
    guard let e = Expression(name: s) else {
        log("--face 只认：\(Expression.allCases.map(\.rawValue).joined(separator: " "))"); exit(2)
    }
    delegate.lockedFace = e
}
if let s = arg("--at") {
    let c = s.split(separator: ",").compactMap { Double($0) }
    if c.count == 2 { delegate.origin = NSPoint(x: c[0], y: c[1]) }
}
app.delegate = delegate
app.run()

