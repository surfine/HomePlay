import AppKit
import Foundation
import QuartzCore
import Network
import CoreWLAN
import IOBluetooth
import IOKit
import IAP2
import Session
import H264
import Wire

/// 桌寵螢幕幾何的單一來源（與 main.swift 的屏幕平面同源）。
/// viewArea＝整塊面板（0 內縮）；safeArea＝圓角裡的最大內接矩形（origin 就是內縮量）；
/// 畫到 safeArea 外（safeAreaDrawOutside）只讓背景鋪到邊，互動內容仍留在 safeArea。
/// 四個環境變量可在真機上直接實驗宣告組合，免重編譯：
///   HOMEPLAY_VIEW_INSET=px   HOMEPLAY_SAFE_INSET=px（設 0 試全幅）
///   HOMEPLAY_PHYS_MM=mm      HOMEPLAY_DRAW_OUTSIDE=0 關掉背景外畫
enum PetDisplay {
    /// 機身螢幕的圓角：顯示面網格（apple-homeview.usdz 的 RFkcSjAtJLGqwDA）在 UV 裡對角線方向的內縮，佔寬度。
    /// 是 Apple 那種連續曲率的角，等效半徑 ≈ 寬度的 13.6%（1088 px 上約 148 px）。
    static let bodyDiag = 0.0398
    /// iOS 的螢幕圓角（遮罩對角內縮 ÷ 寬度）：沒量過時的估計（2026-10-23 iOS 27 截圖反推）
    static let defaultMaskDiag = 0.019

    static func radiusPx(_ widthPx: Int) -> Double { Double(widthPx) * bodyDiag / CornerMaskProtocol.diagPerRadius }
    /// 最大內接矩形每邊內縮（舊做法：只保證 UI 不被圓角切到）
    static func safeInset(_ widthPx: Int) -> Int { Int((Double(widthPx) * bodyDiag).rounded(.up)) }

