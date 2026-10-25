import AppKit
import CoreGraphics
import CoreText

// 进入 CarPlay 的过场：状态是「連線中」且还没出画面时，盖在任何錶面上。
// 没有分阶段数据，所以只显示真的知道的一格：等待第一幀。

enum CarPlayOverlayState {
    static var alpha: CGFloat = 0
    static var forced = false          // 快照用（--connecting）
    static var lastDraw = -1e9
    static var shownSince = -1.0       // 這次蓋板亮了多久：超過 15 秒換一句可操作的提示
    static var needsPairing = false    // receiver 報告「沒有任何已配對的 iPhone」
    static var pairingHost: String?    // 這台 Mac 的藍牙名（receiver 送來；iPhone 上要點的名字）
    static var pairingStale = false    // iPhone 裡可能還留著這台 Mac 的舊配對：要先 ⓘ 忘記再重配
    static var pairingSucceededAt: Double?   // 剛配對成功：畫面出來前先給一句確認
    static var snapshotPaired = false        // 快照用：固定在配對成功那一格
    static var wifiHelp = false       // receiver 發出 Wi-Fi 配置後 30 秒手機仍沒連回：給一次排障提示
    static var wifiNeedsPassword = false   // 沒回連＋本地沒存密碼：提示填一次密碼（右鍵 Wi-Fi 設定）
    static var connectReason: String?     // receiver 判斷的卡住原因（ConnectDiagnostics.Reason）；舊 receiver 沒有
    static var helpSSID = ""              // 要讓 iPhone 連的網路名（空＝receiver 不知道）
    static var helpSince: Double?         // 排障卡這次亮起的時間：40 秒後改給插線退路與診斷報告
    static var needsTrust = false     // USB 插著但 iPhone 沒點「信任」：解鎖並點信任的卡片
    static var needsCable = false     // 首次配對：receiver 先等 20 秒插線（不會打開系統設定）
    static var bluetoothPairing = false   // 有線會話已發起 IOBluetoothDevicePair：iPhone 上點「配對」
    static var bluetoothPairFailed = false // 配對彈窗錯過/失敗：拔線再插一次即可重試
    static var pairPhase: String?          // request／confirm／retry（receiver 的插線配對進度）
    static var pairCode: String?           // 數字比對的 6 位數：和 iPhone 上顯示的核對
    static var pairDeadline: Double?       // 這一輪配對還剩到幾時（CACurrentMediaTime）
    static var pairingViaCable = false     // 手機插著線、receiver 暫緩開畫面等配對（60 秒後先用有線）
    static var pairFailReason: String?     // noResponse＝叫不到手機；notConfirmed＝手機上沒點「配對」
    /// 淡入淡出 0.3 秒
    static func nextAlpha(_ a: CGFloat, target: CGFloat, dt: Double) -> CGFloat {
        let step = CGFloat(dt / 0.3)
        return target > a ? min(target, a + step) : max(target, a - step)
    }
}

/// receiver 送來的已配對 iPhone 清單（右鍵「使用 iPhone」用）。存狀態本身，不譯字。
enum CarPlayPhoneBook {
    struct Phone: Equatable {
        var address: String
        var name: String
    }
    static var phones: [Phone] = []
    static var current: String?

    static func normalize(_ address: String) -> String {
        let hex = address.uppercased().filter(\.isHexDigit)
        guard hex.count == 12 else { return address.uppercased().replacingOccurrences(of: "-", with: ":") }
        var parts: [String] = []
        var i = hex.startIndex
        while i < hex.endIndex {
            let j = hex.index(i, offsetBy: 2)
            parts.append(String(hex[i..<j]))
            i = j
        }
        return parts.joined(separator: ":")
    }
    static func isCurrent(_ address: String) -> Bool {
        guard let current else { return false }
        return normalize(current) == normalize(address)
    }

