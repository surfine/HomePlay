import Foundation

// iAP2 控制会话消息（CSM）的纯编解码。线格式：0x4040 | u16 总长 | u16 消息 | 参数体，大端、无校验。
// 参数体：u16 参数长（含自身）| u16 参数 ID | 载荷，可重复、按序。
// 协议格式参考固定上游（见 docs/handoff/ws2-reuse-2026-10-07/carplay.md）；实现为原创 Swift。

package enum Iap2Csm {

    package static let start: UInt16 = 0x4040
    package static let headerBytes = 6
    package static let maxFrameBytes = 0xffff
    package static let maxBodyBytes = maxFrameBytes - headerBytes
    package static let paramHeaderBytes = 4
    package static let maxParamBytes = 0xffff

    /// 识别信息要按链路换布局：USB（carkit）要 USB host transport 组件（param 16），
    /// 蓝牙要 bluetooth + wireless CarPlay 组件（param 17/24），不能混用。
    package enum Transport: UInt8 { case wireless = 0, wired = 2 }

    package struct Frame: Equatable {
        package var messageId: UInt16
        package var parameters: [Parameter]

        package init(messageId: UInt16, parameters: [Parameter] = []) {
            self.messageId = messageId
            self.parameters = parameters
        }

        package var encoded: [UInt8] {
            var body: [UInt8] = []
            for parameter in parameters { body += parameter.encoded }
            var out: [UInt8] = []
            out += be16(Iap2Csm.start)
            out += be16(UInt16(Iap2Csm.headerBytes + body.count))
            out += be16(messageId)
            out += body
            return out
        }
    }

    package struct Parameter: Equatable {
        package var id: UInt16
        package var payload: [UInt8]

        package init(id: UInt16, payload: [UInt8]) { self.id = id; self.payload = payload }

        package var encoded: [UInt8] {
            be16(UInt16(Iap2Csm.paramHeaderBytes + payload.count)) + be16(id) + payload
        }
    }

    /// 从字节流里解出所有完整 CSM 帧；残缺的留在缓冲区（返回偏移）。垃圾字节逐字节跳过。
    package static func parse(from buffer: [UInt8]) -> (frames: [Frame], consumed: Int) {
        var frames: [Frame] = []
        var index = 0
        while index + headerBytes <= buffer.count {
            if be16At(buffer, index) != start {
                index += 1
                continue
            }
            let length = Int(be16At(buffer, index + 2))
            guard length >= headerBytes, length <= maxFrameBytes else { index += 1; continue }
            guard index + length <= buffer.count else { break }
            let messageId = be16At(buffer, index + 4)
            let body = Array(buffer[(index + headerBytes)..<(index + length)])
            guard let parameters = parseParameters(body) else { index += 1; continue }
            frames.append(Frame(messageId: messageId, parameters: parameters))
            index += length
        }
        return (frames, index)
    }

    package static func parseParameters(_ body: [UInt8]) -> [Parameter]? {
        var parameters: [Parameter] = []
        var offset = 0
        while offset < body.count {
            guard offset + paramHeaderBytes <= body.count else { return nil }
            let length = Int(be16At(body, offset))
            guard length >= paramHeaderBytes, offset + length <= body.count else { return nil }
            parameters.append(Parameter(
                id: be16At(body, offset + 2),
                payload: Array(body[(offset + paramHeaderBytes)..<(offset + length)])))
            offset += length
        }
        return parameters
    }

    // MARK: 消息常量（识别与配件认证）

    package enum Identify {
        package static let start: UInt16 = 0x1d00
        package static let information: UInt16 = 0x1d01
        package static let accepted: UInt16 = 0x1d02
        package static let rejected: UInt16 = 0x1d03
    }

    package enum Mfi {
        package static let requestCertificate: UInt16 = 0xaa00
        package static let certificate: UInt16 = 0xaa01
        package static let requestChallenge: UInt16 = 0xaa02
        package static let response: UInt16 = 0xaa03
        package static let failed: UInt16 = 0xaa04
        package static let succeeded: UInt16 = 0xaa05

        package static let maximumChallengeBytes = 128
        package static let maximumCertificateBytes = 65_525
    }

    // MARK: 识别信息（0x1d01）的参数布局
    // 参数 0-5 是 NUL 结尾串：名字、型号、厂商、序列号、固件、硬件。
    // 6：本端会发的消息 ID 表（u16 拼接）；7：本端会收的消息表；8：u8（无线 0 / 有线 2）；9：u16 常量 20。
    // 10：外设协议组；12/13：语言；17：蓝牙传输组；24：Wi-Fi 组；30：路线引导组。

    package static let messagesSentByAccessory: [UInt16] = [
        0xaa01, 0xaa03,            // 配件认证：证书、应答
        0x5000, 0x5002,            // 正在播放更新开关
        0x5200, 0x5203,            // 路线引导更新开关
        0xae00, 0xae02,            // 电源更新开关
        0x4157, 0x4159,            // 通讯更新开关
        0x4154, 0x4156,            // 通话状态更新开关
        0x4301,                    // CarPlay 开始会话
        0x5703,                    // Wi-Fi 配置信息（无线）
        0x5700,                    // Wi-Fi 資訊分享：向 iPhone 要它現在連的網路（iPhone 問一次「分享 Wi-Fi？」）
    ]

    package static let messagesReceivedFromPhone: [UInt16] = [
        0xaa00, 0xaa02, 0xaa04, 0xaa05, // 配件认证全套
        0xea00, 0xea01,            // 外设协议会话开关
        0x5001, 0x5201, 0x5202,    // 正在播放 / 路线引导更新
        0xae01,                    // 电源更新
        0x4158, 0x4155,            // 通讯 / 通话状态更新
        0x4300,                    // CarPlay 可用性
        0x4e0d, 0x4e0e, 0x5702,    // 无线：手机侧 Wi-Fi/链路消息
        0x5701,                    // Wi-Fi 資訊分享的回覆（名稱＋密碼）
    ]

    // MARK: Wi-Fi 資訊分享（配件向 iPhone 要它目前的 Wi-Fi；iPhone 先問使用者）
    package static let requestWiFiInformation: UInt16 = 0x5700
    package static let wiFiInformation: UInt16 = 0x5701
    package static func requestWiFiInformationFrame() -> Frame { Frame(messageId: requestWiFiInformation, parameters: []) }
    /// 0x5701：0＝狀態（0 成功）、1＝一個位元組（推測是安全類型）、2＝SSID、3＝密碼（UTF-8，帶 NUL）。真機 iOS 27 2026-10-25 量到的欄位
    package static func parseWiFiInformation(_ f: Frame) -> (status: Int, ssid: String?, passphrase: String?) {
        func text(_ id: UInt16) -> String? {
            guard let p = f.parameters.first(where: { $0.id == id }) else { return nil }
            let bytes = p.payload.prefix { $0 != 0 }
            return String(bytes: bytes, encoding: .utf8)
        }
        let status: Int = f.parameters.first(where: { $0.id == 0 })?.payload.first.map { Int($0) } ?? 0
        return (status, text(2), text(3))
    }

    /// 无线（蓝牙引导）识别信息。mac 是六段冒号大写地址；ssid 不为空。
    package static func identificationInformation(
        name: String, model: String, manufacturer: String, serialNumber: String,
        firmwareVersion: String, hardwareVersion: String, externalAccessoryProtocol: String,
        bluetoothMac: String, ssid: String, language: String = "zh-Hans",
        transport: Transport = .wireless
    ) -> Frame {
        let wired = transport == .wired
        var sent = messagesSentByAccessory
        if wired { sent.append(0xae03) }   // PowerSourceUpdate（照 MacPlay：有线才宣称供电）
        var parameters: [Parameter] = [
            Parameter(id: 0, payload: nul(name)),
            Parameter(id: 1, payload: nul(model)),
            Parameter(id: 2, payload: nul(manufacturer)),
            Parameter(id: 3, payload: nul(serialNumber)),
            Parameter(id: 4, payload: nul(firmwareVersion)),
            Parameter(id: 5, payload: nul(hardwareVersion)),
            Parameter(id: 6, payload: u16List(sent)),
            Parameter(id: 7, payload: u16List(messagesReceivedFromPhone)),
            Parameter(id: 8, payload: [wired ? 2 : 0]), // 供电能力：有线 Advanced / 无线 None
            Parameter(id: 9, payload: be16(20)),
            Parameter(id: 10, payload: encodeParameters([
                Parameter(id: 0, payload: [1]),
                Parameter(id: 1, payload: nul(externalAccessoryProtocol)),
                Parameter(id: 2, payload: [4]),   // match_action＝NoActionNoCommunication（照 MacPlay；空載荷會被手機拒 0x1D03）
            ])),
            Parameter(id: 12, payload: nul(language)),
            Parameter(id: 13, payload: nul(language)),
        ]
        if wired {
            // USBHostTransportComponent：id/name/iap2、car_play_interface_number、supports_car_play、iap2 再声明一次
            parameters.append(Parameter(id: 16, payload: encodeParameters([
                Parameter(id: 0, payload: be16(0)),
                Parameter(id: 1, payload: nul("USBHostTransport")),
                Parameter(id: 2, payload: []),
                Parameter(id: 3, payload: [3]),
                Parameter(id: 4, payload: []),
                Parameter(id: 5, payload: []),
            ])))
        } else {
            parameters.append(Parameter(id: 17, payload: encodeParameters([
                Parameter(id: 0, payload: be16(0)),
                Parameter(id: 1, payload: nul("blue")),
                Parameter(id: 2, payload: []),
                Parameter(id: 3, payload: macBytes(bluetoothMac) ?? []),
                Parameter(id: 4, payload: nul("blue")),
                Parameter(id: 5, payload: []),
            ])))
            parameters.append(Parameter(id: 24, payload: encodeParameters([
                Parameter(id: 0, payload: be16(1)),
                Parameter(id: 1, payload: nul(ssid)),
                Parameter(id: 2, payload: []),
                Parameter(id: 3, payload: be16(1)),
                Parameter(id: 4, payload: []),
                Parameter(id: 5, payload: []),
            ])))
        }
        parameters.append(Parameter(id: 30, payload: encodeParameters([
            Parameter(id: 0, payload: be16(42)),
            Parameter(id: 1, payload: nul("RouteGuidance")),
            Parameter(id: 2, payload: be16(64)),
            Parameter(id: 4, payload: be16(64)),
            Parameter(id: 6, payload: be16(8)),
        ])))
        return Frame(messageId: Identify.information, parameters: parameters)
    }

    package static func accessoryCertificate(_ certificate: [UInt8]) -> Frame {
        Frame(messageId: Mfi.certificate, parameters: [
            Parameter(id: 0, payload: certificate),
        ])
    }

    /// 0x5200 StartRouteGuidanceUpdates：display_component_id 省略（MacPlay 同款）
    package static func startRouteGuidanceUpdates() -> Frame { Frame(messageId: 0x5200) }

    /// 0xAE00 StartPowerUpdates：只订阅外部充电/充电状态/电量（MacPlay 同款）
    package static func startPowerUpdates() -> Frame {
        Frame(messageId: 0xae00, parameters: [4, 5, 6].map { Parameter(id: UInt16($0), payload: []) })
    }

    /// 0x4157 StartCommunicationsUpdates：信号/运营商名/蜂窝支持（MacPlay 同款）
    package static func startCommunicationsUpdates() -> Frame {
        Frame(messageId: 0x4157, parameters: [0, 4, 5].map { Parameter(id: UInt16($0), payload: []) })
    }

    /// 0x4154 StartCallStateUpdates：MacPlay 同款字段集合
    package static func startCallStateUpdates() -> Frame {
        Frame(messageId: 0x4154, parameters: [0, 1, 2, 3, 4, 11].map { Parameter(id: UInt16($0), payload: []) })
    }

    /// 0xAE03 PowerSourceUpdate（有线）：0 可用电流 mA（u16）、1 应充电（bool）
    package static func powerSourceUpdate(availableCurrentMa: UInt16, shouldCharge: Bool) -> Frame {
        Frame(messageId: 0xae03, parameters: [
            Parameter(id: 0, payload: be16(availableCurrentMa)),
            Parameter(id: 1, payload: [shouldCharge ? 1 : 0]),
        ])
    }

    package static func authenticationResponse(_ signature: [UInt8]) -> Frame {
        Frame(messageId: Mfi.response, parameters: [
            Parameter(id: 0, payload: signature),
        ])
    }

    // MARK: 无线 CarPlay 交接（行为参照 MacPlay/LIVI 的 iap2-csm wifi.rs、car_play.rs、bringup.rs）
    // 手机先发 0x5702 要 Wi-Fi 配置 → 我们回 0x5703；手机再发 0x4300（CarPlay 可用性）→ 我们回 0x4301 开会话。
    // 编码：str = UTF-8 + NUL；enum/u8 = 1 字节；u32 = 4 字节大端；list = 一个参数里元素载荷直接拼接；group = 嵌套参数表。

    package enum CarPlay {
        package static let wifiConfigRequest: UInt16 = 0x5702
        package static let wifiConfig: UInt16 = 0x5703
        package static let availability: UInt16 = 0x4300
        package static let startSession: UInt16 = 0x4301
    }

    package enum NowPlaying {
        package static let startUpdates: UInt16 = 0x5000
        package static let update: UInt16 = 0x5001
        package static let stopUpdates: UInt16 = 0x5002
        package static let setInfo: UInt16 = 0x5003
    }

    /// 手机经 iAP2 0x5001 送来的「正在播放」。字段都可缺省（手机常发增量更新），
    /// 接收端用 merge 保留上一笔；trackId 变了才清空旧曲目。
    package struct PhoneNowPlaying: Equatable {
        package var trackId: UInt64?
        package var title: String?
        package var artist: String?
        package var album: String?
        package var durationMs: UInt32?
        package var artworkId: UInt8?
        package var status: UInt8?          // 0 stopped / 1 playing / 2 paused / 3 seekFwd / 4 seekBack
        package var elapsedMs: UInt32?
        package var appName: String?
        package var appBundleID: String?
        package var playbackSpeed: UInt16?  // percentage
        package var canSeek: Bool?

        package init() {}

        package var playing: Bool? {
            guard let status else { return nil }
            return status == 1 || status == 3 || status == 4
        }

        package mutating func merge(_ n: PhoneNowPlaying) {
            if let id = n.trackId, id != trackId {
                self = PhoneNowPlaying()
                trackId = id
            } else if let id = n.trackId { trackId = id }
            if let v = n.title { title = v }
            if let v = n.artist { artist = v }
            if let v = n.album { album = v }
            if let v = n.durationMs { durationMs = v }
            if let v = n.artworkId { artworkId = v }
            if let v = n.status { status = v }
            if let v = n.elapsedMs { elapsedMs = v }
            if let v = n.appName { appName = v }
            if let v = n.appBundleID { appBundleID = v }
            if let v = n.playbackSpeed { playbackSpeed = v }
            if let v = n.canSeek { canSeek = v }
        }
    }

    /// 0x5000 StartNowPlayingUpdates：订阅媒体/播放两组字段（flag 是空载荷参数）。
    /// 属性 ID 必须都在 iAP2 定义内：播放组是 0 状态、1 已播毫秒、7 App 名、16 bundle id；
    /// 12/13 不在播放组里，带着它们手机会整条订阅失败（2026-10-20 真机：一个 0x5001 都不来）。
    package static func startNowPlayingUpdates() -> Frame {
        let media = [0, 1, 4, 6, 12, 14, 16, 26].map { Parameter(id: UInt16($0), payload: []) }
        let playback = [0, 1, 7, 16].map { Parameter(id: UInt16($0), payload: []) }
        return Frame(messageId: NowPlaying.startUpdates, parameters: [
            Parameter(id: 0, payload: encodeParameters(media)),
            Parameter(id: 1, payload: encodeParameters(playback)),
        ])
    }

    /// 0x5003 SetNowPlayingInformation：绝对进度（毫秒）
    package static func setNowPlayingInformation(elapsedMs: UInt32) -> Frame {
        Frame(messageId: NowPlaying.setInfo, parameters: [Parameter(id: 0, payload: be32(elapsedMs))])
    }

    package static func phoneNowPlaying(_ frame: Frame) -> PhoneNowPlaying? {
        guard frame.messageId == NowPlaying.update else { return nil }
        var out = PhoneNowPlaying()
        if let group = frame.parameters.first(where: { $0.id == 0 })?.payload,
           let media = parseParameters(group) {
            out.trackId = u64Param(media, 0)
            out.title = stringParam(media, 1)
            out.durationMs = u32Param(media, 4)
            out.album = stringParam(media, 6)
            out.artist = stringParam(media, 12)
            out.artworkId = u8Param(media, 26)
        }
        if let group = frame.parameters.first(where: { $0.id == 1 })?.payload,
           let playback = parseParameters(group) {
            out.status = u8Param(playback, 0)
            out.elapsedMs = u32Param(playback, 1)
            out.appName = stringParam(playback, 7)
            out.playbackSpeed = u16Param(playback, 12)
            if let b = playback.first(where: { $0.id == 13 })?.payload {
                out.canSeek = b.isEmpty || b == [1]
            }
            out.appBundleID = stringParam(playback, 16)
        }
        return out
    }

    package enum WiFiSecurity: UInt8 { case none = 0, wep = 1, wpaWpa2 = 2, wpa3Transition = 3, wpa3Only = 4 }

    /// 0x5703 AccessoryWiFiConfigurationInformation：1 ssid、2 passphrase、3 security、4 channel
    package static func accessoryWiFiConfiguration(ssid: String, passphrase: String, security: WiFiSecurity, channel: UInt8) -> Frame {
        // 0x5703 的 security 枚举止于 2（WPA2 或 WPA2/WPA3 过渡）；3/4 是 0x4301 的
        // CarPlayWiFiSecurityType，塞进这里手机会拒绝整份 Wi-Fi 配置（2026-10-20 对照 LIVI 源码）。
        let wire = min(security.rawValue, WiFiSecurity.wpaWpa2.rawValue)
        return Frame(messageId: CarPlay.wifiConfig, parameters: [
            Parameter(id: 1, payload: nul(ssid)),
            Parameter(id: 2, payload: nul(passphrase)),
            Parameter(id: 3, payload: [wire]),
            Parameter(id: 4, payload: [channel]),
        ])
    }

    /// 0x4301 CarPlayStartSession（无线）：1 = 无线组{0 ssid、1 passphrase、2 channel、3 ip 列表、4 security}，
    /// 2 port（u32）、3 deviceIdentifier（AirPlay 设备身份，须与 TXT deviceid 一致）、
    /// 4 配对标识 pi（字段名叫 public_key，但 iOS 按「配对标识」解析并要求与 TXT pi 一致；不是 Ed25519 公钥）、
    /// 5 source_version。
    package static func carPlayStartSessionWireless(
        ssid: String, passphrase: String, channel: UInt8, ipAddresses: [String], security: WiFiSecurity,
        port: UInt32, deviceIdentifier: String?, publicKey: String, sourceVersion: String
    ) -> Frame {
        var group: [Parameter] = [
            Parameter(id: 0, payload: nul(ssid)),
            Parameter(id: 1, payload: nul(passphrase)),
            Parameter(id: 2, payload: [channel]),
        ]
        if !ipAddresses.isEmpty { group.append(Parameter(id: 3, payload: ipAddresses.flatMap { nul($0) })) }
        group.append(Parameter(id: 4, payload: [security.rawValue]))
        var parameters = [
            Parameter(id: 1, payload: encodeParameters(group)),
            Parameter(id: 2, payload: be32(port)),
        ]
        if let deviceIdentifier { parameters.append(Parameter(id: 3, payload: nul(deviceIdentifier))) }
        parameters.append(Parameter(id: 4, payload: nul(publicKey)))
        parameters.append(Parameter(id: 5, payload: nul(sourceVersion)))
        return Frame(messageId: CarPlay.startSession, parameters: parameters)
    }

    /// 0x4301 有线版：参数 0＝有线组（子 0＝IP 列表，放 AV 网口的链路本地地址），
    /// 2＝端口、3＝deviceID（AV 网口宿主侧 MAC）、4＝配对标识 pi（与 TXT pi 一致，不是公钥）、5＝sourceVersion
    /// （对照 MacPlay iap2-csm car_play.rs 的 CarPlayStartSessionWiredAttributes 与 bringup.rs 的
    /// carplay_start_session 有线分支；iAP2 字段名 public_key 是历史误名）。
    package static func carPlayStartSessionWired(
        ipAddresses: [String], port: UInt32, deviceIdentifier: String?, publicKey: String, sourceVersion: String
    ) -> Frame {
        var group: [Parameter] = []
        if !ipAddresses.isEmpty { group.append(Parameter(id: 0, payload: ipAddresses.flatMap { nul($0) })) }
        var parameters = [
            Parameter(id: 2, payload: be32(port)),
        ]
        if !group.isEmpty { parameters.insert(Parameter(id: 0, payload: encodeParameters(group)), at: 0) }
        if let deviceIdentifier { parameters.append(Parameter(id: 3, payload: nul(deviceIdentifier))) }
        parameters.append(Parameter(id: 4, payload: nul(publicKey)))
        parameters.append(Parameter(id: 5, payload: nul(sourceVersion)))
        return Frame(messageId: CarPlay.startSession, parameters: parameters)
    }

    /// 0x4300 CarPlayAvailability 里无线组（参数 1）的 available（子参数 0，bool）；没有就是 nil
    package static func wirelessCarPlayAvailable(_ frame: Frame) -> Bool? {
        guard frame.messageId == CarPlay.availability,
              let group = frame.parameters.first(where: { $0.id == 1 }),
              let sub = parseParameters(group.payload),
              let flag = sub.first(where: { $0.id == 0 })?.payload.first else { return nil }
        return flag != 0
    }

    /// 0x4300 的两组属性（对照 MacPlay iap2-csm car_play.rs 的 CarPlayAvailability）：
    /// 参数 0＝有线组{0 available、1 usb transport id}，参数 1＝无线组{0 available、1 bluetooth transport id}。
    /// 只用于日志取证：手机在 USB 链路上也可能同时/只报无线可用，不先看清就会答错 0x4301 的类型。
    package struct CarPlayAvailability: Equatable {
        package var wiredAvailable: Bool?
        package var wirelessAvailable: Bool?
        package var wiredTransportId: String?
        package var wirelessTransportId: String?
        package var isEmpty: Bool {
            wiredAvailable == nil && wirelessAvailable == nil
                && wiredTransportId == nil && wirelessTransportId == nil
        }
        package var summary: String {
            let wired = wiredAvailable.map { $0 ? "可用" : "不可用" } ?? "未报"
            let wireless = wirelessAvailable.map { $0 ? "可用" : "不可用" } ?? "未报"
            var out = "有线=\(wired) 无线=\(wireless)"
            if let id = wiredTransportId, !id.isEmpty { out += " \(id)" }
            if let id = wirelessTransportId, !id.isEmpty { out += " \(id)" }
            return out
        }
    }

    package static func carPlayAvailability(_ frame: Frame) -> CarPlayAvailability? {
        guard frame.messageId == CarPlay.availability else { return nil }
        var out = CarPlayAvailability()
        if let group = frame.parameters.first(where: { $0.id == 0 })?.payload,
           let sub = parseParameters(group) {
            if let flag = sub.first(where: { $0.id == 0 })?.payload.first { out.wiredAvailable = flag != 0 }
            out.wiredTransportId = stringParam(sub, 1)
        }
        if let group = frame.parameters.first(where: { $0.id == 1 })?.payload,
           let sub = parseParameters(group) {
            if let flag = sub.first(where: { $0.id == 0 })?.payload.first { out.wirelessAvailable = flag != 0 }
            out.wirelessTransportId = stringParam(sub, 1)
        }
        return out
    }

    package static func challenge(of frame: Frame) -> [UInt8]? {
        frame.parameters.first { $0.id == 0 }?.payload
    }

    /// 组参数：嵌套的同格式参数表，整体作为外层参数的载荷。
    package static func encodeParameters(_ parameters: [Parameter]) -> [UInt8] {
        parameters.flatMap { $0.encoded }
    }

    // MARK: 小工具

    package static func nul(_ string: String) -> [UInt8] {
        Array(string.utf8) + [0]
    }

    package static func u16List(_ values: [UInt16]) -> [UInt8] {
        values.flatMap { be16($0) }
    }

    package static func macBytes(_ mac: String) -> [UInt8]? {
        let parts = mac.split(separator: ":")
        guard parts.count == 6 else { return nil }
        var out: [UInt8] = []
        for part in parts {
            guard let value = UInt8(part, radix: 16) else { return nil }
            out.append(value)
        }
        return out
    }

    package static func be16(_ value: UInt16) -> [UInt8] {
        [UInt8(value >> 8 & 0xff), UInt8(value & 0xff)]
    }

    package static func be32(_ value: UInt32) -> [UInt8] {
        [UInt8(value >> 24 & 0xff), UInt8(value >> 16 & 0xff), UInt8(value >> 8 & 0xff), UInt8(value & 0xff)]
    }

    package static func be16At(_ bytes: [UInt8], _ offset: Int) -> UInt16 {
        UInt16(bytes[offset]) << 8 | UInt16(bytes[offset + 1])
    }

    private static func payload(_ params: [Parameter], _ id: UInt16) -> [UInt8]? {
        params.first { $0.id == id }?.payload
    }
    private static func stringParam(_ params: [Parameter], _ id: UInt16) -> String? {
        guard let b = payload(params, id) else { return nil }
        let cut = b.last == 0 ? b.dropLast() : b[...]
        return String(bytes: cut, encoding: .utf8)
    }
    private static func u16Param(_ params: [Parameter], _ id: UInt16) -> UInt16? {
        guard let b = payload(params, id), b.count == 2 else { return nil }
        return UInt16(b[0]) << 8 | UInt16(b[1])
    }
    private static func u32Param(_ params: [Parameter], _ id: UInt16) -> UInt32? {
        guard let b = payload(params, id), b.count == 4 else { return nil }
        return UInt32(b[0]) << 24 | UInt32(b[1]) << 16 | UInt32(b[2]) << 8 | UInt32(b[3])
    }
    private static func u64Param(_ params: [Parameter], _ id: UInt16) -> UInt64? {
        guard let b = payload(params, id), b.count == 8 else { return nil }
        return b.reduce(0) { $0 << 8 | UInt64($1) }
    }
    private static func u8Param(_ params: [Parameter], _ id: UInt16) -> UInt8? {
        guard let b = payload(params, id), b.count == 1 else { return nil }
        return b[0]
    }
}
