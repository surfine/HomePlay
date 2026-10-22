// 端到端：一台假 iPhone 走真 TCP 驱动 CarPlaySession——/info → pair-setup → pair-verify → 加密 →
// auth-setup（验签）→ 会话 SETUP → 事件通道 → 屏幕 SETUP 推 config + 3 帧 → RECORD → 触控 HID → TEARDOWN。
import Foundation
import CryptoKit
import Security
import Session
import Wire
import H264

/// 阻塞式 TCP 客户端（测试用）
final class TestTCP {
    let fd: Int32
    init?(port: UInt16) {
        fd = socket(AF_INET, SOCK_STREAM, 0)
        var a = sockaddr_in(); a.sin_family = sa_family_t(AF_INET); a.sin_port = port.bigEndian
        a.sin_addr.s_addr = inet_addr("127.0.0.1")
        let r = withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard r == 0 else { close(fd); return nil }
        var tv = timeval(tv_sec: 0, tv_usec: 200_000)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    }
    deinit { close(fd) }
    func send(_ d: Data) { _ = d.withUnsafeBytes { Darwin.send(fd, $0.baseAddress, d.count, 0) } }
    /// 读到 `until` 返回 true 或超时
    func read(timeout: TimeInterval = 5, until: (Data) -> Bool) -> Data {
        var acc = Data(); let end = Date().addingTimeInterval(timeout)
        var buf = [UInt8](repeating: 0, count: 65536)
        while Date() < end && !until(acc) {
            let n = recv(fd, &buf, buf.count, 0)
            if n > 0 { acc.append(contentsOf: buf[0..<n]) } else if n == 0 { break }
        }
        return acc
    }
}

/// 测试用 MFi 签名器：现场生成 P-256；“证书”放公钥的外部表示，验签时直接用
final class TestSigner: AccessorySigner {
    let key: SecKey
    let certificate: [UInt8]
    init() {
        key = SecKeyCreateRandomKey([kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom, kSecAttrKeySizeInBits: 256] as CFDictionary, nil)!
        certificate = [UInt8](SecKeyCopyExternalRepresentation(SecKeyCopyPublicKey(key)!, nil)! as Data)
    }
    func sign(_ digest: [UInt8]) throws -> [UInt8] {
        let der = SecKeyCreateSignature(key, .ecdsaSignatureDigestX962SHA256, Data(digest) as CFData, nil)! as Data
        return try P256.Signing.ECDSASignature(derRepresentation: der).rawRepresentation.map { $0 }
    }
}

/// 假 iPhone 的一条 RTSP 连接（可切换到加密）
final class FakePhoneConn {
    let tcp: TestTCP
    var cipher: ControlCipher?
    var parser = RTSPParser()
    var cseq = 0
    init?(port: UInt16) { guard let t = TestTCP(port: port) else { return nil }; tcp = t }

    func request(_ method: String, _ path: String, body: Data = Data(), type: String? = nil) -> RTSPMessage? {
        cseq += 1
        var head = "\(method) \(path) RTSP/1.0\r\nCSeq: \(cseq)\r\nContent-Length: \(body.count)\r\n"
        if let type { head += "Content-Type: \(type)\r\n" }
        var out = Data((head + "\r\n").utf8); out.append(body)
        if let cipher { out = Data(try! cipher.encrypt([UInt8](out))) }
        tcp.send(out)
        var got: [RTSPMessage] = []
        let end = Date().addingTimeInterval(5)
        var pending = Data()
        while got.isEmpty && Date() < end {
            let d = tcp.read(timeout: 0.3) { !$0.isEmpty }
            if d.isEmpty { continue }
            pending.append(d)
            var plain = pending
            if let cipher { plain = Data((try? cipher.feed([UInt8](pending))) ?? []); pending = Data() } else { pending = Data() }
            got += parser.feed(plain)
        }
        return got.first
    }
}

