// 裝置身分：裝置自己產兩把 P-256 金鑰——ECDH 談每次連線的工作階段金鑰、ECDSA 證明身分。
// Mac 只存公鑰（raw 65 bytes）：名冊被讀走也冒充不了裝置，移除裝置＝刪掉公鑰。
//
// 為什麼是 P-256 而不是 Ed25519／X25519：裝置端是 Safari 的 WebCrypto，P-256 從 Safari 11 就有，
// 舊 iPad（iOS 15）也跑得動；Ed25519 在 Safari 要 17 之後，會把副屏的退路砍掉。
//
// 串流握手（版本 2；舊的金鑰式握手已移除，已配對的裝置要重新配對）：
//   裝置 → Mac  'H' 2 kind id(8) nonceC(6)                                     17 bytes
//   Mac → 裝置  'S' 2 ephS(65) nonceS(6)                                       73 bytes
//   裝置 → Mac  sig(64) = ECDSA-SHA256(signKey, transcript)                     64 bytes
//   transcript = "HomePlay stream v2" ‖ 0 ‖ kind ‖ 0 ‖ id ‖ 0 ‖ nonceC ‖ ephS ‖ nonceS
//   工作階段金鑰 = ChaCha20(ECDH(agreeKey, ephS), nonce = nonceC‖nonceS) 的第 1 塊前 32 bytes
//   （跟舊版同一條 KDF，裝置端的 JS 不用新寫雜湊；ECDH 的秘密本來就是 32 bytes 均勻亂數）
//
// 副屏的 HTTP 沒有長連線：簽一張短票（id、秒級時間戳）換一個記憶體裡的票據，內容照舊只在區網。
// 簽章不加密，但它證明的東西（誰在看）不需要保密。

import Foundation
import CryptoKit

enum RemoteIdentity {
    static let streamVersion: UInt8 = 2
    static let streamTranscript = Data("HomePlay stream v2".utf8)
    static let sideTranscript = Data("HomePlay side v2".utf8)
    static let sideTicketLifetime: Double = 300
    /// 副屏簽章的時間窗（秒）：時鐘差太多就拒收，重放的舊票也只有這段時間有用
    static let sideClockWindow: Double = 120

    /// P-256 公鑰（raw，65 bytes，04 ‖ X ‖ Y）
    static func agreeKey(_ raw: Data) -> P256.KeyAgreement.PublicKey? {
        raw.count == 65 ? try? P256.KeyAgreement.PublicKey(x963Representation: raw) : nil
    }
    static func signKey(_ raw: Data) -> P256.Signing.PublicKey? {
        raw.count == 65 ? try? P256.Signing.PublicKey(x963Representation: raw) : nil
    }

    /// 新的伺服器臨時金鑰（每條連線一把，簽章要把它包進 transcript，舊的握手不能重放）
    static func newEphemeral() -> P256.KeyAgreement.PrivateKey { P256.KeyAgreement.PrivateKey() }
    static func raw(_ k: P256.KeyAgreement.PublicKey) -> Data { k.x963Representation }
    static func raw(_ k: P256.Signing.PublicKey) -> Data { k.x963Representation }

    /// 用 0 分隔的串接：避免 "ab"＋"c" 與 "a"＋"bc" 撞在一起（id 是變長字串）
    static func join(_ parts: [Data]) -> Data {
        var d = Data()
        for p in parts { d.append(contentsOf: p); d.append(0) }
        return d
    }

    static func streamTranscript(kind: UInt8, id: String, nonceC: [UInt8], ephS: Data, nonceS: [UInt8]) -> Data {
        join([streamTranscript, Data([kind]), Data(id.utf8), Data(nonceC), ephS, Data(nonceS)])
    }

    /// 秒級時間戳（十進位字串）：裝置端不用處理位元組序
    static func sideTranscript(id: String, at: Double) -> Data {
        join([sideTranscript, Data(id.utf8), Data(String(Int(at.rounded())).utf8)])
    }

    /// 驗裝置的簽章：公鑰不對、格式不對、簽章不對都回 false
    static func verify(_ sig: Data, transcript: Data, signKey raw: Data) -> Bool {
        guard sig.count == 64, let k = signKey(raw), let s = try? P256.Signing.ECDSASignature(rawRepresentation: sig) else { return false }
        return k.isValidSignature(s, for: transcript)
    }

    /// ECDH → 工作階段金鑰（兩邊同一條：CryptoKit／JS 都先拿 32 bytes 的秘密，再走舊的 ChaCha20 KDF）
    static func streamKey(privateKey: P256.KeyAgreement.PrivateKey, peer: Data, nonceC: [UInt8], nonceS: [UInt8]) -> SymmetricKey? {
        guard nonceC.count == 6, nonceS.count == 6, let pub = agreeKey(peer),
              let shared = try? privateKey.sharedSecretFromKeyAgreement(with: pub) else { return nil }
        let bytes = shared.withUnsafeBytes { Data($0) }
        guard bytes.count == 32 else { return nil }
        return RemoteCrypto.sessionKey(SymmetricKey(data: bytes), nonceC: nonceC, nonceS: nonceS)
    }
}

/// 副屏的短期票據（記憶體，Mac 重啟就沒了）。票只看內容與長度，不從裝置來。
final class RemoteSideTickets {
    private let lock = NSLock()
    private var map: [String: (device: String, expires: Double)] = [:]
    var now: () -> Double = { Date().timeIntervalSince1970 }

    /// 發一張票給驗過簽章的裝置
    func issue(_ device: String) -> String {
        var b = [UInt8](repeating: 0, count: 16)
        for i in b.indices { b[i] = UInt8.random(in: 0...255) }
        let t = b.map { String(format: "%02x", $0) }.joined()
        lock.lock()
        map = map.filter { $0.value.expires > now() }
        map[t] = (device, now() + RemoteIdentity.sideTicketLifetime)
        lock.unlock()
        return t
    }

    /// 換回裝置 id；過期、沒這張都回 nil
    func device(_ ticket: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        guard let e = map[ticket], e.expires > now() else { return nil }
        return e.device
    }

    func revoke(_ device: String) {
        lock.lock(); map = map.filter { $0.value.device != device }; lock.unlock()
    }

    func revokeAll() { lock.lock(); map.removeAll(); lock.unlock() }
}
