// SRP-6a 服务端（HAP / AirPlay 2 配对变体）。参照 MacPlay native/Engine/protocol/srp.ts：
// RFC 5054 3072 位群、SHA-512、用户名 "Pair-Setup"、口令即配对码。群与哈希可替换，便于对 RFC 5054 附录 B 向量。
import CryptoKit
import Foundation

package enum SRPHash {
    case sha1
    case sha512

    package func digest(_ parts: [[UInt8]]) -> [UInt8] {
        switch self {
        case .sha1:
            var h = Insecure.SHA1()
            for p in parts { h.update(data: p) }
            return Array(h.finalize())
        case .sha512:
            var h = SHA512()
            for p in parts { h.update(data: p) }
            return Array(h.finalize())
        }
    }
}

package struct SRPGroup {
    package let N: BigUInt
    package let g: BigUInt
    /// N 的字节数；PAD() 补到这个长度。
    package let byteCount: Int

    package init(N: BigUInt, g: BigUInt) {
        self.N = N
        self.g = g
        self.byteCount = (N.bitWidth + 7) / 8
    }

    package static let rfc5054_3072 = SRPGroup(N: BigUInt(hex: """
        FFFFFFFFFFFFFFFFC90FDAA22168C234C4C6628B80DC1CD129024E088A67CC74
        020BBEA63B139B22514A08798E3404DDEF9519B3CD3A431B302B0A6DF25F1437
        4FE1356D6D51C245E485B576625E7EC6F44C42E9A637ED6B0BFF5CB6F406B7ED
        EE386BFB5A899FA5AE9F24117C4B1FE649286651ECE45B3DC2007CB8A163BF05
        98DA48361C55D39A69163FA8FD24CF5F83655D23DCA3AD961C62F356208552BB
        9ED529077096966D670C354E4ABC9804F1746C08CA18217C32905E462E36CE3B
        E39E772C180E86039B2783A2EC07A28FB5C55DF06F4C52C9DE2BCBF6955817183
        995497CEA956AE515D2261898FA051015728E5A8AAAC42DAD33170D04507A33A
        85521ABDF1CBA64ECFB850458DBEF0A8AEA71575D060C7DB3970F85A6E1E4C7AB
        F5AE8CDB0933D71E8C94E04A25619DCEE3D2261AD2EE6BF12FFA06D98A0864D8
        7602733EC86A64521F2B18177B200CBBE117577A615D6C770988C0BAD946E208
        E24FA074E5AB3143DB5BFCE0FD108E4B82D120A93AD2CAFFFFFFFFFFFFFFFF
        """), g: BigUInt(5))

    package static let rfc5054_1024 = SRPGroup(N: BigUInt(hex: """
        EEAF0AB9ADB38DD69C33F80AFA8FC5E86072618775FF3C0B9EA2314C9C256576
        D674DF7496EA81D3383B4813D692C6E0E0D5D8E250B98BE48E495C1D6089DAD1
        5DC7D7B46154D6B6CE8EF4AD69B15D4982559B297BCF1885C529F566660E57EC
        68EDBC3C05726CC02FD4CBF4976EAA9AFD5138FE8376435B9FC61D2FC0EB06E3
        """), g: BigUInt(2))
}

package final class SRPServer {
    package let group: SRPGroup
    package let hash: SRPHash
    package let salt: [UInt8]
    package let username: [UInt8]
    /// 乘数 k = H(N | PAD(g))
    package let k: BigUInt
    /// x = H(salt | H(I ":" p))
    package let x: BigUInt
    /// 验证子 v = g^x mod N
    package let v: BigUInt
    /// 服务端私钥 b、公钥 B = (k*v + g^b) mod N
    package let b: BigUInt
    package let B: BigUInt

    /// 服务端公钥，补零到群字节数。
    package var publicKey: [UInt8] { B.padded(to: group.byteCount) }

    /// `salt`、`privateB` 只给测试用来固定随机；生产传 nil。
    package init(group: SRPGroup = .rfc5054_3072, hash: SRPHash = .sha512,
                 username: String, password: String,
                 salt: [UInt8]? = nil, privateB: [UInt8]? = nil) {
        self.group = group
        self.hash = hash
        let salt = salt ?? (0 ..< 16).map { _ in UInt8.random(in: .min ... .max) }
        self.salt = salt
        let I = Array(username.utf8)
        self.username = I
        let N = group.N, g = group.g
        k = BigUInt(bytes: hash.digest([N.bytes, g.padded(to: group.byteCount)]))
        x = BigUInt(bytes: hash.digest([salt, hash.digest([I, [0x3a], Array(password.utf8)])]))
        v = g.modPow(x, modulus: N)
        let bBytes = privateB ?? (0 ..< 32).map { _ in UInt8.random(in: .min ... .max) }
        b = BigUInt(bytes: bBytes)
        B = (k * v + g.modPow(b, modulus: N)) % N
    }

    private func pad(_ n: BigUInt) -> [UInt8] { n.padded(to: group.byteCount) }

    /// u = H(PAD(A) | PAD(B))
    package func u(A: BigUInt) -> BigUInt {
        BigUInt(bytes: hash.digest([pad(A), pad(B)]))
    }

    /// 预主密钥 S = (A * v^u)^b mod N；A mod N == 0 时为 nil。
    package func premasterSecret(A: BigUInt) -> BigUInt? {
        let N = group.N
        if (A % N).isZero { return nil }
        let uu = u(A: A)
        return ((A * v.modPow(uu, modulus: N)) % N).modPow(b, modulus: N)
    }

    package struct Proof {
        package let K: [UInt8]
        package let serverM2: [UInt8]
    }

    /// 校验客户端公钥 A 与证明 M1。成功给 K = H(S) 与服务端证明 M2 = H(PAD(A) | M1 | K)。
    package func verify(A aBytes: [UInt8], clientM1: [UInt8]) -> Proof? {
        let A = BigUInt(bytes: aBytes)
        guard let S = premasterSecret(A: A) else { return nil }
        let K = hash.digest([S.bytes])
        let hN = hash.digest([group.N.bytes])
        let hg = hash.digest([group.g.bytes])
        let hXor = zip(hN, hg).map { $0 ^ $1 }
        let expected = hash.digest([hXor, hash.digest([username]), salt, pad(A), pad(B), K])
        guard expected == clientM1 else { return nil }
        return Proof(K: K, serverM2: hash.digest([pad(A), clientM1, K]))
    }
}