/// 把一台假 iPhone 推到 RECORD：pair-setup → pair-verify → 加密 → auth-setup → 会话 SETUP → RECORD。返回连接与 RECORD 的状态码。
func driveToRecord(port: UInt16, store: PairingStore, id: String, seed: Int) -> (conn: FakePhoneConn, recordStatus: Int)? {
    guard let phone = FakePhoneConn(port: port) else { return nil }
    let client = PairingClient(ltsk: Curve25519.Signing.PrivateKey(), id: Array(id.utf8))
    let ps = pairSetupExchange(handle: { b in [UInt8](phone.request("POST", "/pair-setup", body: Data(b), type: "application/pairing+tlv8")?.body ?? Data()) },
                               client: client, a: BigUInt(bytes: pat(32, 7, seed)))
    guard ps.ok else { return nil }
    let pv = pairVerifyExchange(handle: { b in [UInt8](phone.request("POST", "/pair-verify", body: Data(b), type: "application/pairing+tlv8")?.body ?? Data()) },
                                client: client, accessoryPub: store.identity.publicRaw, ephemeral: Curve25519.KeyAgreement.PrivateKey())
    guard pv.ok else { return nil }
    phone.cipher = ControlCipher(readKey: pv.readKey, writeKey: pv.writeKey)
    let ephPub = [UInt8](Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation)
    guard phone.request("POST", "/auth-setup", body: Data([1] + ephPub), type: "application/octet-stream")?.statusCode == 200,
          let body = try? BPlist.encode(["name": "Fake \(id)", "model": "iPhone99,1", "timingPort": 0]),
          phone.request("SETUP", "rtsp://127.0.0.1/1", body: body, type: "application/x-apple-binary-plist")?.statusCode == 200,
          let rec = phone.request("RECORD", "rtsp://127.0.0.1/1") else { return nil }
    return (phone, rec.statusCode ?? -1)
}

