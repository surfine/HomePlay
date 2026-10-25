// 2.0 cc：控制中心模組讀到／動到的「這台 Mac 的真東西」。只用公開 API；做不到的老實打開系統設定。
//
// - Wi‑Fi：CoreWLAN 讀電源與網路名稱（macOS 14 起 SSID 要定位授權，沒有就只說「已連接」）；切換用 CWInterface.setPower
//   （文件說「可能需要管理員」，失敗就打開 Wi‑Fi 設定）。
// - 藍牙：IOBluetooth 讀電源與配對裝置、點裝置連線／中斷（公開 API）；開關電源只有私有 API（blueutil），所以打開藍牙設定。
// - 專注模式：讀 ~/Library/DoNotDisturb/DB 的兩個 JSON（要「完全取用磁碟」；讀不到就顯示「專注模式」不猜）；
//   切換：有同名的捷徑（Shortcuts）就跑它，沒有就打開專注模式設定（系統沒有公開的切換 API）。
// - 聲音輸出：Core Audio 列出輸出裝置、改預設輸出（公開 API，整台 Mac 的聲音一起換）；AirPlay 喇叭 Core Audio 列不全，
//   所以另放一列「聲音設定⋯」。
// - 顯示器亮度：沒有公開 API（內建螢幕只有私有的 DisplayServices），所以滑桿調的是 HomePlay 螢幕自己的亮度。
// 快照與自檢（--snapshot、--screen-png、--selftest、示範資料）一律用示範值，不讀系統、不跳權限視窗、不動任何東西。
// 讀系統只在控制中心開著時、每 2 秒一次；藍牙在主執行緒（IOBluetooth 不保證執行緒安全），其他在背景。

import AppKit
import CoreAudio
import CoreWLAN
import IOBluetooth

final class CCSystem: @unchecked Sendable {
    static let shared = CCSystem()

    struct WiFi: Equatable { var available = true; var on = true; var ssid: String?; var connected = true }
    struct BTDevice: Equatable { var name: String; var address: String; var connected: Bool; var symbol: String }
    struct Bluetooth: Equatable { var available = true; var on = true; var devices: [BTDevice] = [] }
    struct FocusMode: Equatable { var id: String; var name: String; var symbol: String; var tint: NSColor }
    struct Focus: Equatable { var readable = true; var active: String?; var modes: [FocusMode] = [] }
    struct Output: Equatable { var id: AudioDeviceID; var name: String; var selected: Bool; var symbol: String }

    private(set) var wifi = WiFi()
    private(set) var bluetooth = Bluetooth()
    private(set) var focus = Focus()
    private(set) var outputs: [Output] = []
    /// 捷徑 App 裡有哪些捷徑（切換專注模式用；只讀名字）
    private var shortcutNames: Set<String> = []
    private var lastRead = 0.0, lastBT = 0.0, busy = false
    var onChange: (() -> Void)?

    /// 快照、自檢、示範：不碰系統
    static var demo: Bool {
        let a = CommandLine.arguments
        return Face.demoData || OfficialDemo.on || a.contains("--snapshot") || a.contains("--screen-png") || a.contains("--selftest") || a.contains("--cc-demo")
    }

    private init() { if Self.demo { loadDemo() } }

    func loadDemo() {
        wifi = WiFi(available: true, on: true, ssid: "HomePlay 5G", connected: true)
        bluetooth = Bluetooth(available: true, on: true, devices: [
            BTDevice(name: "AirPods Pro", address: "demo-1", connected: true, symbol: "airpodspro"),
            BTDevice(name: "Magic Keyboard", address: "demo-2", connected: true, symbol: "keyboard"),
            BTDevice(name: "HomePod mini", address: "demo-3", connected: false, symbol: "homepodmini.fill"),
        ])
        focus = Focus(readable: true, active: nil, modes: Self.defaultModes)
        outputs = [
            Output(id: 1, name: L("cc.demo.speakers", "MacBook Air 扬声器"), selected: true, symbol: "laptopcomputer"),
            Output(id: 2, name: "AirPods Pro", selected: false, symbol: "airpodspro"),
            Output(id: 3, name: L("cc.demo.livingRoom", "客厅"), selected: false, symbol: "homepodmini.fill"),
        ]
    }

