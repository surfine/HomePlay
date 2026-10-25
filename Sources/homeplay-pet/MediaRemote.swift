// 2.0 第四輪 #11：MediaRemote（系統私有框架）——播客的後退 15 秒、快轉 30 秒、倍速，以及所有「正在播放」更準的控制與進度。
//
// 送指令：dlopen /System/Library/PrivateFrameworks/MediaRemote.framework，用 MRMediaRemoteSendCommand（指令編號照框架的
// MRMediaRemoteCommand：17 往後跳、18 往前跳、19 換倍速、24 跳到某秒；選項鍵 kMRMediaRemoteOption*）。這台 macOS 27 實測：
// 符號都在、指令送得到正在播放的 App（用一個假的 MPRemoteCommandCenter 播放器收到 skip 30／15、rate 1.5、seek 500）。
// 任何一個符號在執行期拿不到 → 對應的按鈕變灰（`canSkip`、`canRate`），不假裝能用。
//
// 讀資料：macOS 15.4 起 MRMediaRemoteGetNowPlayingInfo 對沒有 Apple 授權的行程一律回 nil（實測這台也是）。
// 系統的 /usr/bin/perl 是 Apple 簽的平台程式，用內建的 PerlObjCBridge 讀 MRNowPlayingRequest 就拿得到（實測可讀到標題、
// 長度、經過秒數、倍速、時間戳、來源 App）。所以讀取交給一支常駐的 perl 小迴圈（每秒一次、只在內容變了才輸出一行），
// 父行程不在了它自己結束。只在使用者開著「Mac 正在播放」時才跑；輸出只進記憶體，不寫日誌。

import AppKit

/// MRMediaRemoteCommand 的編號（框架的列舉值；17／18／19／24 已在這台實測）
enum MRCommand: UInt32 {
    case play = 0, pause = 1, togglePlayPause = 2, nextTrack = 4, previousTrack = 5
    case skipForward = 17, skipBackward = 18, changePlaybackRate = 19, seek = 24
}

final class MediaRemote {
    static let shared = MediaRemote()

    private typealias SendFn = @convention(c) (UInt32, CFDictionary?) -> Bool
    private let send: SendFn?
    private let skipKey: String?, rateKey: String?, positionKey: String?

    private init() {
        let h = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW)
        func key(_ s: String) -> String? {
            guard let h, let p = dlsym(h, s) else { return nil }
            return p.assumingMemoryBound(to: CFString.self).pointee as String
        }
        send = h.flatMap { dlsym($0, "MRMediaRemoteSendCommand") }.map { unsafeBitCast($0, to: SendFn.self) }
        skipKey = key("kMRMediaRemoteOptionSkipInterval")
        rateKey = key("kMRMediaRemoteOptionPlaybackRate")
        positionKey = key("kMRMediaRemoteOptionPlaybackPosition")
    }

    /// 快照與自檢：假裝某個符號不在（--mr-missing skip|rate|all）
    nonisolated(unsafe) static var simulateMissing: String? = {
        let a = CommandLine.arguments
        guard let i = a.firstIndex(of: "--mr-missing"), i + 1 < a.count else { return nil }
        return a[i + 1]
    }()

    var canSend: Bool { send != nil && Self.simulateMissing != "all" }
    var canSkip: Bool { canSend && skipKey != nil && Self.simulateMissing != "skip" }
    var canRate: Bool { canSend && rateKey != nil && Self.simulateMissing != "rate" }
    var canSeek: Bool { canSend && positionKey != nil }

    @discardableResult
    func command(_ c: MRCommand, options: [String: Any]? = nil) -> Bool {
        guard canSend, let send else { return false }
        return send(c.rawValue, options.map { $0 as CFDictionary })
    }
    /// 往後（正）或往前（負）跳幾秒：播客的 +30／−15
    @discardableResult
    func skip(_ seconds: Double) -> Bool {
        guard canSkip, let k = skipKey else { return false }
        return command(seconds >= 0 ? .skipForward : .skipBackward, options: [k: abs(seconds)])
    }
    @discardableResult
    func setRate(_ r: Double) -> Bool {
        guard canRate, let k = rateKey else { return false }
        return command(.changePlaybackRate, options: [k: r])
    }
    @discardableResult
    func seek(to seconds: Double) -> Bool {
        guard canSeek, let k = positionKey else { return false }
        return command(.seek, options: [k: max(0, seconds)])
    }

    /// 倍速循環（照播客 App：1× → 1.25× → 1.5× → 2× → 0.75× → 1×）
    static let rateCycle: [Double] = [1, 1.25, 1.5, 2, 0.75]
    static func nextRate(after r: Double) -> Double {
        let i = rateCycle.firstIndex { abs($0 - r) < 0.01 } ?? (rateCycle.count - 1)
        return rateCycle[(i + 1) % rateCycle.count]
    }
    /// 「1×」「1.25×」「0.75×」
    static func rateLabel(_ r: Double) -> String {
        var s = String(format: "%.2f", r)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s + "×"   // l10n-ignore
    }
}

