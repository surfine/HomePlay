// 配对与加密的测试（Crypto 分支）：TLV8、BigUInt、SRP（RFC 5054 向量 + 3072/SHA-512 自洽）、
// 与 MacPlay 真实 TS 模块的差分向量、ControlCipher、完整 pair-setup / pair-verify 模拟、身份存储。
import CryptoKit
import Foundation
import Session

private func hex(_ b: [UInt8]) -> String { b.map { String(format: "%02x", $0) }.joined() }
private func cunhex(_ s: String) -> [UInt8] {
    var out: [UInt8] = []
    var i = s.startIndex
    while i < s.endIndex {
        let j = s.index(i, offsetBy: 2)
        out.append(UInt8(s[i ..< j], radix: 16)!)
        i = j
    }
    return out
}
func pat(_ n: Int, _ mul: Int, _ add: Int) -> [UInt8] { (0 ..< n).map { UInt8(truncatingIfNeeded: $0 * mul + add) } }
private func bigHex(_ n: BigUInt) -> String { n.description.replacingOccurrences(of: "^0+(?=.)", with: "", options: .regularExpression) }

struct PairingClient {
    let ltsk: Curve25519.Signing.PrivateKey
    let id: [UInt8]
    var ltpk: [UInt8] { Array(ltsk.publicKey.rawRepresentation) }
}

/// 测试里的 SRP-6a 客户端（3072 / SHA-512，同 HAP）。
struct SRPClient {
    let group = SRPGroup.rfc5054_3072
    let hash = SRPHash.sha512
    let a: BigUInt
    var A: BigUInt { group.g.modPow(a, modulus: group.N) }

    func proof(salt: [UInt8], B: [UInt8], username: String, password: String)
        -> (A: [UInt8], M1: [UInt8], K: [UInt8], expectedM2: [UInt8]) {
        let N = group.N, g = group.g, n = group.byteCount
        let k = BigUInt(bytes: hash.digest([N.bytes, g.padded(to: n)]))
        let x = BigUInt(bytes: hash.digest([salt, hash.digest([Array(username.utf8), [0x3a], Array(password.utf8)])]))
        let Bn = BigUInt(bytes: B)
        let u = BigUInt(bytes: hash.digest([A.padded(to: n), Bn.padded(to: n)]))
        let base = (Bn + N - ((k * g.modPow(x, modulus: N)) % N)) % N
        let S = base.modPow(a + u * x, modulus: N)
        let K = hash.digest([S.bytes])
        let hx = zip(hash.digest([N.bytes]), hash.digest([g.bytes])).map { $0 ^ $1 }
        let M1 = hash.digest([hx, hash.digest([Array(username.utf8)]), salt, A.padded(to: n), Bn.padded(to: n), K])
        return (A.padded(to: n), M1, K, hash.digest([A.padded(to: n), M1, K]))
    }
}

func tlvState(_ s: UInt8, _ extra: [TLV8Item] = []) -> [UInt8] {
    TLV8.encode([TLV8Item(TLV8Tag.state, [s])] + extra)
}

private func makeStore(_ dir: URL, seed: Int = 3) -> PairingStore {
    let identity = try! AccessoryIdentity(seed: pat(32, seed, 1), pairingId: "AA:BB:CC:DD:EE:FF-acc")
    return PairingStore(directory: dir, newIdentity: identity)
}