func runSessionE2ESuites() {
    suite("session-preempt") {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = PairingStore(directory: dir)
        let ws = try WSServer(port: 0)
        var info = InfoConfig(sourceVersion: "950.7.1", deviceID: "AA:BB:CC:DD:EE:01", bluetoothMAC: "AA:BB:CC:DD:EE:02",
                              name: "HomePlay Test", main: DisplayConfig(widthPixels: 1200, heightPixels: 1200))
        info.model = "HomePlay"; info.disableAudioOutput = true
        var cfg = CarPlaySessionConfig(info: info); cfg.port = 0; cfg.probeForPhone = false
        cfg.serviceName = "HomePlay-preempt-\(UInt16.random(in: 1000...9999))"
        let session = CarPlaySession(config: cfg, store: store, signer: TestSigner(), sink: H264Sink(server: ws))
        let activeCount = LockedBox(0), endedReasons = LockedBox<[String]>([])
        session.onActive = { activeCount.set(activeCount.get() + 1) }
        session.onEnded = { r in endedReasons.set(endedReasons.get() + [r]) }
        let port = try session.start()
        defer { session.stop() }

        // 1. 第二条 RECORD 顶掉第一条：旧 socket 被关，onActive 再叫一次，不送 onEnded，新连接仍可用
        guard let a = driveToRecord(port: port, store: store, id: "fake-iphone-A", seed: 3) else { expect(false, "phone A reaches RECORD"); return }
        expect(a.recordStatus == 200 && waitUntil(2) { activeCount.get() == 1 }, "phone A RECORD → onActive ×1")
        guard let b = driveToRecord(port: port, store: store, id: "fake-iphone-B", seed: 5) else { expect(false, "phone B reaches RECORD"); return }
        expect(b.recordStatus == 200 && waitUntil(2) { activeCount.get() == 2 }, "phone B RECORD → onActive ×2")
        var aClosed = false
        let aEnd = Date().addingTimeInterval(2)
        while !aClosed && Date() < aEnd {
            var buf = [UInt8](repeating: 0, count: 4096)
            let n = recv(a.conn.tcp.fd, &buf, buf.count, 0)   // 200ms 读超时；0 = EOF，<0 且非超时 = 被重置
            if n == 0 || (n < 0 && errno != EAGAIN && errno != EWOULDBLOCK) { aClosed = true }
        }
        expect(aClosed, "phone A's socket closed (EOF/reset within 2s) after B took over")
        expect(endedReasons.get().isEmpty, "preemption does not fire onEnded (ended=\(endedReasons.get()))")
        expect(b.conn.request("POST", "/command")?.statusCode == 200, "phone B still alive: POST /command → 200")
        expect(activeCount.get() == 2, "onActive stays at 2")
    }

    suite("session-drop-after-record") {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = PairingStore(directory: dir)
        let ws = try WSServer(port: 0)
        var info = InfoConfig(sourceVersion: "950.7.1", deviceID: "AA:BB:CC:DD:EE:01", bluetoothMAC: "AA:BB:CC:DD:EE:02",
                              name: "HomePlay Test", main: DisplayConfig(widthPixels: 1200, heightPixels: 1200))
        info.model = "HomePlay"; info.disableAudioOutput = true
        var cfg = CarPlaySessionConfig(info: info); cfg.port = 0; cfg.probeForPhone = false
        cfg.serviceName = "HomePlay-drop-\(UInt16.random(in: 1000...9999))"
        let session = CarPlaySession(config: cfg, store: store, signer: TestSigner(), sink: H264Sink(server: ws))
        let activeCount = LockedBox(0), endedReasons = LockedBox<[String]>([])
        session.onActive = { activeCount.set(activeCount.get() + 1) }
        session.onEnded = { r in endedReasons.set(endedReasons.get() + [r]) }
        let port = try session.start()
        defer { session.stop() }

        guard let phone = driveToRecord(port: port, store: store, id: "fake-iphone-C", seed: 9) else { expect(false, "phone reaches RECORD"); return }
        expect(phone.recordStatus == 200 && waitUntil(2) { activeCount.get() == 1 }, "RECORD → onActive")
        shutdown(phone.conn.tcp.fd, SHUT_RDWR)   // 直接断线（用 shutdown 而不是 close，避免 deinit 二次 close 误关被复用的 fd）
        expect(waitUntil(2) { endedReasons.get().count == 1 }, "TCP drop after RECORD → onEnded ×1")
        expect(endedReasons.get().first?.contains("控制连接关闭") == true, "onEnded reason contains 控制连接关闭 (got \(endedReasons.get()))")
        if let next = FakePhoneConn(port: port) {
            expect(next.request("GET", "/info")?.statusCode == 200, "control port still serves /info after drop")
        } else { expect(false, "control port still accepts a new phone after drop") }
    }

    suite("session-e2e") {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = PairingStore(directory: dir)
        let signer = TestSigner()
        let ws = try WSServer(port: 0)
        let sink = H264Sink(server: ws)
        var info = InfoConfig(sourceVersion: "950.7.1", deviceID: "AA:BB:CC:DD:EE:01", bluetoothMAC: "AA:BB:CC:DD:EE:02",
                              name: "HomePlay Test", main: DisplayConfig(widthPixels: 1200, heightPixels: 1200))
        info.model = "HomePlay"; info.disableAudioOutput = true
        var cfg = CarPlaySessionConfig(info: info); cfg.port = 0; cfg.probeForPhone = false
        cfg.serviceName = "HomePlay-e2e-\(UInt16.random(in: 1000...9999))"
        let session = CarPlaySession(config: cfg, store: store, signer: signer, sink: sink)
        let logs = LockedData()
        session.onLog = { s in logs.append(Data((s + "\n").utf8)) }
        let active = LockedBox(false), ended = LockedBox(false)
        session.onActive = { active.set(true) }
        session.onEnded = { _ in ended.set(true) }
        let port = try session.start()
        defer { session.stop() }

        // 审查发现的两个高危：未认证就 SETUP/RECORD；超大 Content-Length
        if let rogue = FakePhoneConn(port: port) {
            let m1 = TLV8.encode([TLV8Item(TLV8Tag.state, [1]), TLV8Item(TLV8Tag.publicKey, [UInt8](Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation))])
            _ = rogue.request("POST", "/pair-verify", body: Data(m1), type: "application/pairing+tlv8")   // 只走 M1：拿到共享密钥但没被验证
            let su = rogue.request("SETUP", "rtsp://x/1", body: try BPlist.encode(["streams": [["type": 110, "streamConnectionID": 1]]]))
            let rc = rogue.request("RECORD", "rtsp://x/1")
            expect(su?.statusCode == 470 && rc?.statusCode == 470 && !active.get(), "unauthenticated SETUP/RECORD after pair-verify M1 → 470, no session")
        }
        if let big = TestTCP(port: port) {
            big.send(Data("GET /info RTSP/1.0\r\nCSeq: 1\r\nContent-Length: 9223372036854775807\r\n\r\n".utf8))
            let after = big.read(timeout: 2) { _ in false }
            expect(after.isEmpty, "Content-Length = Int.max → connection dropped, no crash")
        }
        var p0 = RTSPParser()
        _ = p0.feed(Data(repeating: 0x41, count: RTSPParser.maxHeader + 10))
        expect(p0.overflowed, "header without CRLFCRLF over 16 KiB → overflow flag")

        guard let phone = FakePhoneConn(port: port) else { expect(false, "connect control port"); return }
        // /info
        let infoRes = phone.request("GET", "/info")
        let infoDict = infoRes.flatMap { try? BPlist.decodeDict($0.body) }
        expect(infoRes?.statusCode == 200 && infoDict?["name"] as? String == "HomePlay Test", "/info 200 with our name")

        // pair-setup（PIN 3939）+ pair-verify，都走真的 RTSP
        let client = PairingClient(ltsk: Curve25519.Signing.PrivateKey(), id: Array("fake-iphone".utf8))
        let ps = pairSetupExchange(handle: { b in [UInt8](phone.request("POST", "/pair-setup", body: Data(b), type: "application/pairing+tlv8")?.body ?? Data()) },
                                   client: client, a: BigUInt(bytes: pat(32, 7, 3)))
        expect(ps.ok, "pair-setup over RTSP completes, accessory signature verifies")
        let pv = pairVerifyExchange(handle: { b in [UInt8](phone.request("POST", "/pair-verify", body: Data(b), type: "application/pairing+tlv8")?.body ?? Data()) },
                                    client: client, accessoryPub: store.identity.publicRaw, ephemeral: Curve25519.KeyAgreement.PrivateKey())
        expect(pv.ok, "pair-verify over RTSP completes")
        phone.cipher = ControlCipher(readKey: pv.readKey, writeKey: pv.writeKey)

        // auth-setup：解出签名，用“证书”里的公钥验
        let eph = Curve25519.KeyAgreement.PrivateKey()
        let ephPub = [UInt8](eph.publicKey.rawRepresentation)
        let auth = phone.request("POST", "/auth-setup", body: Data([1] + ephPub), type: "application/octet-stream")
        var authOK = false
        if let b = auth.map({ [UInt8]($0.body) }), b.count > 40 {
            let ourPub = Array(b[0..<32])
            let certLen = Int(b[32]) << 24 | Int(b[33]) << 16 | Int(b[34]) << 8 | Int(b[35])
            let cert = Array(b[36..<(36 + certLen)])
            let sigLen = Int(b[36 + certLen]) << 24 | Int(b[37 + certLen]) << 16 | Int(b[38 + certLen]) << 8 | Int(b[39 + certLen])
            let encSig = Array(b[(40 + certLen)..<(40 + certLen + sigLen)])
            let shared = try PairingCrypto.x25519Shared(privateKey: eph, peerPublic: ourPub)
            let (k, iv) = AuthSetup.keyAndIV(shared: shared)
            let sig = try AuthSetup.aesCTR(key: k, iv: iv, encSig)
            let pub = try P256.Signing.PublicKey(x963Representation: cert)
            let digest = SHA256.hash(data: ourPub + ephPub)
            let ecdsa = try P256.Signing.ECDSASignature(rawRepresentation: sig)
            authOK = cert == signer.certificate && pub.isValidSignature(ecdsa, for: digest)
        }
        expect(authOK, "auth-setup over encrypted channel: signature over SHA-256(ourPub||phonePub) verifies")

        // 会话级 SETUP
        let s1 = phone.request("SETUP", "rtsp://127.0.0.1/1", body: try BPlist.encode(["name": "Fake iPhone", "model": "iPhone99,1", "timingPort": 0]),
                               type: "application/x-apple-binary-plist")
        let s1d = s1.flatMap { try? BPlist.decodeDict($0.body) }
        let eventPort = (s1d?["eventPort"] as? NSNumber)?.uint16Value ?? 0
        let timingPort = (s1d?["timingPort"] as? NSNumber)?.intValue ?? 0
        expect(s1?.statusCode == 200 && eventPort > 0 && timingPort > 0, "session SETUP returns timing + event ports")
        expect(((s1d?["enabledFeatures"] as? [String]) ?? []).contains("iAPChannel"), "iAPChannel advertised by default (stream 130 implemented)")

        // 事件通道：手机读我们用 Events-Write 写的，自己用 Events-Read 写
        guard let ev = TestTCP(port: eventPort) else { expect(false, "connect event port"); return }
        let evCipher = ControlCipher(readKey: PairingCrypto.hkdfSHA512(pv.shared, salt: "Events-Salt", info: "Events-Write-Encryption-Key"),
                                     writeKey: PairingCrypto.hkdfSHA512(pv.shared, salt: "Events-Salt", info: "Events-Read-Encryption-Key"))

        // 屏幕 SETUP：推 config + 3 帧（用会话派生的密钥现场加密）
        let sid: UInt64 = 9_876_543_210
        let s2 = phone.request("SETUP", "rtsp://127.0.0.1/1", body: try BPlist.encode(["streams": [["type": 110, "streamConnectionID": sid]]]),
                               type: "application/x-apple-binary-plist")
        let dataPort = ((s2.flatMap { try? BPlist.decodeDict($0.body) }?["streams"] as? [[String: Any]])?.first?["dataPort"] as? NSNumber)?.uint16Value ?? 0
        expect(dataPort > 0, "screen SETUP returns a data port")
        let key = deriveStreamKey(sharedSecret: pv.shared, salt: StreamKeyInfo.salt(streamConnectionID: sid), info: "DataStream-Output-Encryption-Key")
        guard let scr = TestTCP(port: dataPort) else { expect(false, "connect screen port"); return }
        func header(_ len: Int, _ op: UInt8) -> Data {
            var h = Data(count: 128)
            h[0] = UInt8(len & 0xff); h[1] = UInt8(len >> 8 & 0xff); h[2] = UInt8(len >> 16 & 0xff); h[3] = UInt8(len >> 24 & 0xff); h[4] = op
            return h
        }
        let avcC = unhex(fx_screenAvcC)
        scr.send(header(avcC.count, 1) + avcC)
        for (i, p) in [fx_screenPlain1, fx_screenPlain2, fx_screenPlain3].map(unhex).enumerated() {
            let h = header(p.count + 16, 0)
            let box = try ChaChaPoly.seal(p, using: SymmetricKey(data: key),
                                          nonce: ChaChaPoly.Nonce(data: ScreenStreamParser.nonce(counter: UInt64(i))), authenticating: h)
            scr.send(h + box.ciphertext + box.tag)
        }
        expect(waitUntil(5) { sink.frames >= 3 }, "decrypted screen frames reached H264Sink (frames=\(sink.frames))")
        expect(sink.lastConfig != nil, "VIDEO_CONFIG built from session avcC")

        // iAP 数据通道（流 130）：SETUP 回 dataPort → 假 iPhone 送加密的 APTransportPackage → 原始 iAP2 字节交到句柄；
        // 反向 link.send → 事件通道上的 iAPSendMessage；TEARDOWN 130 → 句柄 onClosed（isTornDown）
        let tunnelLink = LockedBox<IapTunnelLink?>(nil)
        session.onIapTunnel = { tunnelLink.set($0) }
        let seed: UInt64 = 1_234_567_890_123
        let s3 = phone.request("SETUP", "rtsp://127.0.0.1/1", body: try BPlist.encode(["streams": [["type": 130, "streamConnectionID": sid + 1,
                                                                                                    "clientTypeUUID": IapTunnel.clientTypeUUID, "seed": seed] as [String: Any]]]),
                               type: "application/x-apple-binary-plist")
        let s3stream = (s3.flatMap { try? BPlist.decodeDict($0.body) }?["streams"] as? [[String: Any]])?.first
        let iapPort = (s3stream?["dataPort"] as? NSNumber)?.uint16Value ?? 0
        expect(iapPort > 0 && (s3stream?["type"] as? NSNumber)?.intValue == 130 && (s3stream?["streamID"] as? NSNumber)?.intValue == 1,
               "iAP stream 130 SETUP returns {type 130, streamID 1, dataPort}")
        expect(waitUntil(2) { tunnelLink.get() != nil } && tunnelLink.get()?.dataPort == iapPort, "onIapTunnel hands out the link with the same dataPort")
        let iapGot = LockedData()
        let iapClosed = LockedBox(false), iapTorn = LockedBox(false)
        if let link = tunnelLink.get() {
            link.onIap = { iapGot.append($0) }
            link.onClosed = { [weak link] in iapClosed.set(true); iapTorn.set(link?.isTornDown ?? false) }
        }
        let iapKey = deriveStreamKey(sharedSecret: pv.shared, salt: StreamKeyInfo.salt(streamConnectionID: seed), info: StreamKeyInfo.output)
        guard let iap = TestTCP(port: iapPort) else { expect(false, "connect iAP tunnel port"); return }
        let marker = Data([0xff, 0x55, 0x02, 0x00, 0xee, 0x10])   // iAP2 marker；隧道只管透传
        let syncLike = Data([0xff, 0x5a, 0x00, 0x1a, 0x80, 0x63, 0x00, 0x00, 0xa3] + Array(1...16) + [0x00])
        let iapSealer = ControlCipher(readKey: iapKey, writeKey: iapKey)
        iap.send(Data(try iapSealer.encrypt([UInt8](APTransportPackage.comm(marker)))))
        iap.send(Data(try iapSealer.encrypt([UInt8](APTransportPackage.comm(syncLike)))))
        expect(waitUntil(5) { iapGot.get().count >= marker.count + syncLike.count } && iapGot.get() == marker + syncLike,
               "two encrypted 'comm' packages → raw iAP2 bytes delivered in order (\(iapGot.get().count)B)")
        // 配件→手机：原始 iAP2 字节 → 事件通道 POST /command {type:iAPSendMessage, params:{data}}
        let outBytes = Data([0xff, 0x5a, 0x00, 0x09, 0x40, 0x64, 0x63, 0x0a, 0x33])
        expect(tunnelLink.get()?.send(outBytes) == true, "link.send succeeds while the event channel is connected")
        var iapEvParser = RTSPParser(); var iapCmds: [RTSPMessage] = []
        let iapEnd = Date().addingTimeInterval(5)
        while iapCmds.isEmpty && Date() < iapEnd {
            let d = ev.read(timeout: 0.3) { !$0.isEmpty }
            if !d.isEmpty { iapCmds += iapEvParser.feed(Data((try? evCipher.feed([UInt8](d))) ?? [])) }
        }
        let iapCmdOK = iapCmds.contains { c in
            guard let d = try? BPlist.decodeDict(c.body), d["type"] as? String == "iAPSendMessage",
                  let p = d["params"] as? [String: Any] else { return false }
            return p["data"] as? Data == outBytes
        }
        expect(iapCmdOK, "accessory→phone iAP2 bytes ride the event channel as iAPSendMessage")
        // TEARDOWN 流 130：句柄报 onClosed 且 isTornDown；屏幕流不受影响
        let td130 = phone.request("TEARDOWN", "rtsp://127.0.0.1/1", body: try BPlist.encode(["streams": [["type": 130]]]), type: "application/x-apple-binary-plist")
        expect(td130?.statusCode == 200 && waitUntil(2) { iapClosed.get() } && iapTorn.get(), "TEARDOWN 130 → link.onClosed with isTornDown")
        expect(sink.frames >= 3 && !ended.get(), "screen stream and session survive TEARDOWN of stream 130")

        // RECORD → 会话开始；触控 → 事件通道上的 hidSendReport
        let rec = phone.request("RECORD", "rtsp://127.0.0.1/1")
        expect(rec?.statusCode == 200 && waitUntil(2) { active.get() }, "RECORD → onActive")
        session.sendTouch(x: 0.5, y: 0.25, down: true)
        var evParser = RTSPParser(); var cmds: [RTSPMessage] = []
        let end = Date().addingTimeInterval(5)
        while cmds.isEmpty && Date() < end {
            let d = ev.read(timeout: 0.3) { !$0.isEmpty }
            if !d.isEmpty { cmds += evParser.feed(Data((try? evCipher.feed([UInt8](d))) ?? [])) }
        }
        var touchOK = false
        if let c = cmds.first, let d = try? BPlist.decodeDict(c.body), d["type"] as? String == "hidSendReport",
           let r = d["hidReport"] as? Data, r.count >= 6 {
            let x = Int(r[2]) | Int(r[3]) << 8, y = Int(r[4]) | Int(r[5]) << 8
            touchOK = r[1] == 1 && x == 600 && y == 300
            print("     touch report \(hexs(r)) → x=\(x) y=\(y)")
        }
        expect(cmds.first?.method == "POST" && touchOK, "touch (0.5,0.25) → encrypted POST /command hidSendReport x=600 y=300 down")

        session.sendMedia(.playPause)
        var mediaCmds: [RTSPMessage] = []
        let mediaEnd = Date().addingTimeInterval(5)
        while mediaCmds.isEmpty && Date() < mediaEnd {
            let d = ev.read(timeout: 0.3) { !$0.isEmpty }
            if !d.isEmpty { mediaCmds += evParser.feed(Data((try? evCipher.feed([UInt8](d))) ?? [])) }
        }
        let mediaOK = mediaCmds.contains { c in
            guard let d = try? BPlist.decodeDict(c.body), d["type"] as? String == "hidSendReport",
                  d["uuid"] as? String == "2a2a2a2c", let r = d["hidReport"] as? Data else { return false }
            return r == Data([HID.MediaButton.playPause.rawValue])
        }
        expect(mediaOK, "media playPause → encrypted POST /command hidSendReport mediaUID")

        // 整个会话 TEARDOWN → onEnded
        let td = phone.request("TEARDOWN", "rtsp://127.0.0.1/1")
        expect(td?.statusCode == 200 && waitUntil(2) { ended.get() }, "TEARDOWN → onEnded")

        // 切换手机：不清 discovery / 控制口，只结束旧连接并重新叫新地址；新手机还能连回来
        let switched = LockedBox(false)
        session.switchPhone(to: "AA:BB:CC:DD:EE:99") { switched.set(true) }
        expect(waitUntil(2) { switched.get() }, "switchPhone completes without restarting the receiver")
        if let next = FakePhoneConn(port: port) {
            expect(next.request("GET", "/info")?.statusCode == 200, "control port still serves /info after switchPhone")
        } else {
            expect(false, "control port still accepts a new phone after switchPhone")
        }
        print(String(decoding: logs.get(), as: UTF8.self).split(separator: "\n").map { "     log: " + $0 }.joined(separator: "\n"))
    }
}
