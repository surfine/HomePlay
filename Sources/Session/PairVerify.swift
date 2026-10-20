// CarPlay pair-verify 响应方（配件端）。参照 MacPlay pairVerify.ts：
// 重连的手机用 pair-setup 存下的控制器 LTPK，经临时 X25519 + Ed25519 签名证明身份（HAP pair-verify）。
// 成功后得到控制通道的 ChaCha20-Poly1305 密钥，以及后续派生数据流密钥用的共享密钥。
import CryptoKit
import Foundation

/// 控制通道每方向的密钥。
package struct ControlKeys: Equatable {
    package let readKey: [UInt8]
    package let writeKey: [UInt8]
}

package final class PairVerify {
    private static let errAuthentication: UInt8 = 2

    private let store: PairingStore
    private let ephemeral: Curve25519.KeyAgreement.PrivateKey
    private var clientEphPub: [UInt8]?
    private var shared: [UInt8]?
    private var encKey: [UInt8]?
    package private(set) var controlKeys: ControlKeys?
    package private(set) var verified = false
    package private(set) var controllerId: String?

    /// pair-verify 的 X25519 共享密钥，用来派生数据流密钥（见 `deriveStreamKey`）。
    package var sharedSecret: [UInt8]? { shared }

    private var ephPub: [UInt8] { Array(ephemeral.publicKey.rawRepresentation) }

    /// `ephemeral` 只给测试固定随机。
    package init(store: PairingStore, ephemeral: Curve25519.KeyAgreement.PrivateKey? = nil) {
        self.store = store
        self.ephemeral = ephemeral ?? Curve25519.KeyAgreement.PrivateKey()
    }

    /// 处理一条 pair-verify TLV8 请求，返回 TLV8 响应体。
    package func handle(_ body: [UInt8]) -> [UInt8] {
        let tlv = TLV8.decode(body)
        let state = tlv[TLV8Tag.state]?.first
        do {
            if state == 1 { return try m2(tlv) }
            if state == 3 { return try m4(tlv) }
        } catch {
            FileHandle.standardError.write(Data("[PairVerify] error: \(error)\n".utf8))
        }
        return err(state ?? 0)
    }

    private func m2(_ tlv: [UInt8: [UInt8]]) throws -> [UInt8] {
        guard let clientPub = tlv[TLV8Tag.publicKey] else { return err(2) }
        clientEphPub = clientPub
        let secret = try PairingCrypto.x25519Shared(privateKey: ephemeral, peerPublic: clientPub)
        shared = secret
        let key = PairingCrypto.hkdfSHA512(secret, salt: "Pair-Verify-Encrypt-Salt", info: "Pair-Verify-Encrypt-Info")
        encKey = key

        // 对 ownEphPub || ownPairingId || peerEphPub 用配件长期私钥签名。
        let id = store.identity
        let accId = Array(id.pairingId.utf8)
        let sig = try PairingCrypto.ed25519Sign(privateKey: id.privateRaw, data: ephPub + accId + clientPub)
        let sub = TLV8.encode([TLV8Item(TLV8Tag.identifier, accId), TLV8Item(TLV8Tag.signature, sig)])
        let sealed = try PairingCrypto.chachaSeal(key: key, nonce: PairingCrypto.nonceLabel("PV-Msg02"), plaintext: sub)
        return TLV8.encode([
            TLV8Item(TLV8Tag.state, [2]),
            TLV8Item(TLV8Tag.publicKey, ephPub),
            TLV8Item(TLV8Tag.encryptedData, sealed),
        ])
    }

    private func m4(_ tlv: [UInt8: [UInt8]]) throws -> [UInt8] {
        guard let encKey, let shared, let clientEphPub, let enc = tlv[TLV8Tag.encryptedData] else { return err(4) }
        let sub = TLV8.decode(try PairingCrypto.chachaOpen(
            key: encKey, nonce: PairingCrypto.nonceLabel("PV-Msg03"), data: enc))
        guard let ctrlId = sub[TLV8Tag.identifier], let ctrlSig = sub[TLV8Tag.signature] else { return err(4) }
        let name = String(decoding: ctrlId, as: UTF8.self)
        guard let ctrlLTPK = store.ltpk(for: name) else { return err(4) }

        // 控制器签的是 peerEphPub(我们的对端=它自己) || 它的 ID || ownEphPub(我们的)。
        guard PairingCrypto.ed25519Verify(publicKey: ctrlLTPK, data: clientEphPub + ctrlId + ephPub,
                                          signature: ctrlSig) else { return err(4) }

        // 密钥名从控制器视角起的：配件用控制器的 WRITE 密钥读、用它的 READ 密钥写。
        controlKeys = ControlKeys(
            readKey: PairingCrypto.hkdfSHA512(shared, salt: "Control-Salt", info: "Control-Write-Encryption-Key"),
            writeKey: PairingCrypto.hkdfSHA512(shared, salt: "Control-Salt", info: "Control-Read-Encryption-Key"))
        verified = true
        controllerId = name
        return TLV8.encode([TLV8Item(TLV8Tag.state, [4])])
    }

    private func err(_ state: UInt8) -> [UInt8] {
        TLV8.encode([TLV8Item(TLV8Tag.state, [state]), TLV8Item(TLV8Tag.error, [Self.errAuthentication])])
    }
}