func tempDir() -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("homeplay-crypto-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}

/// 模拟 iPhone 完成 pair-setup，返回控制器与服务端 K。
private func simulatePairSetup(server: PairSetup, client: PairingClient, a: BigUInt) -> (ok: Bool, K: [UInt8]?, m6: [UInt8]) {
    pairSetupExchange(handle: server.handle, client: client, a: a)
}

/// 模拟 iPhone 的 pair-setup；`handle` 是一次请求→应答（直接调服务端，或走真的 /pair-setup）
func pairSetupExchange(handle: ([UInt8]) -> [UInt8], client: PairingClient, a: BigUInt) -> (ok: Bool, K: [UInt8]?, m6: [UInt8]) {
    let server = (handle: handle, ())
    let m2 = TLV8.decode(server.handle(tlvState(1, [TLV8Item(TLV8Tag.method, [0])])))
    guard let B = m2[TLV8Tag.publicKey], let salt = m2[TLV8Tag.salt] else { return (false, nil, []) }
    let c = SRPClient(a: a).proof(salt: salt, B: B, username: "Pair-Setup", password: "3939")
    let m4 = TLV8.decode(server.handle(tlvState(3, [TLV8Item(TLV8Tag.publicKey, c.A), TLV8Item(TLV8Tag.proof, c.M1)])))
    guard m4[TLV8Tag.proof] == c.expectedM2 else { return (false, nil, []) }
    let encKey = PairingCrypto.hkdfSHA512(c.K, salt: "Pair-Setup-Encrypt-Salt", info: "Pair-Setup-Encrypt-Info")
    let signKey = PairingCrypto.hkdfSHA512(c.K, salt: "Pair-Setup-Controller-Sign-Salt", info: "Pair-Setup-Controller-Sign-Info")
    let sig = Array(try! client.ltsk.signature(for: signKey + client.id + client.ltpk))
    let sub = TLV8.encode([TLV8Item(TLV8Tag.identifier, client.id), TLV8Item(TLV8Tag.publicKey, client.ltpk),
                           TLV8Item(TLV8Tag.signature, sig)])
    let sealed = try! PairingCrypto.chachaSeal(key: encKey, nonce: PairingCrypto.nonceLabel("PS-Msg05"), plaintext: sub)
    let m6raw = server.handle(tlvState(5, [TLV8Item(TLV8Tag.encryptedData, sealed)]))
    let m6 = TLV8.decode(m6raw)
    guard m6[TLV8Tag.state] == [6], let enc = m6[TLV8Tag.encryptedData],
          let opened = try? PairingCrypto.chachaOpen(key: encKey, nonce: PairingCrypto.nonceLabel("PS-Msg06"), data: enc)
    else { return (false, c.K, m6raw) }
    // 校验配件签名
    let t = TLV8.decode(opened)
    let accSignKey = PairingCrypto.hkdfSHA512(c.K, salt: "Pair-Setup-Accessory-Sign-Salt", info: "Pair-Setup-Accessory-Sign-Info")
    guard let id = t[TLV8Tag.identifier], let pk = t[TLV8Tag.publicKey], let s = t[TLV8Tag.signature],
          PairingCrypto.ed25519Verify(publicKey: pk, data: accSignKey + id + pk, signature: s) else { return (false, c.K, m6raw) }
    return (true, c.K, m6raw)
}

/// 模拟 iPhone 做 pair-verify，返回 (控制器侧密钥, M4 是否成功, 服务端)。
private func simulatePairVerify(server: PairVerify, client: PairingClient, accessoryPub: [UInt8],
                                ephemeral: Curve25519.KeyAgreement.PrivateKey) -> (ok: Bool, readKey: [UInt8], writeKey: [UInt8], shared: [UInt8]) {
    pairVerifyExchange(handle: server.handle, client: client, accessoryPub: accessoryPub, ephemeral: ephemeral)
}

func pairVerifyExchange(handle: ([UInt8]) -> [UInt8], client: PairingClient, accessoryPub: [UInt8],
                        ephemeral: Curve25519.KeyAgreement.PrivateKey) -> (ok: Bool, readKey: [UInt8], writeKey: [UInt8], shared: [UInt8]) {
    let server = (handle: handle, ())
    let ephPub = Array(ephemeral.publicKey.rawRepresentation)
    let m2 = TLV8.decode(server.handle(tlvState(1, [TLV8Item(TLV8Tag.publicKey, ephPub)])))
    guard let accEph = m2[TLV8Tag.publicKey], let enc = m2[TLV8Tag.encryptedData],
          let shared = try? PairingCrypto.x25519Shared(privateKey: ephemeral, peerPublic: accEph) else { return (false, [], [], []) }
    let encKey = PairingCrypto.hkdfSHA512(shared, salt: "Pair-Verify-Encrypt-Salt", info: "Pair-Verify-Encrypt-Info")
    guard let opened = try? PairingCrypto.chachaOpen(key: encKey, nonce: PairingCrypto.nonceLabel("PV-Msg02"), data: enc) else { return (false, [], [], []) }
    let t = TLV8.decode(opened)
    guard let accId = t[TLV8Tag.identifier], let accSig = t[TLV8Tag.signature],
          PairingCrypto.ed25519Verify(publicKey: accessoryPub, data: accEph + accId + ephPub, signature: accSig) else { return (false, [], [], []) }
    let sig = Array(try! client.ltsk.signature(for: ephPub + client.id + accEph))
    let sub = TLV8.encode([TLV8Item(TLV8Tag.identifier, client.id), TLV8Item(TLV8Tag.signature, sig)])
    let sealed = try! PairingCrypto.chachaSeal(key: encKey, nonce: PairingCrypto.nonceLabel("PV-Msg03"), plaintext: sub)
    let m4 = TLV8.decode(server.handle(tlvState(3, [TLV8Item(TLV8Tag.encryptedData, sealed)])))
    let ok = m4[TLV8Tag.state] == [4] && m4[TLV8Tag.error] == nil
    // 控制器视角：读用 Read 密钥，写用 Write 密钥。
    return (ok, PairingCrypto.hkdfSHA512(shared, salt: "Control-Salt", info: "Control-Read-Encryption-Key"),
            PairingCrypto.hkdfSHA512(shared, salt: "Control-Salt", info: "Control-Write-Encryption-Key"), shared)
}

func runCryptoSuites() {
    suite("crypto-tlv8") {
        for (name, f) in CryptoFixtures.tlv.sorted(by: { $0.key < $1.key }) {
            let items = f.items.map { TLV8Item($0.0, cunhex($0.1)) }
            expect(hex(TLV8.encode(items)) == f.encoded, "TLV8 编码与 MacPlay 一致：\(name)")
        }
        let big = pat(700, 7, 1)
        let enc = TLV8.encode([TLV8Item(3, big), TLV8Item(6, [2])])
        expect(enc.count == 700 + 3 * 2 + 2 + 1, "700 字节值拆成 255+255+190 三片")
        let dec = TLV8.decode(enc)
        expect(dec[3] == big && dec[6] == [2], ">255 字节值往返")
        let exact = TLV8.decode(TLV8.encode([TLV8Item(5, pat(255, 1, 0)), TLV8Item(5, [9])]))
        expect(exact[5] == [9], "255 字节后的同类型项靠分隔符隔开，不被并入")
        expect(TLV8.decode([0x06, 0x01, 0x01]) == [6: [1]], "单项解码")
        expect(TLV8.decode([0x06, 0x05, 0x01]) == [6: [1]], "截断的长度不越界")
    }

    suite("crypto-biguint") {
        expect(BigUInt(4).modPow(BigUInt(13), modulus: BigUInt(497)) == BigUInt(445), "4^13 mod 497 = 445")
        expect(BigUInt(hex: "ff").bytes == [0xff] && BigUInt().bytes == [0], "字节往返与零")
        let a = BigUInt(hex: "123456789abcdef0123456789abcdef0123456789abcdef")
        let b = BigUInt(hex: "fedcba9876543210fedcba98765")
        expect((a * b) % b == BigUInt(), "(a*b) mod b = 0")
        expect(((a * b) + BigUInt(7)) % b == BigUInt(7), "(a*b+7) mod b = 7")
        expect((a + b) - b == a, "加减往返")
        expect(BigUInt(hex: "10000000000000000").bytes.count == 9, "跨 64 位分片的最短字节数")
        let N = SRPGroup.rfc5054_3072.N
        // 费马：g^(N-1) mod N = 1（N 是素数）。同时是 3072 位 modPow 的计时断言。
        let t0 = Date()
        let r = BigUInt(5).modPow(N - BigUInt(1), modulus: N)
        let dt = Date().timeIntervalSince(t0)
        expect(r == BigUInt(1), "3072 位费马检验 5^(N-1) mod N = 1")
        expect(dt < 2.0, "3072 位 modPow（3071 位指数）\(String(format: "%.2f", dt)) 秒 < 2 秒")
    }

    suite("crypto-srp-rfc5054") {
        // RFC 5054 附录 B：1024 位群、SHA-1、I="alice"、P="password123"
        let salt = cunhex("BEB25379D1A8581EB5A727673A2441EE")
        let a = BigUInt(hex: "60975527035CF2AD1989806F0407210BC81EDC04E2762A56AFD529DDDA2D4393")
        let server = SRPServer(group: .rfc5054_1024, hash: .sha1, username: "alice", password: "password123",
                               salt: salt, privateB: cunhex("E487CB59D31AC550471E81F00F6928E01DDA08E974A004F49E61F5D105284D20"))
        expect(bigHex(server.k) == "7556aa045aef2cdd07abaf0f665c3e818913186f", "k 与 RFC 一致")
        expect(bigHex(server.x) == "94b7555aabe9127cc58ccf4993db6cf84d16c124", "x 与 RFC 一致")
        expect(bigHex(server.v) == CryptoFixtures.rfcV, "v 与 RFC 向量一致")
        let A = SRPGroup.rfc5054_1024.g.modPow(a, modulus: SRPGroup.rfc5054_1024.N)
        expect(bigHex(A) == CryptoFixtures.rfcA, "A 与 RFC 向量一致")
        expect(bigHex(server.B) == CryptoFixtures.rfcB, "B 与 RFC 向量一致")
        expect(bigHex(server.u(A: A)) == CryptoFixtures.rfcU, "u 与 RFC 向量一致")
        expect(server.premasterSecret(A: A).map(bigHex) == CryptoFixtures.rfcS, "预主密钥 S 与 RFC 向量一致")
        expect(server.premasterSecret(A: BigUInt()) == nil, "A = 0 被拒绝")
        expect(server.premasterSecret(A: SRPGroup.rfc5054_1024.N) == nil, "A = N 被拒绝")
    }

    suite("crypto-srp-3072-selfconsistency") {
        let server = SRPServer(username: "Pair-Setup", password: "3939")
        let client = SRPClient(a: BigUInt(bytes: pat(32, 5, 9)))
        let c = client.proof(salt: server.salt, B: server.publicKey, username: "Pair-Setup", password: "3939")
        expect(server.publicKey.count == 384, "B 补到 384 字节")
        let r = server.verify(A: c.A, clientM1: c.M1)
        expect(r != nil, "正确口令：服务端接受 M1")
        expect(r?.K == c.K, "两端 K 相同")
        expect(r?.serverM2 == c.expectedM2, "服务端 M2 与客户端预期相同")
        let bad = SRPClient(a: BigUInt(bytes: pat(32, 5, 9)))
            .proof(salt: server.salt, B: server.publicKey, username: "Pair-Setup", password: "0000")
        expect(server.verify(A: bad.A, clientM1: bad.M1) == nil, "错误口令：拒绝")
        expect(server.verify(A: c.A, clientM1: pat(64, 1, 1)) == nil, "错误 M1：拒绝")
        expect(server.verify(A: [UInt8](repeating: 0, count: 384), clientM1: c.M1) == nil, "A = 0：拒绝")
    }

    suite("crypto-srp-differential") {
        let f = CryptoFixtures.srp
        let server = SRPServer(username: "Pair-Setup", password: "3939",
                               salt: cunhex(f["salt"]!), privateB: cunhex(f["b"]!))
        expect(hex(server.publicKey) == f["B"], "B 与 MacPlay 一致")
        let r = server.verify(A: cunhex(f["A"]!), clientM1: cunhex(f["M1"]!))
        expect(r != nil, "MacPlay 客户端算出的 M1 被接受")
        expect(r.map { hex($0.K) } == f["K"], "K 与 MacPlay 一致")
        expect(r.map { hex($0.serverM2) } == f["M2"], "M2 与 MacPlay 一致")
        expect(server.verify(A: cunhex(f["A"]!), clientM1: [UInt8](repeating: 0, count: 64)) == nil, "零 M1 被拒（MacPlay 同样拒）")
    }

    suite("crypto-hkdf-differential") {
        let f = CryptoFixtures.hkdf
        let ikm = cunhex(f["ikm"]!)
        expect(hex(PairingCrypto.hkdfSHA512(ikm, salt: "Pair-Verify-Encrypt-Salt", info: "Pair-Verify-Encrypt-Info")) == f["encrypt32"], "HKDF-SHA512 32 字节")
        expect(hex(PairingCrypto.hkdfSHA512(ikm, salt: "Control-Salt", info: "Control-Write-Encryption-Key", length: 64)) == f["long64"], "HKDF-SHA512 64 字节")
        let salt = StreamKeyInfo.salt(streamConnectionID: 12345678901234567890)
        expect(salt == "DataStream-Salt12345678901234567890", "流盐为十进制 ID")
        expect(hex(deriveStreamKey(sharedSecret: ikm, salt: salt, info: StreamKeyInfo.output)) == f["streamOutput"], "deriveStreamKey 输出方向与 MacPlay 一致")
        expect(hex(deriveStreamKey(sharedSecret: ikm, salt: "DataStream-Salt7", info: StreamKeyInfo.input)) == f["streamInput"], "deriveStreamKey 输入方向与 MacPlay 一致")
    }

    suite("crypto-control-cipher") {
        let f = CryptoFixtures.control
        let rk = cunhex(f["readKey"]!), wk = cunhex(f["writeKey"]!)
        let enc = ControlCipher(readKey: rk, writeKey: wk)
        let m1 = cunhex(f["m1"]!), m2 = cunhex(f["m2"]!)
        expect(hex(try! enc.encrypt(m1)) == f["e1"], "第 1 帧密文与 MacPlay 一致（计数 0）")
        expect(hex(try! enc.encrypt(m2)) == f["e2"], "第 2 帧密文与 MacPlay 一致（计数递增）")
        let big = pat(20000, 17, 3)
        let eBig = try! enc.encrypt(big)
        expect(eBig.count == CryptoFixtures.controlBigLen, "20000 字节拆成两帧，长度 \(eBig.count)")
        expect(hex(Array(SHA256.hash(data: eBig))) == f["bigSha256"], "超过 16 KiB 的拆帧密文与 MacPlay 一致")

        // 对端：读写密钥互换；按字节喂入。
        let peer = ControlCipher(readKey: wk, writeKey: rk)
        var plain: [UInt8] = []
        var ok = true
        for b in cunhex(f["e1"]!) + cunhex(f["e2"]!) + eBig {
            do { plain += try peer.feed([b]) } catch { ok = false }
        }
        expect(ok && plain == m1 + m2 + big, "逐字节喂入，完整还原三条消息")
        let half = ControlCipher(readKey: wk, writeKey: rk)
        let e1 = cunhex(f["e1"]!)
        expect(try! half.feed(Array(e1.prefix(10))).isEmpty, "半帧不吐明文")
        expect(try! half.feed(Array(e1.dropFirst(10))) == m1, "补齐后吐出整条")
        var tampered = cunhex(f["e1"]!); tampered[5] ^= 1
        expect((try? ControlCipher(readKey: wk, writeKey: rk).feed(tampered)) == nil, "篡改密文：认证失败")
        expect((try? ControlCipher(readKey: wk, writeKey: rk).feed(cunhex(f["e2"]!))) == nil, "帧顺序错（计数不符）：认证失败")
        let empty = ControlCipher(readKey: rk, writeKey: wk)
        let ee = try! empty.encrypt([])
        expect(ee.count == 2 + 16 && ee[0] == 0 && ee[1] == 0, "空消息仍是一帧")
    }

    suite("crypto-pair-verify-differential") {
        let f = CryptoFixtures.pairVerify
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = makeStore(dir)
        expect(hex(store.identity.publicRaw) == f["accPub"], "由同一种子得到同一配件公钥")
        store.savePairing(identifier: f["ctlId"]!, ltpk: cunhex(f["ctlPub"]!))
        let eph = try! Curve25519.KeyAgreement.PrivateKey(rawRepresentation: cunhex(f["accEphSeed"]!))
        let server = PairVerify(store: store, ephemeral: eph)
        let m2 = server.handle(cunhex(f["M1"]!))
        // CryptoKit 的 Ed25519 签名带随机性，M2 不能逐字节比；其余字段逐字节比，签名按验签比。
        let mine = TLV8.decode(m2), theirs = TLV8.decode(cunhex(f["M2"]!))
        expect(mine[TLV8Tag.state] == theirs[TLV8Tag.state] && mine[TLV8Tag.publicKey] == theirs[TLV8Tag.publicKey],
               "M2 的状态与临时公钥与 MacPlay 一致")
        let encKey = PairingCrypto.hkdfSHA512(cunhex(f["shared"]!), salt: "Pair-Verify-Encrypt-Salt", info: "Pair-Verify-Encrypt-Info")
        let ctlEph = TLV8.decode(cunhex(f["M1"]!))[TLV8Tag.publicKey]!
        let signed = theirs[TLV8Tag.publicKey]! + Array(f["accId"]!.utf8) + ctlEph
        var sigOK = true, idOK = true
        for blob in [mine, theirs] {
            let sub = TLV8.decode((try? PairingCrypto.chachaOpen(key: encKey, nonce: PairingCrypto.nonceLabel("PV-Msg02"),
                                                                  data: blob[TLV8Tag.encryptedData] ?? [])) ?? [])
            idOK = idOK && sub[TLV8Tag.identifier] == Array(f["accId"]!.utf8)
            sigOK = sigOK && PairingCrypto.ed25519Verify(publicKey: cunhex(f["accPub"]!), data: signed, signature: sub[TLV8Tag.signature] ?? [])
        }
        expect(idOK, "M2 解密后配件 ID 与 MacPlay 一致（我们的与 MacPlay 的都能被同一密钥解开）")
        expect(sigOK, "M2 里的 Ed25519 签名（我们的与 MacPlay 的）都能用配件公钥验过")
        let m4 = server.handle(cunhex(f["M3"]!))
        expect(hex(m4) == f["M4"], "M4 与 MacPlay 一致")
        expect(server.verified && server.controllerId == f["ctlId"], "验证通过且识别出控制器")
        expect(server.sharedSecret.map(hex) == f["shared"], "X25519 共享密钥与 MacPlay 一致")
        expect(server.controlKeys.map { hex($0.readKey) } == f["readKey"], "控制通道读密钥与 MacPlay 一致")
        expect(server.controlKeys.map { hex($0.writeKey) } == f["writeKey"], "控制通道写密钥与 MacPlay 一致")
    }

    suite("crypto-pair-verify-simulated") {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = PairingStore(directory: dir)
        let phone = PairingClient(ltsk: Curve25519.Signing.PrivateKey(), id: Array("phone-\(UUID().uuidString)".utf8))
        store.savePairing(identifier: String(decoding: phone.id, as: UTF8.self), ltpk: phone.ltpk)

        let server = PairVerify(store: store)
        let r = simulatePairVerify(server: server, client: phone, accessoryPub: store.identity.publicRaw,
                                   ephemeral: Curve25519.KeyAgreement.PrivateKey())
        expect(r.ok && server.verified, "已配对手机通过 pair-verify")
        expect(server.sharedSecret == r.shared, "两端共享密钥相同")
        expect(server.controlKeys?.readKey == r.writeKey && server.controlKeys?.writeKey == r.readKey, "服务端读 = 手机写，服务端写 = 手机读")

        // 用得到的密钥通一次加密控制通道。
        let phoneCipher = ControlCipher(readKey: r.readKey, writeKey: r.writeKey)
        let serverCipher = ControlCipher(keys: server.controlKeys!)
        let req = Array("OPTIONS * RTSP/1.0\r\nCSeq: 1\r\n\r\n".utf8)
        expect((try? serverCipher.feed(try! phoneCipher.encrypt(req))) == req, "手机 -> 配件 加密往返")
        let resp = Array("RTSP/1.0 200 OK\r\n\r\n".utf8)
        expect((try? phoneCipher.feed(try! serverCipher.encrypt(resp))) == resp, "配件 -> 手机 加密往返")

        // 数据流密钥：两端各自派生应相同，输入/输出不同。
        let k1 = deriveStreamKey(sharedSecret: server.sharedSecret!, salt: StreamKeyInfo.salt(streamConnectionID: 42), info: StreamKeyInfo.output)
        let k2 = deriveStreamKey(sharedSecret: r.shared, salt: StreamKeyInfo.salt(streamConnectionID: 42), info: StreamKeyInfo.output)
        let k3 = deriveStreamKey(sharedSecret: r.shared, salt: StreamKeyInfo.salt(streamConnectionID: 42), info: StreamKeyInfo.input)
        expect(k1 == k2 && k1.count == 32 && k1 != k3, "数据流密钥两端一致，方向分开")

        // 未配对的手机被拒。
        let stranger = PairingClient(ltsk: Curve25519.Signing.PrivateKey(), id: Array("stranger".utf8))
        let s2 = PairVerify(store: store)
        let rs = simulatePairVerify(server: s2, client: stranger, accessoryPub: store.identity.publicRaw,
                                    ephemeral: Curve25519.KeyAgreement.PrivateKey())
        expect(!rs.ok && !s2.verified && s2.controlKeys == nil, "未配对手机被拒")

        // 配对过但签名不是本人的。
        let impostor = PairingClient(ltsk: Curve25519.Signing.PrivateKey(), id: phone.id)
        let s3 = PairVerify(store: store)
        let ri = simulatePairVerify(server: s3, client: impostor, accessoryPub: store.identity.publicRaw,
                                    ephemeral: Curve25519.KeyAgreement.PrivateKey())
        expect(!ri.ok && !s3.verified, "冒名签名被拒")

        // 乱序 / 垃圾输入返回错误 TLV，不崩。
        let junk = TLV8.decode(PairVerify(store: store).handle(tlvState(3, [TLV8Item(TLV8Tag.encryptedData, pat(40, 1, 1))])))
        expect(junk[TLV8Tag.error] == [2] && junk[TLV8Tag.state] == [4], "M3 先于 M1：错误 TLV")
        let bogus = TLV8.decode(PairVerify(store: store).handle(tlvState(1, [TLV8Item(TLV8Tag.publicKey, [1, 2, 3])])))
        expect(bogus[TLV8Tag.error] == [2], "坏的临时公钥：错误 TLV")
    }

    suite("crypto-pair-setup-differential") {
        let f = CryptoFixtures.pairSetup
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = makeStore(dir)
        let server = PairSetup(store: store, srpSalt: pat(16, 1, 0), srpPrivateB: pat(32, 7, 3))
        expect(hex(server.handle(cunhex(f["M1"]!))) == f["M2"], "M2 与 MacPlay 一致（B、盐）")
        expect(hex(server.handle(cunhex(f["M3"]!))) == f["M4"], "M4 与 MacPlay 一致（SRP M2）")
        expect(server.sessionKey.map(hex) == f["K"], "SRP 会话密钥 K 与 MacPlay 一致")
        let m6 = TLV8.decode(server.handle(cunhex(f["M5"]!)))
        let theirs6 = TLV8.decode(cunhex(f["M6"]!))
        expect(m6[TLV8Tag.state] == [6] && theirs6[TLV8Tag.state] == [6], "M6 状态一致")
        // Ed25519 签名带随机性，M6 解密后按字段比：ID、公钥相同，签名都能验过。
        let K = cunhex(f["K"]!)
        let encKey = PairingCrypto.hkdfSHA512(K, salt: "Pair-Setup-Encrypt-Salt", info: "Pair-Setup-Encrypt-Info")
        let accSignKey = PairingCrypto.hkdfSHA512(K, salt: "Pair-Setup-Accessory-Sign-Salt", info: "Pair-Setup-Accessory-Sign-Info")
        var fieldsOK = true, sigOK = true
        var subs: [[UInt8: [UInt8]]] = []
        for blob in [m6, theirs6] {
            let sub = TLV8.decode((try? PairingCrypto.chachaOpen(key: encKey, nonce: PairingCrypto.nonceLabel("PS-Msg06"),
                                                                  data: blob[TLV8Tag.encryptedData] ?? [])) ?? [])
            subs.append(sub)
            let id = sub[TLV8Tag.identifier] ?? [], pk = sub[TLV8Tag.publicKey] ?? []
            fieldsOK = fieldsOK && id == Array("AA:BB:CC:DD:EE:FF-acc".utf8) && hex(pk) == CryptoFixtures.pairVerify["accPub"]
            sigOK = sigOK && PairingCrypto.ed25519Verify(publicKey: pk, data: accSignKey + id + pk, signature: sub[TLV8Tag.signature] ?? [])
        }
        expect(fieldsOK, "M6 解密后配件 ID 与公钥和 MacPlay 一致")
        expect(sigOK, "M6 里的 Ed25519 签名（我们的与 MacPlay 的）都能验过")
        expect(server.complete && server.controllerId == CryptoFixtures.pairVerify["ctlId"], "配对完成并记下控制器")
        expect(store.ltpk(for: CryptoFixtures.pairVerify["ctlId"]!).map(hex) == CryptoFixtures.pairVerify["ctlPub"], "控制器 LTPK 已存")
    }

    suite("crypto-pair-setup-then-verify-simulated") {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = PairingStore(directory: dir)
        let phone = PairingClient(ltsk: Curve25519.Signing.PrivateKey(), id: Array("iphone-test".utf8))
        let setup = PairSetup(store: store)
        let r = simulatePairSetup(server: setup, client: phone, a: BigUInt(bytes: pat(32, 11, 5)))
        expect(r.ok && setup.complete, "完整 pair-setup M1..M6 通过")
        expect(store.ltpk(for: "iphone-test") == phone.ltpk, "控制器公钥落盘")

        // 重启后用新的 store 实例仍认得，并能 pair-verify。
        let reopened = PairingStore(directory: dir)
        expect(reopened.identity.publicRaw == store.identity.publicRaw && reopened.identity.pairingId == store.identity.pairingId, "身份跨实例稳定")
        let v = PairVerify(store: reopened)
        let rv = simulatePairVerify(server: v, client: phone, accessoryPub: reopened.identity.publicRaw,
                                    ephemeral: Curve25519.KeyAgreement.PrivateKey())
        expect(rv.ok && v.verified, "刚配对的手机立即 pair-verify 通过")

        // 错误配对码
        let bad = PairSetup(store: store, setupCode: "1111")
        let rb = simulatePairSetup(server: bad, client: phone, a: BigUInt(bytes: pat(32, 3, 5)))
        expect(!rb.ok && !bad.complete, "配对码不符：失败")
        // M5 先于 M3 / 垃圾
        let early = TLV8.decode(PairSetup(store: store).handle(tlvState(5, [TLV8Item(TLV8Tag.encryptedData, pat(60, 1, 1))])))
        expect(early[TLV8Tag.error] == [2], "未建立会话就发 M5：错误 TLV")
        let tampered = PairSetup(store: store)
        _ = tampered.handle(tlvState(1))
        expect(TLV8.decode(tampered.handle(tlvState(3, [TLV8Item(TLV8Tag.publicKey, pat(384, 1, 1)), TLV8Item(TLV8Tag.proof, pat(64, 1, 1))])))[TLV8Tag.error] == [2], "错 M1 证明：错误 TLV")
    }

    suite("crypto-pairing-store") {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let s1 = PairingStore(directory: dir)
        s1.savePairing(identifier: "ctl-a", ltpk: pat(32, 1, 1))
        s1.savePairing(identifier: "ctl-b", ltpk: pat(32, 2, 2))
        let file = dir.appendingPathComponent("pairing.json")
        let attrs = try? FileManager.default.attributesOfItem(atPath: file.path)
        expect((attrs?[.posixPermissions] as? Int) == 0o600, "pairing.json 权限 0600")
        let s2 = PairingStore(directory: dir)
        expect(s2.identity.publicRaw == s1.identity.publicRaw && s2.identity.pairingId == s1.identity.pairingId, "重开后身份不变")
        expect(s2.ltpk(for: "ctl-a") == pat(32, 1, 1) && s2.ltpk(for: "ctl-b") == pat(32, 2, 2), "控制器公钥保留")
        expect(s2.ltpk(for: "nobody") == nil, "未知控制器返回 nil")
        expect(s2.pairedIdentifiers == ["ctl-a", "ctl-b"], "列出已配对")
        s2.removePairing(identifier: "ctl-a")
        expect(PairingStore(directory: dir).ltpk(for: "ctl-a") == nil, "移除后落盘")
        expect(s1.identity.publicKeyHex.count == 64 && s1.identity.deviceId.hasPrefix("02:"), "pk 十六进制与设备地址格式")
        try? "not json".write(to: file, atomically: true, encoding: .utf8)
        let s3 = PairingStore(directory: dir)
        expect(s3.identity.publicRaw != s1.identity.publicRaw && s3.ltpk(for: "ctl-b") == nil, "文件损坏时重新生成身份（同 MacPlay）")
    }
}


// ---- 自动生成的差分向量：/private/tmp/claude-501/-Users-aaron-Documents-WindowShade/29b64c53-6453-4f38-a94d-e6761e143e66/scratchpad/p2-crypto/gen-vectors.cjs
// 直接加载 MacPlay 的 TS 模块（srp / tlv8 / crypto / controlCipher / pairSetup / pairVerify）固定随机后产生。
enum CryptoFixtures {
    // RFC 5054 附录 B（1024 位 / SHA-1）：输入取自 RFC，输出由独立的 Python 大整数重算，k x u A B S 前缀与 RFC 逐项核过。
    static let rfcK = "7556aa045aef2cdd07abaf0f665c3e818913186f"
    static let rfcX = "94b7555aabe9127cc58ccf4993db6cf84d16c124"
    static let rfcV = "7e273de8696ffc4f4e337d05b4b375beb0dde1569e8fa00a9886d8129bada1f1822223ca1a605b530e379ba4729fdc59f105b4787e5186f5c671085a1447b52a48cf1970b4fb6f8400bbf4cebfbb168152e08ab5ea53d15c1aff87b2b9da6e04e058ad51cc72bfc9033b564e26480d78e955a5e29e7ab245db2be315e2099afb"
    static let rfcA = "61d5e490f6f1b79547b0704c436f523dd0e560f0c64115bb72557ec44352e8903211c04692272d8b2d1a5358a2cf1b6e0bfcf99f921530ec8e39356179eae45e42ba92aeaced825171e1e8b9af6d9c03e1327f44be087ef06530e69f66615261eef54073ca11cf5858f0edfdfe15efeab349ef5d76988a3672fac47b0769447b"
    static let rfcB = "bd0c61512c692c0cb6d041fa01bb152d4916a1e77af46ae105393011baf38964dc46a0670dd125b95a981652236f99d9b681cbf87837ec996c6da04453728610d0c6ddb58b318885d7d82c7f8deb75ce7bd4fbaa37089e6f9c6059f388838e7a00030b331eb76840910440b1b27aaeaeeb4012b7d7665238a8e3fb004b117b58"
    static let rfcU = "ce38b9593487da98554ed47d70a7ae5f462ef019"
    static let rfcS = "b0dc82babcf30674ae450c0287745e7990a3381f63b387aaf271a10d233861e359b48220f7c4693c9ae12b0a6f67809f0876e2d013800d6c41bb59b6d5979b5c00a172b4a2a5903a0bdcaf8a709585eb2afafa8f3499b200210dcc1f10eb33943cd67fc88a2f39a4be5bec4ec0a3212dc346d7e474b29ede8a469ffeca686e5a"
    static let tlv: [String: (items: [(UInt8, String)], encoded: String)] = [
        "state1": (items: [(6, "01")], encoded: "060101"),
        "big300": (items: [(3, "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f404142434445464748494a4b4c4d4e4f505152535455565758595a5b5c5d5e5f606162636465666768696a6b6c6d6e6f707172737475767778797a7b7c7d7e7f808182838485868788898a8b8c8d8e8f909192939495969798999a9b9c9d9e9fa0a1a2a3a4a5a6a7a8a9aaabacadaeafb0b1b2b3b4b5b6b7b8b9babbbcbdbebfc0c1c2c3c4c5c6c7c8c9cacbcccdcecfd0d1d2d3d4d5d6d7d8d9dadbdcdddedfe0e1e2e3e4e5e6e7e8e9eaebecedeeeff0f1f2f3f4f5f6f7f8f9fafbfcfdfeff000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f202122232425262728292a2b"), (6, "02")], encoded: "03ff000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f404142434445464748494a4b4c4d4e4f505152535455565758595a5b5c5d5e5f606162636465666768696a6b6c6d6e6f707172737475767778797a7b7c7d7e7f808182838485868788898a8b8c8d8e8f909192939495969798999a9b9c9d9e9fa0a1a2a3a4a5a6a7a8a9aaabacadaeafb0b1b2b3b4b5b6b7b8b9babbbcbdbebfc0c1c2c3c4c5c6c7c8c9cacbcccdcecfd0d1d2d3d4d5d6d7d8d9dadbdcdddedfe0e1e2e3e4e5e6e7e8e9eaebecedeeeff0f1f2f3f4f5f6f7f8f9fafbfcfdfe032dff000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f202122232425262728292a2b060102"),
        "exact255": (items: [(5, "0104070a0d101316191c1f2225282b2e3134373a3d404346494c4f5255585b5e6164676a6d707376797c7f8285888b8e9194979a9da0a3a6a9acafb2b5b8bbbec1c4c7cacdd0d3d6d9dcdfe2e5e8ebeef1f4f7fafd000306090c0f1215181b1e2124272a2d303336393c3f4245484b4e5154575a5d606366696c6f7275787b7e8184878a8d909396999c9fa2a5a8abaeb1b4b7babdc0c3c6c9cccfd2d5d8dbdee1e4e7eaedf0f3f6f9fcff0205080b0e1114171a1d202326292c2f3235383b3e4144474a4d505356595c5f6265686b6e7174777a7d808386898c8f9295989b9ea1a4a7aaadb0b3b6b9bcbfc2c5c8cbced1d4d7dadde0e3e6e9eceff2f5f8fb")], encoded: "05ff0104070a0d101316191c1f2225282b2e3134373a3d404346494c4f5255585b5e6164676a6d707376797c7f8285888b8e9194979a9da0a3a6a9acafb2b5b8bbbec1c4c7cacdd0d3d6d9dcdfe2e5e8ebeef1f4f7fafd000306090c0f1215181b1e2124272a2d303336393c3f4245484b4e5154575a5d606366696c6f7275787b7e8184878a8d909396999c9fa2a5a8abaeb1b4b7babdc0c3c6c9cccfd2d5d8dbdee1e4e7eaedf0f3f6f9fcff0205080b0e1114171a1d202326292c2f3235383b3e4144474a4d505356595c5f6265686b6e7174777a7d808386898c8f9295989b9ea1a4a7aaadb0b3b6b9bcbfc2c5c8cbced1d4d7dadde0e3e6e9eceff2f5f8fb"),
        "big510": (items: [(5, "050c131a21282f363d444b525960676e757c838a91989fa6adb4bbc2c9d0d7dee5ecf3fa01080f161d242b323940474e555c636a71787f868d949ba2a9b0b7bec5ccd3dae1e8eff6fd040b121920272e353c434a51585f666d747b828990979ea5acb3bac1c8cfd6dde4ebf2f900070e151c232a31383f464d545b626970777e858c939aa1a8afb6bdc4cbd2d9e0e7eef5fc030a11181f262d343b424950575e656c737a81888f969da4abb2b9c0c7ced5dce3eaf1f8ff060d141b222930373e454c535a61686f767d848b9299a0a7aeb5bcc3cad1d8dfe6edf4fb020910171e252c333a41484f565d646b727980878e959ca3aab1b8bfc6cdd4dbe2e9f0f7fe050c131a21282f363d444b525960676e757c838a91989fa6adb4bbc2c9d0d7dee5ecf3fa01080f161d242b323940474e555c636a71787f868d949ba2a9b0b7bec5ccd3dae1e8eff6fd040b121920272e353c434a51585f666d747b828990979ea5acb3bac1c8cfd6dde4ebf2f900070e151c232a31383f464d545b626970777e858c939aa1a8afb6bdc4cbd2d9e0e7eef5fc030a11181f262d343b424950575e656c737a81888f969da4abb2b9c0c7ced5dce3eaf1f8ff060d141b222930373e454c535a61686f767d848b9299a0a7aeb5bcc3cad1d8dfe6edf4fb020910171e252c333a41484f565d646b727980878e959ca3aab1b8bfc6cdd4dbe2e9f0")], encoded: "05ff050c131a21282f363d444b525960676e757c838a91989fa6adb4bbc2c9d0d7dee5ecf3fa01080f161d242b323940474e555c636a71787f868d949ba2a9b0b7bec5ccd3dae1e8eff6fd040b121920272e353c434a51585f666d747b828990979ea5acb3bac1c8cfd6dde4ebf2f900070e151c232a31383f464d545b626970777e858c939aa1a8afb6bdc4cbd2d9e0e7eef5fc030a11181f262d343b424950575e656c737a81888f969da4abb2b9c0c7ced5dce3eaf1f8ff060d141b222930373e454c535a61686f767d848b9299a0a7aeb5bcc3cad1d8dfe6edf4fb020910171e252c333a41484f565d646b727980878e959ca3aab1b8bfc6cdd4dbe2e9f0f705fffe050c131a21282f363d444b525960676e757c838a91989fa6adb4bbc2c9d0d7dee5ecf3fa01080f161d242b323940474e555c636a71787f868d949ba2a9b0b7bec5ccd3dae1e8eff6fd040b121920272e353c434a51585f666d747b828990979ea5acb3bac1c8cfd6dde4ebf2f900070e151c232a31383f464d545b626970777e858c939aa1a8afb6bdc4cbd2d9e0e7eef5fc030a11181f262d343b424950575e656c737a81888f969da4abb2b9c0c7ced5dce3eaf1f8ff060d141b222930373e454c535a61686f767d848b9299a0a7aeb5bcc3cad1d8dfe6edf4fb020910171e252c333a41484f565d646b727980878e959ca3aab1b8bfc6cdd4dbe2e9f0"),
        "adjacentSame": (items: [(1, "6162"), (1, "6364")], encoded: "01026162ff0001026364"),
        "emptyValue": (items: [(2, ""), (6, "04")], encoded: "0200060104"),
    ]
    static let srp: [String: String] = [
        "salt": "000102030405060708090a0b0c0d0e0f",
        "b": "030a11181f262d343b424950575e656c737a81888f969da4abb2b9c0c7ced5dc",
        "a": "090e13181d22272c31363b40454a4f54595e63686d72777c81868b90959a9fa4",
        "B": "9f907c26920021fc245277e076a6be305d3c5c119fe28acdeeb1132ae6328687ab9451d57e3d9cb1b1eee477804db9cde5b65829fbbcd83aa31354b141ee4cfc3c129948f5b44a97056f6e72dea089be942b6ab41721515bf24e6825163dcc047833f9763d0e7f1bd01ad20d0dc39b188ed8e5f8a999668f0ae1b41f017289e28d758c0ff379aa1bf27b58ccce0b79375b023fffec869956d75ede548a12c8cf3af34ba7ded5cc0a062a8cc1b0d480ecdb4dc4eb10bba23b805285284d9efd0c85352e9809fdbbb15b759f3c39329a6f121922f067bcb32b3aabb2ed7331cc95ccd39f4c6bef042cbc8aad20d74c56eb3f76ccea86b3c44620cc0dc439601bf64baee4a6a85ee0207cf3821c7eec0a22a91e2013f880517ad3c51ea622f31a4490ee012b67ce4b396820b78fa1014609a6b414ee6595e80ff819cfd2775fbbc9922e6e8551134d52f13e1ca77356b72fb894f9092fe808ff8c6b95a778ec5b88e8d992a31bb6f7ea0e67d4c412cf3b6642b3e3158221eb541e0326d04700b399",
        "A": "3b2c0841fa6cc3d85facb41da028273dec334259adabb9346cf656ead64651dc26fcb166b7e338efab835c8300f772c8a7327e3dfe0a392b183050cc475035a85dfbc47d9a9f32d233c75cc984abe34c53bc76639891e696c0f63b3a97a59ab7d6d3b2d70fd5dc04091583b445c674f192ca2d0774deee5579e8700a1ed040b3f66e76e57856461e5032b043b16c04349299716c387f15c4ec3fb31829e6ee1c12cfc86fa64b40b3f6a630479af172b745000f0a1735da34947d4f79f77d40d4185a5a7c82ae5f5f55f55535787808e07254a8a38faacab424e6e91e49d5d950a0599e37e9ade286440e9c5810b3ef950bed45d199e351606b28328860c6b4dbcddb9865e8aab7a1ce2fac75174aaf245b949819939599d3d4331f01d29ed044ce671a98b1a6a25d9d7ac3bb1bc5ec4f07c118b6e8492a555820c276a4592c9ca207445f1ba6276fcdfe9fd2a9221fb83b55b886f97addee4d00ba3c7033d70827a5db75ad9d8527f165d4ddbdb66cdf682f56d35abee19cc4d94e2ddc07189d",
        "M1": "a5bbf9b12cd3c11c22700657094de0ead9db80b18c62c0d2ac322e2b613b45091e75969d9cb43d7ff5297447ee8433fc694afc2ea1eefe6a1200836851fad258",
        "K": "c47ee8abaec6ee857a257636b1aca2ce8c8a0653e95de4a19f594982908cea6a8eb25dec547b2b2d6d9f2299492d52d344467b6fc3f7dbea2e9fdf850688691d",
        "M2": "4e3d6edbb44ce38dde1b6009b08c5125ece03c63d4d783525d7adb05bdcf3b525a56c1463d54e26dcab9c0192430d458eb01d9da62cd1c7223902db3ed4ce99f",
    ]
    static let hkdf: [String: String] = [
        "ikm": "070a0d101316191c1f2225282b2e3134373a3d404346494c4f5255585b5e6164",
        "encrypt32": "91e4324a634b50fa98b510fd847be89d751491ba1d081a482ce30389bac9ee44",
        "long64": "03ed2454087c4990febb4235ff0ca6622475595c63b0fa680214092205342ac28edb9a56c07c86437139783cb3b91e430626cfbdd40a87391a18d07b002ee2f5",
        "streamOutput": "a2545e87ead8b8ea02585e1112bd2265e88d0feb268517c9a1561b8ca14ab437",
        "streamInput": "7ea628b5439a7c730abe49e5b4d7e431a591d4ebf4532480529b884e8ece7e8e",
    ]
    static let control: [String: String] = [
        "readKey": "010c17222d38434e59646f7a85909ba6b1bcc7d2dde8f3fe09141f2a35404b56",
        "writeKey": "020f1c293643505d6a7784919eabb8c5d2dfecf90613202d3a4754616e7b8895",
        "m1": "525453502f312e3020323030204f4b0d0a435365713a20310d0a0d0a",
        "m2": "534554555020727473703a2f2f7820525453502f312e300d0a435365713a20320d0a0d0a",
        "e1": "1c00fce15f57d1665ab624c5afc92d2bcadf5f03173d62353e066a1014fa8100b449bbaf3f871ba09406bde52c7b",
        "e2": "24000df45ff3757ca60607261693ba6220e5f05e2af905ccaa85a3223c1ebd8fe412c63c3e6e20bf5a17e10ff0053a933bb94b06ff92",
        "bigSha256": "237739b1ca4222d38937a98642087c6dc62f590467ffc20310a0bd890ac23f72",
    ]
    static let pairVerify: [String: String] = [
        "accSeed": "0104070a0d101316191c1f2225282b2e3134373a3d404346494c4f5255585b5e",
        "accPub": "5c8ee580f7c1d08f801e472165889625f16d98f237b3abdfa858c50893148e1e",
        "accId": "AA:BB:CC:DD:EE:FF-acc",
        "ctlSeed": "02070c11161b20252a2f34393e43484d52575c61666b70757a7f84898e93989d",
        "ctlPub": "8fdc80faaefe5f5c496e0d20e292e4ace4a06f9ee36d7010ad0db77d5050e03d",
        "ctlId": "controller-1234",
        "accEphSeed": "040d161f28313a434c555e677079828b949da6afb8c1cad3dce5eef70009121b",
        "ctlEphSeed": "061524334251606f7e8d9cabbac9d8e7f60514233241505f6e7d8c9baab9c8d7",
        "M1": "06010103200f4f124c32a220dcac1b96312e95e30f2bebe5fe9e3649d39fc053ffe5e2377a",
        "M2": "0601020320a76892308e4732458a6229d60fb265c287492c30b1114e2a781c7cf456b3464605694edb06688ed293887b49e1dcac2ce23ee5998168b1b729a69a1e607dc007c0deaffd1f6904cae54ac46952aade6a842b24fb2e89aea07166f38585c4a48f6c0ee6ad8ffb61fc8646410ff0d8fbe20ff17bf5f64322266569fd9015ddc6369bf6c13a4a24461aa3f6f7",
        "M3": "0601030563533b4ef31cb208abd975d25826e1a5a4159a5a4219a58bce9885c39107f70d432e7de2e69fb788c47bf917a8f16f008ac1663dea805a4b3b9d7c8a8e3cadca378e983cbdaa86c4e4e89e9e677a22e4f523829f826d271db071c40f60960d471befedc2",
        "M4": "060104",
        "shared": "6f5465d9c9d56a8daedfdf917b0dfe27dafe143f78295515e705877ef23cdc69",
        "readKey": "fbc4e338fab0c8110a49635ce025a549757baeabd38183482067256c8208f4c2",
        "writeKey": "ae191e826c19e25205b4ddf891a579e5790cfa1b419e111b4e36d795fd5cd1c0",
    ]
    static let pairSetup: [String: String] = [
        "M1": "060101000100",
        "M2": "06010203ff9f907c26920021fc245277e076a6be305d3c5c119fe28acdeeb1132ae6328687ab9451d57e3d9cb1b1eee477804db9cde5b65829fbbcd83aa31354b141ee4cfc3c129948f5b44a97056f6e72dea089be942b6ab41721515bf24e6825163dcc047833f9763d0e7f1bd01ad20d0dc39b188ed8e5f8a999668f0ae1b41f017289e28d758c0ff379aa1bf27b58ccce0b79375b023fffec869956d75ede548a12c8cf3af34ba7ded5cc0a062a8cc1b0d480ecdb4dc4eb10bba23b805285284d9efd0c85352e9809fdbbb15b759f3c39329a6f121922f067bcb32b3aabb2ed7331cc95ccd39f4c6bef042cbc8aad20d74c56eb3f76ccea86b3c44620cc0dc439601b0381f64baee4a6a85ee0207cf3821c7eec0a22a91e2013f880517ad3c51ea622f31a4490ee012b67ce4b396820b78fa1014609a6b414ee6595e80ff819cfd2775fbbc9922e6e8551134d52f13e1ca77356b72fb894f9092fe808ff8c6b95a778ec5b88e8d992a31bb6f7ea0e67d4c412cf3b6642b3e3158221eb541e0326d04700b3990210000102030405060708090a0b0c0d0e0f",
        "M3": "06010303ff3b2c0841fa6cc3d85facb41da028273dec334259adabb9346cf656ead64651dc26fcb166b7e338efab835c8300f772c8a7327e3dfe0a392b183050cc475035a85dfbc47d9a9f32d233c75cc984abe34c53bc76639891e696c0f63b3a97a59ab7d6d3b2d70fd5dc04091583b445c674f192ca2d0774deee5579e8700a1ed040b3f66e76e57856461e5032b043b16c04349299716c387f15c4ec3fb31829e6ee1c12cfc86fa64b40b3f6a630479af172b745000f0a1735da34947d4f79f77d40d4185a5a7c82ae5f5f55f55535787808e07254a8a38faacab424e6e91e49d5d950a0599e37e9ade286440e9c5810b3ef950bed45d199e351606b28328860c6b40381dbcddb9865e8aab7a1ce2fac75174aaf245b949819939599d3d4331f01d29ed044ce671a98b1a6a25d9d7ac3bb1bc5ec4f07c118b6e8492a555820c276a4592c9ca207445f1ba6276fcdfe9fd2a9221fb83b55b886f97addee4d00ba3c7033d70827a5db75ad9d8527f165d4ddbdb66cdf682f56d35abee19cc4d94e2ddc07189d0440a5bbf9b12cd3c11c22700657094de0ead9db80b18c62c0d2ac322e2b613b45091e75969d9cb43d7ff5297447ee8433fc694afc2ea1eefe6a1200836851fad258",
        "M4": "06010404404e3d6edbb44ce38dde1b6009b08c5125ece03c63d4d783525d7adb05bdcf3b525a56c1463d54e26dcab9c0192430d458eb01d9da62cd1c7223902db3ed4ce99f",
        "M5": "06010505851c7f9ca22c7afe86e596827ec139dfd077e744417490082d4d473bc0d8b2e27ab71b99b1742ddb26f5be6a0f9057b4b1c270ac2a5084737932e3f37964bee70aab76f0ee5c9da5857ba29a3ef188e8734181460f717e33186e7e0b63635bf7c5008f18d21d572eb435286e247abe9f8479096f2bc6bb7ba690553ef67939e03816df71a5d6",
        "M6": "060106058b2653058d82a09f05bd0ae9272486f6b766c04b66455614f2fe6248c1d43a3fe281ef3cc5c59ddfb5b6db0d2b374155f745ad2d29f026211e122b047cbf2a338107b45d8348b619fb2639a1325ce2ddfa1ed9ce3f59fb7b721162d6f5d624188a76758b9f78551fe613e2edf955edc2ec35f7cf005ff362c5c7cf4b3a6b6867ea7dfa8d72a7109258cd3609",
        "K": "c47ee8abaec6ee857a257636b1aca2ce8c8a0653e95de4a19f594982908cea6a8eb25dec547b2b2d6d9f2299492d52d344467b6fc3f7dbea2e9fdf850688691d",
    ]
    static let controlBigLen = 20036
}
