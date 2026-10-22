// iOS 27「停車時在 CarPlay 播影片」（CarPlay with AirPlay video）的車機端協定。
// 依據：開源車機 DiPlay 對 iOS 27 與 Apple CarPlay Simulator 的觀察記錄（只取協定事實，程式自己寫）。
// 流程：
//   /info 頂層帶 videoPlaybackInfo（沒帶卻啟用 videoPlayback，手機會拆會話）
//   → 會話 SETUP：手機 features 含 "videoPlayback" → 回 enabledFeatures 含它
//   → 事件通道就緒後送 setVideoPlaybackAllowed（早送會被丟，手機整個會話只放聲音）
//   → 流 SETUP：130 + BB493F61（設定資料流，要開 TCP 口、sync 回空 rply）、130 + A6B27562／E3DC3EA6 且 controlType 1（遙控會話，無 socket，回 streamID 3、4…）
//   → 控制口 POST /command（X-Apple-StreamID）{params:{data:<bplist>}}：insertPlayQueueItem → setRate 1 → 每秒 playbackInfo…
//   → 我們的應答與通知走事件通道 POST /command，帶同一個 X-Apple-StreamID。
// 這個檔只放不碰 socket 的純函式與設定資料流；會話整合在 CarPlaySession.swift。
import Foundation
import Network

