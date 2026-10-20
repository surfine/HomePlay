// 配对验证后控制通道（TCP 7000 上的 RTSP）的 ChaCha20-Poly1305 分帧。参照 MacPlay controlCipher.ts。
// 帧：[2 字节小端长度（仅密文）][密文][16 字节标签]；2 字节长度头是 AAD；
// nonce = 4 个零字节 + 8 字节小端计数，每帧后递增；读写用不同密钥。
import Foundation

package final class ControlCipher {
    package static let maxPayload = 0x4000

    private let readKey: [UInt8]
    private let writeKey: [UInt8]
    private var readCounter: UInt64 = 0
    private var writeCounter: UInt64 = 0
    private var pending: [UInt8] = []

    package init(readKey: [UInt8], writeKey: [UInt8]) {
        self.readKey = readKey
        self.writeKey = writeKey
    }

    package convenience init(keys: ControlKeys) {
        self.init(readKey: keys.readKey, writeKey: keys.writeKey)
    }

    /// 喂入网络上来的字节，吐出已完整解密的明文（可能为空）；半帧留在内部缓冲。认证失败抛错。
    package func feed(_ bytes: [UInt8]) throws -> [UInt8] {
        pending.append(contentsOf: bytes)
        var out: [UInt8] = []
        var offset = 0
        while pending.count - offset >= 2 {
            let length = Int(pending[offset]) | (Int(pending[offset + 1]) << 8)
            let end = offset + 2 + length + 16
            if pending.count < end { break }
            let aad = Array(pending[offset ..< offset + 2])
            let body = Array(pending[offset + 2 ..< end])
            out.append(contentsOf: try PairingCrypto.chachaOpen(
                key: readKey, nonce: PairingCrypto.nonce64(readCounter), data: body, aad: aad))
            readCounter += 1
            offset = end
        }
        pending.removeFirst(offset)
        return out
    }

    /// 加密一条明文消息，超过 16 KiB 时拆帧。
    package func encrypt(_ plain: [UInt8]) throws -> [UInt8] {
        var out: [UInt8] = []
        var i = 0
        repeat {
            let chunk = Array(plain[i ..< min(plain.count, i + Self.maxPayload)])
            let header: [UInt8] = [UInt8(chunk.count & 0xff), UInt8(chunk.count >> 8)]
            out.append(contentsOf: header)
            out.append(contentsOf: try PairingCrypto.chachaSeal(
                key: writeKey, nonce: PairingCrypto.nonce64(writeCounter), plaintext: chunk, aad: header))
            writeCounter += 1
            i += Self.maxPayload
        } while i < plain.count
        return out
    }
}
