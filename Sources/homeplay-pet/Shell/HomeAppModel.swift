// 家庭 App 的純邏輯（不碰 AppKit 繪圖，--selftest 直接驗）：
// 配件 → 磚的狀態對應、依房間分組、版面排磚、門鎖「再按一次」確認狀態機、攝影機快照排程、示範資料。
// 資料模型沿用 HomeLink 的 HomeSnapshot／HomeAccessory（跟錶面「家庭模組」同一份）。

import Foundation

// MARK: - 磚

enum HomeTileKind: Equatable { case light, outlet, lock, thermostat, covering, sensor }

struct HomeTile: Equatable {
    var id: String
    var name: String
    var room: String            // 房間 id；沒有房間是 ""
    var kind: HomeTileKind
    var on: Bool                // 亮白磚
    var symbol: String
    var status: String          // 名字下面那行
    var level: Double?          // 燈的亮度、窗簾的位置（0…1）
    var reachable: Bool
    var locked: Bool?           // 門鎖：目前是否鎖著
    var moving: Bool = false    // 門鎖：目標和目前不同（正在動）
    var temp: Double?           // 溫控：目前溫度（°C）
    var target: Double?         // 溫控：目標溫度（°C）
    // 寫入用的特性 id
    var powerID: String?
    var brightnessID: String?
    var lockTargetID: String?
    var targetTempID: String?
    var targetPositionID: String?
    var tempMin = 10.0, tempMax = 38.0, tempStep = 0.5
    // 2.0 第四輪：冷暖氣（HeaterCooler／空調伴侶）
    var activeID: String?       // 開關（HomeKit Active，0／1）
    var mode = 0                // 0 關或待機、1 加熱中、2 製冷中（溫控與冷暖氣共用）
    var humidity: Double?
    var category = ""
    // 2.0 第六輪：多鍵開關「分開顯示」的磚——配件名與第幾個（ClioTalk 用「配件名＋序號」也找得到）
    var accName: String?
    var index: Int?
}

struct HomeRoomGroup: Equatable {
    var id: String              // "" ＝沒有房間的其他配件
    var name: String
    var tiles: [HomeTile]
}

struct HomeCameraItem: Equatable { var id: String; var name: String }

enum HomeAppState: Equatable { case noHelper, connecting, empty, ready }

enum HomeAppModel {
    static var imperial: Bool { Locale.current.measurementSystem == .us }

    static func state(installed: Bool, connected: Bool, ready: Bool, accessories: Int) -> HomeAppState {
        if !installed { return .noHelper }
        if !connected || !ready { return .connecting }
        return accessories == 0 ? .empty : .ready
    }

    /// °C → 顯示字串（美制換成 °F、取整數；公制 .5 保留一位）
    static func tempText(_ c: Double, imperial: Bool = HomeAppModel.imperial) -> String {
        if imperial { return "\(Int((c * 9 / 5 + 32).rounded()))°" }
        let r = (c * 2).rounded() / 2
        return r == r.rounded() ? "\(Int(r))°" : String(format: "%.1f°", r)
    }

    // MARK: 配件 → 磚

    static func isCamera(_ a: HomeAccessory) -> Bool {
        if a.camera == true { return true }
        let n = (a.categoryName ?? "").lowercased()
        return n.contains("camera") || n.contains("doorbell")
    }

