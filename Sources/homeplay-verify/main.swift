// 验证用 client：扮演 WindowShade，连 loopback 接收器，按 wire 协议解出画面并存成 PNG。
// 证明 "真画面 → wire → 解码器" 整条通，不必启动整个 App。
// 用法：./verify --port 8788 --out /tmp/frame.png [--timeout 12]

import Foundation
import VideoToolbox
import CoreMedia
import AppKit

func arg(_ n: String, _ d: String) -> String {
    let a = CommandLine.arguments
    if let i = a.firstIndex(of: n), i + 1 < a.count { return a[i + 1] }; return d
}
let port = arg("--port", "8788")
let outPath = arg("--out", "/tmp/frame.png")
let timeout = Double(arg("--timeout", "12")) ?? 12

func u32(_ b: [UInt8], _ o: Int) -> Int { Int(b[o]) | Int(b[o+1]) << 8 | Int(b[o+2]) << 16 | Int(b[o+3]) << 24 }

final class Verifier: NSObject, URLSessionWebSocketDelegate {
    var task: URLSessionWebSocketTask!
    var format: CMVideoFormatDescription?
    var decomp: VTDecompressionSession?
    var framesSeen = 0
    var configSeen = false
    var saved = false

    func run() {
        let s = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        task = s.webSocketTask(with: URL(string: "ws://127.0.0.1:\(port)")!)
        task.resume()
        receive()
    }
    func urlSession(_ s: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol p: String?) {
        task.send(.string(#"{"type":"keyframe"}"#)) { _ in }
    }
    func receive() {
        task.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let e): FileHandle.standardError.write("接收失败：\(e)\n".data(using: .utf8)!)
            case .success(let msg):
                if case .data(let d) = msg { self.handle([UInt8](d)) }
                self.receive()
            }
        }
    }
    func handle(_ b: [UInt8]) {
        guard b.count >= 2 else { return }
        if b[0] == 1 { // VIDEO_CONFIG
            guard b.count >= 12, b[2] == 1 else { return }
            let w = u32(b, 3), h = u32(b, 7)
            let avcC = Data(b[11...])
            var fmt: CMVideoFormatDescription?
            let st = CMVideoFormatDescriptionCreate(allocator: nil, codecType: kCMVideoCodecType_H264,
                width: Int32(w), height: Int32(h),
                extensions: [kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms: ["avcC": avcC]] as CFDictionary,
                formatDescriptionOut: &fmt)
            if st == noErr, let fmt { format = fmt; configSeen = true
                FileHandle.standardError.write("VIDEO_CONFIG：\(w)x\(h)，avcC \(avcC.count)B\n".data(using: .utf8)!) }
        } else if b[0] == 2 { // VIDEO_FRAME
            framesSeen += 1
            guard let fmt = format else { return }
            let annexB = Array(b[11...])
            decodeAndSave(annexB: annexB, fmt: fmt)
        }
    }
    func decodeAndSave(annexB: [UInt8], fmt: CMVideoFormatDescription) {
        // AnnexB → AVCC
        var nals: [ArraySlice<UInt8>] = []; var i = 0
        func sc(_ a: [UInt8], _ x: Int) -> Int? {
            guard x + 2 < a.count, a[x] == 0, a[x+1] == 0 else { return nil }
            if a[x+2] == 1 { return 3 }
            if x + 3 < a.count, a[x+2] == 0, a[x+3] == 1 { return 4 }; return nil
        }
        while i < annexB.count {
            guard let s = sc(annexB, i) else { i += 1; continue }
            let start = i + s; var n = start
            while n < annexB.count, sc(annexB, n) == nil { n += 1 }
            if n > start { nals.append(annexB[start..<n]) }; i = n
        }
        guard !nals.isEmpty else { return }
        var bytes = [UInt8](); for nal in nals {
            let l = UInt32(nal.count)
            bytes.append(contentsOf: [UInt8(l >> 24 & 0xff), UInt8(l >> 16 & 0xff), UInt8(l >> 8 & 0xff), UInt8(l & 0xff)])
            bytes.append(contentsOf: nal)
        }
        if decomp == nil {
            var cb = VTDecompressionOutputCallbackRecord(
                decompressionOutputCallback: { refcon, _, status, _, imageBuffer, _, _ in
                    guard status == noErr, let imageBuffer, let refcon else { return }
                    Unmanaged<Verifier>.fromOpaque(refcon).takeUnretainedValue().gotImage(imageBuffer as! CVImageBuffer)
                },
                decompressionOutputRefCon: Unmanaged.passUnretained(self).toOpaque())
            var session: VTDecompressionSession?
            let attrs: [CFString: Any] = [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA]
            VTDecompressionSessionCreate(allocator: nil, formatDescription: fmt, decoderSpecification: nil,
                imageBufferAttributes: attrs as CFDictionary, outputCallback: &cb, decompressionSessionOut: &session)
            decomp = session
        }
        guard let decomp else { return }
        var block: CMBlockBuffer?
        CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: bytes.count,
            blockAllocator: nil, customBlockSource: nil, offsetToData: 0, dataLength: bytes.count, flags: 0, blockBufferOut: &block)
        guard let block else { return }
        _ = bytes.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: bytes.count) }
        var sample: CMSampleBuffer?
        var sizes = [bytes.count]
        CMSampleBufferCreateReady(allocator: nil, dataBuffer: block, formatDescription: fmt, sampleCount: 1,
            sampleTimingEntryCount: 0, sampleTimingArray: nil, sampleSizeEntryCount: 1, sampleSizeArray: &sizes, sampleBufferOut: &sample)
        guard let sample else { return }
        VTDecompressionSessionDecodeFrame(decomp, sampleBuffer: sample, flags: [], frameRefcon: nil, infoFlagsOut: nil)
    }
    func gotImage(_ image: CVImageBuffer) {
        guard !saved else { return }; saved = true
        let ci = CIImage(cvImageBuffer: image)
        let ctx = CIContext()
        let w = CVPixelBufferGetWidth(image), h = CVPixelBufferGetHeight(image)
        if let cg = ctx.createCGImage(ci, from: ci.extent) {
            let rep = NSBitmapImageRep(cgImage: cg)
            if let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: outPath))
                print("OK 解出一帧 \(w)x\(h)，存到 \(outPath)（config=\(configSeen) frames=\(framesSeen)）")
                exit(0)
            }
        }
        FileHandle.standardError.write("解出帧但存 PNG 失败\n".data(using: .utf8)!); exit(5)
    }
}

let v = Verifier()
v.run()
DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
    FileHandle.standardError.write("超时：config=\(v.configSeen) framesSeen=\(v.framesSeen) saved=\(v.saved)\n".data(using: .utf8)!)
    exit(1)
}
RunLoop.main.run()
