// 2.0: ClioTalk 的 home_control：用名字（中文、英文都行）找配件、房間或場景，照動作寫進 Home。
// 純邏輯（名字模糊比對、動作解析、哪些動作要先確認、組出要寫的特性）在 ClioHomeControl，--selftest 直接測；
// 真的寫入走 HomeApp 用的同一條路（HomeLink.set／runScene，經「HomePlay Home」小幫手）。
// 開鎖、開車庫門、解除警戒＝替你做的大事：引擎先把動作念給你聽，你說「好」才執行（跟 messages_send 同一道閘門）。
// 隱私：配件與房間的名字不寫日誌。

import AppKit
import Foundation

enum HomeVoiceAction: String, CaseIterable {
    case on, off, setBrightness = "set_brightness", setTemperature = "set_temperature", setPosition = "set_position"
    case lock, unlock, open, close

    /// 模型常寫的別名
    static func parse(_ raw: String) -> HomeVoiceAction? {
        let s = raw.lowercased().trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "-", with: "_").replacingOccurrences(of: " ", with: "_")
        if let a = HomeVoiceAction(rawValue: s) { return a }
        switch s {
        case "turn_on", "switch_on", "power_on": return .on
        case "turn_off", "switch_off", "power_off": return .off
        case "brightness", "dim", "set_level": return .setBrightness
        case "temperature", "set_temp", "temp": return .setTemperature
        case "position", "set_level_position": return .setPosition
        default: return nil
        }
    }
}

enum ClioHomeControl {
    // MARK: 名字比對

    /// 比對用：小寫、繁→簡、去空白與標點與「的」（中英文都能比）
    static func normalized(_ s: String) -> String {
        let lowered = s.lowercased()
        let folded = lowered.applyingTransform(StringTransform("Hant-Hans"), reverse: false) ?? lowered
        // 國字數字換阿拉伯數字（「四键开关二」＝「四键开关2」，兩邊都換所以不影響其他比對）
        let digits: [Character: Character] = ["一": "1", "二": "2", "三": "3", "四": "4", "五": "5", "六": "6", "七": "7", "八": "8", "九": "9"]   // l10n-ignore
        return String(folded.filter { c in !(c.isWhitespace || c.isPunctuation || c.isSymbol || c == "的") }.map { digits[$0] ?? $0 })   // l10n-ignore
    }

    struct Candidate: Equatable {
        var id: String
        var name: String
        var room: String
        var kind: HomeTileKind
        var category: String
        var alt = ""    // 多鍵開關：「配件名＋序號」（例：四键开关2），跟服務名都能指到這個開關
        var nName: String { ClioHomeControl.normalized(name) }
        var nRoom: String { ClioHomeControl.normalized(room) }
    }

    // 關鍵字（已是簡體小寫；比對前會把使用者的話繁→簡）
    static let lightWords = ["灯", "light", "lamp", "bulb"]    // l10n-ignore：比對用詞
    static let coveringWords = ["窗帘", "帘", "curtain", "blind", "shade"]    // l10n-ignore：比對用詞
    static let outletWords = ["插座", "outlet", "plug"]    // l10n-ignore：比對用詞
    static let thermostatWords = ["温控", "空调", "冷气", "暖气", "thermostat", "heater"]    // l10n-ignore：比對用詞
    static let lockWords = ["门锁", "锁", "lock"]    // l10n-ignore：比對用詞
    static let allWords = ["所有", "全部", "全屋", "all", "every", "whole"]    // l10n-ignore：比對用詞
    static let garageWords = ["车库", "garage", "dooropener", "卷帘门"]    // l10n-ignore：比對用詞
    static let securityWords = ["警戒", "安防", "防盗", "安保", "保全", "security", "alarm", "disarm", "撤防"]    // l10n-ignore：比對用詞
    static let sceneRiskWords = ["解锁", "开锁", "开门", "车库", "撤防", "unlock", "garage", "disarm", "opendoor"]    // l10n-ignore：比對用詞

    static func contains(_ s: String, any words: [String]) -> Bool { words.contains { s.contains($0) } }