    static func tile(_ a: HomeAccessory) -> HomeTile? {
        if isCamera(a) { return nil }
        func v(_ t: String) -> Double? { a.characteristic(t)?.value?.number }
        func on(_ t: String) -> Bool? { a.characteristic(t)?.value?.isOn }
        let cat = (a.categoryName ?? "").lowercased()
        var t = HomeTile(id: a.id, name: a.name, room: a.room ?? "", kind: .sensor, on: false, symbol: "sensor.fill", status: "—", reachable: a.reachable)
        let off = L("home.off", "关"), onS = L("home.on", "开")

        if let cur = a.characteristic("lockCurrent") ?? a.characteristic("lockTarget") {
            t.kind = .lock
            let state = Int(a.characteristic("lockCurrent")?.value?.number ?? cur.value?.number ?? 3)
            let target = a.characteristic("lockTarget")?.value?.number.map { Int($0) }
            t.lockTargetID = a.characteristic("lockTarget")?.writable == true ? a.characteristic("lockTarget")?.id : nil
            t.moving = target != nil && target != state && (state == 0 || state == 1)
            t.locked = state == 1
            switch state {
            case 1: t.status = t.moving ? L("home.lock.unlocking", "正在开锁…") : L("home.lock.locked", "已上锁")
            case 0: t.status = t.moving ? L("home.lock.locking", "正在上锁…") : L("home.lock.unlocked", "已开锁")
            case 2: t.status = L("home.lock.jammed", "卡住了")
            default: t.status = L("home.lock.unknown", "状态不明")
            }
            t.on = state != 1                       // 沒鎖才亮：那是要注意的狀態
            t.symbol = state == 1 ? "lock.fill" : "lock.open.fill"
        } else if a.characteristic("targetPosition") != nil {
            t.kind = .covering
            t.targetPositionID = a.characteristic("targetPosition")?.writable == true ? a.characteristic("targetPosition")?.id : nil
            let pos = v("currentPosition") ?? v("targetPosition") ?? 0
            t.level = max(0, min(1, pos / 100))
            t.on = pos > 0
            t.status = pos <= 0 ? L("home.covering.closed", "关闭") : (pos >= 100 ? L("home.covering.open", "打开") : String(format: L("home.covering.pct", "打开 %d%%"), Int(pos.rounded())))
            t.symbol = pos > 0 ? "blinds.horizontal.open" : "blinds.horizontal.closed"
        } else if isClimate(a) {
            // 溫控（Thermostat）與冷暖氣（HeaterCooler，例如空調伴侶）：2×2 磚、目前溫度、目標、開關、− ＋
            t.kind = .thermostat
            t.temp = v("currentTemp"); t.humidity = v("humidity")
            let hcTarget = Int(v("targetHCState") ?? 0)
            let tt = a.characteristic("targetTemp")
                ?? (hcTarget == 1 ? a.characteristic("heatingThreshold") : a.characteristic("coolingThreshold"))
                ?? a.characteristic("coolingThreshold") ?? a.characteristic("heatingThreshold")
            t.target = tt?.value?.number
            t.targetTempID = tt?.writable == true ? tt?.id : nil
            t.tempMin = tt?.min ?? 10; t.tempMax = tt?.max ?? 38; t.tempStep = max(0.5, tt?.step ?? 0.5)
            if let act = a.characteristic("active") {
                t.activeID = act.writable ? act.id : nil
                t.on = act.value?.isOn ?? false
                // HomeKit 冷暖氣目前狀態：0 未啟用、1 待機、2 加熱、3 製冷
                let cur = Int(v("currentHCState") ?? 0)
                t.mode = !t.on ? 0 : cur == 2 ? 1 : cur == 3 ? 2 : (hcTarget == 1 ? 1 : hcTarget == 2 ? 2 : 0)
            } else {
                t.mode = Int(v("currentMode") ?? v("targetMode") ?? 0)
                t.on = t.mode != 0
            }
            t.symbol = cat.contains("air") || a.characteristic("active") != nil ? "air.conditioner.horizontal.fill" : "thermometer.medium"
            let now = t.temp.map { String(format: L("home.thermo.now", "现在 %@"), tempText($0)) }
            let m: String? = t.activeID != nil && !t.on ? off : [1: L("home.thermo.heat", "加热中"), 2: L("home.thermo.cool", "制冷中")][t.mode]
            let hum = t.target == nil ? t.humidity.map { String(format: L("home.sensor.humidity", "湿度 %d%%"), Int($0.rounded())) } : nil
            t.status = [now, m ?? hum].compactMap { $0 }.joined(separator: " · ")
            if t.status.isEmpty { t.status = "—" }
        } else if let p = a.characteristic("power") {
            let isOn = p.value?.isOn ?? false
            t.powerID = p.writable ? p.id : nil
            t.on = isOn
            if let b = a.characteristic("brightness") {
                t.kind = .light
                t.brightnessID = b.writable ? b.id : nil
                let lv = (b.value?.number ?? (isOn ? 100 : 0)) / 100
                t.level = max(0, min(1, lv))
                t.status = isOn ? String(format: L("home.on.pct", "开 · %d%%"), Int((t.level! * 100).rounded())) : off
                t.symbol = isOn ? "lightbulb.fill" : "lightbulb"
            } else if cat.contains("light") || cat.contains("lamp") || cat.contains("bulb") {
                t.kind = .light
                t.status = isOn ? onS : off
                t.symbol = isOn ? "lightbulb.fill" : "lightbulb"
            } else {
                t.kind = .outlet
                t.status = isOn ? onS : off
                t.symbol = isOn ? "powerplug.fill" : "powerplug"
                // R15：官方家庭磚的符號——風扇是桌扇、喇叭／對講是一圈直線（HPComponents.intercomGlyph 畫）
                if cat.contains("fan") { t.symbol = "fan.desk" }
                else if cat.contains("speaker") || cat.contains("intercom") { t.symbol = intercomSymbol }
                // 第四輪：不是插座的開關（Other／Switch，例如牆上的開關、電熱毯）用開關符號，不用插頭
                else if !cat.contains("outlet") { t.symbol = isOn ? "lightswitch.on" : "lightswitch.off" }
            }
        } else {
            // 感測器：只讀。挑一個最有意思的值
            t.kind = .sensor
            if let m = on("motion") {
                t.on = m; t.status = m ? L("home.sensor.motion", "有动静") : L("home.sensor.still", "没有动静"); t.symbol = "figure.walk.motion"
            } else if let o = on("occupancy") {
                t.on = o; t.status = o ? L("home.sensor.occupied", "有人") : L("home.sensor.vacant", "没有人"); t.symbol = "person.fill"
            } else if let c = v("contact") {
                t.on = c != 0; t.status = c == 0 ? L("home.sensor.closed", "已关闭") : L("home.sensor.opened", "已打开")
                t.symbol = c == 0 ? "door.left.hand.closed" : "door.left.hand.open"
            } else if let d = v("doorState") {
                t.on = d != 1; t.status = d == 1 ? L("home.sensor.closed", "已关闭") : L("home.sensor.opened", "已打开"); t.symbol = "door.garage.closed"
            } else if let c = v("currentTemp") {
                t.status = tempText(c); t.symbol = "thermometer.medium"
            } else if let h = v("humidity") {
                t.status = String(format: L("home.sensor.humidity", "湿度 %d%%"), Int(h.rounded())); t.symbol = "humidity.fill"
            } else if let b = v("battery") {
                t.status = String(format: L("home.sensor.battery", "电量 %d%%"), Int(b.rounded())); t.symbol = "battery.75percent"
            } else if !a.reachable {
                // 第四輪：連不上的配件常常一個特性都讀不到——照樣列出來（官方「無回應」），符號照類別
                t.symbol = categorySymbol(cat)
                t.kind = cat.contains("light") || cat.contains("bulb") ? .light : cat.contains("outlet") ? .outlet : .sensor
            } else {
                return nil      // 沒有任何我們看得懂的特性：不顯示
            }
        }
        if !a.reachable { t.on = false; t.status = L("home.noResponse", "无响应") }
        t.category = cat
        return t
    }

    /// 2.0 第六輪：一個配件 → 一塊或多塊磚。多鍵開關（兩個以上、各有電源特性的服務）每個開關一塊，
    /// 跟官方家庭 App 的「分開顯示」一樣；磚的 id 是「配件id#服務id」，每塊只管自己的電源特性。
    /// 名稱：HomeKit 的服務名；沒有（或跟配件同名）就用「配件名 1、2…」。舊快照沒有服務資訊 → 照舊一塊。
    static func tiles(_ a: HomeAccessory) -> [HomeTile] {
        let powers = a.characteristics.filter { $0.type == "power" }
        var svcs: [String] = []
        for p in powers { if let s = p.service, !svcs.contains(s) { svcs.append(s) } }
        let plain = !isCamera(a) && !isClimate(a)
            && !["lockCurrent", "lockTarget", "targetPosition"].contains { a.characteristic($0) != nil }
        guard svcs.count >= 2, powers.allSatisfy({ $0.service != nil }), plain else { return tile(a).map { [$0] } ?? [] }
        var out: [HomeTile] = []
        for (i, sid) in svcs.enumerated() {
            var sub = a
            sub.id = a.id + "#" + sid
            sub.characteristics = a.characteristics.filter { $0.service == sid }
            let sn = (sub.characteristics.compactMap(\.serviceName).first ?? "").trimmingCharacters(in: .whitespaces)
            sub.name = sn.isEmpty || sn == a.name ? "\(a.name) \(i + 1)" : sn
            guard var t = tile(sub) else { continue }
            t.accName = a.name; t.index = i + 1
            out.append(t)
        }
        return out
    }

