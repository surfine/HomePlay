// 2.0: ClioTalk 2 新增五個工具的純邏輯自檢（名字模糊比對、動作解析、哪些動作要確認、DeepSeek 搜尋 JSON、每家的工具清單）。
// 由 ClioSelftest.run 呼叫；不碰網路、不碰 Home、不碰通訊錄。

import Foundation

enum ClioHomeSelftest {
    // 測試資料：名字是樣本（簡、繁、英都有），不是介面文字
    static func snapshot() -> HomeSnapshot {   // l10n-ignore
        func ch(_ id: String, _ type: String, _ val: HomeValue?, w: Bool = true, min: Double? = nil, max: Double? = nil, step: Double? = nil) -> HomeCharacteristic {
            HomeCharacteristic(id: id, type: type, value: val, writable: w, units: nil, min: min, max: max, step: step)
        }
        func acc(_ id: String, _ name: String, _ room: String, _ cat: String, _ cs: [HomeCharacteristic], camera: Bool = false) -> HomeAccessory {
            HomeAccessory(id: id, name: name, home: "h", room: room, category: "x", categoryName: cat, reachable: true, characteristics: cs, camera: camera ? true : nil)
        }
        let rooms = [HomeRoom(id: "r1", name: "客厅", home: "h"), HomeRoom(id: "r2", name: "卧室", home: "h"), HomeRoom(id: "r3", name: "玄关", home: "h"), HomeRoom(id: "r4", name: "Kitchen", home: "h")]   // l10n-ignore
        let accs = [
            acc("a1", "落地灯", "r1", "Lightbulb", [ch("a1p", "power", HomeValue(bool: true)), ch("a1b", "brightness", HomeValue(number: 60))]),   // l10n-ignore
            acc("a2", "沙发灯", "r1", "Lightbulb", [ch("a2p", "power", HomeValue(bool: false)), ch("a2b", "brightness", HomeValue(number: 100))]),   // l10n-ignore
            acc("a3", "床头灯", "r2", "Lightbulb", [ch("a3p", "power", HomeValue(bool: false)), ch("a3b", "brightness", HomeValue(number: 30))]),   // l10n-ignore
            acc("a4", "窗帘", "r1", "Window Covering", [ch("a4c", "currentPosition", HomeValue(number: 70), w: false), ch("a4t", "targetPosition", HomeValue(number: 70))]),   // l10n-ignore
            acc("a5", "大门", "r3", "Door Lock", [ch("a5c", "lockCurrent", HomeValue(number: 1), w: false), ch("a5t", "lockTarget", HomeValue(number: 1))]),   // l10n-ignore
            acc("a6", "温控", "r1", "Thermostat", [ch("a6c", "currentTemp", HomeValue(number: 23), w: false), ch("a6t", "targetTemp", HomeValue(number: 24), min: 16, max: 30, step: 0.5),   // l10n-ignore
                                                 ch("a6m", "currentMode", HomeValue(number: 1), w: false), ch("a6d", "targetMode", HomeValue(number: 1))]),
            acc("a7", "Kitchen Light", "r4", "Lightbulb", [ch("a7p", "power", HomeValue(bool: true))]),
            acc("a8", "车库门", "r3", "Garage Door Opener", [ch("a8d", "doorState", HomeValue(number: 1), w: false)]),   // l10n-ignore
            acc("a9", "门口", "r3", "IP Camera", [], camera: true),   // l10n-ignore
        ]
        let scenes = [HomeScene(id: "s1", name: "晚安", type: "x", home: "h"), HomeScene(id: "s2", name: "Good Morning", type: "x", home: "h"), HomeScene(id: "s3", name: "Unlock Door", type: "x", home: "h")]   // l10n-ignore
        return HomeSnapshot(ready: true, homes: [HomeInfo(id: "h", name: "Home", primary: true)], rooms: rooms, accessories: accs, scenes: scenes)
    }

