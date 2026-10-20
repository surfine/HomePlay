// 二进制 plist 编解码与 CarPlay 会话里用到的各个字典构造器。
// 编解码走 Foundation PropertyListSerialization；字典内容对应 MacPlay getInfo.ts / cpStack.ts。
import Foundation

package enum BPlistError: Error { case notADictionary }

package enum BPlist {
    package static func encode(_ root: Any) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: root, format: .binary, options: 0)
    }
    package static func decode(_ data: Data) throws -> Any {
        try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
    }
    package static func decodeDict(_ data: Data) throws -> [String: Any] {
        guard let d = try decode(data) as? [String: Any] else { throw BPlistError.notADictionary }
        return d
    }

    /// 规范化成可比较的字符串（键排序；区分整数、实数、布尔、二进制），测试与调试用。
    package static func canonical(_ v: Any) -> String {
        if let d = v as? [String: Any] {
            return "{" + d.keys.sorted().map { "\($0):\(canonical(d[$0]!))" }.joined(separator: ",") + "}"
        }
        if let a = v as? [Any] { return "[" + a.map(canonical).joined(separator: ",") + "]" }
        if let s = v as? String { return "\"\(s)\"" }
        if let d = v as? Data { return "<" + d.map { String(format: "%02x", $0) }.joined() + ">" }
        if let n = v as? NSNumber {
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return n.boolValue ? "true" : "false" }
            if CFNumberIsFloatType(n) { return "r\(n.doubleValue)" }
            return "i\(n.int64Value)"
        }
        return "?\(v)"
    }
}

// MARK: - /info 响应

package struct DisplayInsets: Sendable { package var top, bottom, left, right: Int
    package init(top: Int, bottom: Int, left: Int, right: Int) { self.top = top; self.bottom = bottom; self.left = left; self.right = right } }

package struct DisplayConfig: Sendable {
    package var widthPixels: Int
    package var heightPixels: Int
    package var widthPhysicalMm: Int?
    package var heightPhysicalMm: Int?
    package var fps: Int?
    package var primaryInputDevice: Int?
    package var viewArea: DisplayInsets?
    package var safeArea: DisplayInsets?
    package var safeAreaDrawOutside: Bool?
    package var initialURL: String?
    package init(widthPixels: Int, heightPixels: Int, widthPhysicalMm: Int? = nil, heightPhysicalMm: Int? = nil,
                 fps: Int? = nil, primaryInputDevice: Int? = nil, viewArea: DisplayInsets? = nil,
                 safeArea: DisplayInsets? = nil, safeAreaDrawOutside: Bool? = nil, initialURL: String? = nil) {
        self.widthPixels = widthPixels; self.heightPixels = heightPixels
        self.widthPhysicalMm = widthPhysicalMm; self.heightPhysicalMm = heightPhysicalMm
        self.fps = fps; self.primaryInputDevice = primaryInputDevice; self.viewArea = viewArea
        self.safeArea = safeArea; self.safeAreaDrawOutside = safeAreaDrawOutside; self.initialURL = initialURL
    }
}

package struct OEMIcon: Sendable {
    package var widthPixels: Int, heightPixels: Int, data: Data
    package init(widthPixels: Int, heightPixels: Int, data: Data) { self.widthPixels = widthPixels; self.heightPixels = heightPixels; self.data = data }
}

/// /info 里设备相关的取值全部由调用方给；默认值同 MacPlay。
package struct InfoConfig: Sendable {
    package var sourceVersion: String
    /// AirPlay 设备身份（与 TXT deviceid、0x4301 deviceIdentifier 一致，02:…）
    package var deviceID: String
    package var bluetoothMAC: String
    package var name: String
    package var model = "MacPlay"
    package var manufacturer = "LIVI"
    package var rightHandDrive = false
    package var hevc = false
    package var disableAudioOutput = false
    package var entertainmentSampleRate = 44100
    package var main: DisplayConfig
    package var cluster: DisplayConfig?
    package var oemLabel = ""
    package var icons: [OEMIcon] = []
    package init(sourceVersion: String, deviceID: String, bluetoothMAC: String, name: String, main: DisplayConfig) {
        self.sourceVersion = sourceVersion; self.deviceID = deviceID; self.bluetoothMAC = bluetoothMAC
        self.name = name; self.main = main
    }
}

package enum CarPlayStream {
    package static let mainScreen = 110
    package static let altScreen = 111
    package static let mainAudio = 100
    package static let altAudio = 101
    package static let mainHighAudio = 102
    package static let data = 130
}

