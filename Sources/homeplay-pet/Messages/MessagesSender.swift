// 送訊息：交給「訊息」App 的 AppleScript（send … to participant／chat id），送完回頭讀 chat.db 確認真的有一筆外送列。
// 規則（AI System 6）：沒有 confirmed == true 絕不送——ClioTalk 要先把內容念回給使用者、聽到「好」才會帶 confirmed。
// 已知問題：macOS 26 起 AppleScript 回報成功卻只留一筆空的幽靈列，所以一定要驗證；驗不到就回 .unconfirmed，呼叫端別自動重送。
// 隱私：內文與 handle 都不寫日誌。

import Foundation

enum MessagesSendTarget: Equatable {
    case handle(String)      // 電話或信箱（一對一，iMessage）
    case chat(guid: String)  // 群組或既有對話的 guid，例如 "iMessage;+;chat123…"；macOS 26 起多半是 "any;-;+886…"
    case participant(String, service: String)   // 2.0 imsg：一對一的備援路，服務要具體（iMessage／SMS／RCS）
}

enum MessagesSendResult: Equatable {
    case sent                // chat.db 裡找到相符的外送列
    case unconfirmed         // 腳本沒報錯、但 10 s 內查不到：可能已送出，勿自動重試
    case notConfirmed        // 呼叫端沒帶 confirmed: true，什麼都沒做
    case needsAutomation     // 沒有「自動化 › 訊息」權限（-1743）
    case failed(String)      // 腳本錯誤（只含錯誤碼，不含內文）
}

enum MessagesSender {
    static let confirmWindow = 10.0, pollStep = 0.5

    /// AppleScript 字串常值：反斜線與雙引號跳脫，換行用 linefeed 串接（不把使用者文字直接當程式碼）
    static func literal(_ s: String) -> String {
        let parts = s.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n").components(separatedBy: "\n")
        return parts.map { "\"" + $0.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\"" }
            .joined(separator: " & linefeed & ")
    }

    static func script(text: String, to target: MessagesSendTarget) -> String {
        switch target {
        case .handle(let h):
            return script(text: text, to: .participant(h, service: "iMessage"))
        case .participant(let h, let svc):
            let type = ["iMessage", "SMS", "RCS"].contains(svc) ? svc : "iMessage"   // 只准三個常數（照 sdef），不把字串塞進腳本
            return """
            tell application "Messages"
              set svc to 1st account whose service type = \(type)
              set p to participant \(literal(h)) of svc
              send \(literal(text)) to p
            end tell
            """
        case .chat(let g):
            return """
            tell application "Messages"
              send \(literal(text)) to chat id \(literal(g))
            end tell
            """
        }
    }

    /// 送出並驗證。completion 在主執行緒。confirmed 不是 true 就直接回 .notConfirmed。
    /// 2.0 imsg：macOS 26 起 chat guid 是 "any;-;…"；chat id 那條路腳本出錯（沒送出）時，一對一改走 participant＋具體服務
    /// （BlueBubbles server #777／#832 的做法：服務照 chat.service_name，不硬猜 iMessage）。只在腳本錯誤時退，沒驗到不退（可能已送出）。
    static func fallback(for target: MessagesSendTarget, service: String?) -> MessagesSendTarget? {
        guard case .chat(let g) = target, g.contains(";-;"), let svc = service, ["iMessage", "SMS", "RCS"].contains(svc),
              let r = g.range(of: ";-;") else { return nil }
        let handle = String(g[r.upperBound...])
        return handle.isEmpty ? nil : .participant(handle, service: svc)
    }

    static func send(text: String, to target: MessagesSendTarget, confirmed: Bool,
                     databasePath: String = MessagesAccess.defaultPath, fallbackService: String? = nil,
                     completion: @escaping (MessagesSendResult) -> Void) {
        guard confirmed else { completion(.notConfirmed); return }
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { completion(.failed("empty")); return }
        let chatGUID: String? = { if case .chat(let g) = target { return g }; return nil }()
        // 送之前記下游標；驗證用自己的連線（背景佇列）
        let baseline = MessagesStore(path: databasePath)?.maxRowID() ?? 0
        DispatchQueue.main.async {   // NSAppleScript 請在主執行緒跑
            var err: NSDictionary?
            NSAppleScript(source: script(text: body, to: target))?.executeAndReturnError(&err)
            if let e = err, (e[NSAppleScript.errorNumber] as? Int) != -1743, let alt = fallback(for: target, service: fallbackService) {
                log("messages: chat id route error \((e[NSAppleScript.errorNumber] as? Int) ?? 0), trying participant route")
                err = nil
                NSAppleScript(source: script(text: body, to: alt))?.executeAndReturnError(&err)
            }
            if let err {
                let code = (err[NSAppleScript.errorNumber] as? Int) ?? 0
                log("messages: send script error \(code)")
                completion(code == -1743 ? .needsAutomation : .failed("applescript \(code)"))
                return
            }
            DispatchQueue.global(qos: .userInitiated).async {
                let result = confirm(body, chatGUID: chatGUID, baseline: baseline, databasePath: databasePath)
                log("messages: send \(result)")
                DispatchQueue.main.async { completion(result) }
            }
        }
    }

    /// 每 0.5 s 查一次，最多 10 s
    static func confirm(_ text: String, chatGUID: String?, baseline: Int64, databasePath: String) -> MessagesSendResult {
        let deadline = Date().addingTimeInterval(confirmWindow)
        guard let store = MessagesStore(path: databasePath) else { return .unconfirmed }
        repeat {
            switch store.outgoing(after: baseline, text: text, chatGUID: chatGUID) {
            case .found: return .sent
            case .failed: return .failed("delivery")
            case .none: Thread.sleep(forTimeInterval: pollStep)
            }
        } while Date() < deadline
        return .unconfirmed
    }
}
