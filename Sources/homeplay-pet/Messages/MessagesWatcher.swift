// 監看 chat.db：DispatchSource 看 chat.db／-wal／-shm 的變動，加 3 秒輪詢補漏（睡眠喚醒後事件會掉），去抖後
// 用 ROWID 游標找出「新來的對方訊息」交給 handler（主執行緒）。
// Messages 寫入後幾毫秒內還會改同一列（內文、附件），所以：去抖 0.25 s；還沒有內文／附件的新列最多等 10 s 才放過。

import Foundation

struct MessagesIncoming {
    var message: MsgMessage
    var chatTitle: String
    var isGroup: Bool
}

final class MessagesWatcher: @unchecked Sendable {
    static let debounce = 0.25, pollInterval = 3.0, graceSeconds = 10.0

    private let queue = DispatchQueue(label: "homeplay.messages.watcher")
    private var store: MessagesStore?
    private var sources: [DispatchSourceFileSystemObject] = []
    private var timer: DispatchSourceTimer?
    private var pending: DispatchWorkItem?
    private(set) var cursor: Int64 = 0
    private let path: String
    private let open: () -> MessagesStore?
    var handler: (([MessagesIncoming]) -> Void)?

    init(path: String = MessagesAccess.defaultPath, open: (() -> MessagesStore?)? = nil) {
        self.path = path
        self.open = open ?? { MessagesStore(path: path) }
    }

    /// 開始監看；游標從目前最大的 ROWID 起算（不補播舊訊息）。沒權限時回 false，呼叫端去解釋。
    @discardableResult
    func start() -> Bool {
        var ok = false
        queue.sync {
            guard store == nil, let s = open() else { return }
            store = s; cursor = s.maxRowID(); ok = true
            armSources()
            let t = DispatchSource.makeTimerSource(queue: queue)
            // leeway 1 秒：輪詢只是檔案事件的補漏（睡眠喚醒後事件會掉），
            // 給系統合併喚醒的空間，週期語意不變（效能／能效整理，2026-10-26）
            t.schedule(deadline: .now() + Self.pollInterval, repeating: Self.pollInterval, leeway: .seconds(1))
            t.setEventHandler { [weak self] in self?.check() }
            t.resume(); timer = t
        }
        return ok
    }

    func stop() {
        queue.sync {
            timer?.cancel(); timer = nil
            sources.forEach { $0.cancel() }; sources = []
            pending?.cancel(); store = nil
        }
    }

    /// 為 db、-wal、-shm 各掛一個檔案事件；檔案被換掉（checkpoint 刪 wal）就重掛
    private func armSources() {
        sources.forEach { $0.cancel() }; sources = []
        for suffix in ["", "-wal", "-shm"] {
            let fd = Darwin.open(path + suffix, O_EVTONLY)
            guard fd >= 0 else { continue }
            let s = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .extend, .delete, .rename, .attrib], queue: queue)
            s.setEventHandler { [weak self, weak s] in
                guard let self else { return }
                if let m = s?.data, m.contains(.delete) || m.contains(.rename) {
                    self.queue.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.armSources() }
                }
                self.schedule()
            }
            s.setCancelHandler { Darwin.close(fd) }
            s.resume(); sources.append(s)
        }
    }

    private func schedule() {
        pending?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.check() }
        pending = w
        queue.asyncAfter(deadline: .now() + Self.debounce, execute: w)
    }

    /// 查一次游標之後的新列（測試也直接呼叫）。回傳這次交出去的訊息
    @discardableResult
    func check(now: Date = Date()) -> [MessagesIncoming] {
        guard let store else { return [] }
        let rows = store.newRows(after: cursor, incomingOnly: false)
        var out: [MessagesIncoming] = []
        for r in rows {
            let m = r.message
            let ready = !m.text.isEmpty || !m.attachments.isEmpty
            // 還沒填好的新列：10 s 內先不放過（游標停在它前面，下一輪再看）
            if !ready && now.timeIntervalSince(m.date) < Self.graceSeconds { break }
            cursor = m.rowID
            if !m.isFromMe && ready { out.append(MessagesIncoming(message: m, chatTitle: r.chatTitle, isGroup: r.isGroup)) }
        }
        if !out.isEmpty {
            log("messages: \(out.count) new incoming")
            let h = handler
            DispatchQueue.main.async { h?(out) }
        }
        return out
    }
}
