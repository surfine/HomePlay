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

func log(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }

/// 診斷日誌的落地點。`appendDiag` 會被事件 tap、相機佇列這些不能等磁碟的地方呼叫，
/// 所以一律丟進這條序列佇列非同步寫；每支檔案超過 1 MB 就輪轉成 `<name>.1`，只留一份舊檔。
private let diagQueue = DispatchQueue(label: "homeplay.diag", qos: .utility)
private let diagDir: URL = HomePlayState.directory
private let diagLimit: UInt64 = 1 << 20
private var diagHandles: [String: FileHandle] = [:]   // 只在 diagQueue 上存取

private func diagHandle(_ name: String) -> FileHandle? {
    if let h = diagHandles[name] { return h }
    try? FileManager.default.createDirectory(at: diagDir, withIntermediateDirectories: true)
    let url = diagDir.appendingPathComponent(name)
    // 日誌只給自己讀寫（0600）：新建就是 0600，舊版留下的 0644 第一次打開時修正
    if !FileManager.default.fileExists(atPath: url.path) {
        FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
    } else {
        chmod(url.path, 0o600)
    }
    guard let h = try? FileHandle(forWritingTo: url) else { return nil }
    h.seekToEndOfFile()
    diagHandles[name] = h
    return h
}

private func diagWrite(_ name: String, _ text: String) {
    guard let data = text.data(using: .utf8), let h = diagHandle(name) else { return }
    let size = h.offsetInFile
    if size > diagLimit {
        // 先關檔再搬：留著的 handle 會指到舊 inode，之後的寫入就丟了。
        try? h.close(); diagHandles[name] = nil
        let url = diagDir.appendingPathComponent(name)
        let old = diagDir.appendingPathComponent(name + ".1")
        try? FileManager.default.removeItem(at: old)
        try? FileManager.default.moveItem(at: url, to: old)
        guard let fresh = diagHandle(name) else { return }
        _ = try? fresh.write(contentsOf: data)
        return
    }
    _ = try? h.write(contentsOf: data)
}

/// 舊版（0.4 之前）把每個按鍵寫進 keys.log：只刪這兩個確切檔名，其他檔不碰。回傳刪了幾個。
@discardableResult
func removeLegacyKeyLogs(in dir: URL) -> Int {
    var removed = 0
    for name in ["keys.log", "keys.log.1"] {
        let url = dir.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: url.path), (try? FileManager.default.removeItem(at: url)) != nil { removed += 1 }
    }
    return removed
}
let legacyKeyLogsKey = "HomePlayLegacyKeyLogsRemoved"

/// 啟動時把 HomePlay 資料夾裡所有日誌（含輪轉的 .1、舊版留下的）收成 0600：
/// receiver.log 有 Wi-Fi 名稱與手機位址，舊版的 keys.log 有按鍵紀錄，都不該給同機其他帳號讀。不刪、不改內容。
func tightenLogPermissions() {
    diagQueue.async {
        // 一次性：刪掉舊版留下的按鍵紀錄（只記一行，不讀內容）
        if !UserDefaults.standard.bool(forKey: legacyKeyLogsKey) {
            if removeLegacyKeyLogs(in: diagDir) > 0 { log("removed legacy keys.log") }
            UserDefaults.standard.set(true, forKey: legacyKeyLogsKey)
        }
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: diagDir.path) else { return }
        for n in names where n.hasSuffix(".log") || n.hasSuffix(".log.1") {
            let path = diagDir.appendingPathComponent(n).path
            if let mode = (try? FileManager.default.attributesOfItem(atPath: path))?[.posixPermissions] as? Int, mode & 0o077 != 0 {
                chmod(path, 0o600)
            }
        }
    }
}
/// 诊断日志：异步追加一行到 Application Support/HomePlay/<name>。
func appendDiag(_ name: String, _ line: String) {
    let text = "[\(Date())] \(line)\n"
    diagQueue.async { diagWrite(name, text) }
}
