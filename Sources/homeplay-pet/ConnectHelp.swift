import AppKit

// 首次連 iPhone 的說明與排障：
// - 連線卡（CarPlayOverlay）卡住時，照接收器判斷的原因（ConnectDiagnostics.Reason）給一句能照做的話；
// - 「連接步驟…」：純文字步驟，第一次進配對引導時自動出一次，右鍵 › iPhone 隨時再看；
// - 「拷貝診斷報告」：只有次數、秒數、狀態（不含 Wi-Fi 名稱、密碼、位址、裝置名稱），朋友可以直接貼給你。

/// 卡住時那張卡的四行字
struct ConnectCard: Equatable {
    var title: String
    var subtitle: String
    var hint: String?
    var chip: String
}

enum ConnectHelp {
    /// 排障卡亮了這麼久還沒好：改給「插線一次」的退路和「拷貝診斷報告」
    static let escalateAfter = 40.0

    /// reason：接收器送來的原因（舊版接收器沒有就當 Wi-Fi 沒連回）。ssid：要讓 iPhone 連的網路名（空＝不知道）。
    static func card(reason: String?, ssid: String, needsPassword: Bool, helpElapsed: Double) -> ConnectCard {
        let late = helpElapsed >= escalateAfter
        let cable = L("status.help.cable", "还不行？插线连一次：解锁 iPhone 点「信任」")
        let report = L("status.help.copyReport", "右键 → iPhone → 拷贝诊断报告")
        let autoRetry = L("status.help.autoRetry", "改好后自动重试")
        switch reason {
        case "macFirewall":
            return ConnectCard(title: L("status.help.firewall.title", "Mac 防火墙挡住了 iPhone"),
                               subtitle: L("status.help.firewall.body", "系统设置 › 网络 › 防火墙 › 选项"),
                               hint: L("status.help.firewall.hint", "关掉「阻止所有传入连接」，并允许 homeplay-receiver"),
                               chip: late ? report : autoRetry)
        case "localNetwork":
            return ConnectCard(title: L("status.help.localNetwork.title", "允许 HomePlay 使用本地网络"),
                               subtitle: L("status.help.localNetwork.body", "系统设置 › 隐私与安全性 › 本地网络"),
                               hint: L("status.help.localNetwork.hint", "打开 HomePlay 旁边的开关"),
                               chip: late ? report : autoRetry)
        case "carPlayConsent":
            return ConnectCard(title: L("status.help.consent.title", "在 iPhone 上点「连接」"),
                               subtitle: L("status.help.consent.body", "解锁 iPhone，CarPlay 提示出现时点「连接」"),
                               hint: L("status.help.consent.hint", "没看到？打开 iPhone 设置 › 通用 › CarPlay，点 HomePlay"),
                               chip: late ? report : L("status.help.consent.chip2", "点了就会出现画面"))
        case "wifiShare":
            // HomePlay 已經請 iPhone 分享 Wi-Fi：這時只要叫使用者按「分享」，不提任何錯誤
            return ConnectCard(title: L("status.help.share.title", "在 iPhone 上点「分享」"),
                               subtitle: L("status.help.share.body", "iPhone 会把现在的 Wi-Fi 分享给 HomePlay，不用打密码"),
                               hint: late ? cable : L("status.help.share.hint", "没看到？解锁 iPhone 看一下通知或屏幕顶端"),
                               chip: late ? report : L("status.help.share.chip", "分享后几秒就会出现画面"))
        case "ssidUnknown":
            return ConnectCard(title: L("status.help.ssid.title", "告诉 HomePlay 你的 Wi-Fi"),
                               subtitle: L("status.help.ssid.body", "macOS 不让 App 读取 Wi-Fi 名称，请填 iPhone 所连的网络"),
                               hint: late ? cable : L("status.help.ssid.hint", "填好保存后会马上再连一次"),
                               chip: late ? report : L("status.overlay.wifiHelpChip", "右键 → iPhone → Wi-Fi 设置"))
        case "usbNoData":
            return ConnectCard(title: L("status.help.usbNoData.title", "iPhone 在充电，但没在传数据"),
                               subtitle: L("status.help.usbNoData.body", "解锁 iPhone；若问是否允许配件连接，点「允许」"),
                               hint: L("status.help.usbNoData.hint", "还不行？换一根能传数据的线，直接插 Mac、不经扩展坞"),
                               chip: late ? report : L("status.help.unlockChip", "解锁后自动继续"))
        case "usbLocked":
            return ConnectCard(title: L("status.help.usbLocked.title", "解锁 iPhone"),
                               subtitle: L("status.help.usbLocked.body", "iPhone 锁着时不让 Mac 通过数据线打开 CarPlay"),
                               hint: nil, chip: late ? report : L("status.help.unlockChip", "解锁后自动继续"))
        case "usbTrustExpired":
            return ConnectCard(title: L("status.help.usbTrust.title", "重新信任这台 Mac"),
                               subtitle: L("status.help.usbTrust.body", "拔线，解锁 iPhone 再插上，点「信任」"),
                               hint: nil, chip: late ? report : L("status.overlay.trustChip", "点了「信任」自动继续"))
        case "usbNoNetwork":
            return ConnectCard(title: L("status.help.usbNet.title", "数据线连上了，CarPlay 没起来"),
                               subtitle: L("status.help.usbNet.body", "拔掉再插一次，直接插 Mac、不经扩展坞"),
                               hint: L("status.help.usbNet.hint", "或拔线改用无线：iPhone 和 Mac 连同一个 Wi-Fi"),
                               chip: report)
        case "inboundBlocked":
            return ConnectCard(title: L("status.help.inbound.title", "iPhone 连不进这台 Mac"),
                               subtitle: L("status.help.inbound.body", "同一个 Wi-Fi 却被挡住：检查防火墙或 Little Snitch、LuLu 这类 App"),
                               hint: cable, chip: report)
        default:   // wifiNoConnectBack，或舊接收器沒給原因
            let body = ssid.isEmpty
                ? L("status.help.wifi.body", "iPhone 要和这台 Mac 连同一个 Wi-Fi，不是访客网络")
                : String(format: L("status.help.wifi.bodyNamed", "iPhone 要连「%@」，不是访客网络或另一个 5G／2.4G 名称"),
                         ssid.count > 24 ? String(ssid.prefix(23)) + "…" : ssid)
            let hint: String? = late ? cable
                : needsPassword ? L("status.overlay.wifiNeedPassword", "iPhone 所连的 Wi-Fi 可能需要密码（只填一次）") : nil
            let chip = late ? report
                : needsPassword ? L("status.overlay.wifiPasswordChip", "右键 → iPhone → Wi-Fi 设置填密码")
                : L("status.overlay.wifiHelpChip", "右键 → iPhone → Wi-Fi 设置")
            return ConnectCard(title: L("status.help.wifi.title", "在 iPhone 上关开一次 Wi-Fi"), subtitle: body, hint: hint, chip: chip)
        }
    }

