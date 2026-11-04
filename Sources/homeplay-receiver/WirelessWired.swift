import AppKit
import Foundation
import QuartzCore
import Network
import CoreWLAN
import IOBluetooth
import IOKit
import IAP2
import Session
import H264
import Wire

// 有線（USB）路徑。行文本自 Wireless.swift 拆出。
extension Wireless {
    // MARK: 有线（USB）路径：usbmuxd carkit 流上跑同一套 iAP2 核心；
    // 手机报 0x4300 时回有线版开会话（AV 走它自己的 NCM 网口连回控制口），不需要 Wi-Fi。
    static func runWired(_ o: Options, server: WSServer) -> Never {
        let identity: Iap2MfiIdentity
        do { identity = try Iap2MfiIdentity(directory: o.identityDir) }
        catch { note("身份加载失败：\(error)"); exit(2) }
        note("身份自检通过（证书 \(identity.certificate.count) 字节，内容不打印）")

        let store = PairingStore()
        let (s, h264) = makeSession(o: o, server: server, store: store, identity: identity) { $0.probeForPhone = false }   // 有线不用 _carplay-ctrl 探测，手机直接连回来
        s.onLog = { note($0) }
        s.onActive = { live = true; DispatchQueue.main.async { server.broadcastText(#"{"type":"session","state":"started"}"#) }; note("会话开始，等画面") }
        s.onEnded = { why in live = false; DispatchQueue.main.async { server.broadcastText(#"{"type":"session","state":"ended"}"#) }; note("会话结束：\(why)") }
        do { try s.start() } catch {
            if isAddressInUse(error) {
                // 登录瞬间桌宠与 launchd 可能同时拉起接收器：端口被占时优雅退出，
                // 避免 KeepAlive 每 10 秒重启一次（2026-10-20 重启实测的 spawm 循环）。
                note("控制口 \(o.controlPort) 已被另一个接收器实例占用：本实例退出（不重启）")
                exit(0)
            }
            note("控制口 \(o.controlPort) 起不来：\(error)"); exit(1)
        }
        session = s; sink = h264

        server.onConnect = { conn in
            server.sendText(Wire.helloJSON(name: "CarPlay (有线)", width: o.width, height: o.height), to: conn)
            if let m = Wireless.lastCornerMask { server.sendText(m, to: conn) }
            if let config = h264.lastConfig { server.sendBinary(config, to: conn) }
            if let json = Wireless.cachedNowPlaying() { server.sendText(json, to: conn) }
            if let art = Wireless.cachedArtwork() { server.sendText(art, to: conn) }
            for text in Wireless.cachedTelephony() { server.sendText(text, to: conn) }
            s.requestKeyframe()
        }
        server.onText = { text in
            if text.contains("\"type\":\"stop\"") {
                note("收到斷開指令，結束 CarPlay 會話")
                Wireless.shutdown()
                DispatchQueue.main.asyncAfter(deadline: .now() + Wireless.exitGrace) { exit(0) }
                return
            }
            if text.contains("\"keyframe\"") { s.requestKeyframe() }
            if let t = Touch.parse(text) { s.sendTouch(x: t.x, y: t.y, down: t.down) }
            if let b = mediaButton(text) { s.sendMedia(b) }
            phoneControl(text, session: s)
            carVideoFromPet(text, session: s)
            applySeek(text)
        }
        server.start()

        var backoff = BackoffSchedule(ladder: [5, 10, 20, 30, 60], slow: 60)
        var retryItem: DispatchWorkItem?
        func scheduleUsbRetry(after delay: TimeInterval, because reason: String) {
            retryItem?.cancel()
            note("USB \(Int(delay))s 后重试（\(reason)）")
            let item = DispatchWorkItem { usbSupervise() }
            retryItem = item
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
        }

        func usbSupervise() {
            guard let device = (try? Usbmuxd.listDevices())?.first else {
                scheduleUsbRetry(after: 3, because: "没插 USB 设备")
                return
            }
            let tag = String(device.serial.prefix(8))
            note("USB 设备 \(tag)：开 carkit")
            let acc: Iap2UsbAccessory
            do {
                acc = try Iap2UsbAccessory(device: device, identity: identity, stopAfterAuth: false) { note("USB " + $0) }
            } catch {
                note("carkit 打不开（\(error)）——确认 iPhone 已解锁、点「信任」，且数据线能传数据")
                if let hint = Wireless.usbTrustHintPayload() { server.broadcastText(hint) }   // 桌宠显示「点信任」卡片
                scheduleUsbRetry(after: backoff.next(live: live), because: "carkit 失败")
                return
            }
            server.broadcastText(#"{"type":"trustDone"}"#)   // 打开了：之前若亮着「点信任」卡片，收起
            accessoryUsb = acc
            acc.onLog = { note("USB " + $0) }
            acc.onPhase = { if $0 == .authenticated { backoff.reset() } }
            acc.onFinished = { code in
                accessoryUsb = nil
                clearNowPlaying(server: server)
                note("USB iAP2 结束（\(code)）")
                scheduleUsbRetry(after: backoff.next(live: live), because: live ? "会话进行中，慢速" : "退避重连")
            }
            acc.onMessage = { frame in
            acc.onArtwork = { id, data in publishArtwork(id: id, data: data, server: server) }
                switch frame.messageId {
                case Iap2Csm.CarPlay.availability:
                    if live { note("会话进行中，忽略重复的 CarPlay 可用通知"); return [] }
                    // 有线：AV 走手机自己的 NCM 网口（macOS 自己绑的 enX），没就绪就先不回（手机会再问）
                    guard let iface = UsbNet.ncmInterfaces(udid: device.serial).first else {
                        note("还没看到手机的 NCM 网口（ioreg），先不回 0x4301")
                        return []
                    }
                    guard let fe80 = UsbNet.linkLocalV6(iface) else {
                        note("NCM 网口 \(iface) 还没有链路本地地址，先不回 0x4301")
                        return []
                    }
                    // 有线 deviceIdentifier 用手机 AV 网口在 Mac 这一侧的 MAC（mib2q/DiPlay 同款），
                    // public_key 字段仍是配对标识 pi——与无线同一契约，不是 Ed25519 公钥。
                    let mac = NetInfo.mac(iface)?.uppercased() ?? "00:00:00:00:00:00"
                    note("开有线会话：AV \(iface) \(fe80) → 控制口 \(o.controlPort)")
                    return [Iap2Csm.carPlayStartSessionWired(
                        ipAddresses: [fe80], port: UInt32(o.controlPort),
                        deviceIdentifier: mac, publicKey: store.identity.pairingId, sourceVersion: "950.7.1")]
                case Iap2Csm.Communications.callStateUpdate, Iap2Csm.Communications.update:
                    publishTelephony(frame, server: server)
                    return []
                case Iap2Csm.NowPlaying.update:
                    publishNowPlaying(frame, server: server, seek: { [weak acc] ms in
                        acc?.core.send(Iap2Csm.setNowPlayingInformation(elapsedMs: ms))
                    })
                    return []
                default:
                    note(String(format: "iAP2 消息 0x%04x（未处理）", frame.messageId))
                    return []
                }
            }
            acc.start()
        }
        usbSupervise()
        note("等 iPhone：插线即连（USB carkit → iAP2 → 有线会话），拔了自动等下一次")
        RunLoop.main.run()
        exit(0)
    }
}
