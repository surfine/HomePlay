// 2.0: ClioTalk 的 identify_song（聽歌辨曲）：ShazamKit 的 SHManagedSession 開這台 Mac 的麥克風聽約 8 秒，回歌名與歌手。
// 麥克風權限沿用桌寵的權限卡（app.withPermission(.microphone)）；音訊只交給 ShazamKit 比對，不錄、不存。
// ShazamKit 要 App ID 開了 ShazamKit 服務才連得上 Apple 的目錄：這份簽名沒有時，比對會回錯誤，這裡照實說「這個版本不能辨曲」，不當作沒聽到。

import AppKit
import AVFoundation
import Foundation
#if canImport(ShazamKit)
import ShazamKit
#endif

enum ClioSongTools {
    static let listenSeconds = 8.0

    /// 比對結果 → 給模型看的一句（純函式，selftest 用）
    static func describe(title: String?, artist: String?) -> String {
        guard let t = title?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else {
            return "No match: the song was not recognized. Suggest holding the music closer to the Mac and trying again."
        }
        let a = artist?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return a.isEmpty ? "Recognized: \"\(t)\"." : "Recognized: \"\(t)\" by \(a)."
    }

    static let unavailable = "Song recognition is not available in this build of HomePlay (ShazamKit is not enabled for it). Tell the user in one sentence."

    static func run() async -> ClioToolResult {
        func fail(_ s: String) -> ClioToolResult { ClioToolResult(content: s, isError: true, source: .music) }
        // 麥克風：沒問過就用桌寵的權限卡問；被拒就請使用者到系統設定
        let ok: Bool = await withCheckedContinuation { c in
            DispatchQueue.main.async {
                switch AVCaptureDevice.authorizationStatus(for: .audio) {
                case .authorized: c.resume(returning: true)
                case .denied, .restricted: c.resume(returning: false)
                default:
                    guard let app = NSApp.delegate as? AppDelegate else { c.resume(returning: false); return }
                    app.withPermission(.microphone) { c.resume(returning: $0) }
                }
            }
        }
        guard ok else { return fail("The microphone is not allowed for HomePlay. Tell the user to allow it in HomePlay Settings › Permissions (or System Settings › Privacy & Security).") }
        #if canImport(ShazamKit)
        if #available(macOS 14.0, *) {
            let session = SHManagedSession()
            let timer = Task {
                try? await Task.sleep(nanoseconds: UInt64(listenSeconds * 1e9))
                session.cancel()
            }
            let result = await session.result()
            timer.cancel()
            switch result {
            case .match(let m):
                let item = m.mediaItems.first
                return ClioToolResult(content: describe(title: item?.title, artist: item?.artist), source: .music)
            case .noMatch:
                return ClioToolResult(content: describe(title: nil, artist: nil), source: .music)
            case .error(let e, _):
                let ns = e as NSError
                log("ClioTalk shazam: \(ns.domain) \(ns.code)")
                // 被自己的計時取消＝沒聽到歌；其他（沒網路、服務沒開）照實說
                if ns.domain == SHError.errorDomain {
                    if ns.code == SHError.Code.signatureInvalid.rawValue || ns.code == SHError.Code.signatureDurationInvalid.rawValue { return ClioToolResult(content: describe(title: nil, artist: nil), source: .music) }   // 太安靜或太短＝沒聽到歌
                    if ns.code == SHError.Code.matchAttemptFailed.rawValue { return fail("Song recognition could not reach the Shazam service (no network, or it is not enabled for this build). Tell the user in one sentence.") }
                }
                if e is CancellationError || ns.code == NSUserCancelledError { return ClioToolResult(content: describe(title: nil, artist: nil), source: .music) }
                return fail(unavailable)
            @unknown default:
                return fail(unavailable)
            }
        }
        #endif
        return fail(unavailable)
    }
}