    // MARK: 連接步驟

    static let stepsShownKey = "HomePlayConnectStepsShown"

    /// 純文字、編號步驟。有線最簡單放第一段；沒線的那段明講「只在其他裝置點一次、說不支援也別忘記它」。
    static func stepsText() -> String {
        let cable = [
            L("steps.cable1", "用数据线把 iPhone 接到这台 Mac，解锁 iPhone，点「信任」并输入密码。"),
            L("steps.cable2", "HomePlay 请你配对时，在 iPhone 设置 › 蓝牙 › 其他设备里点这台 Mac 一次；不想配，60 秒后先用有线。"),
            L("steps.cable3", "配好之后拔线也能用，以后自动无线连接。"),
        ]
        let wireless = [
            L("steps.bt1", "HomePlay 显示「在 iPhone 上配对这个 Mac」时，打开 iPhone 设置 › 蓝牙。"),
            L("steps.bt2", "在「其他设备」里点这台 Mac 的名字一次，两边都点「配对」。"),
            L("steps.bt3", "iPhone 若说「不支持」，是正常的：别点「忽略此设备」，也别在「我的设备」里再点它。"),
            L("steps.bt4", "iPhone 弹出 CarPlay 提示时点「连接」。"),
            L("steps.bt5", "iPhone 和 Mac 要连同一个 Wi-Fi（不是访客网络）；卡在「正在连接」就在 iPhone 控制中心关开一次 Wi-Fi。"),
        ]
        func numbered(_ a: [String]) -> String { a.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n") }
        return L("steps.cableHeader", "有线（最简单）") + "\n" + numbered(cable) + "\n\n"
            + L("steps.btHeader", "没有线") + "\n" + numbered(wireless) + "\n\n"
            + L("steps.footer", "连不上时：右键 → iPhone → 拷贝诊断报告，发给帮你看的人。")
    }

    static func showSteps() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = L("steps.title", "第一次连接 iPhone")
        alert.informativeText = stepsText()
        alert.addButton(withTitle: L("gaze.denied.ok", "好"))
        alert.runModal()
    }