/// MediaRemote 讀到的一筆「正在播放」
struct MRNowPlaying: Equatable {
    var title: String
    var artist: String
    var album: String
    var duration: Double
    var elapsed: Double          // 在 timestamp 那一刻的秒數
    var rate: Double             // 0＝暫停
    var defaultRate: Double      // 播放時用的倍速（暫停時 rate 是 0，看這個）
    var timestamp: Double        // 1970 起的秒（MR 的 kMRMediaRemoteNowPlayingInfoTimestamp）
    var playing: Bool
    var bundle: String
    var pid: Int32
    var contentID: String

    /// 現在的倍速（暫停時取預設倍速）
    var speed: Double { rate > 0 ? rate : (defaultRate > 0 ? defaultRate : 1) }

    /// 換成畫面用的 NowPlayingInfo：位置推到「現在」，stamp 用 CACurrentMediaTime
    func info(wallNow: Double = Date().timeIntervalSince1970, now: Double = CACurrentMediaTime()) -> NowPlayingInfo {
        var pos = elapsed
        if playing, timestamp > 0 { pos += max(0, wallNow - timestamp) * (rate > 0 ? rate : 1) }
        if duration > 0 { pos = min(pos, duration) }
        var i = NowPlayingInfo(title: title, artist: artist, duration: duration, position: pos, playing: playing, stamp: now)
        i.rate = playing ? speed : 1
        return i
    }

    /// 解析 perl 迴圈的一行：NP \t playing \t title \t artist \t album \t duration \t elapsed \t rate \t defaultRate \t timestamp \t bundle \t pid \t id
    /// 「NONE」或格式不對＝nil（純函式，自檢用）
    static func parse(_ line: String) -> MRNowPlaying? {
        let f = line.components(separatedBy: "\t")
        guard f.count >= 13, f[0] == "NP" else { return nil }
        func num(_ s: String) -> Double { Double(s.trimmingCharacters(in: .whitespaces)) ?? 0 }
        let title = f[2].trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty else { return nil }
        let rate = num(f[7])
        return MRNowPlaying(title: title, artist: f[3].trimmingCharacters(in: .whitespaces), album: f[4].trimmingCharacters(in: .whitespaces),
                            duration: num(f[5]), elapsed: num(f[6]), rate: rate, defaultRate: num(f[8]), timestamp: num(f[9]),
                            playing: f[1] == "1" || rate > 0, bundle: f[10], pid: Int32(num(f[11])), contentID: f[12])
    }
}

/// 常駐的 perl 迴圈（見檔頭）。主執行緒讀寫 latest／art
final class MediaRemoteReader {
    static let shared = MediaRemoteReader()
    private(set) var latest: MRNowPlaying?
    private(set) var art: CGImage?
    private(set) var artID = ""
    private(set) var running = false
    /// 內容變了（主執行緒）
    var onChange: (() -> Void)?
    private var process: Process?
    private var buffer = Data()
    private var restarts = 0