package enum CarVideoProtocol {
    package static let feature = "videoPlayback"
    package static let uiURL = "videoplayback:"
    package static let settingsChannelUUID = "BB493F61-A6B8-4769-8D74-80C23A9F71C4"
    package static let remoteControlUUIDs: Set<String> = [
        "A6B27562-B43A-4F2D-B75F-82391E250194",   // video setup
        "E3DC3EA6-E6C3-4B30-847C-B7ACFEBEA654",   // overlay UI
    ]
    /// 播不了時回報手機的 CoreMedia 錯誤碼
    package static let errorNetwork = -17221
    package static let errorDecoder = -12911
    package static let errorIncompatible = -12927

    /// 既有 features 整數再設 bit 0 與 bit 64，轉小端位元組、去掉尾端 0，再 base64
    package static func featuresEx(_ legacy: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: 9)
        var v = UInt64(bitPattern: Int64(legacy)) | 1
        for i in 0..<8 { bytes[i] = UInt8(v & 0xff); v >>= 8 }
        bytes[8] |= 0x01   // bit 64
        while let last = bytes.last, last == 0 { bytes.removeLast() }
        return Data(bytes).base64EncodedString()
    }

    /// /info 頂層的 videoPlaybackInfo
    package static func info(legacyFeatures: Int, allowed: Bool) -> [String: Any] {
        ["videoPlaybackAllowed": allowed,
         "featuresEx": featuresEx(legacyFeatures),
         "playbackCapabilities": [
            "supportsOfflineHLS": false, "supportsAirPlayVideoWithSharePlay": false, "supportsInterstitials": false,
            "supportsIntegratedTimeline": false, "supportsAVMetrics": false, "supportsUIForAudioOnlyContent": true,
            "supportsFPSSecureStop": false,
         ] as [String: Any]]
    }

    /// 會話 SETUP 的 features 陣列裡有沒有 videoPlayback
    package static func proposed(_ setup: [String: Any]) -> Bool {
        ((setup["features"] as? [Any]) ?? []).contains { ($0 as? String) == feature }
    }

    /// 一個佇列項目（只收 http/https；app 自有 scheme 要經手機代載，還沒做）
    package struct Item: Equatable {
        package var uuid: String
        package var url: String
        package var startMs: Int
        package init(uuid: String, url: String, startMs: Int) { self.uuid = uuid; self.url = url; self.startMs = startMs }
    }
    package static func parseItem(_ m: [String: Any]) -> Item? {
        guard let item = m["item"] as? [String: Any], let url = item["Content-Location"] as? String else { return nil }
        let scheme = url.split(separator: ":").first.map { $0.lowercased() } ?? ""
        guard scheme == "http" || scheme == "https" else { return nil }
        var start = (item["Start-Position-Seconds"] as? NSNumber)?.doubleValue
        if start == nil, let t = item["Start-Position"] as? [String: Any] { start = seconds(t) }
        let uuid = (item["uuid"] as? String) ?? (item["uuid"].map { "\($0)" } ?? "")
        return Item(uuid: uuid, url: url, startMs: Int(max(0, (start ?? 0) * 1000)))
    }

    /// CMTime 字典 → 秒
    package static func seconds(_ t: [String: Any]) -> Double? {
        guard let v = (t["value"] as? NSNumber)?.doubleValue, let s = (t["timescale"] as? NSNumber)?.doubleValue, s > 0 else { return nil }
        return v / s
    }
    package static func cmTime(_ s: Double) -> [String: Any] {
        ["value": Int((s * 1000).rounded()), "timescale": 1000, "flags": 1, "epoch": 0]
    }
    private static func range(_ start: Double, _ duration: Double) -> [String: Any] {
        ["start": cmTime(start), "duration": cmTime(duration)]
    }

    /// 桌寵播放器的狀態（接收器快取最新一筆，用來回答手機每秒一次的 playbackInfo）
    package struct PlayerState: Equatable {
        package var prepared = false, playing = false
        package var position = 0.0, duration = 0.0, buffered = 0.0
        package init(prepared: Bool = false, playing: Bool = false, position: Double = 0, duration: Double = 0, buffered: Double = 0) {
            self.prepared = prepared; self.playing = playing; self.position = position; self.duration = duration; self.buffered = buffered
        }
    }

    package static func playbackInfoResponse(messageID: Any?, itemUUID: String?, state: PlayerState?) -> [String: Any] {
        let ready = state?.prepared == true
        var info: [String: Any] = [
            "rate": state?.playing == true ? 1.0 : 0.0,
            "readyToPlay": ready, "playbackLikelyToKeepUp": ready,
            "droppedVideoFrames": 0, "totalVideoFrames": 0, "decodedFrameCount": 0,
            "interstitialInfo": [String: Any](),
            "playbackState": state == nil || !ready ? "loading" : (state!.playing ? "playing" : "paused"),
        ]
        if let itemUUID { info["item"] = ["uuid": itemUUID] }
        if let s = state, ready {
            info["position"] = cmTime(s.position)
            info["duration"] = cmTime(s.duration)
            info["seekableTimeRanges"] = [range(0, s.duration)]
            info["loadedTimeRanges"] = [range(0, s.buffered)]
        }
        var r: [String: Any] = ["info": info, "kind": "response", "type": "playbackInfo"]
        if let messageID { r["messageID"] = messageID }
        return r
    }
    package static func seekResponse(messageID: Any?) -> [String: Any] {
        var r: [String: Any] = ["type": "seek", "kind": "response"]
        if let messageID { r["messageID"] = messageID }
        return r
    }
    /// 回答 property：做不到的不給 value（plist 沒有 null）
    package static func propertyResponse(messageID: Any?, key: String?, state: PlayerState?) -> [String: Any] {
        var r: [String: Any] = ["kind": "response", "type": "property"]
        if let messageID { r["messageID"] = messageID }
        if let key { r["key"] = key }
        let ready = state?.prepared == true
        switch key {
        case "hasEnabledAudio": r["value"] = true
        case "muted": r["value"] = false
        case "seekableTimeRanges" where ready: r["value"] = [range(0, state!.duration)]
        case "loadedTimeRanges" where ready: r["value"] = [range(0, state!.buffered)]
        default: break
        }
        return r
    }
    package static func playbackStateNotification(playing: Bool, itemUUID: String?) -> [String: Any] {
        var r: [String: Any] = ["type": "playbackState", "name": playing ? "playing" : "paused"]
        if playing, let itemUUID { r["item"] = ["uuid": itemUUID] }
        return r
    }
    package static func errorNotification(code: Int, itemUUID: String?) -> [String: Any] {
        var r: [String: Any] = ["type": "error", "error": ["domain": "", "code": code] as [String: Any]]
        if let itemUUID { r["uuid"] = itemUUID }
        return r
    }
    /// 包成 /command 正文：{params:{data:<bplist(message)>}}
    package static func wrap(_ message: [String: Any]) throws -> Data {
        try BPlist.encode(["params": ["data": try BPlist.encode(message)]])
    }
    /// 拆 /command 正文：{params:{data:<bplist>}} → 內層訊息
    package static func unwrap(_ body: Data) -> [String: Any]? {
        guard let outer = try? BPlist.decodeDict(body), let p = outer["params"] as? [String: Any],
              let d = p["data"] as? Data else { return nil }
        return try? BPlist.decodeDict(d)
    }
    package static func setAllowedCommand(_ allowed: Bool) throws -> Data {
        try BPlist.encode(["type": "setVideoPlaybackAllowed", "params": ["videoPlaybackAllowed": allowed]])
    }

    /// sync 的空回覆：32 位元組頭，type "rply"，seq 照抄 sync 的 [20..27]
    package static func reply(toSync header: Data) -> Data {
        var h = Data(count: APTransportPackage.headerLength)
        h[3] = 0x20
        for (i, b) in "rply".utf8.enumerated() { h[4 + i] = b }
        let s = header.startIndex
        for i in 20..<28 { h[i] = header[s + i] }
        return h
    }
    package static func packageType(_ header: Data) -> String {
        let s = header.startIndex
        let bytes = header[(s + 4)..<(s + 16)].prefix { $0 != 0 }
        return String(decoding: bytes, as: UTF8.self)
    }
}