    static func candidates(_ snap: HomeSnapshot) -> [Candidate] {
        let rooms = Dictionary(snap.rooms.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        let home = (snap.homes.first(where: \.primary) ?? snap.homes.first)?.id
        return snap.accessories.flatMap { a -> [Candidate] in
            if home != nil, a.home != nil, a.home != home { return [] }
            return HomeAppModel.tiles(a).map { t in   // 2.0：多鍵開關一個開關一個候選（id ＝ 磚 id）
                Candidate(id: t.id, name: t.name, room: a.room.flatMap { rooms[$0] } ?? "", kind: t.kind, category: a.categoryName ?? "",
                          alt: t.index.map { "\(t.accName ?? "")\($0)" } ?? "")
            }
        }
    }

    /// 一個名字對一個配件的分數（0 ＝ 不是）
    static func score(_ q: String, name n: String, room r: String) -> Int {
        guard !q.isEmpty, !n.isEmpty else { return 0 }
        if q == n || (!r.isEmpty && (q == r + n || q == n + r)) { return 100 }
        if q.contains(n) { return 80 + (!r.isEmpty && q.contains(r) ? 10 : 0) }
        if q.count >= 2, n.contains(q) { return 60 }
        return 0
    }

    static func kinds(for a: HomeVoiceAction, query q: String) -> Set<HomeTileKind> {
        var k = Set<HomeTileKind>()
        if contains(q, any: lightWords) { k.insert(.light) }
        if contains(q, any: coveringWords) { k.insert(.covering) }
        if contains(q, any: outletWords) { k.insert(.outlet) }
        if contains(q, any: thermostatWords) { k.insert(.thermostat) }
        if contains(q, any: lockWords) { k.insert(.lock) }
        if !k.isEmpty { return k }
        switch a {
        case .on, .off, .setBrightness: return [.light]
        case .setTemperature: return [.thermostat]
        case .setPosition: return [.covering]
        case .lock, .unlock: return [.lock]
        case .open, .close: return [.covering, .lock]
        }
    }

    enum Resolution: Equatable {
        case found([Candidate])
        case ambiguous([Candidate])
        case none
    }

    /// 使用者說的名字 → 配件：先比配件名（同分並列＝要問是哪一個），比不到再看房間名＋類別（「客廳的燈」＝那間房的所有燈）
    static func resolve(_ query: String, action: HomeVoiceAction, in all: [Candidate], rooms: [String]) -> Resolution {
        let q = normalized(query)
        guard !q.isEmpty else { return .none }
        let scored = all.map { ($0, max(score(q, name: $0.nName, room: $0.nRoom), score(q, name: normalized($0.alt), room: $0.nRoom))) }
        let top = scored.map(\.1).max() ?? 0
        if top >= 90 { return pick(scored.filter { $0.1 == top }.map(\.0)) }
        // 房間＋類別
        let wantKinds = kinds(for: action, query: q)
        let wholeHome = contains(q, any: allWords)
        let roomNames = Set(rooms.map(normalized).filter { !$0.isEmpty && q.contains($0) })
        if !roomNames.isEmpty || wholeHome {
            let byRoom = all.filter { c in (wholeHome && roomNames.isEmpty || roomNames.contains(c.nRoom)) && wantKinds.contains(c.kind) }
            if !byRoom.isEmpty, top < 80 || wholeHome { return .found(byRoom) }
        }
        if top >= 60 { return pick(scored.filter { $0.1 == top }.map(\.0)) }
        // 只說了類別（「燈」）：那一類的都是候選，一個就用、多個要問
        if contains(q, any: lightWords + coveringWords + outletWords + thermostatWords + lockWords) {
            let byKind = all.filter { wantKinds.contains($0.kind) }
            if !byKind.isEmpty { return pick(byKind) }
        }
        return .none
    }

    private static func pick(_ c: [Candidate]) -> Resolution { c.count == 1 ? .found(c) : .ambiguous(c) }

    // MARK: 輸入解析

    struct Command: Equatable {
        var target: String
        var action: HomeVoiceAction
        var value: Double?
    }

    struct Request: Equatable {
        var commands: [Command] = []
        var scene: String?
        /// nil＝不看攝影機；""＝全部（格狀）
        var camera: String?
        var error: String?
    }

    static func parse(_ input: [String: Any]) -> Request {
        var req = Request()
        var raw = input["commands"] as? [[String: Any]] ?? []
        if raw.isEmpty, input["action"] != nil { raw = [input] }   // 模型有時把單一動作平放在最上層
        for c in raw {
            let target = ((c["target"] ?? c["accessory"] ?? c["room"] ?? c["name"]) as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard let a = (c["action"] as? String).flatMap(HomeVoiceAction.parse) else {
                req.error = "Unknown action. Use one of: " + HomeVoiceAction.allCases.map(\.rawValue).joined(separator: ", ") + "."
                return req
            }
            guard !target.isEmpty else { req.error = "Each command needs the accessory or room name in \"target\"."; return req }
            let v = (c["value"] as? NSNumber)?.doubleValue ?? (c["value"] as? String).flatMap(Double.init)
            if [.setBrightness, .setTemperature, .setPosition].contains(a), v == nil {
                req.error = "\(a.rawValue) needs a numeric \"value\"."
                return req
            }
            req.commands.append(Command(target: target, action: a, value: v))
        }
        if let s = (input["scene"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty { req.scene = s }
        if let c = input["show_camera"] {
            if let b = c as? Bool { req.camera = b ? "" : nil }
            else if let s = c as? String { req.camera = s.trimmingCharacters(in: .whitespacesAndNewlines) }
        }
        if req.commands.isEmpty, req.scene == nil, req.camera == nil { req.error = "Nothing to do: give \"commands\", a \"scene\" or \"show_camera\"." }
        return req
    }

    // MARK: 計畫

    struct Write: Equatable {
        var charID: String
        var value: HomeValue
        var type: String
    }

    struct Step: Equatable {
        var command: Command
        var targets: [Candidate] = []
        var writes: [Write] = []              // 全部目標合起來要寫的
        var perTarget: [String: String] = [:] // 目標 id → 失敗原因（寫不了的）
        var error: String?                    // 找不到或名字不明確
        var sensitive = false                 // 開鎖、開車庫、解除警戒
    }

    struct Plan: Equatable {
        var steps: [Step] = []
        var scene: (id: String, name: String)?
        var sceneSensitive = false
        var camera: String?                   // nil＝不開；"" ＝格狀；否則攝影機 id
        var cameraName: String?
        var error: String?
        var needsConfirmation: Bool { steps.contains { $0.sensitive } || sceneSensitive }
        static func == (a: Plan, b: Plan) -> Bool {
            a.steps == b.steps && a.scene?.id == b.scene?.id && a.sceneSensitive == b.sceneSensitive && a.camera == b.camera && a.error == b.error
        }
    }

    /// 這個動作對這個配件要不要先確認
    static func isSensitive(_ a: HomeVoiceAction, _ c: Candidate) -> Bool {
        let hay = normalized(c.name + c.category)
        if c.kind == .lock { return a == .unlock || a == .open || a == .off }
        if contains(hay, any: securityWords) { return a == .off || a == .open || a == .unlock }
        if contains(hay, any: garageWords) { return a == .open || a == .on || a == .unlock }
        return false
    }

    static func plan(_ req: Request, snapshot snap: HomeSnapshot) -> Plan {
        var plan = Plan()
        if let e = req.error { plan.error = e; return plan }
        let cands = candidates(snap)
        let roomNames = snap.rooms.map(\.name)
        var tilesByID: [String: HomeTile] = [:]
        for a in snap.accessories { for t in HomeAppModel.tiles(a) { tilesByID[t.id] = t } }
        for cmd in req.commands {
            var step = Step(command: cmd)
            switch resolve(cmd.target, action: cmd.action, in: cands, rooms: roomNames) {
            case .none:
                step.error = "No accessory or room matches \"\(cmd.target)\". Ask the user for the name as it appears in Home."
            case .ambiguous(let c):
                step.error = "\"\(cmd.target)\" matches several accessories: " + c.prefix(5).map { $0.room.isEmpty ? $0.name : "\($0.room) \($0.name)" }.joined(separator: ", ") + ". Ask the user which one."
            case .found(let c):
                step.targets = c
                for cand in c {
                    guard let t = tilesByID[cand.id] else { continue }
                    if !t.reachable { step.perTarget[cand.id] = "not responding"; continue }
                    switch writes(for: cmd, tile: t) {
                    case .success(let w): step.writes += w
                    case .failure(let why): step.perTarget[cand.id] = why.why
                    }
                    if isSensitive(cmd.action, cand) { step.sensitive = true }
                }
            }
            plan.steps.append(step)
        }
        if let s = req.scene {
            let names = snap.scenes.map { (id: $0.id, name: $0.name) }
            let q = normalized(s)
            let scored = names.map { ($0, score(q, name: normalized($0.name), room: "")) }
            let top = scored.map(\.1).max() ?? 0
            let best = scored.filter { $0.1 == top && top >= 60 }.map(\.0)
            if best.count == 1 {
                plan.scene = best[0]
                plan.sceneSensitive = contains(normalized(best[0].name), any: sceneRiskWords)
            } else if best.count > 1 {
                plan.error = "\"\(s)\" matches several scenes: " + best.prefix(5).map(\.name).joined(separator: ", ") + ". Ask the user which one."
            } else {
                plan.error = "No scene matches \"\(s)\"."
            }
        }
        if let cam = req.camera {
            let cams = HomeAppModel.cameras(snap)
            if cam.isEmpty || contains(normalized(cam), any: allWords) { plan.camera = "" }
            else {
                let q = normalized(cam)
                let hit = cams.map { ($0, score(q, name: normalized($0.name), room: "")) }.filter { $0.1 >= 60 }.max { $0.1 < $1.1 }
                if let h = hit { plan.camera = h.0.id; plan.cameraName = h.0.name } else { plan.camera = ""; plan.cameraName = nil }
            }
            if cams.isEmpty { plan.error = plan.error ?? "No cameras were found in Home."; plan.camera = nil }
        }
        return plan
    }

    /// 一個磚＋一個命令 → 要寫的特性（寫不了就說為什麼）
    static func writes(for cmd: Command, tile t: HomeTile) -> Result<[Write], PlanFailure> {
        func w(_ id: String?, _ v: HomeValue, _ type: String) -> Result<[Write], PlanFailure> {
            guard let id else { return .failure(PlanFailure("read-only")) }
            return .success([Write(charID: id, value: v, type: type)])
        }
        func power(_ on: Bool) -> Result<[Write], PlanFailure> { w(t.powerID, HomeValue(bool: on), "power") }
        switch (cmd.action, t.kind) {
        case (.on, .light), (.on, .outlet): return power(true)
        case (.off, .light), (.off, .outlet): return power(false)
        case (.on, .covering), (.open, .covering): return w(t.targetPositionID, HomeValue(number: 100), "targetPosition")
        case (.off, .covering), (.close, .covering): return w(t.targetPositionID, HomeValue(number: 0), "targetPosition")
        case (.setBrightness, .light):
            let pct = HomeAppModel.clamp((cmd.value ?? 0).rounded(), 0, 100)
            if pct <= 0 { return power(false) }
            guard let b = t.brightnessID else { return .failure(PlanFailure("not dimmable")) }
            var out = [Write(charID: b, value: HomeValue(number: pct), type: "brightness")]
            if let p = t.powerID, !t.on { out.append(Write(charID: p, value: HomeValue(bool: true), type: "power")) }
            return .success(out)
        case (.setTemperature, .thermostat):
            var c = cmd.value ?? 0
            if c > 45 { c = (c - 32) * 5 / 9 }          // 模型給了華氏
            c = HomeAppModel.clamp((c / t.tempStep).rounded() * t.tempStep, t.tempMin, t.tempMax)
            return w(t.targetTempID, HomeValue(number: c), "targetTemp")
        case (.setPosition, .covering):
            return w(t.targetPositionID, HomeValue(number: HomeAppModel.clamp((cmd.value ?? 0).rounded(), 0, 100)), "targetPosition")
        case (.lock, .lock), (.close, .lock): return w(t.lockTargetID, HomeValue(number: 1), "lockTarget")
        case (.unlock, .lock), (.open, .lock): return w(t.lockTargetID, HomeValue(number: 0), "lockTarget")
        case (.open, .sensor), (.close, .sensor), (.on, .sensor), (.off, .sensor):
            return .failure(PlanFailure("this door cannot be controlled from HomePlay yet"))
        default:
            return .failure(PlanFailure("\(cmd.action.rawValue) does not apply to this accessory"))
        }
    }
    struct PlanFailure: Error, Equatable { var why: String; init(_ w: String) { why = w } }

    // MARK: 念回來

    static func verb(_ c: Command) -> String {
        switch c.action {
        case .on: return L("clio.home.act.on", "打开")
        case .off: return L("clio.home.act.off", "关闭")
        case .lock: return L("clio.home.act.lock", "上锁")
        case .unlock: return L("clio.home.act.unlock", "解锁")
        case .open: return L("clio.home.act.open", "打开")
        case .close: return L("clio.home.act.close", "关闭")
        case .setBrightness: return String(format: L("clio.home.act.brightness", "亮度设为 %d%%"), Int(c.value ?? 0))
        case .setPosition: return String(format: L("clio.home.act.position", "位置设为 %d%%"), Int(c.value ?? 0))
        case .setTemperature: return String(format: L("clio.home.act.temp", "温度设为 %@"), HomeAppModel.tempText(c.value ?? 0, imperial: false))
        }
    }

    /// 第一行問句、第二行「動作：配件」（卡片畫成資料卡，跟行事曆確認同一格式）
    static func readback(_ plan: Plan) -> String {
        let sep = L("clio.home.join", "、")
        var parts: [String] = []
        for s in plan.steps where s.error == nil && !s.targets.isEmpty {
            let names = s.targets.prefix(3).map(\.name).joined(separator: sep) + (s.targets.count > 3 ? "…" : "")
            parts.append(String(format: L("clio.confirm.detail", "%1$@：%2$@"), verb(s.command), names))
        }
        if let sc = plan.scene { parts.append(String(format: L("clio.confirm.detail", "%1$@：%2$@"), L("clio.home.act.scene", "场景"), sc.name)) }
        return L("clio.confirm.home", "要执行这个家庭操作吗？") + "\n" + parts.joined(separator: sep)
    }

    /// 引擎在背景叫：快照在主執行緒上，這裡同步取（引擎不在主執行緒）
    nonisolated(unsafe) static var snapshotProvider: () -> HomeSnapshot = {
        Thread.isMainThread ? HomeLink.shared.snapshot : DispatchQueue.main.sync { HomeLink.shared.snapshot }
    }

    static func needsConfirmation(input: [String: Any]) -> Bool {
        plan(parse(input), snapshot: snapshotProvider()).needsConfirmation
    }

    static func readback(input: [String: Any]) -> String {
        readback(plan(parse(input), snapshot: snapshotProvider()))
    }
}

// MARK: - 執行

enum ClioHomeTools {
    /// 一次寫入，等幫手回覆（最多 6 秒，不卡住引擎）
    private static func write(_ w: ClioHomeControl.Write) async -> Bool {
        await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            let once = Once()
            DispatchQueue.main.async {
                // 2.0 第四輪：本機先改、成功重讀、失敗還原（Shell/HomeWrite.swift）
                HomeWrite.perform(w.charID, w.value) { ok in
                    if once.take() { c.resume(returning: ok) }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 6) { if once.take() { c.resume(returning: false) } }
            }
        }
    }

    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        func take() -> Bool { lock.lock(); defer { lock.unlock() }; if done { return false }; done = true; return true }
    }

    static func run(input: [String: Any]) async -> ClioToolResult {
        func fail(_ s: String) -> ClioToolResult { ClioToolResult(content: s, isError: true, source: .home) }
        guard PersonalGate.cached else { return fail("Home control is only available to the owner of this Mac. Guest mode is on or the owner is not recognized.") }
        guard HomeLink.helperInstalled else { return fail("The HomePlay Home helper is not installed, so ClioTalk cannot control the home.") }
        let snap: HomeSnapshot = await MainActor.run { HomeLink.shared.snapshot }
        guard snap.ready else { return fail("Home is not connected yet. Try again in a few seconds.") }
        let plan = ClioHomeControl.plan(ClioHomeControl.parse(input), snapshot: snap)
        if let e = plan.error, plan.steps.isEmpty, plan.scene == nil { return fail(e) }
        var lines: [String] = []
        var succeeded = false
        if let e = plan.error { lines.append(e) }
        for s in plan.steps {
            if let e = s.error { lines.append(e); continue }
            // 同一步的目標：寫得了的一起寫，寫不了的照實說
            var okNames: [String] = [], bad: [String] = []
            for t in s.targets {
                if let why = s.perTarget[t.id] { bad.append("\(t.name): \(why)"); continue }
                okNames.append(t.name)
            }
            var failedWrites = 0
            for w in s.writes { if !(await write(w)) { failedWrites += 1 } }
            if failedWrites > 0 { lines.append("Could not reach Home for: " + okNames.joined(separator: ", ") + ".") }
            else if !okNames.isEmpty { succeeded = true; lines.append("Done: " + okNames.joined(separator: ", ") + " (\(s.command.action.rawValue)\(s.command.value.map { " \(Int($0))" } ?? "")).") }
            if !bad.isEmpty { lines.append("Not done: " + bad.joined(separator: "; ") + ".") }
        }
        if let sc = plan.scene {
            let ok: Bool = await withCheckedContinuation { c in
                let once = Once()
                DispatchQueue.main.async {
                    HomeLink.shared.runScene(id: sc.id) { ok, _ in if once.take() { c.resume(returning: ok) } }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 6) { if once.take() { c.resume(returning: false) } }
                }
            }
            lines.append(ok ? "Scene \"\(sc.name)\" ran." : "Scene \"\(sc.name)\" could not be run.")
            succeeded = succeeded || ok
        }
        if let cam = plan.camera {
            let opened: Bool = await MainActor.run { HomeApp.shared.showCameras(id: cam.isEmpty ? nil : cam) }
            lines.append(opened ? "The camera view is open on the desk pet screen." : "The desk pet is not ready to show cameras.")
            succeeded = succeeded || opened
        }
        return ClioToolResult(content: lines.joined(separator: "\n"), isError: !succeeded, source: .home)
    }
}
