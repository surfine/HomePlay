// 仪表盘副屏（流 111）探针：只收、不显示。解密照主屏（ScreenStream），
// 码流转成 Annex-B 原样存档（ffmpeg 可直接解），日志只记编码、首帧、关键帧与总量，
// 用来回答「手机到底送不送第二地图、送的是什么」。
import Foundation

package final class ClusterProbe {
    /// LIVI livi-cp stack.rs CLUSTER_MAP_URL
    package static let defaultURL = "maps:/car/instrumentcluster/map"

    package var onLog: ((String) -> Void)?
    package var frameCount: Int { frames }
    private let stream: ScreenStream
    private let dumpPath: String?
    private var file: FileHandle?
    private var codec: ScreenCodec?
    private var frames = 0
    private var keyframes = 0
    private var bytes = 0
    private let startedAt = Date()
    private var firstFrameAt: Date?

    package init(key: Data, dumpPath: String?) {
        stream = ScreenStream(key: key)
        self.dumpPath = dumpPath
        stream.onConfig = { [weak self] c, rec in self?.config(c, rec) }
        stream.onFrame = { [weak self] nals, key in self?.frame(nals, key) }
        stream.onError = { [weak self] e in self?.onLog?("副屏流：\(e)") }
    }

    package func start() throws -> UInt16 { try stream.start() }

    package func stop() {
        stream.stop()
        try? file?.close(); file = nil
        onLog?("副屏探针收尾：\(summary)")
    }

    package var summary: String {
        let name = codec.map { $0 == .h265 ? "HEVC" : "H.264" } ?? "沒收到編碼配置"
        let first = firstFrameAt.map { String(format: "首幀在 SETUP 後 %.1f s", $0.timeIntervalSince(startedAt)) } ?? "沒收到任何幀"
        return "\(name)，\(frames) 幀（關鍵幀 \(keyframes)），\(bytes / 1024) KB，\(first)"
    }

    private func config(_ c: ScreenCodec, _ record: Data) {
        codec = c
        onLog?("副屏編碼配置：\(c == .h265 ? "HEVC hvcC" : "H.264 avcC")（\(record.count)B）")
        let nals = c == .h265 ? ScreenStreamParser.hvcCToAVCC(record) : ScreenStreamParser.avcCToNALs(record)
        if let nals { write(nals) }
    }

    private func frame(_ nals: Data, _ key: Bool) {
        frames += 1; bytes += nals.count
        if key { keyframes += 1 }
        if firstFrameAt == nil {
            firstFrameAt = Date()
            onLog?("副屏首幀（\(nals.count)B，關鍵幀＝\(key)）")
        } else if key || frames % 300 == 0 {
            onLog?("副屏：\(summary)")
        }
        write(nals)
    }

    /// 长度前缀 NAL → Annex-B（00 00 00 01）追加到存档
    private func write(_ avcc: Data) {
        guard let base = dumpPath else { return }
        if file == nil {
            let path = base + (codec == .h264 ? ".h264" : ".h265")
            FileManager.default.createFile(atPath: path, contents: nil)
            file = FileHandle(forWritingAtPath: path)
            onLog?("副屏碼流存到 \(path)")
        }
        var out = Data(capacity: avcc.count + 16)
        var i = avcc.startIndex
        while avcc.endIndex - i >= 4 {
            let n = Int(avcc[i]) << 24 | Int(avcc[i + 1]) << 16 | Int(avcc[i + 2]) << 8 | Int(avcc[i + 3])
            i += 4
            guard n > 0, avcc.endIndex - i >= n else { break }
            out.append(contentsOf: [0, 0, 0, 1]); out.append(avcc[i..<i + n])
            i += n
        }
        file?.write(out)
    }
}