    /// 溫控或冷暖氣（有目標溫度、HomeKit Active＋門檻溫度，或類別就是）
    static func isClimate(_ a: HomeAccessory) -> Bool {
        let cat = (a.categoryName ?? "").lowercased()
        if a.characteristic("targetTemp") != nil, a.characteristic("targetMode") != nil || a.characteristic("currentTemp") != nil || cat.contains("thermostat") { return true }
        if a.characteristic("active") != nil, ["coolingThreshold", "heatingThreshold", "currentHCState", "targetHCState"].contains(where: { a.characteristic($0) != nil }) { return true }
        return (cat.contains("air conditioner") || cat.contains("heater") || cat.contains("cooler") || cat.contains("thermostat")) && a.characteristic("currentTemp") != nil
    }

    /// 只有類別、沒有特性時的符號（連不上的配件）
    static func categorySymbol(_ cat: String) -> String {
        if cat.contains("light") || cat.contains("bulb") { return "lightbulb" }
        if cat.contains("outlet") { return "powerplug" }
        if cat.contains("fan") { return "fan.desk" }
        if cat.contains("air") || cat.contains("heater") || cat.contains("thermostat") { return "air.conditioner.horizontal" }
        if cat.contains("lock") { return "lock" }
        if cat.contains("switch") || cat.contains("other") { return "lightswitch.off" }
        return "questionmark.square.dashed"
    }

    // MARK: 分組

    /// 只看主要家庭。房間順序照 Home 給的；沒有房間的配件放最後的「其他」。空房間不列。
    static func groups(_ s: HomeSnapshot) -> [HomeRoomGroup] {
        let home = (s.homes.first(where: \.primary) ?? s.homes.first)?.id
        let rooms = s.rooms.filter { home == nil || $0.home == nil || $0.home == home }
        let tiles = s.accessories.filter { home == nil || $0.home == nil || $0.home == home }.flatMap(tiles)
        var out: [HomeRoomGroup] = []
        for r in rooms {
            let ts = tiles.filter { $0.room == r.id }
            if !ts.isEmpty { out.append(HomeRoomGroup(id: r.id, name: r.name, tiles: ts)) }
        }
        let known = Set(rooms.map(\.id))
        let rest = tiles.filter { !known.contains($0.room) }
        if !rest.isEmpty { out.append(HomeRoomGroup(id: "", name: L("home.room.other", "其他"), tiles: rest)) }
        return out
    }

    static func cameras(_ s: HomeSnapshot) -> [HomeCameraItem] {
        let home = (s.homes.first(where: \.primary) ?? s.homes.first)?.id
        return s.accessories.filter { (home == nil || $0.home == nil || $0.home == home) && isCamera($0) }.prefix(HPTokens.HomeCameras.max).map { HomeCameraItem(id: $0.id, name: $0.name) }   // 2.0 P10：4 → 9 路（官方 Home Camera 九路）
    }

    static func scenes(_ s: HomeSnapshot) -> [HomeScene] {
        let home = (s.homes.first(where: \.primary) ?? s.homes.first)?.id
        return s.scenes.filter { home == nil || $0.home == nil || $0.home == home }
    }

    /// 對講／喇叭的符號記號（不是 SF Symbol，HomeApp 看到它就用 HPComponents.intercomGlyph 畫）
    static let intercomSymbol = "homeplay.intercom"

    /// R15：磚上的名稱拿掉開頭或結尾的房間名（官方「Lights／Entryway」；中文「玄关灯」在「玄关」→「灯」），拿完是空的就用原名
    static func shortName(_ name: String, room: String) -> String {
        let r = room.trimmingCharacters(in: .whitespaces)
        guard !r.isEmpty, name.count > r.count else { return name }
        var n = name
        if n.lowercased().hasPrefix(r.lowercased()) {
            n = String(n.dropFirst(r.count))
            // 第四輪：房間名後面的所有格（粵語「客厅嘅空调伴侣」、「卧室的灯」、英文「Bedroom's Lamp」）一起拿掉
            let t = n.trimmingCharacters(in: .whitespaces)
            for p in ["嘅", "的", "之", "'s", "’s", "s'", "'"] where t.lowercased().hasPrefix(p) { n = String(t.dropFirst(p.count)); break }   // l10n-ignore
        }
        else if n.lowercased().hasSuffix(r.lowercased()) { n = String(n.dropLast(r.count)) }
        n = n.trimmingCharacters(in: CharacterSet(charactersIn: " ·-–—的嘅"))   // l10n-ignore：拿掉的連接符號，不是介面文字
        return n.isEmpty ? name : n
    }

    static func homeName(_ s: HomeSnapshot) -> String {
        (s.homes.first(where: \.primary) ?? s.homes.first)?.name ?? L("app.home", "家庭")
    }

    // MARK: 版面（純幾何）

    /// 三欄排磚：span 是佔幾欄（溫控 2，其餘 1）；放不下這一列剩的欄就換列。回傳 (欄, 列, 欄數)。
    static func place(spans: [Int], columns: Int = 3) -> [(col: Int, row: Int, span: Int)] {
        var out: [(Int, Int, Int)] = []
        var col = 0, row = 0
        for s in spans {
            let w = min(s, columns)
            if col + w > columns { col = 0; row += 1 }
            out.append((col, row, w))
            col += w
            if col >= columns { col = 0; row += 1 }
        }
        return out
    }

