// 省電海報層：靜態快照 + 活區塊修補——自 main.swift 拆出。
import Accelerate
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

final class PosterImageView: NSView {
    override var isFlipped: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    func show(_ cg: CGImage, scale: CGFloat) {
        guard let l = layer else { return }
        l.contentsScale = scale
        l.contentsGravity = .resize
        // 縮放視窗時海報會被拉伸：用線性取樣，別出鋸齒和馬賽克
        l.magnificationFilter = .linear
        l.minificationFilter = .trilinear
        l.contents = cg
    }
    func clear() { layer?.contents = nil }
}

