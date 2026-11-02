// CarPlay 的 Opus 編解碼。CoreAudio 的 AudioConverter 對「裸 Opus 包」解不出聲音
// （2026-11-02 真機：同一批包 libopus 解出 14 秒有效人聲，AudioConverter 全 0），
// 所以電話／Siri／短信朗讀的 Opus 下行改用 libopus。brew install opus。
import COpus
import Foundation

/// 裸 Opus 包 → 交錯 Float32。`sampleRate` 是輸出率（下行固定 48k）。
package final class OpusDecoder {
    private let decoder: OpaquePointer
    private let channels: Int
    private let frameCapacity: Int32

    package init?(sampleRate: Int, channels: Int = 1) {
        var error: Int32 = 0
        guard let d = opus_decoder_create(Int32(sampleRate), Int32(channels), &error), error == 0 else { return nil }
        decoder = d
        self.channels = max(1, channels)
        frameCapacity = Int32(max(1, sampleRate / 1000 * 120))   // 120ms 上限
    }

    deinit { opus_decoder_destroy(decoder) }

    package func decode(_ packet: Data) -> [Float] {
        guard !packet.isEmpty else { return [] }
        var pcm = [Float](repeating: 0, count: Int(frameCapacity) * channels)
        let n: Int32 = packet.withUnsafeBytes { raw in
            let p = raw.bindMemory(to: UInt8.self).baseAddress
            return opus_decode_float(decoder, p, Int32(packet.count), &pcm, frameCapacity, 0)
        }
        guard n > 0 else { return [] }
        return Array(pcm.prefix(Int(n) * channels))
    }
}

/// 交錯 Float32 → 裸 Opus 包。上行用協商到的 16/24/48k；每幀 `frameMs`。
package final class OpusEncoder {
    private let encoder: OpaquePointer
    private let frameSize: Int32
    private let maxPacket: Int32 = 4000

    package init?(sampleRate: Int, channels: Int = 1, bitrate: Int, frameMs: Int) {
        var error: Int32 = 0
        // 2048 = OPUS_APPLICATION_VOIP
        guard let e = opus_encoder_create(Int32(sampleRate), Int32(channels), 2048, &error), error == 0 else { return nil }
        encoder = e
        frameSize = Int32(max(2, sampleRate * frameMs / 1000))
        homeplay_opus_encoder_settings(e, Int32(bitrate))
    }

    deinit { opus_encoder_destroy(encoder) }

    package func encode(_ samples: [Float]) -> Data {
        guard samples.count >= Int(frameSize) else { return Data() }
        var out = [UInt8](repeating: 0, count: Int(maxPacket))
        let n: Int32 = samples.withUnsafeBufferPointer { sp in
            out.withUnsafeMutableBufferPointer { buf in
                opus_encode_float(encoder, sp.baseAddress!, frameSize, buf.baseAddress!, maxPacket)
            }
        }
        guard n > 0 else { return Data() }
        return Data(out.prefix(Int(n)))
    }
}
