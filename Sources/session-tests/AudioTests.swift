// 无线 CarPlay 音频的离线测试（对照 MacPlay livi-gst-video/rust/audio 的线格式与其单元测试）：
// 一个 UDP 包的解密封装（RTP 头 + 密文 + tag + nonce，AAD=时间戳+SSRC）、AudioSpecificConfig 位、
// audioFormat 位选解码器。全部离线，不出声。
import Foundation
import CryptoKit
import Session

func audioPacket(sample: UInt32, nonceCounter: UInt64, plain: [UInt8], key: SymmetricKey) -> [UInt8] {
    var header: [UInt8] = [0x80, 0x60, 0x00, 0x00]
    header.append(contentsOf: sample.bigEndianBytes)
    header.append(contentsOf: [0xaa, 0xbb, 0xcc, 0xdd])   // SSRC
    var nonce = [UInt8](repeating: 0, count: 12)
    nonce.replaceSubrange(4..., with: nonceCounter.littleEndianBytes)
    let sealed = try! ChaChaPoly.seal(Data(plain), using: key,
                                      nonce: ChaChaPoly.Nonce(data: Data(nonce)),
                                      authenticating: Data(header[4...]))
    var pkt = header
    pkt.append(contentsOf: sealed.ciphertext)
    pkt.append(contentsOf: sealed.tag)
    pkt.append(contentsOf: nonceCounter.littleEndianBytes)
    return pkt
}

extension UInt32 {
    var bigEndianBytes: [UInt8] { [UInt8(self >> 24), UInt8(self >> 16), UInt8(self >> 8), UInt8(self & 0xff)] }
}
extension UInt64 {
    var littleEndianBytes: [UInt8] {
        [UInt8(self & 0xff), UInt8((self >> 8) & 0xff), UInt8((self >> 16) & 0xff), UInt8((self >> 24) & 0xff),
         UInt8((self >> 32) & 0xff), UInt8((self >> 40) & 0xff), UInt8((self >> 48) & 0xff), UInt8((self >> 56) & 0xff)]
    }
}

