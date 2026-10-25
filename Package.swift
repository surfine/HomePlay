// swift-tools-version: 6.0
// HomePlay：3D HomeView 桌宠 + 自己的 CarPlay 接收器。GPL-3.0-or-later，见 LICENSE / NOTICE。
import PackageDescription

let v5: [SwiftSetting] = [.swiftLanguageMode(.v5)]

let package = Package(
    name: "HomePlay",
    defaultLocalization: "zh-Hans",
    platforms: [.macOS(.v14)],
    targets: [
        // 共享模块
        .target(name: "Wire", swiftSettings: v5),
        .target(name: "H264", dependencies: ["Wire"], swiftSettings: v5),
        .target(name: "IAP2", linkerSettings: [.linkedFramework("Security"), .linkedFramework("IOBluetooth")]),
        .target(name: "Session", dependencies: ["H264", "Wire"], swiftSettings: v5),
        // 可执行
        .executableTarget(name: "homeplay-pet", exclude: ["Design/README.md"], resources: [.process("Resources")], swiftSettings: v5),   // HPDS 規格書不進 bundle
        .executableTarget(name: "homeplay-receiver", dependencies: ["Wire", "H264", "IAP2", "Session"], swiftSettings: v5,
                          linkerSettings: [.linkedFramework("CoreWLAN")]),
        .executableTarget(name: "homeplay-verify", swiftSettings: v5),
        .executableTarget(name: "iap2-probe", dependencies: ["IAP2"],
                          linkerSettings: [.linkedFramework("IOBluetooth")]),
        .executableTarget(name: "iap2-offline-tests", dependencies: ["IAP2"]),
        .executableTarget(name: "session-tests", dependencies: ["Session"], swiftSettings: v5),
    ]
)
