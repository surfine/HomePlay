import AppKit
import ApplicationServices
import AVFoundation
import Metal
import RealityKit
import Combine
import simd
import VideoToolbox
import CoreMedia
import CoreImage
import ImageIO
import IOKit.ps
import IOKit.hid
import Carbon.HIToolbox
import Network
import EventKit
import ServiceManagement
import Security

func homography(from src: [CGPoint], to dst: [CGPoint]) -> [Double]? {
    guard src.count == 4, dst.count == 4 else { return nil }
    var a = [[Double]](repeating: [Double](repeating: 0, count: 9), count: 8)
    for i in 0..<4 {
        let x = Double(src[i].x), y = Double(src[i].y)
        let u = Double(dst[i].x), v = Double(dst[i].y)
        a[i * 2] = [x, y, 1, 0, 0, 0, -u * x, -u * y, u]
        a[i * 2 + 1] = [0, 0, 0, x, y, 1, -v * x, -v * y, v]
    }
    for col in 0..<8 {
        var pivot = col
        for r in col..<8 where abs(a[r][col]) > abs(a[pivot][col]) { pivot = r }
        guard abs(a[pivot][col]) > 1e-12 else { return nil }
        if pivot != col { a.swapAt(pivot, col) }
        let pv = a[col][col]
        for j in col...8 { a[col][j] /= pv }
        for r in 0..<8 where r != col {
            let f = a[r][col]
            if abs(f) > 1e-15 { for j in col...8 { a[r][j] -= f * a[col][j] } }
        }
    }
    return (0..<8).map { a[$0][8] } + [1]
}
func applyHomography(_ h: [Double], _ p: CGPoint) -> CGPoint {
    let x = Double(p.x), y = Double(p.y)
    let w = h[6] * x + h[7] * y + h[8]
    guard abs(w) > 1e-12 else { return CGPoint(x: -1, y: -1) }
    return CGPoint(x: (h[0] * x + h[1] * y + h[2]) / w,
                   y: (h[3] * x + h[4] * y + h[5]) / w)
}

func clamp01(_ x: CGFloat) -> CGFloat { max(0, min(1, x)) }
func ease(_ x: CGFloat) -> CGFloat { x < 0.5 ? 4 * x * x * x : 1 - pow(-2 * x + 2, 3) / 2 }

/// 方屏 uv（0..1，左上原点）→ 画面 0..1。画面等比放进方屏，留黑的地方回 nil。
func screenToVideo(u: Double, v: Double, videoW: Double, videoH: Double) -> (Double, Double)? {
    guard videoW > 0, videoH > 0 else { return nil }
    var x = u, y = v
    if videoW >= videoH {
        let h = videoH / videoW; y = (v - (1 - h) / 2) / h
    } else {
        let w = videoW / videoH; x = (u - (1 - w) / 2) / w
    }
    guard (0...1).contains(x), (0...1).contains(y) else { return nil }
    return (x, y)
}

struct AxisLock {
    enum Axis { case pending, horizontal, vertical }
    private(set) var axis: Axis = .pending

    mutating func pass(dx: CGFloat, dy: CGFloat, threshold: CGFloat = 3) -> (dx: CGFloat, dy: CGFloat) {
        if axis == .pending {
            guard abs(dx) > threshold || abs(dy) > threshold else { return (0, 0) }
            axis = abs(dx) >= abs(dy) ? .horizontal : .vertical
        }
        switch axis {
        case .horizontal: return (dx, 0)
        case .vertical: return (0, dy)
        case .pending: return (0, 0)
        }
    }
    mutating func reset() { axis = .pending }
}

/// 视频健康（照 MacPlay videoHealth 的规则）：收到≥3 帧却 2.5 s 没解出一帧 → 重建解码并要关键帧；
/// 重建后每 0.9 s 最多要一次关键帧，8 s 仍没出帧再重建；60 s 内最多重建 3 次、总共 6 次，超过就放弃（断开重连）。