    /// 当前手机的名字（没有名字就 nil）；给「连不上」提示用。
    static var currentName: String? {
        guard let current,
              let phone = phones.first(where: { normalize($0.address) == normalize(current) }) else { return nil }
        let name = phone.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    struct MenuEntry: Equatable {
        var title: String
        var address: String
        var current: Bool
    }
    /// 右键子菜单的纯数据：名字为空时退回地址，当前手机带勾选。
    static func menuEntries() -> [MenuEntry] {
        phones.map { phone in
            let name = phone.name.trimmingCharacters(in: .whitespacesAndNewlines)
            return MenuEntry(title: name.isEmpty ? phone.address : name,
                             address: phone.address,
                             current: isCurrent(phone.address))
        }
    }

    /// 解析 receiver 的 `{"type":"phones",...}`；格式不对返回 false，不动旧列表。
    @discardableResult
    static func apply(json s: String) -> Bool {
        guard let data = s.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = obj["items"] as? [[String: Any]] else { return false }
        phones = raw.compactMap { item in
            guard let address = item["address"] as? String, !address.isEmpty else { return nil }
            return Phone(address: address, name: item["name"] as? String ?? "")
        }
        let current = obj["current"] as? String
        self.current = current?.isEmpty == false ? current : nil
        return true
    }
}

/// receiver 回報的目前 Wi-Fi（自動偵測或使用者設定），給「Wi-Fi 設定」對話框預填 SSID。
enum CarPlayWiFi {
    static var ssid: String = ""
}

extension Face {
    var carPlayConnecting: Bool { CarPlayOverlayState.forced || status == .connecting }

    /// 只在盖板可见时约 15fps 重画；返回要不要重画
    func tickCarPlayOverlay(_ now: Double, _ dt: Double) -> Bool {
        let target: CGFloat = carPlayConnecting ? 1 : 0
        if target == 1, CarPlayOverlayState.shownSince < 0 { CarPlayOverlayState.shownSince = now }
        if target == 0 { CarPlayOverlayState.shownSince = -1 }
        let a = CarPlayOverlayState.alpha
        if CarPlayOverlayState.forced && a == 0 { CarPlayOverlayState.alpha = 1; return true }
        let na = CarPlayOverlayState.nextAlpha(a, target: target, dt: dt)
        CarPlayOverlayState.alpha = na
        if na == 0 { return a != 0 }
        if na != a || now - CarPlayOverlayState.lastDraw >= 1.0 / 15 { return true }
        return false
    }