    /// 一排膠囊（寬度已知）放進 avail：要看到 selected，回傳可見範圍 start...end（含）。
    static func chipWindow(widths: [CGFloat], selected: Int, gap: CGFloat, avail: CGFloat) -> (start: Int, end: Int) {
        guard !widths.isEmpty else { return (0, -1) }
        let sel = max(0, min(widths.count - 1, selected))
        func span(_ a: Int, _ b: Int) -> CGFloat { widths[a...b].reduce(0, +) + gap * CGFloat(b - a) }
        // 先從頭放；放不下選到的就把左邊挪掉
        var start = 0
        while start < sel && span(start, sel) > avail { start += 1 }
        var end = sel
        while end + 1 < widths.count && span(start, end + 1) <= avail { end += 1 }
        return (start, end)
    }

    // MARK: 調整

    static func clamp(_ v: Double, _ lo: Double, _ hi: Double) -> Double { max(lo, min(hi, v)) }

    /// 溫控目標 ±1 步（°C）
    static func steppedTarget(_ t: HomeTile, direction: Int) -> Double? {
        guard let cur = t.target else { return nil }
        return clamp(cur + Double(direction) * t.tempStep, t.tempMin, t.tempMax)
    }

    /// 燈／窗簾的位置（0…100 的整數）
    static func percent(_ level: Double) -> Double { (clamp(level, 0, 1) * 100).rounded() }

    // MARK: 示範資料（--demo-home）

    static func demoSnapshot() -> HomeSnapshot {
        func ch(_ id: String, _ type: String, _ val: HomeValue?, w: Bool = true, min: Double? = nil, max: Double? = nil, step: Double? = nil, svc: String? = nil, sn: String? = nil) -> HomeCharacteristic {
            HomeCharacteristic(id: id, type: type, value: val, writable: w, units: nil, min: min, max: max, step: step, service: svc, serviceName: sn)
        }
        func acc(_ id: String, _ name: String, _ room: String, _ cat: String, _ cs: [HomeCharacteristic], camera: Bool = false) -> HomeAccessory {
            HomeAccessory(id: id, name: name, home: "h1", room: room, category: "x", categoryName: cat, reachable: true, characteristics: cs, camera: camera ? true : nil)
        }
        let living = L("homemod.demo.livingRoom", "客厅")
        _ = living
        let rooms = [HomeRoom(id: "r1", name: L("home.demo.living", "客厅"), home: "h1"), HomeRoom(id: "r2", name: L("home.demo.bedroom", "卧室"), home: "h1"),
                     HomeRoom(id: "r3", name: L("home.demo.entry", "玄关"), home: "h1"), HomeRoom(id: "r4", name: L("home.demo.kitchen", "厨房"), home: "h1")]
        let accs = [
            acc("a1", L("home.demo.thermostat", "温控"), "r1", "Thermostat", [ch("c1a", "currentTemp", HomeValue(number: 23), w: false), ch("c1b", "targetTemp", HomeValue(number: 24), min: 16, max: 30, step: 0.5),
                                                             ch("c1c", "currentMode", HomeValue(number: 1), w: false), ch("c1d", "targetMode", HomeValue(number: 1))]),
            acc("a2", L("homemod.demo.floorLamp", "落地灯"), "r1", "Lightbulb", [ch("c2a", "power", HomeValue(bool: true)), ch("c2b", "brightness", HomeValue(number: 60))]),
            acc("a3", L("home.demo.sofaLight", "沙发灯"), "r1", "Lightbulb", [ch("c3a", "power", HomeValue(bool: false)), ch("c3b", "brightness", HomeValue(number: 100))]),
            acc("a4", L("home.demo.curtain", "窗帘"), "r1", "Window Covering", [ch("c4a", "currentPosition", HomeValue(number: 70), w: false), ch("c4b", "targetPosition", HomeValue(number: 70))]),
            acc("a5", L("home.demo.fan", "风扇插座"), "r1", "Outlet", [ch("c5a", "power", HomeValue(bool: true))]),
            acc("a6", L("home.demo.tvPlug", "电视插座"), "r1", "Outlet", [ch("c6a", "power", HomeValue(bool: false))]),
            acc("a7", L("home.demo.humidity", "湿度感测器"), "r1", "Sensor", [ch("c7a", "humidity", HomeValue(number: 56), w: false)]),
            acc("a8", L("home.demo.bedLamp", "床头灯"), "r2", "Lightbulb", [ch("c8a", "power", HomeValue(bool: false)), ch("c8b", "brightness", HomeValue(number: 30))]),
            // 第四輪：冷暖氣（空調伴侶）、牆上開關（Other）、連不上的燈——跟使用者家裡同一種形狀
            acc("a18", L("home.demo.ac", "空调"), "r2", "Air Conditioner", [ch("c18a", "currentTemp", HomeValue(number: 27), w: false), ch("c18b", "active", HomeValue(number: 1)),
                                                                     ch("c18c", "currentHCState", HomeValue(number: 3), w: false), ch("c18d", "targetHCState", HomeValue(number: 2)),
                                                                     ch("c18e", "coolingThreshold", HomeValue(number: 25), min: 16, max: 30, step: 1), ch("c18f", "humidity", HomeValue(number: 68), w: false)]),
            acc("a19", L("home.demo.wallSwitch", "墙壁开关"), "r2", "Other", [ch("c19a", "power", HomeValue(bool: true))]),
            // 第六輪：四鍵開關＝四個開關服務，每個一塊磚（兩個有名字、兩個沒有 → 「四键开关 2」「四键开关 4」）
            acc("a21", L("home.demo.switch4", "四键开关"), "r2", "Switch", [ch("c21a", "power", HomeValue(bool: true), svc: "s1", sn: L("home.demo.switch4.main", "主灯")), ch("c21b", "power", HomeValue(bool: false), svc: "s2", sn: ""),
                                                                    ch("c21c", "power", HomeValue(bool: true), svc: "s3", sn: L("home.demo.switch4.night", "夜灯")), ch("c21d", "power", HomeValue(bool: false), svc: "s4", sn: "")]),
            HomeAccessory(id: "a20", name: L("home.demo.deskLamp", "台灯"), home: "h1", room: "r2", category: "x", categoryName: "Lightbulb", reachable: false, characteristics: [], camera: nil),
            acc("a9", L("homemod.demo.frontDoor", "大门"), "r3", "Door Lock", [ch("c9a", "lockCurrent", HomeValue(number: 1), w: false), ch("c9b", "lockTarget", HomeValue(number: 1))]),
            acc("a10", L("home.demo.entryLight", "玄关灯"), "r3", "Lightbulb", [ch("c10a", "power", HomeValue(bool: true)), ch("c10b", "brightness", HomeValue(number: 60))]),
            acc("a11", L("home.demo.doorSensor", "门磁"), "r3", "Sensor", [ch("c11a", "contact", HomeValue(number: 0), w: false)]),
            acc("a12", L("home.demo.motion", "动态感测器"), "r3", "Sensor", [ch("c12a", "motion", HomeValue(bool: true), w: false)]),
            acc("a13", L("home.demo.kitchenLight", "厨房灯"), "r4", "Lightbulb", [ch("c13a", "power", HomeValue(bool: true)), ch("c13b", "brightness", HomeValue(number: 85))]),
            acc("a14", L("home.demo.cam.door", "大门"), "r3", "IP Camera", [], camera: true),
            acc("a15", L("home.demo.cam.garage", "车库"), "r3", "IP Camera", [], camera: true),
            acc("a16", L("home.demo.cam.yard", "后院"), "r4", "IP Camera", [], camera: true),
            acc("a17", L("home.demo.cam.living", "客厅"), "r1", "IP Camera", [], camera: true),
        ]
        let scenes = [HomeScene(id: "s1", name: L("homemod.demo.goodNight", "晚安"), type: "x", home: "h1"), HomeScene(id: "s2", name: L("home.demo.goodMorning", "早安"), type: "x", home: "h1"),
                      HomeScene(id: "s3", name: L("home.demo.movie", "看电影"), type: "x", home: "h1")]
        var all = accs
        // 2.0 P10 快照：--home-cameras N（5…9）多放幾台示範攝影機，看 3×3
        if let i = CommandLine.arguments.firstIndex(of: "--home-cameras"), i + 1 < CommandLine.arguments.count, let n = Int(CommandLine.arguments[i + 1]), n > 4 {
            let extra = [L("home.demo.cam.porch", "门廊"), L("home.demo.cam.driveway", "车道"), L("home.demo.cam.kitchen", "厨房"),
                         L("home.demo.cam.patio", "露台"), L("home.demo.cam.hall", "走廊")]
            for (k, name) in extra.prefix(min(9, n) - 4).enumerated() { all.append(acc("a3\(k)", name, "r1", "IP Camera", [], camera: true)) }
        }
        return HomeSnapshot(ready: true, homes: [HomeInfo(id: "h1", name: L("home.demo.homeName", "我的家"), primary: true)], rooms: rooms, accessories: all, scenes: scenes)
    }
}

