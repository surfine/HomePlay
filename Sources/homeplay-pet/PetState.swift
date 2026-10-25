// 桌寵的狀態資料夾，和接收器的 HomePlayState（Sources/Wire/HomePlayState.swift）同一個規則：
// 預設 ~/Library/Application Support/HomePlay；HOMEPLAY_STATE_NAME 換資料夾（首次配對演練，docs/first-pair-test.md）。
import Foundation

enum HomePlayState {
    static let name: String = {
        let raw = ProcessInfo.processInfo.environment["HOMEPLAY_STATE_NAME"]?.trimmingCharacters(in: .whitespaces) ?? ""
        return raw.isEmpty || raw.contains("/") || raw.hasPrefix(".") ? "HomePlay" : raw
    }()
    static var isolated: Bool { name != "HomePlay" }
    static let directory: URL =
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent(name, isDirectory: true)
}
