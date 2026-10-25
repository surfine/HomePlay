// 2.0 閒置裝置·網頁串流（docs/plans/idle-devices.md 路線一）：配對碼、加密、區網判斷——都是純函數，--selftest 直接驗。
//
// 為什麼不用 TLS：舊 iPad 的 Safari 遇到自簽憑證要使用者手動信任，「加入主畫面」後更常連不上；
// 而純 http 的頁面拿不到 WebCrypto，所以裝置端用一份自己寫的 ChaCha20-Poly1305（ES5，RemotePage.swift），
// Mac 端用 CryptoKit 的 ChaChaPoly，兩邊逐位元組對過（RemoteSelftest）。
//
// 握手（每條 WebSocket 一次）：
//   裝置 → Mac（明文 17 bytes）：'H' 1 kind(P 配對／D 裝置) id(8) nonceC(6)
//   Mac → 裝置（明文 8 bytes）：'H' 1 nonceS(6)
//   兩邊各自算 session key＝ChaCha20(長期金鑰, nonceC‖nonceS) 第 1 塊的前 32 bytes（CryptoKit：封 32 個 0 的密文）。
//   之後每則訊息都是 ChaCha20-Poly1305：nonce＝方向(1) 0 0 0 計數(8, LE)，不傳 nonce；第一則解不開就斷線。
// 長期金鑰：配對時＝配對碼（80 bits，後面補 0 到 32 bytes）；配對後＝Mac 發給那台裝置的 32 bytes 隨機金鑰。

import Foundation
import CryptoKit
import Network

enum RemoteCrypto {
    /// Crockford base32（去掉 I L O U，抄碼不會看錯）
    static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")

    /// 配對碼：10 bytes 隨機＝16 個字，顯示成 XXXX-XXXX-XXXX-XXXX
    static func newPairingSecret() -> [UInt8] {
        var b = [UInt8](repeating: 0, count: 10)
        for i in b.indices { b[i] = UInt8.random(in: 0...255) }
        return b
    }

    static func encode(_ bytes: [UInt8]) -> String {
        var out = "", acc = 0, bits = 0
        for b in bytes {
            acc = (acc << 8) | Int(b); bits += 8
            while bits >= 5 { bits -= 5; out.append(alphabet[(acc >> bits) & 31]) }
        }
        if bits > 0 { out.append(alphabet[(acc << (5 - bits)) & 31]) }
        return out
    }

    /// 讀使用者打的碼：大小寫、空白、連字號都容許；O→0、I/L→1（Crockford 的規則）
    static func decode(_ s: String) -> [UInt8]? {
        var acc = 0, bits = 0, out: [UInt8] = []
        for ch in s.uppercased() {
            if ch == "-" || ch == " " { continue }
            let c: Character = ch == "O" ? "0" : (ch == "I" || ch == "L") ? "1" : ch
            guard let v = alphabet.firstIndex(of: c) else { return nil }
            acc = (acc << 5) | v; bits += 5
            if bits >= 8 { bits -= 8; out.append(UInt8((acc >> bits) & 255)) }
            acc &= (1 << bits) - 1
        }
        return out
    }

    static func display(_ bytes: [UInt8]) -> String {
        let s = Array(encode(bytes))
        return stride(from: 0, to: s.count, by: 4).map { String(s[$0..<min(s.count, $0 + 4)]) }.joined(separator: "-")
    }

    static func pairingKey(_ secret: [UInt8]) -> SymmetricKey {
        SymmetricKey(data: Data(secret + [UInt8](repeating: 0, count: max(0, 32 - secret.count))))
    }

    static func sessionKey(_ key: SymmetricKey, nonceC: [UInt8], nonceS: [UInt8]) -> SymmetricKey? {
        guard nonceC.count == 6, nonceS.count == 6, let n = try? ChaChaPoly.Nonce(data: Data(nonceC + nonceS)),
              let box = try? ChaChaPoly.seal(Data(count: 32), using: key, nonce: n) else { return nil }
        return SymmetricKey(data: box.ciphertext)
    }

