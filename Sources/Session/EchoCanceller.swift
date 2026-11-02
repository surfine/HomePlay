// SpeexDSP 的參考訊號回聲消除（社區標準做法）。Apple 的 VPIO 需要輸入/輸出同一個
// 2 聲道裝置；Studio Display 的 8 聲道輸出會讓它初始化失敗（-10875）。SpeexDSP 是
// 純 C、BSD、無額外依賴的 AEC，我們只把「播放參考」與「麥克風」兩路餵給它。
import CSpeex
import Foundation

package final class EchoCanceller {
    private let state: OpaquePointer
    package let sampleRate: Int
    package let frameSize: Int

    /// 16 kHz、20 ms 一幀、300 ms 回聲尾長（桌面喇叭到麥克風的延遲通常遠小於這個）。
    package init?(sampleRate: Int = 16000, frameMs: Int = 20, filterMs: Int = 300) {
        let frame = max(1, sampleRate * frameMs / 1000)
        let filter = max(frame, sampleRate * filterMs / 1000)
        guard let st = speex_echo_state_init(Int32(frame), Int32(filter)) else { return nil }
        guard homeplay_speex_set_rate(st, Int32(sampleRate)) == 0 else {
            speex_echo_state_destroy(st)
            return nil
        }
        state = st
        self.sampleRate = sampleRate
        self.frameSize = frame
    }

    deinit { speex_echo_state_destroy(state) }

    /// 喇叭即將播放的音訊（遠端參考），必須剛好 frameSize 個樣本。
    package func playback(_ frame: [Int16]) {
        guard frame.count == frameSize else { return }
        frame.withUnsafeBufferPointer { speex_echo_playback(state, $0.baseAddress!) }
    }

    /// 麥克風收到的近端訊號 → 去掉回聲後的近端訊號，樣本數與輸入相同。
    package func capture(_ frame: [Int16]) -> [Int16] {
        guard frame.count == frameSize else { return frame }
        var out = [Int16](repeating: 0, count: frameSize)
        frame.withUnsafeBufferPointer { inBuf in
            out.withUnsafeMutableBufferPointer { outBuf in
                speex_echo_capture(state, inBuf.baseAddress!, outBuf.baseAddress!)
            }
        }
        return out
    }

    package func reset() { speex_echo_state_reset(state) }
}
