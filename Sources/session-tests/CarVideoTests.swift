// CarPlay 影片（iOS 27 停車時播影片）的車機端協定：/info、允許的送出時機、播放訊息的應答、設定資料流的 rply
import Foundation
import Session

func runCarVideoSuites() {
    suite("carvideo-info") {
        // DiPlay 的觀察值：0x615653aee2 → "465TVmEAAAAB"（e3 ae 53 56 61 00 00 00 01）
        expect(CarVideoProtocol.featuresEx(0x615653aee2) == "465TVmEAAAAB", "featuresEx sets bit 0 and bit 64, little-endian base64")
        let i = CarVideoProtocol.info(legacyFeatures: 0x615653aee2, allowed: true)
        expect(i["videoPlaybackAllowed"] as? Bool == true, "videoPlaybackInfo carries the allowed flag")
        let caps = i["playbackCapabilities"] as? [String: Any] ?? [:]
        expect(caps.count == 7 && caps["supportsUIForAudioOnlyContent"] as? Bool == true, "seven capabilities, audio-only UI on")
        var cfg = InfoConfig(sourceVersion: "1", deviceID: "02:00:00:00:00:01", bluetoothMAC: "00:00:00:00:00:01", name: "HomePlay",
                             main: DisplayConfig(widthPixels: 1088, heightPixels: 1088))
        expect(CarPlayPlist.info(cfg)["videoPlaybackInfo"] == nil, "/info has no videoPlaybackInfo unless enabled")
        cfg.videoPlayback = true; cfg.videoAllowed = false
        let vi = CarPlayPlist.info(cfg)["videoPlaybackInfo"] as? [String: Any]
        expect(vi?["videoPlaybackAllowed"] as? Bool == false, "/info videoPlaybackInfo follows the setting")
        expect((try? CarPlayPlist.infoResponse(cfg)) != nil, "/info with video still encodes as a bplist")
        expect(CarVideoProtocol.proposed(["features": ["hevc", "videoPlayback"]]), "SETUP features with videoPlayback = proposed")
        expect(!CarVideoProtocol.proposed(["timingPort": 1]), "no features array = not proposed")
    }

    suite("carvideo-allow-gate") {
        var g = CarVideoAllowGate()
        expect(g.set(desired: true) == nil, "nothing sent before SETUP enables the feature")
        expect(g.set(feature: true) == nil, "still waits for the event channel")
        expect(g.set(eventReady: true) == true, "both ready → send the latest value")
        expect(g.set(desired: true) == nil, "same value is not sent twice")
        expect(g.set(desired: false) == false, "a change is sent at once")
        _ = g.set(eventReady: false)
        expect(g.set(eventReady: true) == false, "event channel reconnect → send again")
        expect(g.resend() == false, "session going live → resend current value")
    }

    suite("carvideo-messages") {
        let insert: [String: Any] = ["type": "insertPlayQueueItem",
                                     "item": ["uuid": "A1", "Content-Location": "https://example.com/v.m3u8",
                                              "Start-Position": ["value": 12_500_000_000, "timescale": 1_000_000_000, "flags": 1, "epoch": 0]]]
        let item = CarVideoProtocol.parseItem(insert)
        expect(item == .init(uuid: "A1", url: "https://example.com/v.m3u8", startMs: 12500), "insertPlayQueueItem → url, uuid, CMTime start")
        expect(CarVideoProtocol.parseItem(["item": ["uuid": "B", "Content-Location": "mainm3u8://x"]]) == nil, "app-scheme URLs are refused for now")
        expect(CarVideoProtocol.parseItem(["item": ["uuid": "C", "Content-Location": "file:///etc/passwd"]]) == nil, "local schemes are refused")
        // {params:{data:<bplist>}} 來回
        let wrapped = try CarVideoProtocol.wrap(["type": "playbackInfo", "kind": "request", "messageID": 7])
        let back = CarVideoProtocol.unwrap(wrapped)
        expect(back?["type"] as? String == "playbackInfo" && (back?["messageID"] as? NSNumber)?.intValue == 7, "wrap/unwrap round-trips the inner bplist")
        // 未就緒：loading、沒有 position；就緒：CMTime 毫秒
        let loading = CarVideoProtocol.playbackInfoResponse(messageID: 7, itemUUID: "A1", state: nil)
        let li = loading["info"] as? [String: Any] ?? [:]
        expect(li["playbackState"] as? String == "loading" && li["position"] == nil, "not ready → loading, no position")
        expect((try? BPlist.encode(loading)) != nil, "loading response has no nulls (encodes)")
        let st = CarVideoProtocol.PlayerState(prepared: true, playing: true, position: 3.25, duration: 60, buffered: 20)
        let ready = CarVideoProtocol.playbackInfoResponse(messageID: 8, itemUUID: "A1", state: st)
        let ri = ready["info"] as? [String: Any] ?? [:]
        expect(ri["playbackState"] as? String == "playing" && (ri["rate"] as? Double) == 1.0, "playing → rate 1.0")
        expect(((ri["position"] as? [String: Any])?["value"] as? Int) == 3250, "position is a CMTime in ms")
        expect(ready["kind"] as? String == "response" && (ready["messageID"] as? Int) == 8, "response echoes messageID")
        let prop = CarVideoProtocol.propertyResponse(messageID: 9, key: "somethingElse", state: st)
        expect(prop["value"] == nil && (try? BPlist.encode(prop)) != nil, "unknown property → no value key")
        let n = CarVideoProtocol.playbackStateNotification(playing: false, itemUUID: "A1")
        expect(n["name"] as? String == "paused" && n["item"] == nil, "paused notification carries no item")
        expect(try CarVideoProtocol.setAllowedCommand(true).count > 0, "setVideoPlaybackAllowed encodes")
    }

    suite("carvideo-settings-rply") {
        var sync = Data(count: 32)
        sync[3] = 0x20
        for (i, b) in "sync".utf8.enumerated() { sync[4 + i] = b }
        for i in 20..<28 { sync[i] = UInt8(i) }
        let r = CarVideoProtocol.reply(toSync: sync)
        expect(r.count == 32 && r[3] == 0x20, "rply is a bare 32-byte header")
        expect(CarVideoProtocol.packageType(r) == "rply" && CarVideoProtocol.packageType(sync) == "sync", "package type read from bytes 4…15")
        expect(Array(r[20..<28]) == Array(sync[20..<28]), "rply echoes the sync sequence number")
    }
}
