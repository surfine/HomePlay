// CarPlay pair-setup 响应方（配件端）。参照 MacPlay pairSetup.ts：
// 无认证（unauthenticated）pair-setup —— SRP-6a（3072 位、SHA-512）+ 固定配对码 "3939"（不输入、pair-setup 内不做 MFi），
// 随后是加密的 Ed25519 长期公钥交换（M5/M6）。控制器公钥落盘供 pair-verify 使用。MacPlay 不使用 transient 模式。
import Foundation

package final class PairSetup {
    package static let setupCode = "3939"
    package static let username = "Pair-Setup"
    private static let errAuthentication: UInt8 = 2

    private let store: PairingStore
    private let setupCode: String
    private let srpSalt: [UInt8]?
    private let srpPrivateB: [UInt8]?
    private var srp: SRPServer?
    private var sessionKeyBytes: [UInt8]?
    package private(set) var complete = false
    package private(set) var controllerId: String?

    /// SRP 会话密钥 K（M4 校验通过之后才有）。
    package var sessionKey: [UInt8]? { sessionKeyBytes }

    /// `srpSalt` / `srpPrivateB` 只给测试固定随机。
    package init(store: PairingStore, setupCode: String = PairSetup.setupCode,
                 srpSalt: [UInt8]? = nil, srpPrivateB: [UInt8]? = nil) {
        self.store = store
        self.setupCode = setupCode
        self.srpSalt = srpSalt
        self.srpPrivateB = srpPrivateB
    }

    /// 处理一条 pair-setup TLV8 请求，返回 TLV8 响应体。
    package func handle(_ body: [UInt8]) -> [UInt8] {
        let tlv = TLV8.decode(body)
        let state = tlv[TLV8Tag.state]?.first
        do {
            if state == 1 { return m2() }
            if state == 3 { return m4(tlv) }
            if state == 5 { return try m6(tlv) }
        } catch {
            FileHandle.standardError.write(Data("[PairSetup] error: \(error)\n".utf8))
        }
        return err(state ?? 0)
    }

    private func m2() -> [UInt8] {
        let server = SRPServer(username: Self.username, password: setupCode,
                               salt: srpSalt, privateB: srpPrivateB)
        srp = server
        return TLV8.encode([
            TLV8Item(TLV8Tag.state, [2]),
            TLV8Item(TLV8Tag.publicKey, server.publicKey),
            TLV8Item(TLV8Tag.salt, server.salt),
        ])
    }

    private func m4(_ tlv: [UInt8: [UInt8]]) -> [UInt8] {
        guard let srp, let A = tlv[TLV8Tag.publicKey], let proof = tlv[TLV8Tag.proof] else { return err(4) }
        guard let result = srp.verify(A: A, clientM1: proof) else { return err(4) }
        sessionKeyBytes = result.K
        return TLV8.encode([
            TLV8Item(TLV8Tag.state, [4]),
            TLV8Item(TLV8Tag.proof, result.serverM2),
        ])
    }

    private func m6(_ tlv: [UInt8: [UInt8]]) throws -> [UInt8] {
        guard let K = sessionKeyBytes, let enc = tlv[TLV8Tag.encryptedData] else { return err(6) }
        let encKey = PairingCrypto.hkdfSHA512(K, salt: "Pair-Setup-Encrypt-Salt", info: "Pair-Setup-Encrypt-Info")
        let sub = TLV8.decode(try PairingCrypto.chachaOpen(
            key: encKey, nonce: PairingCrypto.nonceLabel("PS-Msg05"), data: enc))
        guard let ctrlId = sub[TLV8Tag.identifier], let ctrlLTPK = sub[TLV8Tag.publicKey],
              let ctrlSig = sub[TLV8Tag.signature] else { return err(6) }

        // 控制器对 (signKey || identifier || 它的 LTPK) 的签名。
        let ctrlSignKey = PairingCrypto.hkdfSHA512(K, salt: "Pair-Setup-Controller-Sign-Salt",
                                                   info: "Pair-Setup-Controller-Sign-Info")
        guard PairingCrypto.ed25519Verify(publicKey: ctrlLTPK, data: ctrlSignKey + ctrlId + ctrlLTPK,
                                          signature: ctrlSig) else { return err(6) }
        let ctrlName = String(decoding: ctrlId, as: UTF8.self)
        store.savePairing(identifier: ctrlName, ltpk: ctrlLTPK)

        let id = store.identity
        let accId = Array(id.pairingId.utf8)
        let accSignKey = PairingCrypto.hkdfSHA512(K, salt: "Pair-Setup-Accessory-Sign-Salt",
                                                  info: "Pair-Setup-Accessory-Sign-Info")
        let accSig = try PairingCrypto.ed25519Sign(privateKey: id.privateRaw,
                                                   data: accSignKey + accId + id.publicRaw)
        let subResp = TLV8.encode([
            TLV8Item(TLV8Tag.identifier, accId),
            TLV8Item(TLV8Tag.publicKey, id.publicRaw),
            TLV8Item(TLV8Tag.signature, accSig),
        ])
        let sealed = try PairingCrypto.chachaSeal(key: encKey, nonce: PairingCrypto.nonceLabel("PS-Msg06"),
                                                  plaintext: subResp)
        complete = true
        controllerId = ctrlName
        return TLV8.encode([
            TLV8Item(TLV8Tag.state, [6]),
            TLV8Item(TLV8Tag.encryptedData, sealed),
        ])
    }

    private func err(_ state: UInt8) -> [UInt8] {
        TLV8.encode([TLV8Item(TLV8Tag.state, [state]), TLV8Item(TLV8Tag.error, [Self.errAuthentication])])
    }
}