// MARK: - 門鎖確認狀態機

/// 沒鎖著的門，點一下直接上鎖；鎖著的門，第一下只「待命」（磚上寫「再按一次开锁」），4 秒內同一把再按一次才真的開鎖。
/// 4 秒到了、或點了別的東西，就回到待命前。
struct LockConfirm: Equatable {
    var armed: String?
    var until: Double = 0
    static let window = 4.0
    enum Action: Equatable { case lock, unlock, arm }

    mutating func press(id: String, locked: Bool, now: Double) -> Action {
        _ = expire(now)
        if !locked { armed = nil; return .lock }
        if armed == id { armed = nil; return .unlock }
        armed = id; until = now + Self.window
        return .arm
    }
    func isArmed(_ id: String, now: Double) -> Bool { armed == id && now < until }
    mutating func cancel() { armed = nil }
    /// 過期就清掉；有變回 true（要重畫）
    @discardableResult mutating func expire(_ now: Double) -> Bool {
        if armed != nil, now >= until { armed = nil; return true }
        return false
    }
}

// MARK: - 攝影機快照排程

/// 每 10 秒更新一次可見的攝影機；同一台還沒回來就不再要；失敗也等滿 10 秒才重試（不狂敲）。
struct SnapshotSchedule: Equatable {
    static let interval = 10.0
    private(set) var asked: [String: Double] = [:]
    private(set) var inFlight: Set<String> = []
    private(set) var got: [String: Double] = [:]

    func due(_ ids: [String], now: Double) -> [String] {
        ids.filter { !inFlight.contains($0) && now - (asked[$0] ?? -1e9) >= Self.interval }
    }
    /// 2.0 depth：最近一次失敗（之後沒再成功過）——家庭 App 的攝影機寫「沒有回應」，不是一直「正在取得快照」或秒數一直長
    private(set) var failed: [String: Double] = [:]
    mutating func finished(_ id: String, ok: Bool, now: Double) { inFlight.remove(id); if ok { got[id] = now; failed[id] = nil } else { failed[id] = now } }
    func age(_ id: String, now: Double) -> Int? { got[id].map { max(0, Int(now - $0)) } }
    func noResponse(_ id: String) -> Bool { failed[id] != nil }

    // 2.0 P10：九路時錯開——同時最多 maxInFlight 台在要、兩次開始至少隔 spacing 秒；每台的更新間隔跟著台數拉長（四台以內 10 秒，九台 15 秒）
    static let maxInFlight = 3
    static let spacing = 0.35
    private(set) var lastStart = -1e9
    static func interval(count: Int) -> Double { max(interval, 10 + Double(max(0, count - 4))) }
    /// 這一幀可以開始要的（最多一台；排最久沒更新的那台）
    func next(_ ids: [String], now: Double) -> [String] {
        guard inFlight.count < Self.maxInFlight, now - lastStart >= Self.spacing else { return [] }
        let every = Self.interval(count: ids.count)
        let ready = ids.filter { !inFlight.contains($0) && now - (asked[$0] ?? -1e9) >= every }
        guard let pick = ready.min(by: { (asked[$0] ?? -1e9) < (asked[$1] ?? -1e9) }) else { return [] }
        return [pick]
    }
    mutating func began(_ id: String, now: Double) { asked[id] = now; inFlight.insert(id); lastStart = now }
}

// MARK: - 自檢

