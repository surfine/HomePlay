// 通話音量偏移（車機的 call volume）：和媒體音量分開，預設 +6 dB。
// 桌寵的「通话音量」選單會經 WS 送 {"type":"audio","command":"callGain","db":X}；
// 接收器更新這個值，所有活著的 MicUplink 立刻改 DynamicsProcessor 的 OverallGain。
import Foundation

package enum CallAudioSettings {
    private static let lock = NSLock()
    private static var _gainDb: Float = {
        let raw = ProcessInfo.processInfo.environment["HOMEPLAY_CALL_GAIN_DB"] ?? "6"
        return max(0, min(18, Float(raw) ?? 6))
    }()

    package static var gainDb: Float {
        lock.lock(); defer { lock.unlock() }
        return _gainDb
    }

    package static func setGain(_ db: Float) {
        lock.lock()
        _gainDb = max(0, min(18, db))
        lock.unlock()
        NotificationCenter.default.post(name: changed, object: nil)
    }

    package static let changed = Notification.Name("HomePlayCallGainChanged")
}
