// CarPlay 影片（iOS 27 停車時播影片）的車機端協定：/info、允許的送出時機、播放訊息的應答、設定資料流的 rply
import Foundation
import CoreGraphics
import ImageIO
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

    suite("corner-masks") {
        var d = DisplayConfig(widthPixels: 1088, heightPixels: 1088, viewArea: DisplayInsets(top: 0, bottom: 0, left: 0, right: 0),
                              safeArea: DisplayInsets(top: 36, bottom: 36, left: 36, right: 36), safeAreaDrawOutside: true)
        func mainDisplay(_ d: DisplayConfig) -> [String: Any] {
            let cfg = InfoConfig(sourceVersion: "1", deviceID: "02:00:00:00:00:01", bluetoothMAC: "00:00:00:00:00:01", name: "HomePlay", main: d)
            return ((CarPlayPlist.info(cfg)["displays"] as? [[String: Any]]) ?? []).first ?? [:]
        }
        let plain = mainDisplay(d)
        expect(plain["cornerMasks"] == nil, "no cornerMasks key unless asked")
        expect(((plain["viewAreas"] as? [[String: Any]])?.first?["safeArea"]) != nil, "safeArea kept without cornerMasks")
        d.cornerMasks = true
        let masked = mainDisplay(d)
        expect(masked["cornerMasks"] as? Bool == true, "/info display declares cornerMasks")
        expect(((masked["viewAreas"] as? [[String: Any]])?.first?["safeArea"]) == nil, "cornerMasks drops safeArea (iOS 27 tears down with both)")
        let png = Data([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a] + [UInt8](repeating: 0, count: 60))
        expect(CornerMaskProtocol.find(["topLeftCornerMask": png]) == png, "mask at the top level")
        expect(CornerMaskProtocol.find(["update": ["topLeftCornerMask": png]]) == png, "mask inside update")
        expect(CornerMaskProtocol.find(["streams": [["type": 110, "topLeftCornerMask": png]]]) == png, "mask inside a stream")
        expect(CornerMaskProtocol.find(["topLeftCornerMask": Data(repeating: 1, count: 80)]) == nil, "not a PNG: ignored")
        expect(CornerMaskProtocol.find(["a": ["b": ["c": ["d": ["e": ["topLeftCornerMask": png]]]]]]) == nil, "too deep: ignored")
        // 合成一張 64² 的遮罩（左上角、半徑 40 px，亮＝保留），量對角內縮；再翻成右下角，應該量到一樣的值
        func maskPNG(flip: Bool) -> Data {
            let side = 64, r = 40.0
            var px = [UInt8](repeating: 0, count: side * side)
            for y in 0..<side { for x in 0..<side {
                let dx = max(0, r - (Double(x) + 0.5)), dy = max(0, r - (Double(y) + 0.5))
                let cov = max(0, min(1, r - (dx * dx + dy * dy).squareRoot() + 0.5))
                let (X, Y) = flip ? (side - 1 - x, side - 1 - y) : (x, y)
                px[Y * side + X] = UInt8((cov * 255).rounded())
            } }
            let ctx = CGContext(data: &px, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side,
                                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
            let out = NSMutableData()
            let dst = CGImageDestinationCreateWithData(out as CFMutableData, "public.png" as CFString, 1, nil)!
            CGImageDestinationAddImage(dst, ctx.makeImage()!, nil); CGImageDestinationFinalize(dst)
            return out as Data
        }
        let want = 40 * CornerMaskProtocol.diagPerRadius
        let got = CornerMaskProtocol.diagonalInset(png: maskPNG(flip: false)) ?? -1
        let gotFlip = CornerMaskProtocol.diagonalInset(png: maskPNG(flip: true)) ?? -1
        expect(abs(got - want) < 1 && abs(gotFlip - want) < 1, "mask diagonal inset ≈ r·(1−1/√2) (\(got), flipped \(gotFlip), want \(want))")
        // 同心內縮：s = R − m；iOS 圓角比機身大時只躲圓角
        let s = CornerMaskProtocol.concentricInset(widthPx: 1088, bodyDiag: 0.0398, maskDiag: 0.019)
        let R = 0.0398 / CornerMaskProtocol.diagPerRadius * 1088, m = 0.019 / CornerMaskProtocol.diagPerRadius * 1088
        expect(abs(Double(s) - (R - m)) <= 0.5 && s > 43, "concentric inset = R − m (\(s) px)")
        expect(CornerMaskProtocol.concentricInset(widthPx: 1088, bodyDiag: 0.0398, maskDiag: 0.05) == 43, "rounder iOS: just clear the corner")
        // 圓角記憶：舊格式轉換、按手機版本、三種策略
        let old = CornerMemory(json: ["maskDiag": 0.0182, "build": "24B115"])
        expect(old.masks["24B115"] == 0.0182 && old.lastBuild == "24B115", "old single-value store migrates to per-build")
        var mem = CornerMemory(masks: ["24B115": 0.0182, "19H394": 0.0071, "15H000": 0], lastBuild: "24B115")
        expect(CornerMemory(json: mem.json) == mem, "store round-trips through JSON")
        let ios27 = mem.plan(style: .concentric, widthPx: 1088, bodyDiag: 0.0398)
        mem.lastBuild = "19H394"
        let ios15 = mem.plan(style: .concentric, widthPx: 1088, bodyDiag: 0.0398)
        expect(ios27 == .inset(80) && ios15 == .inset(121), "each phone gets its own concentric inset (iOS 27 80 px, iOS 15 121 px)")
        expect(mem.plan(style: .maximize, widthPx: 1088, bodyDiag: 0.0398) == .inset(44), "maximize: just clear the body corner")
        expect(mem.plan(style: .balanced, widthPx: 1088, bodyDiag: 0.0398) == .inset(83), "balanced: halfway (121 and 44 → 83)")
        mem.lastBuild = "15H000"
        expect(mem.plan(style: .concentric, widthPx: 1088, bodyDiag: 0.0398) == .inset(44), "a release that sends no mask: maximize, never relearn")
        mem.lastBuild = "26A000"
        expect(mem.plan(style: .concentric, widthPx: 1088, bodyDiag: 0.0398) == .learn, "a new release: learn once")
        expect(mem.plan(style: .maximize, widthPx: 1088, bodyDiag: 0.0398) == .inset(44), "maximize never needs learning")
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
