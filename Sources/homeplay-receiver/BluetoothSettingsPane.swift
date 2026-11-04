import AppKit
import Foundation
import QuartzCore
import Network
import CoreWLAN
import IOBluetooth
import IOKit
import IAP2
import Session
import H264
import Wire

/// 第一次配对走系统蓝牙：打开「系统设置 › 蓝牙」后 Mac 才可被 iPhone 发现，
/// iPhone 点这台 Mac 的名字、两边确认配对码即可（和 MacPlay／DiPlay 一样由手机发起）。
/// 不碰私有 API，也不要求先插 USB。
///
/// macOS 自 10.9 起把「可被发现」绑在蓝牙设置面板是否打开上：面板关闭即不可发现，
/// `IOBluetoothPreferenceSetDiscoverableState`（blueutil 用的私有函数）在 macOS 26 上
/// 已是空实现，也没有对应的 defaults 键。所以这里后台打开面板（不抢焦点），
/// 并在配对引导期间每分钟补开一次，避免用户关掉面板后 Mac 变得不可发现。
enum BluetoothSettingsPane {
    static func open() {
        let config = NSWorkspace.OpenConfiguration()
        config.activates = false          // 后台打开：不打断用户当前操作
        for text in ["x-apple.systempreferences:com.apple.BluetoothSettings",
                     "x-apple.systempreferences:com.apple.preferences.Bluetooth"] {
            if let url = URL(string: text) {
                NSWorkspace.shared.open(url, configuration: config) { _, _ in }
                return
            }
        }
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app"),
                                configuration: config) { _, _ in }
    }
}