    // MARK: 診斷報告

    /// receiver.log 裡的里程碑：只數次數，不抄任何一行（那些行裡有網路名稱與位址）。
    /// 字串是接收器日誌的原文（不是介面文字）。
    static let logMilestones: [(label: String, needle: String)] = [
        ("receiver starts", "身份自检通过"),
        ("iPhone authenticated", "MFi 认证通过"),
        ("Wi-Fi config asked", "要 Wi-Fi 配置"),
        ("start sent", "送 0x4301"),
        ("start resent", "补发 0x4301"),
        ("phone connected", "手机连入控制口"),
        ("sessions", "会话开始，等画面"),
        ("session ends", "会话结束："),
        ("connect help shown", "连不上（"),
        ("pairing guide", "→ 首次配对"),
        ("self-heal restarts", "自愈："),
        ("Bluetooth link ends", "蓝牙 iAP2 结束"),
        ("Wi-Fi name unknown at start", "SSID 未知"),
    ]

    /// 只看最後 2 MB；回傳一行「標籤 次數」
    static func summarizeLog(_ text: Substring) -> String {
        var lines = 0
        var counts = [Int](repeating: 0, count: logMilestones.count)
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            lines += 1
            for (i, m) in logMilestones.enumerated() where line.contains(m.needle) { counts[i] += 1 }
        }
        let parts = zip(logMilestones, counts).filter { $0.1 > 0 }.map { "\($0.0.label) \($0.1)" }
        return "receiver.log (\(lines) lines): " + (parts.isEmpty ? "no milestones" : parts.joined(separator: " · "))
    }

    static func logSummary() -> String {
        let url = HomePlayState.directory.appendingPathComponent("receiver.log")
        guard let h = try? FileHandle(forReadingFrom: url) else { return "receiver.log: not found" }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        let start = size > 2_000_000 ? size - 2_000_000 : 0
        try? h.seek(toOffset: start)
        guard let data = try? h.readToEnd() else { return "receiver.log: unreadable" }
        return summarizeLog(Substring(String(decoding: data, as: UTF8.self)))   // 從中間切進來的半個字元換成 U+FFFD
    }

    /// 整份報告：桌寵這邊的狀態＋接收器的現場（沒回應就註明）＋日誌里程碑次數
    static func compose(petLines: [String], receiver: String?, log: String) -> String {
        var out = ["HomePlay diagnostic report — counts, timings and states only (no Wi-Fi names, passwords, addresses or device names)"]
        out += petLines
        out.append(receiver ?? "Receiver: did not answer (not running, or still starting)")
        out.append(log)
        return out.joined(separator: "\n")
    }
}
