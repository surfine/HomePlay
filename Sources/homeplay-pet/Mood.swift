// 表情排程器——自 main.swift 拆出。
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

final class Mood {
    enum Sleep { case awake, drowsy, asleep }
    static let drowsyAfter = 180.0, asleepAfter = 480.0     // 夜里闲置 3 分钟困倦，再 5 分钟睡着

    var apart = false
    var disconnected = false        // CarPlay 连上过、后来断了
    var near = false                // 游标在机身 120 pt 内
    private(set) var petSince: Double?
    private var flash: (Expression, Double)?
    private var lastActivity: Double
    private var pokes: [Double] = []

    init(now: Double) { lastActivity = now }

    static func isNight(_ hour: Int) -> Bool { hour >= 22 || hour < 6 }

    /// 短暂反应：d 秒后回到按状态算出来的脸
    func show(_ e: Expression, for d: Double, now: Double) { flash = (e, now + d) }

    /// 有人碰它（游标靠近、点、拖）。困倦或睡着时被叫醒，先惊讶 0.4 s。
    func activity(now: Double, hour: Int) {
        if sleepStage(now: now, hour: hour) != .awake { show(.surprised, for: 0.4, now: now) }
        lastActivity = now
    }

    /// 游标停在底座上（摸头）。离开时如果已经笑了，再笑 0.6 s 才回去。
    func petting(_ on: Bool, now: Double) {
        if on { if petSince == nil { petSince = now }; return }
        guard let s = petSince else { return }
        petSince = nil
        if now - s >= 1.5 { show(.happy, for: 0.6, now: now) }
    }

    /// 点身体：1.5 s 内第 5 下＝不耐烦（专注脸 1.5 s），返回 true 让调用方顺便摇头。
    func poke(now: Double) -> Bool {
        pokes = pokes.filter { now - $0 < 1.5 } + [now]
        guard pokes.count >= 5 else { return false }
        pokes = []; show(.annoyed, for: 1.5, now: now)
        return true
    }

    func sleepStage(now: Double, hour: Int) -> Sleep {
        guard Self.isNight(hour) else { return .awake }
        let idle = now - lastActivity
        return idle >= Self.asleepAfter ? .asleep : (idle >= Self.drowsyAfter ? .drowsy : .awake)
    }

    func current(now: Double, hour: Int) -> Expression {
        if let f = flash { if now < f.1 { return f.0 }; flash = nil }
        if apart { return .surprised }
        if disconnected { return .worried }
        switch sleepStage(now: now, hour: hour) {
        case .asleep: return .asleep
        case .drowsy: return .sleepy
        case .awake: break
        }
        if let s = petSince { if now - s >= 4 { return .love }; if now - s >= 1.5 { return .happy } }
        return .idle
    }
}

// MARK: - 模型（照「HomeView 拆解」稿：单位、位置、偏移都从稿里搬）

/// 外观：G4 白（白色亮面塑料，屏幕走 Aqua）或真机四色铝。铝色是照产品图估的近似值，不是官方色码。
