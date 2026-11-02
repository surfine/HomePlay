// swift-tools-version: 6.0
// HomePlay：3D HomeView 桌宠 + 自己的 CarPlay 接收器。GPL-3.0-or-later，见 LICENSE / NOTICE。
import Foundation
import PackageDescription

let v5: [SwiftSetting] = [.swiftLanguageMode(.v5)]

// libopus：CoreAudio 的 AudioConverter 解不了裸 Opus 包（真机验证为全 0），
// 电话/Siri/短信朗读的 Opus 下行必须用 libopus。brew install opus。
// HOMEPLAY_OPUS_LIB 可指向自己编的静态库（发布版用 14.0 部署目标编，避免 Homebrew
// bottle 把 minOS 抬到 26/27 时链接器警告）。
let opusCandidates = [ProcessInfo.processInfo.environment["HOMEPLAY_OPUS_LIB"],
                      "/opt/homebrew/lib/libopus.a", "/usr/local/lib/libopus.a"].compactMap { $0 }
let opusLib = opusCandidates.first { FileManager.default.fileExists(atPath: $0) }
let opusLink: LinkerSetting = opusLib.map { .unsafeFlags([$0]) }
    ?? .unsafeFlags(["-L/opt/homebrew/lib", "-L/usr/local/lib", "-lopus"])

// SpeexDSP：VPIO 起不来时的参考信号回声消除（电话/Siri 上行）。brew install speexdsp。
// HOMEPLAY_SPEEX_LIB 同上。
let speexCandidates = [ProcessInfo.processInfo.environment["HOMEPLAY_SPEEX_LIB"],
                       "/opt/homebrew/lib/libspeexdsp.a", "/usr/local/lib/libspeexdsp.a"].compactMap { $0 }
let speexLib = speexCandidates.first { FileManager.default.fileExists(atPath: $0) }
let speexLink: LinkerSetting = speexLib.map { .unsafeFlags([$0]) }
    ?? .unsafeFlags(["-L/opt/homebrew/lib", "-L/usr/local/lib", "-lspeexdsp"])

let package = Package(
    name: "HomePlay",
    defaultLocalization: "zh-Hans",
    platforms: [.macOS(.v14)],
    targets: [
        // 共享模块
        .target(name: "Wire", swiftSettings: v5),
        .target(name: "H264", dependencies: ["Wire"], swiftSettings: v5),
        .target(name: "IAP2", linkerSettings: [.linkedFramework("Security"), .linkedFramework("IOBluetooth")]),
        // CoreAudio 的 AudioConverter 对裸 Opus 包解不出声音（实机验证为全 0）；
        // CarPlay 电话/Siri/短信朗读的 Opus 下行用 libopus 解。brew install opus。
        .target(name: "COpus", path: "Sources/COpus", publicHeadersPath: "include",
                linkerSettings: [opusLink]),
        .target(name: "CSpeex", path: "Sources/CSpeex", publicHeadersPath: "include",
                linkerSettings: [speexLink]),
        .target(name: "Session", dependencies: ["H264", "Wire", "COpus", "CSpeex"], swiftSettings: v5),
        // 可执行
        .executableTarget(name: "homeplay-pet", exclude: ["Design/README.md"], resources: [.process("Resources")], swiftSettings: v5),   // HPDS 規格書不進 bundle
        .executableTarget(name: "homeplay-receiver", dependencies: ["Wire", "H264", "IAP2", "Session"], swiftSettings: v5,
                          linkerSettings: [.linkedFramework("CoreWLAN")]),
        .executableTarget(name: "homeplay-verify", swiftSettings: v5),
        .executableTarget(name: "homeplay-glance", swiftSettings: v5),   // iPhone 即時動態 → JSON（私有 API 隔離在這裡）
        .executableTarget(name: "iap2-probe", dependencies: ["IAP2"],
                          linkerSettings: [.linkedFramework("IOBluetooth")]),
        .executableTarget(name: "iap2-offline-tests", dependencies: ["IAP2"]),
        .executableTarget(name: "session-tests", dependencies: ["Session"], swiftSettings: v5),
    ]
)
