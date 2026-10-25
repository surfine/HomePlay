// 接收器、會話層共用的狀態資料夾：~/Library/Application Support/HomePlay。
// HOMEPLAY_STATE_NAME（只是資料夾名，例「HomePlay Fresh」）可換到另一個資料夾：首次配對演練用，
// 不碰使用者真正的 pairing.json／wireless.json（見 docs/first-pair-test.md）。桌寵有一份同樣的（PetState）。
import Foundation

package enum HomePlayState {
    package static let name: String = {
        let raw = ProcessInfo.processInfo.environment["HOMEPLAY_STATE_NAME"]?.trimmingCharacters(in: .whitespaces) ?? ""
        return raw.isEmpty || raw.contains("/") || raw.hasPrefix(".") ? "HomePlay" : raw
    }()
    package static var isolated: Bool { name != "HomePlay" }
    package static let directory: URL =
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent(name, isDirectory: true)
}