    static var defaultModes: [FocusMode] {
        [FocusMode(id: "com.apple.donotdisturb.mode.default", name: L("cc.dnd", "勿扰模式"), symbol: "moon.fill", tint: HPTokens.indigo),
         FocusMode(id: "com.apple.sleep.sleep-mode", name: L("cc.focus.sleep", "睡眠"), symbol: "bed.double.fill", tint: HPTokens.mint),
         FocusMode(id: "com.apple.focus.personal-time", name: L("cc.focus.personal", "个人"), symbol: "person.fill", tint: HPTokens.purple),
         FocusMode(id: "com.apple.focus.work", name: L("cc.focus.work", "工作"), symbol: "person.lanyardcard.fill", tint: HPTokens.teal)]
    }

    // MARK: 讀

    /// 控制中心開著時每幀叫；2 秒讀一次
    func refresh(now: Double) {
        guard !Self.demo, now - lastRead > 2, !busy else { return }
        lastRead = now; busy = true
        if now - lastBT > 3 { lastBT = now; readBluetooth() }
        outputs = Self.readOutputs()
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let w = Self.readWiFi(), f = Self.readFocus()
            let names = (self?.shortcutNames.isEmpty ?? false) ? Self.readShortcuts() : nil
            DispatchQueue.main.async {
                guard let self else { return }
                let changed = w != self.wifi || f != self.focus
                self.wifi = w; self.focus = f
                if let names { self.shortcutNames = names.isEmpty ? ["-"] : names }
                self.busy = false
                if changed { self.onChange?() }
            }
        }
    }

    private static func readWiFi() -> WiFi {
        guard let i = CWWiFiClient.shared().interface() else { return WiFi(available: false, on: false, ssid: nil, connected: false) }
        let on = i.powerOn()
        let s = i.ssid().flatMap { $0.isEmpty || $0.localizedCaseInsensitiveContains("redacted") ? nil : $0 }
        // 沒有定位授權時 ssid 是 nil，但 BSSID／傳送速率還在：有速率＝連著
        let connected = on && (s != nil || i.transmitRate() > 0)
        return WiFi(available: true, on: on, ssid: s, connected: connected)
    }

    private func readBluetooth() {
        guard let host = IOBluetoothHostController.default() else { bluetooth = Bluetooth(available: false, on: false, devices: []); return }
        let on = host.powerState == kBluetoothHCIPowerStateON
        let devs = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] ?? []).compactMap { d -> BTDevice? in
            guard let name = d.name, !name.isEmpty else { return nil }
            return BTDevice(name: name, address: d.addressString ?? name, connected: d.isConnected(), symbol: Self.btSymbol(name, major: d.deviceClassMajor))
        }
        bluetooth = Bluetooth(available: true, on: on, devices: devs.sorted { ($0.connected ? 0 : 1, $0.name) < ($1.connected ? 0 : 1, $1.name) })
    }

    static func btSymbol(_ name: String, major: BluetoothDeviceClassMajor) -> String {
        let n = name.lowercased()
        if n.contains("airpods max") { return "airpodsmax" }
        if n.contains("airpods pro") { return "airpodspro" }
        if n.contains("airpods") { return "airpods" }
        if n.contains("keyboard") { return "keyboard" }
        if n.contains("mouse") { return "magicmouse" }
        if n.contains("trackpad") { return "rectangle.and.hand.point.up.left" }
        if n.contains("homepod") { return "homepodmini.fill" }
        if n.contains("iphone") { return "iphone" }
        if n.contains("watch") { return "applewatch" }
        switch major {
        case BluetoothDeviceClassMajor(kBluetoothDeviceClassMajorAudio): return "headphones"
        case BluetoothDeviceClassMajor(kBluetoothDeviceClassMajorPhone): return "iphone"
        case BluetoothDeviceClassMajor(kBluetoothDeviceClassMajorPeripheral): return "keyboard"
        case BluetoothDeviceClassMajor(kBluetoothDeviceClassMajorComputer): return "laptopcomputer"
        default: return "dot.radiowaves.left.and.right"
        }
    }

    /// 專注模式：讀不到（沒有完全取用磁碟）就 readable＝false，介面只顯示「專注模式」
    static func readFocus() -> Focus {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/DoNotDisturb/DB")
        guard let modesData = try? Data(contentsOf: dir.appendingPathComponent("ModeConfigurations.json")),
              let assertData = try? Data(contentsOf: dir.appendingPathComponent("Assertions.json")) else {
            return Focus(readable: false, active: nil, modes: defaultModes)
        }
        return parseFocus(modes: modesData, assertions: assertData) ?? Focus(readable: false, active: nil, modes: defaultModes)
    }

    /// 純函數（selftest 驗）：ModeConfigurations.json＋Assertions.json → 模式清單與目前開著的
    static func parseFocus(modes: Data, assertions: Data) -> Focus? {
        guard let m = try? JSONSerialization.jsonObject(with: modes) as? [String: Any],
              let mdata = (m["data"] as? [[String: Any]])?.first,
              let configs = mdata["modeConfigurations"] as? [String: Any] else { return nil }
        let order = ["com.apple.donotdisturb.mode.default", "com.apple.sleep.sleep-mode", "com.apple.focus.personal-time", "com.apple.focus.work"]
        var list: [FocusMode] = []
        for (id, v) in configs {
            guard let mode = (v as? [String: Any])?["mode"] as? [String: Any] else { continue }
            var name = mode["name"] as? String ?? id
            if let local = defaultModes.first(where: { $0.id == id }), name == "Do Not Disturb" || name.isEmpty { name = local.name }
            if id == "com.apple.focus.reduce-interruptions", name == "Reduce Interruptions" { name = L("cc.focus.reduce", "减少干扰") }
            list.append(FocusMode(id: id, name: name, symbol: mode["symbolImageName"] as? String ?? "moon.fill", tint: tint(mode["tintColorName"] as? String)))
        }
        list.sort { (order.firstIndex(of: $0.id) ?? 99, $0.name) < (order.firstIndex(of: $1.id) ?? 99, $1.name) }
        var active: String?
        if let a = try? JSONSerialization.jsonObject(with: assertions) as? [String: Any], let d = a["data"] as? [[String: Any]] {
            for blk in d {
                for r in blk["storeAssertionRecords"] as? [[String: Any]] ?? [] {
                    if let id = (r["assertionDetails"] as? [String: Any])?["assertionDetailsModeIdentifier"] as? String { active = id }
                }
            }
        }
        return Focus(readable: true, active: active, modes: list.isEmpty ? defaultModes : list)
    }

    static func tint(_ name: String?) -> NSColor {
        switch name ?? "" {
        case "systemPurpleColor": return HPTokens.purple
        case "systemMintColor": return HPTokens.mint
        case "systemTealColor": return HPTokens.teal
        case "systemOrangeColor": return HPTokens.orange
        case "systemGreenColor": return HPTokens.green
        case "systemBlueColor": return HPTokens.blue
        case "systemPinkColor": return HPTokens.pink
        case "systemRedColor": return HPTokens.red
        default: return HPTokens.indigo
        }
    }

    private static func readShortcuts() -> Set<String> {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
        p.arguments = ["list"]
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return Set((String(data: data, encoding: .utf8) ?? "").split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) })
    }

    // MARK: 聲音輸出（Core Audio）

    private static func prop(_ id: AudioObjectID, _ sel: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, _ v: inout UInt32) -> Bool {
        var addr = AudioObjectPropertyAddress(mSelector: sel, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &v) == noErr
    }

    private static func deviceName(_ id: AudioObjectID) -> String? {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &name) == noErr else { return nil }
        return name?.takeRetainedValue() as String?
    }

    static func readOutputs() -> [Output] {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return [] }
        var def = AudioDeviceID(0)
        _ = prop(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice, &def)
        return ids.compactMap { id in
            var sa = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
            var ss: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(id, &sa, 0, nil, &ss) == noErr, ss > 0 else { return nil }
            var transport: UInt32 = 0
            _ = prop(id, kAudioDevicePropertyTransportType, &transport)
            if transport == kAudioDeviceTransportTypeAggregate || transport == kAudioDeviceTransportTypeVirtual { return nil }
            guard let n = deviceName(id), !n.isEmpty else { return nil }
            let sym: String
            switch transport {
            case kAudioDeviceTransportTypeBuiltIn: sym = "laptopcomputer"
            case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: sym = n.lowercased().contains("airpods") ? "airpodspro" : "headphones"
            case kAudioDeviceTransportTypeAirPlay: sym = "airplayaudio"
            case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort: sym = "tv"
            default: sym = "hifispeaker.fill"
            }
            return Output(id: id, name: n, selected: id == def, symbol: sym)
        }
    }

    // MARK: 動（只在真的使用者動作時叫；示範模式只改本機狀態）

    func setWiFi(_ on: Bool) {
        if Self.demo { wifi.on = on; wifi.connected = on; onChange?(); return }
        DispatchQueue.global(qos: .userInitiated).async {
            var ok = false
            if let i = CWWiFiClient.shared().interface() { ok = (try? i.setPower(on)) != nil }
            DispatchQueue.main.async {
                if !ok { Self.openSettings(.wifi) }
                self.lastRead = 0; self.onChange?()
            }
        }
    }
    /// 藍牙電源只有私有 API：打開藍牙設定（示範模式改本機狀態）
    func toggleBluetooth() {
        if Self.demo { bluetooth.on.toggle(); onChange?(); return }
        Self.openSettings(.bluetooth)
    }
    func toggleDevice(_ address: String) {
        if Self.demo {
            if let i = bluetooth.devices.firstIndex(where: { $0.address == address }) { bluetooth.devices[i].connected.toggle(); onChange?() }
            return
        }
        guard let d = IOBluetoothDevice(addressString: address) else { return }
        if d.isConnected() { d.closeConnection() } else { d.openConnection(nil) }
        lastBT = 0; lastRead = 0
    }
    /// 專注模式：有同名捷徑就跑（例如捷徑「睡眠」裡放「設定專注模式」），沒有就打開設定
    func toggleFocus(_ id: String?) {
        let mode = id.flatMap { i in focus.modes.first { $0.id == i } } ?? focus.modes.first
        if Self.demo { focus.active = focus.active == mode?.id ? nil : mode?.id; onChange?(); return }
        guard let mode, shortcutNames.contains(mode.name) || shortcutNames.contains("HomePlay \(mode.name)") else { Self.openSettings(.focus); return }
        let name = shortcutNames.contains(mode.name) ? mode.name : "HomePlay \(mode.name)"
        DispatchQueue.global(qos: .userInitiated).async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
            p.arguments = ["run", name]
            try? p.run(); p.waitUntilExit()
            DispatchQueue.main.async { self.lastRead = 0; self.onChange?() }
        }
    }
    /// 改預設輸出裝置（整台 Mac）
    func selectOutput(_ id: AudioDeviceID) {
        if Self.demo { for i in outputs.indices { outputs[i].selected = outputs[i].id == id }; onChange?(); return }
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var d = id
        _ = AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, UInt32(MemoryLayout<AudioDeviceID>.size), &d)
        outputs = Self.readOutputs()
        ControlCenter.volume = SystemVolume.get() ?? ControlCenter.volume
        onChange?()
    }

    enum Pane: String {
        case wifi = "com.apple.wifi-settings-extension", bluetooth = "com.apple.BluetoothSettings", focus = "com.apple.Focus-Settings.extension"
        case sound = "com.apple.Sound-Settings.extension", displays = "com.apple.Displays-Settings.extension"
    }
    static func openSettings(_ p: Pane) {
        guard !demo, let u = URL(string: "x-apple.systempreferences:\(p.rawValue)") else { return }
        NSWorkspace.shared.open(u)
    }

    // MARK: 深色模式（HomePlay 自己的外觀；跟夜間紅色分開）

    static let darkKey = "shell.darkAppearance"
    nonisolated(unsafe) static var darkAppearance: Bool = UserDefaults.standard.bool(forKey: darkKey) {
        didSet { if !demo { UserDefaults.standard.set(darkAppearance, forKey: darkKey) } }
    }

    // MARK: selftest

    static func selftest(_ check: (Bool, String) -> Void) {
        let modes = Data(#"{"data":[{"modeConfigurations":{"com.apple.focus.work":{"mode":{"name":"工作","symbolImageName":"person.lanyardcard.fill","tintColorName":"systemTealColor"}},"com.apple.donotdisturb.mode.default":{"mode":{"name":"Do Not Disturb","symbolImageName":"moon.fill","tintColorName":"systemIndigoColor"}}}}]}"#.utf8)   // l10n-ignore：樣本資料
        let none = Data(#"{"data":[{"storeInvalidationRecords":[]}]}"#.utf8)
        let on = Data(#"{"data":[{"storeAssertionRecords":[{"assertionDetails":{"assertionDetailsModeIdentifier":"com.apple.focus.work"}}]}]}"#.utf8)
        let a = parseFocus(modes: modes, assertions: none), b = parseFocus(modes: modes, assertions: on)
        check(a?.active == nil && a?.modes.first?.id == "com.apple.donotdisturb.mode.default" && a?.modes.first?.name == L("cc.dnd", "勿扰模式"),
              "控制中心：專注模式清單照系統檔，勿擾排第一、名字在地化")   // l10n-ignore：selftest 訊息
        check(b?.active == "com.apple.focus.work", "控制中心：讀得到目前開著的專注模式")
        check(parseFocus(modes: Data("x".utf8), assertions: none) == nil, "控制中心：專注模式檔讀不懂就不猜")
        check(btSymbol("Aaron's AirPods Pro", major: 0) == "airpodspro" && btSymbol("x", major: BluetoothDeviceClassMajor(kBluetoothDeviceClassMajorAudio)) == "headphones",
              "控制中心：藍牙裝置圖示照名字與類別")   // l10n-ignore：selftest 訊息
    }
}