    /// 每台手機（iOS 版本）量到的圓角（carplay-corner.json）
    static var storeURL: URL {
        HomePlayState.directory.appendingPathComponent("carplay-corner.json")
    }
    static var memory: CornerMemory {
        get {
            guard let d = try? Data(contentsOf: storeURL), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return CornerMemory() }
            return CornerMemory(json: o)
        }
        set {
            var o = newValue.json
            // 給設定頁看的：這台手機目前每邊內收多少
            if case .inset(let px) = newValue.plan(style: style, widthPx: 1088, bodyDiag: bodyDiag) { o["appliedInset"] = px }
            if let d = try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys, .prettyPrinted]) { try? d.write(to: storeURL, options: .atomic) }
        }
    }
    /// 圓角策略：carplay-display.json 的 cornerStyle；舊的 concentric:false＝最大畫面
    static var style: CornerStyle {
        if let raw = fileValue("cornerStyle") as? String, let s = CornerStyle(rawValue: raw) { return s }
        if (fileValue("concentric") as? Bool) == false { return .maximize }
        return .concentric
    }
    /// SETUP 看到手機版本：記成「最近的手機」；回傳日誌（換了手機才有）
    static func observe(build: String) -> String? {
        var m = memory
        guard m.lastBuild != build else { return nil }
        let old = m.lastBuild ?? "-"
        m.lastBuild = build; memory = m
        return "手機版本 \(old) → \(build)（圓角\(m.current.map { $0 > 0 ? String(format: "已量過 %.4f W", $0) : "：這版不送遮罩" } ?? "沒量過")）"
    }
    /// 收到遮罩：量、按目前手機版本存；回傳日誌
    static func learn(png: Data, widthPx: Int) -> String {
        guard let px = CornerMaskProtocol.diagonalInset(png: png), widthPx > 0 else { return "圓角遮罩量不出來" }
        var m = memory
        let build = m.lastBuild ?? "unknown"
        m.masks[build] = px / Double(widthPx); memory = m
        let next = CornerMaskProtocol.concentricInset(widthPx: widthPx, bodyDiag: bodyDiag, maskDiag: px / Double(widthPx))
        return String(format: "圓角遮罩（%@）：對角內縮 %.1f px（%.4f W）→ 同心安全區 %d px", build, px, px / Double(widthPx), next)
    }
    /// 這一版 iOS 不送遮罩（沒提議 cornerMasks、或學習連線裡等不到）：記成 0，照最大畫面處理，不再學
    static func markNoMask() -> String {
        var m = memory
        let build = m.lastBuild ?? "unknown"
        m.masks[build] = 0; memory = m
        return "手機（\(build)）不送圓角遮罩：照最大畫面內收，之後不再學"
    }

    static func fileValue(_ key: String) -> Any? {
        guard let d = try? Data(contentsOf: HomePlayState.directory.appendingPathComponent("carplay-display.json")),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return nil }
        return o[key]
    }
    private static func envInt(_ key: String) -> Int? {
        ProcessInfo.processInfo.environment[key].flatMap { Int($0) }
    }

    static func apply(_ main: inout DisplayConfig) {
        // 物理尺寸：環境變數，或 carplay-display.json 的 physMm（實驗：iOS 的圓角遮罩是不是照毫米算）
        let fileMm: Int? = {
            guard let d = try? Data(contentsOf: HomePlayState.directory.appendingPathComponent("carplay-display.json")),
                  let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return nil }
            return (o["physMm"] as? NSNumber)?.intValue
        }()
        if let mm = envInt("HOMEPLAY_PHYS_MM") ?? fileMm, mm > 0, main.widthPixels > 0 {
            main.widthPhysicalMm = mm
            main.heightPhysicalMm = mm * main.heightPixels / main.widthPixels
        }
        let v = envInt("HOMEPLAY_VIEW_INSET") ?? 0
        main.viewArea = DisplayInsets(top: v, bottom: v, left: v, right: v)
        main.safeAreaDrawOutside = ProcessInfo.processInfo.environment["HOMEPLAY_DRAW_OUTSIDE"] != "0"
        // 圓角策略（設定 › CarPlay › 圓角）。同心：安全區內縮到「iOS 的螢幕圓角放上去正好跟機身同心」，
        // iOS 自己把桌布畫滿到機身邊、圖示和 Dock 往內收。iOS 的圓角每一版不同，按手機版本記：
        // 沒量過的手機，這一次連線改宣告 cornerMasks（不能同時帶安全區，手機會立刻斷），手機送來遮罩、量好，
        // 接收器立刻重開會話回到平常模式（runDual 的 reopen），整段約 2–3 秒。
        var plan = memory.plan(style: style, widthPx: main.widthPixels, bodyDiag: bodyDiag)
        if case .learn = plan, ProcessInfo.processInfo.environment["HOMEPLAY_CORNER_MASKS"] == "0" { plan = .inset(safeInset(main.widthPixels)) }
        switch plan {
        case .learn:
            main.cornerMasks = true; main.safeArea = nil
        case .inset(let px):
            let s = envInt("HOMEPLAY_SAFE_INSET") ?? px
            main.cornerMasks = nil
            main.safeArea = DisplayInsets(top: s, bottom: s, left: s, right: s)
        }
    }
    /// 宣告裡跟圓角有關的部分（比對要不要重開會話用）
    static func key(_ d: DisplayConfig) -> String { "\(d.cornerMasks == true)|\(d.safeArea?.left ?? -1)" }

    /// 開場日誌用：把實際宣告寫清楚（含環境覆蓋後的值），方便和手機行為對照
    static func describe(_ widthPx: Int, _ heightPx: Int) -> String {
        let v = envInt("HOMEPLAY_VIEW_INSET") ?? 0
        var probe = DisplayConfig(widthPixels: widthPx, heightPixels: heightPx); apply(&probe)
        let i = probe.safeArea?.left ?? 0
        let outside = ProcessInfo.processInfo.environment["HOMEPLAY_DRAW_OUTSIDE"] != "0"
        let mm = probe.widthPhysicalMm ?? 125
        let cm = probe.cornerMasks == true
        return "display style=\(style.rawValue) cornerMasks=\(cm) phone=\(memory.lastBuild ?? "-") viewArea=(\(v),\(v) \(widthPx - 2*v)x\(heightPx - 2*v)) safeArea=(\(i),\(i) \(widthPx - 2*i)x\(heightPx - 2*i)) origin=(\(i),\(i)) drawOutside=\(outside) phys=\(mm)mm radius=\(Int(radiusPx(widthPx)))px"
    }
}