/// 「允許播影片」的送出時機：要等 SETUP 已啟用 videoPlayback、且事件通道就緒；之前只留最新一筆，同值不重送。
package struct CarVideoAllowGate: Equatable {
    package private(set) var desired: Bool?
    private var featureEnabled = false, eventReady = false
    private var lastSent: Bool?
    package init() {}
    /// 回傳現在要送的值（nil＝先不送）
    package mutating func set(desired d: Bool) -> Bool? { desired = d; return flush() }
    package mutating func set(feature on: Bool) -> Bool? {
        if featureEnabled != on { featureEnabled = on; if !on { lastSent = nil } }
        return flush()
    }
    package mutating func set(eventReady on: Bool) -> Bool? {
        if eventReady != on { eventReady = on; if !on { lastSent = nil } }
        return flush()
    }
    /// 會話剛 live：照目前的值再送一次
    package mutating func resend() -> Bool? { lastSent = nil; return flush() }
    private mutating func flush() -> Bool? {
        guard let d = desired, featureEnabled, eventReady, lastSent != d else { return nil }
        lastSent = d
        return d
    }
}

/// 「CarPlayVideo Settings App」資料流：手機連我們的 TCP 口，加密分框與 iAP 隧道同法；每個 sync 回一個空 rply。
/// 拒絕這條流手機會拆會話，所以一定要開。內容（設定訊息）播放用不到，不解析。
package final class CarVideoSettingsChannel {
    private let readKey: Data, writeKey: [UInt8]
    private var listener: NWListener?
    private var conn: NWConnection?
    private var writeCounter: UInt64 = 0
    private let queue = DispatchQueue(label: "session.video-settings")
    package var onLog: ((String) -> Void)?

    package init(readKey: Data, writeKey: Data) { self.readKey = readKey; self.writeKey = [UInt8](writeKey) }

    package func start(timeout: TimeInterval = 5) throws -> UInt16 {
        _ = try IapTunnelParser(key: readKey)
        let l = try NWListener(using: .tcp)
        l.newConnectionHandler = { [weak self] c in self?.accept(c) }
        let port = try listenAndWait(l, queue: queue, timeout: timeout)
        listener = l
        return port
    }
    package func stop() {
        listener?.cancel(); listener = nil
        queue.async { [self] in conn?.cancel(); conn = nil }
    }
    private func accept(_ c: NWConnection) {
        guard let parser = try? IapTunnelParser(key: readKey) else { c.cancel(); return }
        conn?.cancel(); conn = c; writeCounter = 0
        c.start(queue: queue)
        onLog?("影片設定資料流已連上")
        receive(c, parser)
    }
    private func receive(_ c: NWConnection, _ parser: IapTunnelParser) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [weak self] data, _, done, err in
            guard let self, self.conn === c else { return }
            if let data, !data.isEmpty {
                do {
                    for p in try parser.feed(data) where CarVideoProtocol.packageType(p.header) == "sync" {
                        self.send(CarVideoProtocol.reply(toSync: p.header), on: c)
                    }
                } catch { self.onLog?("影片設定資料流解密失敗：\(error)"); c.cancel(); self.conn = nil; return }
            }
            if done || err != nil { self.conn = nil; c.cancel(); return }
            self.receive(c, parser)
        }
    }
    /// 一框：[2B 小端長度][密文][16B 標籤]，AAD＝長度頭，nonce＝4 個 0＋8 位元組小端計數
    private func send(_ plain: Data, on c: NWConnection) {
        let len = UInt16(plain.count)
        let aad: [UInt8] = [UInt8(len & 0xff), UInt8(len >> 8)]
        guard let sealed = try? PairingCrypto.chachaSeal(key: writeKey, nonce: PairingCrypto.nonce64(writeCounter), plaintext: [UInt8](plain), aad: aad) else { return }
        writeCounter += 1
        c.send(content: Data(aad + sealed), completion: .contentProcessed { _ in })
    }
}