    /// 訊息 nonce：dir 0＝裝置→Mac、1＝Mac→裝置
    static func nonce(dir: UInt8, counter: UInt64) -> ChaChaPoly.Nonce {
        var b: [UInt8] = [dir, 0, 0, 0]
        for i in 0..<8 { b.append(UInt8((counter >> (8 * UInt64(i))) & 255)) }
        return try! ChaChaPoly.Nonce(data: Data(b))
    }

    static func seal(_ plain: Data, key: SymmetricKey, dir: UInt8, counter: UInt64) -> Data? {
        guard let box = try? ChaChaPoly.seal(plain, using: key, nonce: nonce(dir: dir, counter: counter)) else { return nil }
        return box.ciphertext + box.tag
    }

    static func open(_ data: Data, key: SymmetricKey, dir: UInt8, counter: UInt64) -> Data? {
        guard data.count >= 16,
              let box = try? ChaChaPoly.SealedBox(nonce: nonce(dir: dir, counter: counter), ciphertext: data.prefix(data.count - 16), tag: data.suffix(16)) else { return nil }
        return try? ChaChaPoly.open(box, using: key)
    }

    // MARK: 只在區網

    /// 允許的來源：RFC 1918、連結本地、迴路、IPv6 ULA／連結本地（含 IPv4 對映）。100.64/10（CGNAT、Tailscale）不算家裡。
    static func isPrivate(_ host: NWEndpoint.Host) -> Bool {
        switch host {
        case .ipv4(let a): return isPrivateV4(Array(a.rawValue))
        case .ipv6(let a):
            let b = Array(a.rawValue)
            guard b.count == 16 else { return false }
            if b[0..<10].allSatisfy({ $0 == 0 }) && b[10] == 0xff && b[11] == 0xff { return isPrivateV4(Array(b[12..<16])) }   // ::ffff:a.b.c.d
            if b[0..<15].allSatisfy({ $0 == 0 }) && b[15] == 1 { return true }     // ::1
            if b[0] == 0xfe && (b[1] & 0xc0) == 0x80 { return true }               // fe80::/10
            if b[0..<6] == [0xfd, 0x7a, 0x11, 0x5c, 0xa1, 0xe0] { return false }   // fd7a:115c:a1e0::/48＝Tailscale，不是家裡
            if (b[0] & 0xfe) == 0xfc { return true }                               // fc00::/7
            return false
        default: return false
        }
    }

    static func isPrivateV4(_ b: [UInt8]) -> Bool {
        guard b.count == 4 else { return false }
        switch (b[0], b[1]) {
        case (10, _), (127, _): return true
        case (172, 16...31): return true
        case (192, 168): return true
        case (169, 254): return true
        default: return false
        }
    }

    /// Host 標頭只收 IP、.local、localhost（擋 DNS rebinding：外面的網頁把自己的網域指到這台 Mac 也進不來）
    static func hostAllowed(_ host: String) -> Bool { canonicalHost(host) != nil }

    /// 驗過、重組過的 Host（只剩 [a-z0-9.-]、IPv6 由 IPv6Address 解析後重寫、port 是數字）：
    /// 要放進 CSP、Origin 比對的都用這個，不回填使用者送來的原字串
    static func canonicalHost(_ host: String) -> String? {
        let h = host.lowercased()
        guard !h.isEmpty, h.count <= 255 else { return nil }
        var name: String, port: String?
        if h.hasPrefix("[") {
            guard let close = h.firstIndex(of: "]") else { return nil }
            name = String(h[h.index(after: h.startIndex)..<close])
            let rest = h[h.index(after: close)...]
            if !rest.isEmpty { guard rest.hasPrefix(":") else { return nil }; port = String(rest.dropFirst()) }
            guard !name.contains("%"), let a = IPv6Address(name) else { return nil }   // 不收 zone id（fe80::1%en0）
            name = "[" + "\(a)" + "]"
        } else {
            if let i = h.lastIndex(of: ":") { port = String(h[h.index(after: i)...]); name = String(h[..<i]) } else { name = h }
            let ok = name == "localhost" || IPv4Address(name) != nil
                || (name.hasSuffix(".local") && name.count > 6 && name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == ".") })
            guard ok else { return nil }
            if let a = IPv4Address(name) { name = "\(a)" }
        }
        if let p = port {
            guard let n = UInt16(p), n > 0 else { return nil }
            return name + ":" + String(n)
        }
        return name
    }
}