    func drawCarPlayOverlay(_ g: CGContext, _ now: Double) {
        let a = CarPlayOverlayState.alpha
        guard a > 0.003 else { return }
        CarPlayOverlayState.lastDraw = now
        g.saveGState(); g.setAlpha(a)
        let retro = isSystem6Era   // AI System 6 年代：開機畫面「Welcome to HomePlay.」（Faces/System6Series.swift）
        if !retro {
        g.setFillColor(srgb(0x050607).cgColor); g.fill(CGRect(x: 0, y: 0, width: 1024, height: 1024))
        // 柔和的蓝色径向光
        let cs = CGColorSpaceCreateDeviceRGB()
        let colors = [srgb(0x408cff, 0.28).cgColor, srgb(0x408cff, 0).cgColor] as CFArray
        if let grad = CGGradient(colorsSpace: cs, colors: colors, locations: [0, 1]) {
            g.drawRadialGradient(grad, startCenter: CGPoint(x: 512, y: 470), startRadius: 0,
                                 endCenter: CGPoint(x: 512, y: 470), endRadius: 512, options: [])
        }
        // 进度环：底圈 + 转动的弧
        let c = CGPoint(x: 512, y: 426), r: CGFloat = 188   // 環和膠囊兩端留 40 的空氣
        let paired = CarPlayOverlayState.snapshotPaired || (CarPlayOverlayState.pairingSucceededAt.map { now - $0 < 3.0 } ?? false)
        g.setLineWidth(10); g.setLineCap(.round)
        g.setStrokeColor(NSColor.white.withAlphaComponent(0.12).cgColor)
        g.addArc(center: c, radius: r, startAngle: 0, endAngle: .pi * 2, clockwise: false); g.strokePath()
        if paired {   // 配對成功：環補滿成綠色、停住，和「連線中」一眼分得出來
            g.setStrokeColor(srgb(0x34c759).cgColor)
            g.addArc(center: c, radius: r, startAngle: 0, endAngle: .pi * 2, clockwise: false); g.strokePath()
        } else {
            let a0 = CGFloat(now * 3.6).truncatingRemainder(dividingBy: .pi * 2)
            g.setStrokeColor(srgb(0x4a9bff).cgColor)
            g.addArc(center: c, radius: r, startAngle: a0, endAngle: a0 + .pi * 1.1, clockwise: false); g.strokePath()
        }
        drawIsland(g, at: c, scale: 0.5, liveAt: c, now: now)
        }
        // 三段时间：15 秒给常规排查，40 秒给首次使用（还没配对过）的指引
        let elapsed = CarPlayOverlayState.shownSince > 0 ? now - CarPlayOverlayState.shownSince : 0
        let pairing = CarPlayOverlayState.needsPairing
        let succeeded = CarPlayOverlayState.snapshotPaired || (CarPlayOverlayState.pairingSucceededAt.map { now - $0 < 3.0 } ?? false)
        let wifiHelp = CarPlayOverlayState.wifiHelp
        // 卡住時照 receiver 判斷的原因給一張照做就能過的卡（ConnectHelp.card）
        let helpCard = ConnectHelp.card(reason: CarPlayOverlayState.connectReason, ssid: CarPlayOverlayState.helpSSID,
                                        needsPassword: CarPlayOverlayState.wifiNeedsPassword,
                                        helpElapsed: CarPlayOverlayState.helpSince.map { now - $0 } ?? 0)
        let recentlyPaired = CarPlayOverlayState.pairingSucceededAt.map { now - $0 < 120 } ?? false
        let needTrust = CarPlayOverlayState.needsTrust
        let cable = CarPlayOverlayState.needsCable
        let btPairing = CarPlayOverlayState.bluetoothPairing
        let btFailed = CarPlayOverlayState.bluetoothPairFailed
        let slow = elapsed > 15, verySlow = elapsed > 40 || pairing || cable || btPairing
        let host: String? = CarPlayOverlayState.pairingHost.flatMap { raw in
            let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return nil }
            return name.count > 22 ? String(name.prefix(21)) + "…" : name
        }
        let currentPhone: String? = CarPlayPhoneBook.currentName.map { name in
            name.count > 18 ? String(name.prefix(17)) + "…" : name
        }
        // 插線配對：照 receiver 報的階段說清楚手機上會看到什麼、該按什麼、還剩多久
        let phase = CarPlayOverlayState.pairPhase
        let code: String? = CarPlayOverlayState.pairCode.map { c in c.count == 6 ? c.prefix(3) + " " + c.suffix(3) : c }
        let secondsLeft: Int? = CarPlayOverlayState.pairDeadline.map { max(0, Int(($0 - now).rounded(.up))) }
        let failReason = CarPlayOverlayState.pairFailReason
        let title = succeeded ? L("status.overlay.pairSuccess", "iPhone 已配对")
                    : btFailed ? (failReason == "noResponse"
                                  ? L("status.overlay.pairNoResponseTitle", "找不到这台 iPhone")
                                  : L("status.overlay.pairFailedTitle", "配对还差一步"))
                    : btPairing && phase == "confirm" && code != nil
                        ? String(format: L("status.overlay.pairCodeTitle", "核对数字 %@"), code!)
                    : btPairing && phase == "retry" ? L("status.overlay.pairRetryTitle", "正在呼叫 iPhone…")
                    : btPairing ? L("status.overlay.pairConfirmTitle", "在 iPhone 上点「配对」")
                    : needTrust ? L("status.overlay.trustTitle", "在 iPhone 上点「信任」")
                    : cable ? L("status.overlay.cableTitle", "用数据线连一次 iPhone")
                    : pairing ? L("status.overlay.pairTitle", "在 iPhone 上配对这个 Mac")
                    : wifiHelp ? helpCard.title
                              : L("status.overlay.title", "正在连接 CarPlay")
        if !retro {
            // 三步進度：①配對 ②在 iPhone 上確認（分享 Wi-Fi、連接）③完成。目前那步亮、做完的打勾
            let step = succeeded ? 3 : (pairing || btPairing || btFailed || needTrust || cable) ? 1 : 2
            drawSetupSteps(g, current: step, y: 652)
            drawCentered(g, title, font: Self.rounded(54, weight: .bold), kern: 0, y: 722, color: .white)
        }
        let subtitle: String
        if succeeded { subtitle = L("status.overlay.pairSuccessBody", "以后自动无线连接，不用再插线；正在打开画面…") }
        else if btFailed {
            subtitle = failReason == "noResponse"
                ? L("status.overlay.pairNoResponseBody", "确认 iPhone 已解锁、蓝牙已打开，再拔线重插")
                : failReason == "notConfirmed"
                    ? L("status.overlay.pairNotConfirmedBody", "刚才没在 iPhone 上点「配对」；拔线再插会再问一次")
                    : L("status.overlay.pairFailedBody", "没看到配对弹窗；拔线再插一次就能重试")
        }
        else if btPairing {
            if phase == "confirm" {
                subtitle = L("status.overlay.pairCodeBody", "iPhone 上显示同样的数字，就点「配对」")
            } else if phase == "retry" {
                subtitle = L("status.overlay.pairRetryBody", "请保持 iPhone 解锁、蓝牙打开")
            } else if let host {
                subtitle = String(format: L("status.overlay.pairRequestBodyHost", "iPhone 会弹出「%@」的蓝牙配对请求，点「配对」"), host)
            } else {
                subtitle = L("status.overlay.pairRequestBody", "iPhone 会弹出「蓝牙配对请求」，点「配对」")
            }
        }
        else if needTrust {
            // 有线首次：iPhone 弹「信任此电脑」，解锁＋点信任＋输密码即连；点完自动继续，不用重启 App
            subtitle = L("status.overlay.trustBody", "解锁 iPhone → 点「信任」并输入密码，画面自动出现")
        }
        else if cable {
            subtitle = L("status.overlay.cableBody", "插上数据线，解锁 iPhone 并点「信任」")
        }
        else if pairing {
            // 蓝牙优先：Mac 的蓝牙设置面板打开时可被 iPhone 发现，由手机发起配对。
            let body = L("status.overlay.pairBody", "设置 › 蓝牙 › 其他设备 → 点「%@」")
            subtitle = host.map { String(format: body, $0) }
                ?? L("status.overlay.pairBodyNoHost", "设置 › 蓝牙 › 其他设备 → 点这台 Mac 的名字")
        }
        else if wifiHelp { subtitle = helpCard.subtitle }
        else if verySlow {
            // 40 秒：才給一個具體、溫和的下一步（不用「連不上？」這種會讓人慌的問句）
            subtitle = L("status.overlay.calmVerySlow", "让 iPhone 保持解锁、靠近这台 Mac，通常再等一下就好")
        }
        else if slow {
            let format = L("status.overlay.calmWaitingNamed", "正在等「%@」回应…")
            subtitle = currentPhone.map { String(format: format, $0) } ?? L("status.overlay.calmWaiting", "正在等 iPhone 回应…")
        }
        else if let currentPhone {
            let format = L("status.overlay.connectingNamed", "正在连接「%@」…")
            subtitle = String(format: format, currentPhone)
        }
        else { subtitle = L("status.overlay.hint", "请稍候，画面即将出现") }
        if retro {   // 只在要使用者動手（或等太久）時多一個對話盒；平常就是開機畫面
            let plain = !(succeeded || btFailed || btPairing || needTrust || cable || pairing || wifiHelp || slow)
            drawWelcome1988(g, note: plain ? nil : (title, subtitle))
            g.restoreGState(); return
        }
        drawCentered(g, subtitle, font: Self.rounded(30, weight: .semibold), kern: 0, y: 772,
                     color: NSColor.white.withAlphaComponent(0.6))
        // 没线也能配：一次蓝牙设置。有线的用户插上就自动配对，完全不用进设置。
        // 三段提示线与底部胶囊同理：trust 状态只有一句「点了信任自动继续」
        if btFailed {
            drawCentered(g, L("status.overlay.pairFailedHint", "也可以在 iPhone 设置 › 蓝牙里点这台 Mac"),
                         font: Self.rounded(24, weight: .medium), kern: 0, y: 822,
                         color: NSColor.white.withAlphaComponent(0.55))
        } else if btPairing {
            drawCentered(g, L("status.overlay.pairConfirmHint", "配对成功后拔线即可无线；以后会自动连接"),
                         font: Self.rounded(24, weight: .medium), kern: 0, y: 822,
                         color: NSColor.white.withAlphaComponent(0.55))
        } else if needTrust {
            let hint = L("status.overlay.trustHint", "线没插好也会这样：换根数据线再试")
            drawCentered(g, hint, font: Self.rounded(24, weight: .medium), kern: 0, y: 822,
                         color: NSColor.white.withAlphaComponent(0.55))
        } else if cable {
            drawCentered(g, L("status.overlay.cableHint", "没有线也没关系：稍后会自动改为蓝牙配对"),
                         font: Self.rounded(24, weight: .medium), kern: 0, y: 822,
                         color: NSColor.white.withAlphaComponent(0.55))
        } else if pairing {
            let hint: String
            if CarPlayOverlayState.pairingViaCable {
                hint = L("status.overlay.pairCableHint", "配好就自动开画面；不想现在配，60 秒后先用有线连上")
            } else if CarPlayOverlayState.pairingStale {
                hint = L("status.overlay.pairStale", "iPhone 里若还有这台 Mac 的旧配对：点 ⓘ → 忽略此设备，再重新配对")
            } else if elapsed > 25 {
                hint = L("status.overlay.pairTrouble", "没看到 Mac？保持两边蓝牙设置开着，等几秒会刷新")
            } else {
                // 只在「其他裝置」點一次；配好後 iPhone 常說「不支援」，那是正常的，忘記它才會壞事
                hint = L("status.overlay.pairOnce", "只点一次；iPhone 说「不支持」也别点「忽略此设备」")
            }
            drawCentered(g, hint, font: Self.rounded(24, weight: .medium), kern: 0, y: 822,
                         color: NSColor.white.withAlphaComponent(0.55))
        } else if wifiHelp {
            // 真機 2026-10-24：iPhone 在拿到 HomePlay 的 Wi-Fi 設定之前就連著這個網路時，要重新連一次 Wi-Fi 才會把它當 CarPlay 網路
            //（這一步現在是 wifiNoConnectBack 卡的標題；其他原因各有自己的下一步）
            if let hint = helpCard.hint {
                drawCentered(g, hint, font: Self.rounded(24, weight: .medium), kern: 0, y: 822,
                             color: NSColor.white.withAlphaComponent(0.55))
            }
        } else if recentlyPaired {
            drawCentered(g, L("status.help.notSupported", "iPhone 说「不支持」是正常的，别点「忽略此设备」"),
                         font: Self.rounded(24, weight: .medium), kern: 0, y: 822,
                         color: NSColor.white.withAlphaComponent(0.55))
        } else if verySlow {
            let hint = L("status.overlay.carPlayReset", "已解锁仍不行：设置 › 通用 › CarPlay › 忘记这台 Mac，再重新连接")
            drawCentered(g, hint, font: Self.rounded(24, weight: .medium), kern: 0, y: 822,
                         color: NSColor.white.withAlphaComponent(0.55))
        }
        // 只放真的知道的一格
        let font = Self.rounded(26, weight: .semibold)
        let text: String
        if succeeded { text = L("status.overlay.pairSuccessChip", "以后自动无线连接") }
        else if btFailed { text = L("status.overlay.pairFailedChip", "拔线再插一次") }
        else if btPairing {
            text = secondsLeft.map { String(format: L("status.overlay.pairCountdown", "等待 iPhone 确认，还剩 %d 秒"), $0) }
                ?? L("status.overlay.pairConfirmChip", "等待 iPhone 确认…")
        }
        else if needTrust { text = L("status.overlay.trustChip", "点了「信任」自动继续") }
        else if cable { text = L("status.overlay.cableChip", "第一次只需一根数据线") }
        else if pairing { text = L("status.overlay.pairWaiting", "两边都点「配对」后自动继续") }
        else if wifiHelp { text = helpCard.chip }
        else if verySlow {
            text = currentPhone != nil
                ? L("status.overlay.switchHint", "可右键换一台 iPhone")
                : L("status.overlay.pairHint", "配对一次，之后走无线")
        }
        else if slow { text = L("status.overlay.cancelHint", "仍可右键取消连接") }
        else if currentPhone != nil { text = L("status.overlay.carPlayPrompt", "若 iPhone 弹出 CarPlay 提示，请点允许") }
        else { text = L("status.overlay.waiting", "等待第一帧…") }
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: Typo.attributes(font, color: NSColor.white.withAlphaComponent(0.8))))
        let w = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        let chip = CGRect(x: 512 - (w + 44) / 2, y: 886, width: w + 44, height: 56)
        g.setFillColor(NSColor.white.withAlphaComponent(0.12).cgColor)
        g.addPath(CGPath(roundedRect: chip, cornerWidth: 28, cornerHeight: 28, transform: nil)); g.fillPath()
        drawCentered(g, text, font: font, kern: 0, y: chip.minY + 37, color: NSColor.white.withAlphaComponent(0.8))
        g.restoreGState()
    }
}

