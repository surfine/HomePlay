// 2.0: ClioTalk 的訊息工具：messages_read_recent（讀一個對話最近幾則）、messages_send（替你送出）。
// 送出照 AI System 6：引擎先把「要傳給誰：『…』嗎？」念給你聽，你說「好」才走到這裡的 run，
// 再交給 MessagesSender.send(confirmed: true)（它沒帶 confirmed 一律不送），送完回頭查 chat.db 確認。
// 設定裡「信息」那個同意開關預設關；訪客模式／認不出主人時引擎根本不送這兩個工具給模型。
// 隱私：內文、名字、號碼都不寫日誌。

import Foundation

/// 送出前念回來的那一句（訊息 App 的確認卡與 ClioTalk 共用）
enum MessagesReadback {
    static func text(name: String, body: String) -> String {
        String(format: L("msg.confirm.send", "要传给 %1$@：『%2$@』吗？"), name, body.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

enum ClioMessagesTools {
    /// 名字比對用：小寫、去空白與方括號
    static func normalized(_ s: String) -> String {
        s.lowercased().filter { !$0.isWhitespace && !"[]［］「」".contains($0) }
    }

    /// 照使用者說的名字找對話：完全相同 > 名字包含 > 參與者的號碼／信箱相同。回傳候選（多個＝要問是哪一個）
    static func match(_ query: String, in convs: [MsgConversation]) -> [MsgConversation] {
        let q = normalized(query)
        guard !q.isEmpty else { return [] }
        let exact = convs.filter { normalized($0.title) == q }
        if !exact.isEmpty { return Array(exact.prefix(1)) }
        let contains = convs.filter { normalized($0.title).contains(q) }
        if !contains.isEmpty { return contains }
        let key = HandleKey.make(query)
        return convs.filter { c in c.participants.contains { HandleKey.make($0) == key } || HandleKey.make(c.chatIdentifier) == key }
    }

    private static func openStore() -> MessagesStore? {
        guard MessagesAccess.check() == .available, let s = MessagesStore.openDefault() else { return nil }
        let contacts = MessagesContacts.shared
        if !contacts.loaded, MessagesContacts.status == .authorized { contacts.reload() }
        s.nameResolver = { contacts.name(for: $0) }
        return s
    }

    /// 2.0: find_messages 用同一個開法
    static func openStoreForSearch() -> MessagesStore? { openStore() }

    /// selftest 關掉：念回來時不去查真的 chat.db
    nonisolated(unsafe) static var lookUpNames = true

    /// 念回來時顯示的名字：找得到唯一的對話就用它的標題，否則照使用者說的
    static func displayName(_ contact: String) -> String {
        let c = contact.trimmingCharacters(in: .whitespacesAndNewlines)
        guard lookUpNames, let s = openStore() else { return c }
        let m = match(c, in: s.conversations(limit: 200))
        if m.count == 1 { return m[0].title }
        if m.isEmpty, let p = contactTarget(c) { return p.name }   // 2.0 imsg：沒有對話的人，照通訊錄的名字念
        return c
    }

    /// 2.0 imsg：沒有既有對話時，通訊錄裡唯一符合、而且只有一個號碼／信箱的人（多個就要問，不猜）
    static func contactTarget(_ contact: String) -> (name: String, handle: String)? {
        guard MessagesContacts.status == .authorized else { return nil }
        if !MessagesContacts.shared.loaded { MessagesContacts.shared.reload() }
        let hits = MessagesContacts.shared.search(contact, limit: 3)
        guard hits.count == 1, hits[0].handles.count == 1 else { return nil }
        return (hits[0].name, hits[0].handles[0])
    }

    /// 2.0 imsg：給模型看的一行（照片、語音、連結、已編輯、撤回、回應都講出來；不加任何解讀）
    static func line(_ m: MsgMessage) -> String {
        if m.isUnsent { return "[unsent a message]" }
        var parts: [String] = []
        for a in m.attachments where m.link == nil {
            parts.append(a.isSticker ? "[sticker]" : (m.isAudioMessage || a.isAudio) ? "[audio message]" : a.isVideo ? "[video]" : a.isImage ? "[photo]" : "[file]")
        }
        if let l = m.link { parts.append("[link \(l.title.isEmpty ? l.url : l.title + " – " + l.host)]") }
        else if !m.text.isEmpty { parts.append(m.text) }
        if m.isEdited { parts.append("(edited)") }
        if !m.tapbacks.isEmpty { parts.append("(reactions: " + m.tapbacks.map { MessagesScreen.glyph($0) }.joined() + ")") }
        return parts.joined(separator: " ")
    }

    static func run(name: String, input: [String: Any]) async -> ClioToolResult {
        func fail(_ s: String) -> ClioToolResult { ClioToolResult(content: s, isError: true, source: .messages) }
        guard PersonalGate.cached else { return fail("Messages are only available to the owner of this Mac. Guest mode is on or the owner is not recognized.") }
        guard let store = openStore() else {
            return fail(MessagesAccess.check() == .needsFullDiskAccess
                        ? "HomePlay cannot read Messages yet: the user has to allow Full Disk Access for HomePlay in System Settings › Privacy & Security."
                        : "Messages is not set up on this Mac.")
        }
        let contact = (input["contact"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let found = match(contact, in: store.conversations(limit: 200))
        // 2.0 imsg：送給還沒有對話的人：通訊錄裡唯一符合的人（一個號碼／信箱）走 participant
        if found.isEmpty, name == "messages_send", let p = contactTarget(contact) {
            let text = (input["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return fail("text is required") }
            let result: MessagesSendResult = await withCheckedContinuation { c in
                MessagesSender.send(text: text, to: .handle(p.handle), confirmed: true) { c.resume(returning: $0) }
            }
            return outcome(result, to: p.name)
        }
        guard !found.isEmpty else { return fail("No conversation matches \"\(contact)\". Ask the user for the name as it appears in Messages.") }
        guard found.count == 1 else {
            return fail("Several conversations match: " + found.prefix(5).map(\.title).joined(separator: ", ") + ". Ask the user which one.")
        }
        let conv = found[0]
        switch name {
        case "messages_read_recent":
            let limit = max(1, min(20, (input["limit"] as? NSNumber)?.intValue ?? 8))
            let msgs = store.messages(chat: conv.rowID, limit: limit).reversed()
            if msgs.isEmpty { return ClioToolResult(content: "No messages in \(conv.title).", source: .messages) }
            let lines = msgs.map { m -> String in
                let who = m.isFromMe ? "me" : (store.nameResolver?(m.senderHandle) ?? (conv.isGroup ? m.senderHandle : conv.title))
                return "- \(ClioDates.machine(m.date).prefix(16)) \(who): \(line(m))"
            }
            return ClioToolResult(content: "Conversation \"\(conv.title)\", oldest first:\n" + lines.joined(separator: "\n"), source: .messages)
        case "messages_send":
            let text = (input["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return fail("text is required") }
            // 走到這裡＝引擎已經念給使用者聽、使用者說了「好」
            let result: MessagesSendResult = await withCheckedContinuation { c in
                MessagesSender.send(text: text, to: .chat(guid: conv.guid), confirmed: true, fallbackService: conv.service) { c.resume(returning: $0) }
            }
            return outcome(result, to: conv.title)
        default:
            return fail("Unknown tool \(name).")
        }
    }

    /// 送出結果照實說：查到才算送出；查不到不要叫使用者重送
    static func outcome(_ r: MessagesSendResult, to title: String) -> ClioToolResult {
        switch r {
        case .sent: return ClioToolResult(content: "Sent to \(title).", source: .messages)
        case .unconfirmed:
            return ClioToolResult(content: "The message may have been sent to \(title), but HomePlay could not confirm it. Tell the user to check Messages; do not offer to resend.", isError: true, source: .messages)
        case .needsAutomation:
            return ClioToolResult(content: "Not sent: HomePlay needs permission to control Messages (System Settings › Privacy & Security › Automation).", isError: true, source: .messages)
        case .notConfirmed:
            return ClioToolResult(content: "Not sent: the user did not confirm.", isError: true, source: .messages)
        case .failed:
            return ClioToolResult(content: "Not sent: Messages reported an error.", isError: true, source: .messages)
        }
    }
}