package enum CarPlayPlist {
    package static let mainDisplayUUID = "b7e6c5a0-1111-4000-8000-000000000001"
    package static let altDisplayUUID = "b7e6c5a0-2222-4000-8000-000000000002"

    static let features: Int = 0x615653aee2
    static let audioFeatures: Int = 0x10004540a00
    static let featuresNoAudio: Int = features & ~audioFeatures

    private static func resource(_ id: Int) -> [String: Any] {
        ["resourceID": id, "transferType": 1, "transferPriority": 100,
         "takeConstraint": 100, "borrowConstraint": 100, "unborrowConstraint": 100]
    }

    private static func modes() -> [String: Any] {
        ["resources": [resource(1), resource(2)],
         // speechMode -1 在 MacPlay 里是实数（其 JS 编码器对负数写 real），照搬
         "appStates": [["appStateID": 2, "state": false] as [String: Any],
                       ["appStateID": 1, "speechMode": -1.0] as [String: Any],
                       ["appStateID": 3, "state": false] as [String: Any]]]
    }

    private static func audioLatencies() -> [[String: Any]] {
        func base(_ type: Int, _ audioType: String? = nil) -> [String: Any] {
            var d: [String: Any] = ["type": type, "inputLatencyMicros": 0, "outputLatencyMicros": 0]
            if let audioType { d["audioType"] = audioType }
            return d
        }
        return [base(100), base(100, "default"), base(100, "media"), base(100, "telephony"),
                base(100, "speechRecognition"), base(100, "alert"), base(101), base(101, "default"), base(102, "default")]
    }

    private static func audioFormats(_ rate: Int) -> [[String: Any]] {
        func f(_ type: Int, _ audioType: String, _ out: Int, _ inp: Int? = nil) -> [String: Any] {
            var d: [String: Any] = ["type": type, "audioType": audioType, "audioOutputFormats": out]
            if let inp { d["audioInputFormats"] = inp }
            return d
        }
        let is48 = rate == 48000
        let pcmVoice = 0x3fc
        let pcm = pcmVoice | (is48 ? 0xc000 : 0xc00)
        let pcmMono = 0x154 | (is48 ? 0x4000 : 0x400)
        let pcmMedia = is48 ? 0x8000 : 0x800
        let opus = 0x70000000
        let aacLC = is48 ? 0x800000 : 0x400000
        // 不宣告 Opus 輸出：Opus 解碼器還沒接，宣告了手機會送來卻被當「暫不解」丟掉。
        // 導航/Siri 改走 PCM/AAC；輸入端仍保留 Opus 位，麥克風是另一個未做項。
        // 無線時 PCM 是 USB-only，實時媒體流（100/101）必須也宣告 AAC-LC，否則手機會認為
        // 沒有可用的無線音頻格式、乾脆不建音頻流（2026-10-20 真機：/info 只有 PCM 時一個
        // SETUP 音頻都不來）。AAC-LC 在 audioCodec 裡本來就能解。
        // 与 MacPlay 完全一致（含 Opus）——先确认无线时手机选哪一路；Opus 解码还没接，
        // 真收到 Opus 只会占位不出声。确认后再决定要不要接 Opus 解码器。
        return [f(100, "compatibility", pcm, pcmMono), f(101, "compatibility", pcm),
                f(100, "default", pcm | opus, pcmMono | opus), f(100, "alert", pcm | opus),
                f(100, "media", pcmMedia), f(100, "telephony", pcmMono | opus, pcmMono | opus),
                f(100, "speechRecognition", pcmMono | opus, pcmMono | opus),
                f(101, "default", pcm | opus), f(102, "media", aacLC)]
    }

    private static func areaDict(_ d: DisplayConfig) -> [String: Any]? {
        guard let va = d.viewArea else { return nil }
        var view: [String: Any] = ["widthPixels": d.widthPixels - va.left - va.right,
                                   "heightPixels": d.heightPixels - va.top - va.bottom,
                                   "originXPixels": va.left, "originYPixels": va.top]
        if let sa = d.safeArea {
            var safe: [String: Any] = ["widthPixels": d.widthPixels - sa.left - sa.right,
                                       "heightPixels": d.heightPixels - sa.top - sa.bottom,
                                       "originXPixels": sa.left, "originYPixels": sa.top]
            if let o = d.safeAreaDrawOutside { safe["drawUIOutsideSafeArea"] = o }
            view["safeArea"] = safe
        }
        return view
    }

    private static func displayEntry(_ d: DisplayConfig, type: Int, uuid: String) -> [String: Any] {
        let wp = d.widthPhysicalMm ?? 200
        // JS Math.round：正数四舍五入（半数向上）
        let hp = d.heightPhysicalMm ?? max(1, Int((Double(wp * d.heightPixels) / Double(max(1, d.widthPixels)) + 0.5).rounded(.down)))
        var e: [String: Any] = ["uuid": uuid, "type": type, "maxFPS": d.fps ?? 60,
                                "widthPixels": d.widthPixels, "heightPixels": d.heightPixels,
                                "widthPhysical": wp, "heightPhysical": hp,
                                "features": 0x08 | 0x02, "primaryInputDevice": d.primaryInputDevice ?? 3]
        if let v = areaDict(d) { e["viewAreas"] = [v]; e["initialViewArea"] = 0 }
        if let u = d.initialURL, !u.isEmpty { e["initialURL"] = u }
        return e
    }

    package static func info(_ c: InfoConfig) -> [String: Any] {
        var displays = [displayEntry(c.main, type: CarPlayStream.mainScreen, uuid: mainDisplayUUID)]
        if let cl = c.cluster { displays.append(displayEntry(cl, type: CarPlayStream.altScreen, uuid: altDisplayUUID)) }
        var info: [String: Any] = [
            "sourceVersion": c.sourceVersion,
            "features": c.disableAudioOutput ? featuresNoAudio : features,
            "statusFlags": 4, "model": c.model, "manufacturer": c.manufacturer,
            "deviceID": c.deviceID, "bluetoothIDs": [c.bluetoothMAC], "name": c.name,
            "rightHandDrive": c.rightHandDrive, "keepAliveLowPower": false, "keepAliveSendStatsAsBody": false,
            "modes": modes(),
            "extendedFeatures": ["vocoderInfo", "enhancedRequestCarUI"],
            "displays": displays,
            "hidDevices": [HID.touchDevice(xMax: c.main.widthPixels, yMax: c.main.heightPixels, displayUUID: mainDisplayUUID),
                           HID.knobDevice(displayUUID: mainDisplayUUID),
                           HID.mediaDevice(displayUUID: mainDisplayUUID),
                           HID.telephonyDevice(displayUUID: mainDisplayUUID)],
        ]
        if !c.disableAudioOutput {
            info["audioLatencies"] = audioLatencies()
            info["audioFormats"] = audioFormats(c.entertainmentSampleRate)
        }
        if !c.icons.isEmpty {
            info["oemIconVisible"] = true
            info["oemIconLabel"] = c.oemLabel
            info["oemIcons"] = c.icons.map { ["imageData": $0.data, "widthPixels": $0.widthPixels,
                                              "heightPixels": $0.heightPixels, "prerendered": true] as [String: Any] }
        }
        if c.hevc { info["hevcInfo"] = [String: Any]() }
        return info
    }

    package static func infoResponse(_ c: InfoConfig) throws -> Data { try BPlist.encode(info(c)) }

    // MARK: SETUP 应答

    /// 会话级 SETUP：timingPort + eventPort（+ keepAlivePort），enabledFeatures 同 MacPlay。
    package static func setupSessionResponse(timingPort: Int, eventPort: Int, keepAlivePort: Int = 0,
                                             hevc: Bool = false, altScreen: Bool = false) throws -> Data {
        var r: [String: Any] = ["timingPort": timingPort, "eventPort": eventPort]
        if keepAlivePort != 0 { r["keepAlivePort"] = keepAlivePort }
        var feats: [String] = hevc ? ["hevc", "iAPChannel"] : ["iAPChannel"]
        feats.append("viewAreas")
        if altScreen { feats.append("altScreen") }
        r["enabledFeatures"] = feats
        return try BPlist.encode(r)
    }

    /// 流级 SETUP：每路流回 {type, dataPort}
    package static func setupStreamsResponse(_ streams: [(type: Int, dataPort: Int)]) throws -> Data {
        try BPlist.encode(["streams": streams.map { ["type": $0.type, "dataPort": $0.dataPort] as [String: Any] }])
    }

    // MARK: 事件通道命令

    package static func hidSendReport(uuid: UInt32, report: Data) throws -> Data {
        try BPlist.encode(["type": "hidSendReport", "uuid": String(uuid, radix: 16), "hidReport": report] as [String: Any])
    }

    /// uuid 是显示器的 UUID 字符串（MacPlay 放在 params 里）
    package static func forceKeyFrame(displayUUID: String = mainDisplayUUID) throws -> Data {
        try BPlist.encode(["type": "forceKeyFrame", "params": ["uuid": displayUUID]] as [String: Any])
    }

    package static func requestSiri(action: Int) throws -> Data {
        try BPlist.encode(["type": "requestSiri", "params": ["siriAction": action]] as [String: Any])
    }

    package static func iAPSendMessage(_ data: Data) throws -> Data {
        try BPlist.encode(["type": "iAPSendMessage", "params": ["data": data]] as [String: Any])
    }
}
