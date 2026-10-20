// /auth-setup（MFiSAP 应答，配件侧），行为对应 MacPlay protocol/authSetup.ts。
// 请求：[1 字节版本 = 1][32 字节手机 X25519 公钥]。
// 应答：[我们的临时 X25519 公钥 32][证书长度 u32 大端][证书][签名长度 u32 大端][AES-128-CTR 加密的签名]。
// 签名对象：协议 3 = SHA-256(我们公钥 || 手机公钥)，协议 2 = SHA-1；AES 密钥/IV = SHA-1("AES-KEY"/"AES-IV" || 共享密钥) 前 16 字节。
import Foundation
import CryptoKit
import CommonCrypto

package enum AuthSetup {
    package static let version: UInt8 = 1

    package static func respond(body: [UInt8], signer: AccessorySigner, protocolMajor: Int = 3,
                                ephemeral: Curve25519.KeyAgreement.PrivateKey = .init()) throws -> [UInt8]? {
        guard body.count == 33, body[0] == version else { return nil }
        let peer = Array(body[1..<33])
        let ourPub = [UInt8](ephemeral.publicKey.rawRepresentation)
        let shared = try PairingCrypto.x25519Shared(privateKey: ephemeral, peerPublic: peer)
        guard shared.contains(where: { $0 != 0 }) else { return nil }
        let (key, iv) = keyAndIV(shared: shared)
        let digest: [UInt8] = protocolMajor == 2
            ? Array(Insecure.SHA1.hash(data: ourPub + peer))
            : Array(SHA256.hash(data: ourPub + peer))
        let sig = try signer.sign(digest)
        let enc = try aesCTR(key: key, iv: iv, sig)
        return ourPub + be32(signer.certificate.count) + signer.certificate + be32(enc.count) + enc
    }

    package static func keyAndIV(shared: [UInt8]) -> (key: [UInt8], iv: [UInt8]) {
        (Array(Insecure.SHA1.hash(data: Array("AES-KEY".utf8) + shared).prefix(16)),
         Array(Insecure.SHA1.hash(data: Array("AES-IV".utf8) + shared).prefix(16)))
    }

    /// AES-128-CTR（大端计数器），加解密同一个操作
    package static func aesCTR(key: [UInt8], iv: [UInt8], _ input: [UInt8]) throws -> [UInt8] {
        var ref: CCCryptorRef?
        var st = CCCryptorCreateWithMode(CCOperation(kCCEncrypt), CCMode(kCCModeCTR), CCAlgorithm(kCCAlgorithmAES),
                                         CCPadding(ccNoPadding), iv, key, key.count, nil, 0, 0,
                                         CCModeOptions(kCCModeOptionCTR_BE), &ref)
        guard st == kCCSuccess, let ref else { throw PairingCryptoError.malformed("AES-CTR") }
        defer { CCCryptorRelease(ref) }
        var out = [UInt8](repeating: 0, count: input.count)
        var moved = 0
        st = CCCryptorUpdate(ref, input, input.count, &out, out.count, &moved)
        guard st == kCCSuccess, moved == input.count else { throw PairingCryptoError.malformed("AES-CTR") }
        return out
    }

    private static func be32(_ n: Int) -> [UInt8] {
        [UInt8(n >> 24 & 0xff), UInt8(n >> 16 & 0xff), UInt8(n >> 8 & 0xff), UInt8(n & 0xff)]
    }
}