func runAudioTests() -> Int {
    var failures = 0
    func expect(_ c: Bool, _ m: String) { if c { print("ok   \(m)") } else { failures += 1; print("FAIL \(m)") } }
    let key = SymmetricKey(data: Data(repeating: 9, count: 32))
    let dec = { AudioStreamDecryptor(key: Data(repeating: 9, count: 32)) }

    // 解密：一包解开，带着采样位置
    do {
        let d = dec()
        let r = d.push(audioPacket(sample: 4242, nonceCounter: 0, plain: [1, 2, 3, 4], key: key))
        expect(r?.sample == 4242 && r?.payload == [1, 2, 3, 4], "audio packet decrypts with its sample position")
        let r2 = d.push(audioPacket(sample: 5000, nonceCounter: 1, plain: [], key: key))
        expect(r2?.sample == 5000 && r2?.payload.isEmpty == true, "empty payload still reports")
    }
    // 篡改密文 → 认证失败，安静地丢
    do {
        var bad = audioPacket(sample: 7, nonceCounter: 0, plain: [0x55], key: key)
        bad[12] ^= 0xff
        expect(dec().push(bad) == nil, "tampered packet is dropped")
    }
    // 太短的包
    do {
        expect(dec().push([UInt8](repeating: 0, count: 12 + 24 - 1)) == nil, "datagram shorter than header+tail ignored")
    }
    // 两个方向不同的密钥互不解（Output key 收，Input key 是麦克风的）
    do {
        let other = SymmetricKey(data: Data(repeating: 7, count: 32))
        expect(dec().push(audioPacket(sample: 9, nonceCounter: 0, plain: [9], key: other)) == nil, "wrong key does not open")
    }

    // AudioSpecificConfig：AAC-LC(2) + 48k(3) + 立体声(2) = 0x1190
    expect(aacSpecificConfig(rate: 48000, channels: 2) == [0x11, 0x90], "ASC 48k stereo = 1190")
    expect(aacSpecificConfig(rate: 44100, channels: 2) == [0x12, 0x10], "ASC 44.1k stereo = 1210")
    expect(aacFrequencyIndex(11025) == 3, "unknown rate falls back to 48k index")

    // ADTS 头：557 字节帧 @48k 立体声 → 帧长 564 = 0x234 写进 13 位长度字段
    expect(adtsHeader(frameLength: 557, rate: 48000, channels: 2) == [0xff, 0xf1, 0x4c, 0x80, 0x46, 0x9f, 0xfc],
           "ADTS header 48k stereo len 564")

    // audioFormat 位选解码器（无线媒体 AAC-LC，48k / 44.1k；Opus 占位；PCM 直解）
    do {
        let a48 = audioCodec(fromFormat: 0x800000)
        expect(a48.canPlay && a48.codec.rate == 48000 && a48.codec.channels == 2, "AAC-LC 48k stereo chosen for 0x800000")
        let a44 = audioCodec(fromFormat: 0x400000)
        expect(a44.canPlay && a44.codec.rate == 44100, "AAC-LC 44.1k chosen for 0x400000")
        // Opus 用 CoreAudio 自帶的解碼器（Siri/導航/電話的低延遲流）
        let opus24 = audioCodec(fromFormat: 0x20000000)
        expect(opus24.canPlay && opus24.codec.isOpus && opus24.codec.rate == 24000 && opus24.codec.channels == 1,
               "Opus 24k mono playable via CoreAudio")
        let opus48 = audioCodec(fromFormat: 0x40000000)
        expect(opus48.canPlay && opus48.codec.isOpus && opus48.codec.rate == 48000, "Opus 48k playable")
        let pcm = audioCodec(fromFormat: 0x8000)
        expect(pcm.canPlay && pcm.codec.rate == 48000 && pcm.codec.channels == 2 && !pcm.codec.isAAC, "PCM 48k stereo passes through")

        // 麦克风上行包（对照 MacPlay mic/src/lib.rs）：0x80、PT、seq/timestamp 大端、SSRC=0、
        // 密文+tag、小端 nonce 尾 8 字节；AAD=header[4..12]。
        let micKey = SymmetricKey(data: Data((0..<32).map { UInt8($0) }))
        let body = Data([0xF8, 0x01, 0x02, 0x03])
        if let pkt = MicUplink.sealPacket(key: micKey, payloadType: 100, seq: 7, timestamp: 960,
                                          nonce: 3, body: body) {
            let b = [UInt8](pkt)
            let headerOK = b.count == 12 + body.count + 16 + 8
                && b[0] == 0x80 && b[1] == 100
                && b[2] == 0x00 && b[3] == 0x07
                && b[4] == 0x00 && b[5] == 0x00 && b[6] == 0x03 && b[7] == 0xc0
                && b[8] == 0 && b[9] == 0 && b[10] == 0 && b[11] == 0
            let tail = Data(b.suffix(8))
            var nonce = Data([0, 0, 0, 0]); nonce.append(tail)
            let ct = Data(b[12..<(b.count - 24)])
            let tag = Data(b[(b.count - 24)..<(b.count - 8)])
            let box = try? ChaChaPoly.SealedBox(nonce: ChaChaPoly.Nonce(data: nonce), ciphertext: ct, tag: tag)
            let opened = box.flatMap { try? ChaChaPoly.open($0, using: micKey, authenticating: Data(b[4..<12])) }
            expect(headerOK && tail == Data([3, 0, 0, 0, 0, 0, 0, 0]) && opened == body,
                   "mic uplink packet: RTP header + sealed body + LE nonce tail")
        } else {
            expect(false, "mic uplink packet seals")
        }

        // PCM 上行（手机 SETUP fmt=0x40 时）：16-bit 大端、超范围削波；双声道时 L=R。
        let pcmBody = MicUplink.pcm16BE([0, 0.5, -0.5, 1.5, -1.5])
        expect([UInt8](pcmBody) == [0x00, 0x00, 0x40, 0x00, 0xC0, 0x00, 0x7F, 0xFF, 0x80, 0x01],
               "mic uplink PCM is 16-bit big-endian and clamped")
        let stereo = MicUplink.pcm16BE([0.5], channels: 2)
        expect([UInt8](stereo) == [0x40, 0x00, 0x40, 0x00], "mic uplink PCM repeats mono into both channels")
    }
    return failures
}
