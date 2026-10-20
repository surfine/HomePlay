// 配对用的密码学原语（CryptoKit 封装）。参照 MacPlay native/Engine/protocol/crypto.ts。
// Curve25519 ECDH、Ed25519、HKDF-SHA512、ChaCha20-Poly1305。
import CryptoKit
import Foundation

package enum PairingCryptoError: Error {
    case authenticationFailed
    case malformed(String)
}

package enum PairingCrypto {
    package static func hkdfSHA512(_ ikm: [UInt8], salt: [UInt8], info: [UInt8], length: Int = 32) -> [UInt8] {
        let key = HKDF<SHA512>.deriveKey(inputKeyMaterial: SymmetricKey(data: ikm),
                                         salt: salt, info: info, outputByteCount: length)
        return key.withUnsafeBytes { Array($0) }
    }

    package static func hkdfSHA512(_ ikm: [UInt8], salt: String, info: String, length: Int = 32) -> [UInt8] {
        hkdfSHA512(ikm, salt: Array(salt.utf8), info: Array(info.utf8), length: length)
    }

    /// 12 字节 nonce：4 个零字节 + 8 字节小端计数（AirPlay 风格）。
    package static func nonce64(_ counter: UInt64) -> [UInt8] {
        var n = [UInt8](repeating: 0, count: 12)
        for i in 0 ..< 8 { n[4 + i] = UInt8((counter >> UInt64(8 * i)) & 0xff) }
        return n
    }

    /// 12 字节 nonce：8 字节 ASCII 标签右对齐（HomeKit 配对风格，如 "PV-Msg02"）。
    package static func nonceLabel(_ label: String) -> [UInt8] {
        var n = [UInt8](repeating: 0, count: 12)
        for (i, b) in Array(label.utf8).prefix(8).enumerated() { n[4 + i] = b }
        return n
    }

    /// 返回 密文 || 16 字节标签。
    package static func chachaSeal(key: [UInt8], nonce: [UInt8], plaintext: [UInt8], aad: [UInt8] = []) throws -> [UInt8] {
        let box = try ChaChaPoly.seal(plaintext, using: SymmetricKey(data: key),
                                      nonce: ChaChaPoly.Nonce(data: nonce), authenticating: aad)
        return Array(box.ciphertext) + Array(box.tag)
    }

    /// 输入 密文 || 标签；认证失败抛 `.authenticationFailed`。
    package static func chachaOpen(key: [UInt8], nonce: [UInt8], data: [UInt8], aad: [UInt8] = []) throws -> [UInt8] {
        guard data.count >= 16 else { throw PairingCryptoError.authenticationFailed }
        do {
            let box = try ChaChaPoly.SealedBox(nonce: ChaChaPoly.Nonce(data: nonce),
                                               ciphertext: data.dropLast(16), tag: data.suffix(16))
            return Array(try ChaChaPoly.open(box, using: SymmetricKey(data: key), authenticating: aad))
        } catch {
            throw PairingCryptoError.authenticationFailed
        }
    }

    package static func ed25519Sign(privateKey: [UInt8], data: [UInt8]) throws -> [UInt8] {
        Array(try Curve25519.Signing.PrivateKey(rawRepresentation: privateKey).signature(for: data))
    }

    package static func ed25519Verify(publicKey: [UInt8], data: [UInt8], signature: [UInt8]) -> Bool {
        guard let key = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKey) else { return false }
        return key.isValidSignature(signature, for: data)
    }

    package static func x25519Shared(privateKey: Curve25519.KeyAgreement.PrivateKey, peerPublic: [UInt8]) throws -> [UInt8] {
        let peer = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: peerPublic)
        return try privateKey.sharedSecretFromKeyAgreement(with: peer).withUnsafeBytes { Array($0) }
    }
}

/// 数据流密钥：HKDF-SHA512(配对验证共享密钥, salt, info, 32)。
/// MacPlay：salt = "DataStream-Salt<streamConnectionID>"，输出方向 info = "DataStream-Output-Encryption-Key"，
/// 输入方向 "DataStream-Input-Encryption-Key"。
package func deriveStreamKey(sharedSecret: [UInt8], salt: String, info: String) -> [UInt8] {
    PairingCrypto.hkdfSHA512(sharedSecret, salt: salt, info: info, length: 32)
}

package enum StreamKeyInfo {
    package static let output = "DataStream-Output-Encryption-Key"
    package static let input = "DataStream-Input-Encryption-Key"
    package static func salt(streamConnectionID: UInt64) -> String { "DataStream-Salt\(streamConnectionID)" }
}

/// MFi 配件签名器：P4 用 IAP2 的 Iap2MfiIdentity 适配。证书原样交给 iPhone，签名对已给的摘要/挑战。
package protocol AccessorySigner {
    var certificate: [UInt8] { get }
    func sign(_ digestOrChallenge: [UInt8]) throws -> [UInt8]
}
