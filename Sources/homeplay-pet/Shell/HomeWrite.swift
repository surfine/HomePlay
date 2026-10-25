// 2.0 第四輪（家庭真的能控制）：所有寫入走同一條路——
// 先在本機把磚改成新值（不等幫手，按下就有反應）→ HomeLink.set → 成功就請幫手重讀那個特性（幫手寫完不一定會推新值，
// 實測約 1 秒內沒有 changed）→ 失敗就還原成寫入前的值。家庭 App 的磚、溫控、燈，以及 ClioTalk 的 home_control 都用它。
// 門鈴：幫手把門鈴服務的按鈕事件叫 "doorbell"；收到就接管畫面打開那台門鈴的攝影機（開機時起、不必先開家庭 App）。

import AppKit

/// 寫入要用到的幾件事（selftest 用假的，不碰真的配件）
protocol HomeWriting: AnyObject {
    func value(of id: String) -> HomeValue?
    func applyLocal(characteristic id: String, value: HomeValue)
    func set(characteristic: String, value: Any, completion: ((Bool, String?) -> Void)?)
    func reread(characteristic id: String, completion: ((Bool) -> Void)?)
}
extension HomeLink: HomeWriting {}

enum HomeWrite {
    /// 這一下是訪客裝置點的（主執行緒）
    static var refusesGuest: Bool { RemoteInput.fromGuest }

    /// 寫一個值：本機先改、送出、成功重讀、失敗還原。revertTo：還原成這個（連續調整時是動手前的值），nil＝寫入前快照裡的值。
    /// completion 在主執行緒
    /// guestOK：這個特性訪客可以寫（HomeApp 訪客版裡燈的開關、亮度）
    static func perform(_ id: String, _ value: HomeValue, revertTo: HomeValue? = nil, via w: HomeWriting = HomeLink.shared,
                        guestOK: Bool = false, completion: ((Bool) -> Void)? = nil) {
        // 2.0 idle: 訪客裝置點來的寫入只收燈（使用者 2026-10-25）；門鎖、車庫、保全、其他配件一律拒絕（Remote/RemoteInput.swift）
        if refusesGuest && !guestOK { log("home: 訪客裝置的寫入已拒絕"); completion?(false); return }
        let old = revertTo ?? w.value(of: id)
        w.applyLocal(characteristic: id, value: value)
        w.set(characteristic: id, value: value.jsonAny) { ok, err in
            if ok { w.reread(characteristic: id, completion: nil) }
            else {
                if let old { w.applyLocal(characteristic: id, value: old) }
                log("home: 寫入失敗（已還原）\(err ?? "")")
            }
            completion?(ok)
        }
    }
}

/// 門鈴：有人按就接管畫面
final class HomeDoorbell {
    static let shared = HomeDoorbell()
    private var observer: NSObjectProtocol?
    private var connectedAt = 0.0
    private var lastRing = -1e9
    /// 剛連上的前 5 秒不算（幫手重連時可能補送舊事件）；同一台 20 秒內只接管一次
    static let quiet = 5.0, repeatWindow = 20.0

    func start() {
        guard observer == nil, !HomeApp.demo, HomeLink.helperInstalled else { return }
        HomeLink.shared.start()
        connectedAt = CACurrentMediaTime()
        observer = NotificationCenter.default.addObserver(forName: .homeLinkChanged, object: nil, queue: .main) { [weak self] n in
            guard let ch = n.object as? HomeChange else { return }
            MainActor.assumeIsolated { self?.handle(ch) }
        }
        NotificationCenter.default.addObserver(forName: .homeLinkConnection, object: nil, queue: .main) { [weak self] n in
            if (n.object as? Bool) == true { self?.connectedAt = CACurrentMediaTime() }
        }
    }

    /// 要不要接管（純函式，自檢用）
    static func shouldRing(type: String, now: Double, connectedAt: Double, lastRing: Double) -> Bool {
        type == "doorbell" && now - connectedAt >= quiet && now - lastRing >= repeatWindow
    }

    @MainActor private func handle(_ ch: HomeChange) {
        let now = CACurrentMediaTime()
        guard Self.shouldRing(type: ch.type, now: now, connectedAt: connectedAt, lastRing: lastRing) else { return }
        lastRing = now
        ring(accessory: ch.accessory)
    }

    /// 接管：舊畫面放大＋模糊淡出（外殼的 takeover），換成門鈴攝影機全螢幕
    @MainActor func ring(accessory id: String) {
        guard let v = (NSApp.delegate as? AppDelegate)?.view else { return }
        Shell.beginTakeover(v.face)
        _ = HomeApp.shared.showCameras(id: id)
    }
}

enum HomeWriteSelfTest {
    /// 假的 HomeLink：記下每一步，set 的結果照 ok
    final class Fake: HomeWriting {
        var values: [String: HomeValue] = [:]
        var log: [String] = []
        var ok = true
        func value(of id: String) -> HomeValue? { values[id] }
        func applyLocal(characteristic id: String, value: HomeValue) { values[id] = value; log.append("local \(id)=\(value.raw ?? -1)") }
        func set(characteristic: String, value: Any, completion: ((Bool, String?) -> Void)?) { log.append("set \(characteristic)"); completion?(ok, ok ? nil : "fail") }
        func reread(characteristic id: String, completion: ((Bool) -> Void)?) { log.append("read \(id)"); completion?(true) }
    }

    static func run(_ check: (Bool, String) -> Void) {
        let f = Fake()
        f.values["p"] = HomeValue(bool: false)
        var result: Bool?
        HomeWrite.perform("p", HomeValue(bool: true), via: f) { result = $0 }
        check(f.log == ["local p=1.0", "set p", "read p"] && f.values["p"]?.isOn == true && result == true, "家庭寫入：本機先改 → 送出 → 成功後重讀")
        f.log = []; f.ok = false
        HomeWrite.perform("p", HomeValue(bool: false), via: f) { result = $0 }
        check(f.log == ["local p=0.0", "set p", "local p=1.0"] && f.values["p"]?.isOn == true && result == false, "家庭寫入：失敗就還原、不重讀")
        f.log = []
        f.values["b"] = HomeValue(number: 70)
        HomeWrite.perform("b", HomeValue(number: 40), revertTo: HomeValue(number: 20), via: f)
        check(f.values["b"]?.number == 20, "家庭寫入：連續調整失敗時還原成動手前的值")
        check(HomeDoorbell.shouldRing(type: "doorbell", now: 100, connectedAt: 90, lastRing: -1e9), "門鈴：有人按就接管")
        check(!HomeDoorbell.shouldRing(type: "doorbell", now: 92, connectedAt: 90, lastRing: -1e9), "門鈴：剛連上的補送事件不算")
        check(!HomeDoorbell.shouldRing(type: "doorbell", now: 110, connectedAt: 90, lastRing: 100), "門鈴：20 秒內不重複接管")
        check(!HomeDoorbell.shouldRing(type: "motion", now: 100, connectedAt: 0, lastRing: -1e9), "門鈴：只認門鈴事件")
    }
}