extension Face {
    /// 設定的三步進度：①配對 ②確認 ③完成（目前步驟白色，做完的綠色打勾，未到的淡）
    func drawSetupSteps(_ g: CGContext, current: Int, y: CGFloat) {
        let labels = [L("status.step.pair", "配对"), L("status.step.confirm", "在 iPhone 上确认"), L("status.step.done", "完成")]
        let font = Self.rounded(24, weight: .semibold)
        let widths = labels.map { Typo.width($0, font) + 44 }
        let gap: CGFloat = 26
        var x = 512 - (widths.reduce(0, +) + gap * 2) / 2
        for (i, label) in labels.enumerated() {
            let n = i + 1
            let done = n < current, now = n == current
            let dot = CGRect(x: x, y: y - 14, width: 28, height: 28)
            g.setFillColor((done ? srgb(0x34c759) : NSColor.white.withAlphaComponent(now ? 0.95 : 0.22)).cgColor)
            g.fillEllipse(in: dot)
            if done {
                g.setStrokeColor(NSColor.white.cgColor); g.setLineWidth(3.5); g.setLineCap(.round); g.setLineJoin(.round)
                g.move(to: CGPoint(x: dot.minX + 8, y: dot.midY)); g.addLine(to: CGPoint(x: dot.minX + 12.5, y: dot.midY + 5))
                g.addLine(to: CGPoint(x: dot.maxX - 7, y: dot.minY + 9)); g.strokePath()
            } else {
                let nf = Self.rounded(18, weight: .bold)
                drawLeft(g, "\(n)", font: nf, x: dot.midX - Typo.width("\(n)", nf) / 2, y: dot.midY + 6.5,
                         color: now ? srgb(0x050607) : NSColor.white.withAlphaComponent(0.7))
            }
            drawLeft(g, label, font: font, x: dot.maxX + 10, y: y + 8.5,
                     color: NSColor.white.withAlphaComponent(done ? 0.75 : now ? 0.95 : 0.4))
            x += widths[i] + gap
        }
    }
}

/// CarPlay 目前的狀態。存的是狀態本身，不是譯好的字：語言切換後下一次畫就是新語言，
/// 判斷「連線中」也不用去比對字串。
enum CarPlayStatus {
    case notConnected, live, paused, reconnecting, connecting, pausedResume, background
    var text: String {
        switch self {
        case .notConnected:
            // 从没配过手机：引导「重按开始」；已有手机但没连：显示在等谁，别用技术词吓人
            if CarPlayPhoneBook.phones.isEmpty { return L("status.notSetup", "重按连上 iPhone") }
            if let name = CarPlayPhoneBook.currentName {
                return String(format: L("status.waitingNamed", "正在等待「%@」"), name)
            }
            return L("status.notConnected", "CarPlay 未连接 · 重按进入")
        case .live: return L("status.live", "CarPlay 显示中")
        case .paused: return L("status.paused", "CarPlay 已暂停")
        case .reconnecting: return L("status.reconnecting", "稍后重新连接")
        case .connecting: return L("status.connecting", "CarPlay 连接中…")
        case .pausedResume: return L("status.pausedResume", "CarPlay 已暂停 · 空格继续")
        case .background: return L("status.background", "CarPlay 在后台 · 重按返回")
        }
    }
}