enum HomeAppSelfTest {
    /// 第四輪：照使用者家裡實際的配件形狀（--home-dump 看到的：空調伴侶只有溫濕度、開關是 Other、連不上的燈沒有特性）
    static func realHome(_ check: (Bool, String) -> Void) {
        func ch(_ id: String, _ type: String, _ val: HomeValue?, w: Bool = true, min: Double? = nil, max: Double? = nil, step: Double? = nil) -> HomeCharacteristic {
            HomeCharacteristic(id: id, type: type, value: val, writable: w, units: nil, min: min, max: max, step: step)
        }
        func acc(_ cat: String, _ cs: [HomeCharacteristic], reachable: Bool = true) -> HomeAccessory {
            HomeAccessory(id: "x", name: "x", home: "h", room: "r", category: "c", categoryName: cat, reachable: reachable, characteristics: cs, camera: nil)
        }
        let acOld = HomeAppModel.tile(acc("Air Conditioner", [ch("h", "humidity", HomeValue(number: 68), w: false), ch("t", "currentTemp", HomeValue(number: 27.1), w: false)]))
        check(acOld?.kind == .thermostat && acOld?.temp == 27.1 && acOld?.target == nil && acOld?.targetTempID == nil && (acOld?.status.contains("27") ?? false),
              "家庭：只有溫濕度的空調伴侶＝2×2 溫控磚、顯示目前溫度")   // l10n-ignore：自檢
        let ac = HomeAppModel.tile(acc("Air Conditioner", [ch("t", "currentTemp", HomeValue(number: 27.1), w: false), ch("a", "active", HomeValue(number: 1)),
                                                           ch("cs", "currentHCState", HomeValue(number: 3), w: false), ch("ts", "targetHCState", HomeValue(number: 2)),
                                                           ch("ct", "coolingThreshold", HomeValue(number: 25), min: 16, max: 30, step: 1),
                                                           ch("ht", "heatingThreshold", HomeValue(number: 20), min: 16, max: 30, step: 1)]))
        check(ac?.on == true && ac?.mode == 2 && ac?.target == 25 && ac?.targetTempID == "ct" && ac?.activeID == "a" && ac?.tempStep == 1, "家庭：冷暖氣開著製冷、目標＝製冷門檻、可開關")
        let acOff = HomeAppModel.tile(acc("Air Conditioner", [ch("t", "currentTemp", HomeValue(number: 27), w: false), ch("a", "active", HomeValue(number: 0)),
                                                              ch("ts", "targetHCState", HomeValue(number: 1)), ch("ht", "heatingThreshold", HomeValue(number: 21))]))
        check(acOff?.on == false && acOff?.mode == 0 && acOff?.targetTempID == "ht", "家庭：冷暖氣關著、暖氣模式改的是加熱門檻")
        let sw = HomeAppModel.tile(acc("Other", [ch("p", "power", HomeValue(bool: true)), ch("p2", "power", HomeValue(bool: false))]))
        check(sw?.kind == .outlet && sw?.symbol == "lightswitch.on" && sw?.powerID == "p", "家庭：Other 類的開關用開關符號，不用插頭")
        check(HomeAppModel.tile(acc("Outlet", [ch("p", "power", HomeValue(bool: true))]))?.symbol == "powerplug.fill", "家庭：插座照樣是插頭")
        let dead = HomeAppModel.tile(acc("Lightbulb", [], reachable: false))
        check(dead?.reachable == false && dead?.kind == .light && dead?.symbol == "lightbulb" && dead?.status == L("home.noResponse", "无响应"), "家庭：連不上又沒有特性的燈照樣列出「無回應」")
        check(HomeAppModel.tile(acc("Other", [])) == nil, "家庭：連得上但沒有看得懂的特性就不列")
    }

    /// 第六輪：多鍵開關「分開顯示」——四個開關服務 → 四塊磚；舊快照沒有服務資訊 → 一塊；ClioTalk 用名字或「配件名＋序號」找對那一個
    static func multiSwitch(_ check: (Bool, String) -> Void) {
        func ch(_ id: String, _ val: Bool, _ svc: String?, _ sn: String?) -> HomeCharacteristic {
            HomeCharacteristic(id: id, type: "power", value: HomeValue(bool: val), writable: true, units: nil, min: nil, max: nil, step: nil, service: svc, serviceName: sn)
        }
        func acc(_ cs: [HomeCharacteristic]) -> HomeAccessory {
            HomeAccessory(id: "sw", name: "客厅四键开关", home: "h", room: "r", category: "c", categoryName: "Switch", reachable: true, characteristics: cs, camera: nil)   // l10n-ignore：自檢
        }
        let four = acc([ch("p1", true, "s1", "主灯"), ch("p2", false, "s2", ""), ch("p3", true, "s3", "夜灯"), ch("p4", false, "s4", "客厅四键开关")])   // l10n-ignore：自檢
        let ts = HomeAppModel.tiles(four)
        check(ts.count == 4 && ts.map(\.powerID) == ["p1", "p2", "p3", "p4"] && ts.map(\.on) == [true, false, true, false] && Set(ts.map(\.id)).count == 4,
              "家庭：四鍵開關＝四塊磚、各管各的電源特性")   // l10n-ignore：自檢
        check(ts.map(\.name) == ["主灯", "客厅四键开关 2", "夜灯", "客厅四键开关 4"], "家庭：多鍵開關磚名＝服務名；沒有（或跟配件同名）＝「配件名 N」")   // l10n-ignore：自檢
        check(HomeAppModel.shortName(ts[1].name, room: "客厅") == "四键开关 2", "家庭：多鍵開關每塊都拿掉房間名")   // l10n-ignore：自檢
        let old = acc([ch("p1", true, nil, nil), ch("p2", false, nil, nil)])
        let ot = HomeAppModel.tiles(old)
        check(ot.count == 1 && ot[0].id == "sw" && ot[0].name == "客厅四键开关" && ot[0].powerID == "p1", "家庭：舊快照（特性沒有服務資訊）＝照舊一塊磚")   // l10n-ignore：自檢
        check(HomeAppModel.tiles(acc([ch("p1", true, "s1", "灯")])).count == 1, "家庭：只有一個開關服務＝一塊磚")   // l10n-ignore：自檢
        let snap = HomeSnapshot(ready: true, homes: [HomeInfo(id: "h", name: "h", primary: true)], rooms: [HomeRoom(id: "r", name: "客厅", home: "h")], accessories: [four], scenes: [])   // l10n-ignore
        func plan(_ target: String, _ action: String = "off") -> ClioHomeControl.Plan {
            ClioHomeControl.plan(ClioHomeControl.parse(["commands": [["target": target, "action": action]]]), snapshot: snap)
        }
        func writes(_ p: ClioHomeControl.Plan) -> [String] { p.steps.first?.writes.map(\.charID) ?? [] }
        check(writes(plan("四键开关二")) == ["p2"] && writes(plan("客厅四鍵開關四")) == ["p4"] && writes(plan("四键开关 1")) == ["p1"],   // l10n-ignore：自檢
              "ClioTalk：「四鍵開關二」（配件名＋序號，國字或數字）只指到那一個開關")   // l10n-ignore：自檢
        check(writes(plan("夜灯", "on")) == ["p3"] && writes(plan("夜燈")) == ["p3"], "ClioTalk：用服務名（繁簡都行）指到那一個開關")   // l10n-ignore：自檢
        check(plan("四键开关").steps.first?.error != nil, "ClioTalk：只說「四鍵開關」（四個都符合）＝問是哪一個")   // l10n-ignore：自檢
    }