    static func run(_ check: (Bool, String) -> Void) {
        let snap = snapshot()
        let cands = ClioHomeControl.candidates(snap)
        let rooms = snap.rooms.map(\.name)
        func ids(_ r: ClioHomeControl.Resolution) -> [String] {
            switch r { case .found(let c): return c.map(\.id); case .ambiguous(let c): return c.map { "?" + $0.id }; case .none: return [] }
        }
        func res(_ q: String, _ a: HomeVoiceAction = .off) -> [String] { ids(ClioHomeControl.resolve(q, action: a, in: cands, rooms: rooms)) }

        // 名字比對
        check(ClioHomeControl.normalized("客廳 的 燈") == ClioHomeControl.normalized("客厅灯"), "家庭：繁簡、空白、「的」不影響比對")
        check(res("落地灯") == ["a1"] && res("落地燈") == ["a1"] && res("沙發燈") == ["a2"], "家庭：配件名完全相同（簡、繁）")
        check(res("kitchen light") == ["a7"] && res("turn the Kitchen Lights") == ["a7"], "家庭：英文名與多餘的字")
        check(res("客厅灯") == ["a1", "a2"], "家庭：房間＋類別＝那間房的所有燈（不含窗帘、溫控）")
        check(res("卧室灯", .on) == ["a3"], "家庭：房間燈只有一盞就直接用")
        check(res("灯").allSatisfy { $0.hasPrefix("?") } && res("灯").count == 4, "家庭：只說「燈」＝並列，要問是哪一個")
        check(res("客厅窗帘", .open) == ["a4"] && res("窗帘", .open) == ["a4"], "家庭：窗帘")
        check(res("所有灯") == ["a1", "a2", "a3", "a7"], "家庭：「所有燈」＝全屋的燈")
        check(res("大门", .unlock) == ["a5"] && res("车库门", .open) == ["a8"], "家庭：門鎖與車庫門")
        check(res("不存在的东西").isEmpty, "家庭：找不到就空")

        // 動作解析
        check(HomeVoiceAction.parse("turn_off") == .off && HomeVoiceAction.parse("Set Brightness") == .setBrightness && HomeVoiceAction.parse("explode") == nil, "家庭：動作別名")
        let r1 = ClioHomeControl.parse(["commands": [["target": "落地灯", "action": "off"], ["accessory": "窗帘", "action": "set_position", "value": 40]], "scene": "晚安"])   // l10n-ignore
        check(r1.error == nil && r1.commands.count == 2 && r1.commands[1].target == "窗帘" && r1.commands[1].value == 40 && r1.scene == "晚安", "家庭：解析 commands 與 scene")
        check(ClioHomeControl.parse(["commands": [["target": "x", "action": "set_brightness"]]]).error != nil, "家庭：要數值的動作沒給數值＝錯誤")
        check(ClioHomeControl.parse(["target": "落地灯", "action": "on"]).commands.count == 1, "家庭：單一動作平放也收")
        check(ClioHomeControl.parse([:]).error != nil && ClioHomeControl.parse(["show_camera": true]).camera == "", "家庭：什麼都沒給＝錯誤；show_camera")

        // 計畫與寫入
        func plan(_ cmds: [[String: Any]], scene: String? = nil, camera: Any? = nil) -> ClioHomeControl.Plan {
            var i: [String: Any] = ["commands": cmds]
            if let scene { i["scene"] = scene }
            if let camera { i["show_camera"] = camera }
            return ClioHomeControl.plan(ClioHomeControl.parse(i), snapshot: snap)
        }
        let off = plan([["target": "落地灯", "action": "off"]])   // l10n-ignore
        check(off.steps[0].writes == [.init(charID: "a1p", value: HomeValue(bool: false), type: "power")], "家庭：關燈寫 power=false")
        let dim = plan([["target": "沙发灯", "action": "set_brightness", "value": 50]])   // l10n-ignore
        check(dim.steps[0].writes.map(\.charID) == ["a2b", "a2p"] && dim.steps[0].writes[0].value.number == 50, "家庭：燈是關的，調亮度同時打開")
        let temp = plan([["target": "温控", "action": "set_temperature", "value": 75]])   // l10n-ignore
        check(temp.steps[0].writes.first?.value.number == 24, "家庭：給了華氏 75 → 24°C")
        check(plan([["target": "温控", "action": "set_temperature", "value": 99]]).steps[0].writes.first?.value.number == 30, "家庭：溫度夾在溫控的範圍內")
        check(plan([["target": "窗帘", "action": "set_position", "value": 40]]).steps[0].writes.first?.value.number == 40, "家庭：窗簾位置")
        check(plan([["target": "大门", "action": "unlock"]]).steps[0].writes.first?.value.number == 0 && plan([["target": "大门", "action": "lock"]]).steps[0].writes.first?.value.number == 1, "家庭：鎖 1＝上鎖、0＝開鎖")
        check(plan([["target": "落地灯", "action": "lock"]]).steps[0].perTarget["a1"] != nil, "家庭：不適用的動作照實說")
        check(plan([["target": "车库门", "action": "open"]]).steps[0].perTarget["a8"] != nil, "家庭：車庫門目前小幫手寫不了＝照實說")
        check(plan([["target": "落地灯", "action": "off"]], scene: "good morning").scene?.id == "s2", "家庭：場景名不分大小寫")
        check(plan([], scene: "晚安").scene?.id == "s1" && plan([["target": "x", "action": "on"]], camera: "").camera == "", "家庭：場景與攝影機格狀")
        check(plan([], camera: "门口").camera == "a9", "家庭：攝影機按名字")

        // 哪些要確認
        check(plan([["target": "大门", "action": "unlock"]]).needsConfirmation, "確認：開鎖要")
        check(plan([["target": "大门", "action": "open"]]).needsConfirmation, "確認：把門鎖「打開」也算開鎖")
        check(plan([["target": "车库门", "action": "open"]]).needsConfirmation, "確認：開車庫門要")
        check(!plan([["target": "大门", "action": "lock"]]).needsConfirmation, "確認：上鎖不用")
        check(!plan([["target": "落地灯", "action": "off"], ["target": "窗帘", "action": "open"], ["target": "温控", "action": "set_temperature", "value": 22]]).needsConfirmation, "確認：燈、窗簾、溫控不用")
        check(plan([["target": "落地灯", "action": "off"], ["target": "大门", "action": "unlock"]]).needsConfirmation, "確認：一次多件，其中一件要就整批要")
        check(plan([], scene: "Unlock Door").needsConfirmation && !plan([], scene: "晚安").needsConfirmation, "確認：名字帶解鎖的場景要，一般場景不用")
        var sec = snap
        sec.accessories.append(HomeAccessory(id: "a10", name: "家里保全", home: "h", room: "r3", category: "x", categoryName: "Security System",   // l10n-ignore
                                             reachable: true, characteristics: [HomeCharacteristic(id: "a10t", type: "power", value: HomeValue(bool: true), writable: true, units: nil, min: nil, max: nil, step: nil)], camera: nil))
        check(ClioHomeControl.plan(ClioHomeControl.parse(["commands": [["target": "家里保全", "action": "off"]]]), snapshot: sec).needsConfirmation, "確認：解除警戒要")
        let old = ClioHomeControl.snapshotProvider
        ClioHomeControl.snapshotProvider = { snap }
        check(ClioToolCatalog.needsConfirmation(name: "home_control", input: ["commands": [["target": "大门", "action": "unlock"]]]) && !ClioToolCatalog.needsConfirmation(name: "home_control", input: ["commands": [["target": "落地灯", "action": "on"]]]), "確認：目錄按實際動作決定 home_control")
        let rb = ClioToolCatalog.readback(name: "home_control", input: ["commands": [["target": "大门", "action": "unlock"]]]) ?? ""   // l10n-ignore
        check(rb.contains("\n") && rb.contains("大门"), "確認：念回來的那句有第二行動作與配件")
        ClioHomeControl.snapshotProvider = old
        check(ClioToolCatalog.needsConfirmation(name: "call", input: [:]) && !ClioToolCatalog.needsConfirmation(name: "find_messages", input: [:]) && !ClioToolCatalog.needsConfirmation(name: "identify_song", input: [:]), "確認：打電話要、找訊息與辨曲不用")
        check((ClioToolCatalog.readback(name: "call", input: ["contact": "媽媽", "video": true]) ?? "").contains("媽媽"), "確認：打電話念給你聽")

        // 打電話與找訊息
        check(ClioCallTools.url(handle: "+886 912-345-678", video: false)?.absoluteString == "facetime-audio://+886912345678", "電話：號碼 → facetime-audio")
        check(ClioCallTools.url(handle: "0912 345 678", video: true)?.absoluteString == "facetime://0912345678" && ClioCallTools.url(handle: "a@b.com", video: true)?.absoluteString == "facetime://a@b.com", "電話：視訊與信箱")
        check(ClioCallTools.url(handle: "  ", video: false) == nil, "電話：空的不撥")
        check(ClioCallTools.bestHandle(phones: [("_$!<Work>!$_", "1"), ("_$!<Mobile>!$_", "2")], emails: ["x@y"]) == "2" && ClioCallTools.bestHandle(phones: [], emails: ["x@y"]) == "x@y", "電話：手機優先，沒號碼用信箱")
        check(ClioFindMessages.matches("週末一起吃飯", keyword: "周末") && !ClioFindMessages.matches("hello", keyword: "bye") && ClioFindMessages.matches("Hello", keyword: "hello"), "訊息搜尋：繁簡、大小寫")
        check(ClioSongTools.describe(title: "Song", artist: "Me") == "Recognized: \"Song\" by Me." && ClioSongTools.describe(title: nil, artist: nil).hasPrefix("No match"), "辨曲：結果句")

        // 網頁搜尋
        let sample = #"{"results":[{"title":"B","url":"https://www.example.com/b","snippet":"snip b","summary":"sum b","date":"2026-10-20","rerank_score":0.4,"authority":0.5},{"title":"A","url":"https://news.test/a","snippet":"snip a","rerank_score":0.9}]}"#
        let hits = ClioWebSearch.parse(Data(sample.utf8))
        check(hits.map(\.title) == ["A", "B"] && hits[1].text == "sum b" && hits[0].text == "snip a" && hits[1].date == "2026-10-20", "搜尋：解析 results、summary 優先、依 rerank_score 排")
        check(ClioWebSearch.parse(Data(#"{"data":{"results":[{"title":"T","url":"u","summary":"s"}]}}"#.utf8)).count == 1 && ClioWebSearch.parse(Data(#"{"data":[{"title":"T","summary":"s"}]}"#.utf8)).count == 1 && ClioWebSearch.parse(Data(#"[{"title":"T","snippet":"s"}]"#.utf8)).count == 1, "搜尋：results／data／data.results／陣列都收")
        check(ClioWebSearch.parse(Data("not json".utf8)).isEmpty && ClioWebSearch.parse(Data(#"{"results":[]}"#.utf8)).isEmpty, "搜尋：壞資料或空＝沒結果")
        let fmt = ClioWebSearch.format(hits)
        check(fmt.hasPrefix("[1] A (news.test): snip a") && fmt.contains("[2] B (example.com, 2026-10-20): sum b"), "搜尋：給模型的格式（編號、網站、日期、摘要）")
        let req = ClioWebSearch.request(query: "天气", count: 99, key: "k-test")   // l10n-ignore
        let body = (try? JSONSerialization.jsonObject(with: req.httpBody ?? Data())) as? [String: Any]
        check(req.url?.absoluteString == "https://api.deepseek.com/v1/tools/search" && req.httpMethod == "POST" && req.value(forHTTPHeaderField: "Authorization") == "Bearer k-test"
              && body?["query"] as? String == "天气" && body?["count"] as? Int == 10 && body?["need_content"] as? Bool == false, "搜尋：請求網址、Bearer、內文（count 夾到 10）")   // l10n-ignore

        // 每家的工具清單
        let all = Set(ClioToolGroup.allCases)
        let new5 = ["home_control", "find_messages", "call", "identify_song"]
        func names(_ p: ClioProviderID, key: Bool, groups: Set<ClioToolGroup> = all) -> [String] {
            ClioToolCatalog.specs(groups, provider: p, includeEscalate: false, canSearchWeb: key).map(\.name)
        }
        let an = names(.anthropic, key: true)
        check(new5.allSatisfy(an.contains) && an.contains("web_search") && !an.contains("search_web"), "工具清單：Anthropic 有四個新工具與伺服器端 web_search，沒有 search_web")
        let ds = names(.deepseek, key: true), dsNo = names(.deepseek, key: false)
        check(new5.allSatisfy(ds.contains) && ds.last == "search_web" && !ds.contains("web_search"), "工具清單：DeepSeek 有金鑰＝多一個 search_web")
        check(!dsNo.contains("search_web") && new5.allSatisfy(dsNo.contains), "工具清單：沒有 DeepSeek 金鑰＝不送 search_web")
        check(!names(.deepseek, key: true, groups: all.subtracting([.webSearch])).contains("search_web") && !names(.deepseek, key: true, groups: all.subtracting([.home, .calls])).contains("home_control"), "工具清單：設定關掉的組不送")
        check(ClioToolCatalog.specs(all, provider: .onDevice, includeEscalate: true, canSearchWeb: true).isEmpty, "工具清單：裝置端不帶工具")
        check(ClioToolCatalog.group(of: "search_web") == .webSearch && ClioToolCatalog.group(of: "call") == .calls && ClioToolCatalog.group(of: "home_control") == .home && ClioToolCatalog.group(of: "identify_song") == .music, "工具清單：新工具各歸一組")
        check(ClioToolGroup.home.isPersonal && ClioToolGroup.calls.isPersonal && ClioToolGroup.home.defaultOn, "工具清單：家庭與電話只給主人")
        check(ClioPersona.prompt(for: ClioToolCatalog.specs(all, provider: .anthropic, includeEscalate: false)) == ClioPersona.system
              && ClioPersona.prompt(for: ClioToolCatalog.specs(all, provider: .deepseek, includeEscalate: false, canSearchWeb: true)) == ClioPersona.system
              && ClioPersona.prompt(for: ClioToolCatalog.specs(all, provider: .deepseek, includeEscalate: false)).hasSuffix(ClioPersona.noSearchNote), "系統說明：能上網就一樣，不能上網補一句「查不了」")   // l10n-ignore
        check(ClioWebSearch.offered(provider: .deepseek, hasKey: true) && !ClioWebSearch.offered(provider: .deepseek, hasKey: false) && !ClioWebSearch.offered(provider: .anthropic, hasKey: true), "搜尋：只有非 Anthropic 且有 DeepSeek 金鑰才送")
    }
}