    static let script = #"""
    use strict; use warnings; use Foundation;
    $| = 1; binmode STDOUT, ':encoding(UTF-8)';
    NSBundle->bundleWithPath_("/System/Library/PrivateFrameworks/MediaRemote.framework")->load;
    @MRNowPlayingRequest::ISA = ("PerlObjCBridge");
    sub ok { my $o = shift; return defined($o) && ref($o) && $$o; }
    sub str { my ($d, $k) = @_; my $v = $d->objectForKey_($k); return "" unless ok($v); my $s = $v->description->UTF8String; $s =~ s/[\t\r\n]/ /g; return $s; }
    sub num { my ($d, $k) = @_; my $v = $d->objectForKey_($k); return "" unless ok($v); return $v->doubleValue; }
    my ($last, $lastArt) = ("", "");
    while (1) {
      exit 0 if getppid() == 1;
      my $line = "NONE";
      my $item = MRNowPlayingRequest->localNowPlayingItem;
      my $i = ok($item) ? $item->nowPlayingInfo : undef;
      if (ok($i)) {
        my ($bid, $pid) = ("", 0);
        my $p = MRNowPlayingRequest->localNowPlayingPlayerPath;
        if (ok($p)) { my $c = $p->client; if (ok($c)) { my $b = $c->bundleIdentifier; $bid = $b->UTF8String if ok($b); $pid = $c->processIdentifier; } }
        my $ts = $i->objectForKey_("kMRMediaRemoteNowPlayingInfoTimestamp");
        my $t = ok($ts) ? $ts->timeIntervalSince1970 : "";
        my $playing = MRNowPlayingRequest->localIsPlaying ? 1 : 0;
        my $id = str($i, "kMRMediaRemoteNowPlayingInfoContentItemIdentifier");
        $line = join("\t", "NP", $playing, str($i, "kMRMediaRemoteNowPlayingInfoTitle"), str($i, "kMRMediaRemoteNowPlayingInfoArtist"),
          str($i, "kMRMediaRemoteNowPlayingInfoAlbum"), num($i, "kMRMediaRemoteNowPlayingInfoDuration"), num($i, "kMRMediaRemoteNowPlayingInfoElapsedTime"),
          num($i, "kMRMediaRemoteNowPlayingInfoPlaybackRate"), num($i, "kMRMediaRemoteNowPlayingInfoDefaultPlaybackRate"), $t, $bid, $pid, $id);
        my $art = $i->objectForKey_("kMRMediaRemoteNowPlayingInfoArtworkData");
        if (ok($art) && $id ne $lastArt) { $lastArt = $id; print "ART\t", $id, "\t", $art->base64EncodedStringWithOptions_(0)->UTF8String, "\n"; }
      }
      if ($line ne $last) { print $line, "\n"; $last = $line; }
      sleep 1;
    }
    """#

    func start() {
        guard !running, FileManager.default.isExecutableFile(atPath: "/usr/bin/perl") else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        p.arguments = ["-e", Self.script]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        out.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            DispatchQueue.main.async { self?.receive(d) }
        }
        p.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, self.running else { return }
                self.running = false; self.process = nil
                // 意外結束：最多重開三次（例如 perl 被系統更新換掉），再不行就退回 AppleScript
                if self.restarts < 3 { self.restarts += 1; DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.start() } }
            }
        }
        do { try p.run(); process = p; running = true } catch { running = false }
    }

    func stop() {
        running = false
        process?.standardOutput.flatMap { $0 as? Pipe }?.fileHandleForReading.readabilityHandler = nil
        process?.terminate(); process = nil
        if latest != nil { latest = nil; art = nil; artID = ""; onChange?() }
    }

    private func receive(_ d: Data) {
        guard !d.isEmpty else { return }
        buffer.append(d)
        while let nl = buffer.firstIndex(of: 0x0a) {
            let lineData = buffer[buffer.startIndex..<nl]
            buffer.removeSubrange(buffer.startIndex...nl)
            guard let line = String(data: lineData, encoding: .utf8) else { continue }
            handle(line)
        }
        if buffer.count > 8_000_000 { buffer.removeAll() }   // 不該發生：防一行沒有換行把記憶體吃光
    }

    private func handle(_ line: String) {
        if line.hasPrefix("ART\t") {
            let f = line.split(separator: "\t", maxSplits: 2).map(String.init)
            guard f.count == 3, let data = Data(base64Encoded: f[2]), let img = MediaUI.cgImage(from: data, maxSide: 800) else { return }
            art = img; artID = f[1]; onChange?()
            return
        }
        var np = MRNowPlaying.parse(line)
        // 自己發布的（手機的正在播放經 PhoneNowPlayingBridge 進系統）不要再讀回來
        if let n = np, n.pid == ProcessInfo.processInfo.processIdentifier || n.bundle == Bundle.main.bundleIdentifier { np = nil }
        guard np != latest else { return }
        if np?.contentID != latest?.contentID, np?.contentID != artID { art = nil }
        latest = np
        onChange?()
    }
}
