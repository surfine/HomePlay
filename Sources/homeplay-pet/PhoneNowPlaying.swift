// 手機（iAP2 0x5001）的正在播放 → Mac 系統 Now Playing / Control Center。
// 只發布元數據與播放狀態；播放/暫停/上一首/下一首走 CarPlay HID（經 receiver）。
// 進度跳轉走 iAP2 0x5003（absolute ms，帶 trackId 校驗）；封面走 iAP2 file transfer，按 ftid 匹配。
import Foundation
import MediaPlayer
import AppKit

final class PhoneNowPlayingBridge {
    static let shared = PhoneNowPlayingBridge()

    private(set) var active = false
    private(set) var canSeek = false
    private var current: NowPlayingInfo?
    private var currentTrack: String?
    private var currentAlbum: String?
    private var currentArtworkId: UInt8?
    private var artwork: MPMediaItemArtwork?
    private var artworkCache: [UInt8: MPMediaItemArtwork] = [:]
    private var configured = false

    /// 更新桌寵臉上的「正在播放」膠囊（傳 nil 表示清掉）
    var onUpdate: ((NowPlayingInfo?) -> Void)?
    /// 把系統媒體鍵送回 receiver（receiver 再發 CarPlay HID）
    var onCommand: ((MediaCommand) -> Void)?
    /// 進度跳轉（毫秒 + 當前曲目 id；receiver 會再比對一次）
    var onSeek: ((UInt32, String?) -> Void)?

    private init() {}

    /// 必須在主執行緒呼叫一次（AppDelegate 啟動時）
    func configure() {
        guard !configured else { return }
        configured = true
        let center = MPRemoteCommandCenter.shared()
        center.changePlaybackPositionCommand.isEnabled = false
        for (command, mapped) in [
            (center.playCommand, MediaCommand.play),
            (center.pauseCommand, MediaCommand.pause),
            (center.togglePlayPauseCommand, MediaCommand.playPause),
            (center.nextTrackCommand, MediaCommand.next),
            (center.previousTrackCommand, MediaCommand.previous),
        ] {
            command.addTarget { [weak self] _ in
                guard let self, self.active else { return .commandFailed }
                self.onCommand?(mapped)
                return .success
            }
        }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let self, self.active, self.canSeek, let current = self.current,
                  let e = event as? MPChangePlaybackPositionCommandEvent,
                  e.positionTime.isFinite else { return .commandFailed }
            let seconds = max(0, min(e.positionTime, current.duration))
            self.onSeek?(UInt32(seconds * 1000), self.currentTrack)
            return .success
        }
        setCommands(enabled: false)
    }

    private func setCommands(enabled: Bool) {
        guard configured else { return }
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.isEnabled = enabled
        center.pauseCommand.isEnabled = enabled
        center.togglePlayPauseCommand.isEnabled = enabled
        center.nextTrackCommand.isEnabled = enabled
        center.previousTrackCommand.isEnabled = enabled
        center.changePlaybackPositionCommand.isEnabled = enabled && canSeek && (current?.duration ?? 0) > 0
    }

    /// receiver 的 {"type":"nowplaying",...}（已 merge 過的完整/增量狀態）
    func apply(_ json: [String: Any], now: Double = CACurrentMediaTime()) {
        let title = (json["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let currentTitle = current?.title ?? ""
        guard !title.isEmpty || !currentTitle.isEmpty else { return }
        var info = current ?? NowPlayingInfo(title: "", artist: "", duration: 0, position: 0, playing: false, stamp: now)
        if !title.isEmpty { info.title = title }
        info.artist = (json["artist"] as? String) ?? info.artist
        info.duration = Double((json["durationMs"] as? NSNumber)?.doubleValue ?? info.duration * 1000) / 1000
        info.position = Double((json["elapsedMs"] as? NSNumber)?.doubleValue ?? info.position * 1000) / 1000
        info.playing = (json["playing"] as? Bool) ?? info.playing
        info.stamp = now
        info.fixed = false
        let track = json["trackId"] as? String
        let album = json["album"] as? String
        let artId = (json["artworkId"] as? NSNumber)?.uint8Value
        if track != currentTrack || artId != currentArtworkId { artwork = nil }
        currentTrack = track
        currentAlbum = album
        currentArtworkId = artId
        if let artId, let cached = artworkCache[artId] { artwork = cached }
        canSeek = (json["canSeek"] as? Bool) ?? false

        active = true
        current = info
        onUpdate?(info)
        publish(info, track: track, album: album)
        setCommands(enabled: true)
    }

    private func publish(_ info: NowPlayingInfo, track: String?, album: String?) {
        var d: [String: Any] = [
            MPMediaItemPropertyTitle: info.title,
            MPMediaItemPropertyArtist: info.artist,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: info.position,
            MPNowPlayingInfoPropertyPlaybackRate: info.playing ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
            MPNowPlayingInfoPropertyIsLiveStream: info.duration <= 0,
        ]
        if let album, !album.isEmpty { d[MPMediaItemPropertyAlbumTitle] = album }
        if info.duration > 0 { d[MPMediaItemPropertyPlaybackDuration] = info.duration }
        if let track, !track.isEmpty { d[MPNowPlayingInfoPropertyExternalContentIdentifier] = track }
        if let artwork { d[MPMediaItemPropertyArtwork] = artwork }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = d
        MPNowPlayingInfoCenter.default().playbackState = info.playing ? .playing : .paused
    }

    func clear() {
        guard active || MPNowPlayingInfoCenter.default().nowPlayingInfo != nil else { return }
        active = false
        canSeek = false
        current = nil
        currentTrack = nil
        onUpdate?(nil)
        setCommands(enabled: false)
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        MPNowPlayingInfoCenter.default().playbackState = .stopped
    }

    /// 文件傳輸完成的封面；ftid 必須等於目前曲目的 artworkId，舊圖遲到也不會覆蓋新曲。
    func applyArtwork(id: UInt8, data: Data) {
        guard let image = NSImage(data: data) else { return }
        let item = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
        if artworkCache.count >= 8 { artworkCache.removeValue(forKey: artworkCache.keys.first!) }
        artworkCache[id] = item
        guard active, id == currentArtworkId else { return }
        artwork = item
        if let current { publish(current, track: currentTrack, album: currentAlbum) }
    }

    /// 面板/系統媒體鍵：只有手機來源在線時接手；回 false 代表交給本機 Music/Spotify。
    func send(_ command: MediaCommand) -> Bool {
        guard active, let onCommand else { return false }
        onCommand(command)
        return true
    }

    /// 離線自檢：真的寫進 MPNowPlayingInfoCenter 再清掉，確認系統 bridge 沒有靜默失效。
    func selftest() -> Bool {
        configure()
        apply(["type": "nowplaying", "title": "Song", "artist": "Artist", "album": "Album",
               "durationMs": 180000, "elapsedMs": 42000, "playing": true,
               "canSeek": true, "trackId": "42", "artworkId": 7])
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Wl2ZQAAAABJRU5ErkJggg==")!
        applyArtwork(id: 7, data: png)
        let info = MPNowPlayingInfoCenter.default().nowPlayingInfo
        let ok = (info?[MPMediaItemPropertyTitle] as? String) == "Song"
            && (info?[MPMediaItemPropertyArtist] as? String) == "Artist"
            && (info?[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double) == 42
            && MPRemoteCommandCenter.shared().changePlaybackPositionCommand.isEnabled
            && MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyArtwork] != nil
        clear()
        return ok
    }
}