    static func run(_ check: (Bool, String) -> Void) {
        let snap = HomeAppModel.demoSnapshot()
        let groups = HomeAppModel.groups(snap)
        check(groups.map(\.id) == ["r1", "r2", "r3", "r4"], "家庭：房間分組照 Home 的順序、攝影機不進磚")
        check(groups[0].tiles.map(\.kind) == [.thermostat, .light, .light, .covering, .outlet, .outlet, .sensor], "家庭：客廳磚的種類")
        check(HomeAppModel.cameras(snap).count == 4, "家庭：示範四路攝影機")
        var many = snap
        for k in 0..<8 { many.accessories.append(HomeAccessory(id: "cx\(k)", name: "c", home: "h1", room: "r1", category: "x", categoryName: "IP Camera", reachable: true, characteristics: [], camera: true)) }
        check(HomeAppModel.cameras(many).count == 9, "家庭：攝影機頁最多九路（P10）")
        // R15：磚名拿掉房間名（官方 Lights／Entryway）
        let short = HomeAppModel.shortName("玄关灯", room: "玄关") == "灯" && HomeAppModel.shortName("Entryway Lights", room: "Entryway") == "Lights"   // l10n-ignore
            && HomeAppModel.shortName("Lights", room: "Entryway") == "Lights" && HomeAppModel.shortName("Office", room: "Office") == "Office"
        check(short, "家庭：磚名拿掉房間名")
        let possessive = HomeAppModel.shortName("客厅嘅空调伴侣", room: "客厅") == "空调伴侣" && HomeAppModel.shortName("卧室的灯", room: "卧室") == "灯"   // l10n-ignore：自檢
            && HomeAppModel.shortName("Bedroom's Lamp", room: "Bedroom") == "Lamp" && HomeAppModel.shortName("Bedroom Lamp", room: "Bedroom") == "Lamp"   // l10n-ignore
            && HomeAppModel.shortName("客厅嘅", room: "客厅") == "客厅嘅"   // l10n-ignore：自檢
        check(possessive, "家庭：房間名後面的「嘅／的／'s」一起拿掉")
        HomeAppSelfTest.realHome(check)
        HomeAppSelfTest.multiSwitch(check)
        // 磚的狀態
        let lamp = groups[0].tiles[1], sofa = groups[0].tiles[2], curtain = groups[0].tiles[3], thermo = groups[0].tiles[0]
        check(lamp.on && lamp.level == 0.6 && lamp.brightnessID == "c2b" && lamp.powerID == "c2a" && lamp.symbol == "lightbulb.fill", "家庭：開著的燈＝亮白、60%")
        check(!sofa.on && sofa.symbol == "lightbulb", "家庭：關著的燈＝暗磚")
        check(curtain.kind == .covering && curtain.on && curtain.level == 0.7 && curtain.targetPositionID == "c4b", "家庭：窗簾位置 70%")
        check(thermo.on && thermo.target == 24 && thermo.temp == 23 && thermo.targetTempID == "c1b", "家庭：溫控目標 24、現在 23、暖氣中＝亮")
        check(HomeAppModel.steppedTarget(thermo, direction: 1) == 24.5 && HomeAppModel.steppedTarget(thermo, direction: -1) == 23.5, "家庭：溫控 ±0.5")
        var low = thermo; low.target = 16
        check(HomeAppModel.steppedTarget(low, direction: -1) == 16, "家庭：溫控不低於最小值")
        let lock = groups[2].tiles[0], contact = groups[2].tiles[2], motion = groups[2].tiles[3]
        check(lock.kind == .lock && lock.locked == true && !lock.on && lock.lockTargetID == "c9b", "家庭：鎖著的門＝暗磚、可寫目標")
        check(contact.kind == .sensor && !contact.on && motion.on && motion.kind == .sensor && motion.powerID == nil, "家庭：感測器只讀，有動靜才亮")
        check(HomeAppModel.tempText(21.5, imperial: false) == "21.5°" && HomeAppModel.tempText(22, imperial: false) == "22°" && HomeAppModel.tempText(22, imperial: true) == "72°", "家庭：溫度字串")
        // 沒房間的配件放「其他」、斷線的配件不亮
        var s2 = snap
        s2.accessories[1].room = nil
        s2.accessories[2].reachable = false
        let g2 = HomeAppModel.groups(s2)
        check(g2.last?.id == "" && g2.last?.tiles.count == 1, "家庭：沒房間的配件進「其他」")
        check(HomeAppModel.tile(s2.accessories[2])?.on == false && HomeAppModel.tile(s2.accessories[2])?.reachable == false, "家庭：連不到的配件不亮")
        // 門鎖正在動
        var moving = snap.accessories.first { $0.id == "a9" }!
        moving.characteristics[1].value = HomeValue(number: 0)
        check(HomeAppModel.tile(moving)?.moving == true, "家庭：目標≠目前＝正在動")
        // 狀態
        check(HomeAppModel.state(installed: false, connected: false, ready: false, accessories: 0) == .noHelper, "家庭：沒裝小幫手＝說明卡")
        let connecting = HomeAppModel.state(installed: true, connected: false, ready: false, accessories: 0)
        let empty = HomeAppModel.state(installed: true, connected: true, ready: true, accessories: 0)
        let ready = HomeAppModel.state(installed: true, connected: true, ready: true, accessories: 3)
        check(connecting == .connecting && empty == .empty && ready == .ready, "家庭：連線中、沒配件、可用")
        // 排磚
        let p = HomeAppModel.place(spans: [2, 1, 1, 1, 2, 1])
        check(p.map { $0.row } == [0, 0, 1, 1, 2, 2] && p.map { $0.col } == [0, 2, 0, 1, 0, 2], "家庭：溫控佔兩欄的排法")
        check(HomeAppModel.place(spans: [1, 1, 2]).map { $0.row } == [0, 0, 1], "家庭：剩一欄放不下兩欄寬的就換列")
        // 房間膠囊視窗
        let w1 = HomeAppModel.chipWindow(widths: [200, 200, 200, 200, 200], selected: 0, gap: 20, avail: 700)
        let w2 = HomeAppModel.chipWindow(widths: [200, 200, 200, 200, 200], selected: 4, gap: 20, avail: 700)
        check(w1.start == 0 && w1.end == 2 && w2.end == 4 && w2.start == 2, "家庭：房間膠囊放不下時，視窗跟著選到的那個")
        // 門鎖確認
        var lc = LockConfirm()
        check(lc.press(id: "a9", locked: true, now: 100) == .arm && lc.isArmed("a9", now: 101), "門鎖：鎖著的門第一下只待命")
        check(lc.press(id: "a9", locked: true, now: 102) == .unlock && lc.armed == nil, "門鎖：4 秒內再按一次才開鎖")
        _ = lc.press(id: "a9", locked: true, now: 200)
        check(lc.expire(203.9) == false && lc.expire(204) == true && lc.press(id: "a9", locked: true, now: 205) == .arm, "門鎖：4 秒到了回到待命前，要重新按兩下")
        _ = lc.press(id: "a9", locked: true, now: 300)
        lc.cancel()
        check(lc.press(id: "a9", locked: true, now: 301) == .arm, "門鎖：點了別的東西取消待命")
        _ = lc.press(id: "a9", locked: true, now: 400)
        check(lc.press(id: "other", locked: true, now: 401) == .arm && lc.armed == "other", "門鎖：待命換到另一把，不會直接開")
        check(lc.press(id: "x", locked: false, now: 402) == .lock, "門鎖：沒鎖的門點一下就上鎖（不需確認）")
        // 快照排程
        var sch = SnapshotSchedule()
        check(sch.due(["a", "b"], now: 0) == ["a", "b"], "快照：第一次全部要")
        sch.began("a", now: 0); sch.finished("a", ok: true, now: 1)
        check(sch.due(["a", "b"], now: 5) == ["b"] && sch.due(["a"], now: 10) == ["a"] && sch.age("a", now: 6) == 5, "快照：10 秒更新一次")
        sch.began("b", now: 25)
        check(sch.due(["b"], now: 30).isEmpty, "快照：還沒回來的不重複要")
        sch.finished("b", ok: false, now: 31)
        check(sch.due(["b"], now: 31).isEmpty && sch.due(["b"], now: 35) == ["b"] && sch.age("b", now: 40) == nil, "快照：失敗也等滿 10 秒才重試")
        // P10：九路錯開
        var nine = SnapshotSchedule(); let ids = (0..<9).map { "c\($0)" }
        var t = 100.0, started: [Double] = []
        while t < 103 { for id in nine.next(ids, now: t) { nine.began(id, now: t); started.append(t) }; t += 0.05 }
        check(started.count == 3 && zip(started, started.dropFirst()).allSatisfy { $1 - $0 >= SnapshotSchedule.spacing - 1e-9 }, "快照：九路錯開、同時最多三台在要")
        for (k, id) in ids.prefix(3).enumerated() { nine.finished(id, ok: true, now: 101 + Double(k)) }
        var more = 0; t = 103
        while t < 113 { for id in nine.next(ids, now: t) { nine.began(id, now: t); more += 1; nine.finished(id, ok: true, now: t + 0.2) }; t += 0.05 }
        check(more == 6 && nine.next(ids, now: 113).isEmpty && SnapshotSchedule.interval(count: 9) == 15 && SnapshotSchedule.interval(count: 4) == 10,
              "快照：每台更新間隔跟著台數拉長（九台 15 秒）")   // l10n-ignore：selftest 訊息
        // 協定：快照回應的 base64 解碼；請求的位元組
        let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0, 1, 2, 3])
        let line = Data(#"{"ok":true,"image":"\#(jpeg.base64EncodedString())"}"#.utf8)
        check(HomeLink.decodeImage(line: line) == jpeg, "協定：cameraSnapshot 回應解出 JPEG")
        check(HomeLink.decodeImage(line: Data(#"{"ok":false,"error":"x"}"#.utf8)) == nil && HomeLink.decodeImage(line: Data(#"{"ok":true}"#.utf8)) == nil, "協定：失敗或沒圖回 nil")
        let acc = try? JSONDecoder().decode(HomeAccessory.self, from: Data(#"{"id":"1","name":"n","category":"c","reachable":true,"characteristics":[],"camera":true}"#.utf8))
        let old = try? JSONDecoder().decode(HomeAccessory.self, from: Data(#"{"id":"1","name":"n","category":"c","reachable":true,"characteristics":[]}"#.utf8))
        check(acc?.camera == true && old != nil && old?.camera == nil, "協定：camera 欄位可有可無（舊幫手相容）")
        let pos = try? JSONDecoder().decode(HomeCharacteristic.self, from: Data(#"{"id":"1","type":"targetPosition","value":40,"writable":true}"#.utf8))
        check(pos?.value?.number == 40, "協定：新特性 targetPosition 解得出")
    }
}
