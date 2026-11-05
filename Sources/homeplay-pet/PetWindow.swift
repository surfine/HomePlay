// 桌寵無邊框面板——自 main.swift 拆出。
import Accelerate
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

final class PetWindow: NSPanel {
    init(size: NSSize) {
        super.init(contentRect: NSRect(origin: .zero, size: size),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = AppDelegate.alwaysOnTop ? .floating : .normal
        isMovableByWindowBackground = false
        // 不加 .fullScreenAuxiliary：全螢幕 App 在前景时自动不出现，回到桌面再出来
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        isReleasedWhenClosed = false
    }
    override var canBecomeKey: Bool { true }
}

// MARK: - App

// MARK: - 拉起 receiver（重按进 CarPlay 用）
/// 参数读 ~/Library/Application Support/HomePlay/wireless.json（phone、ssid、size、port）；
/// Wi-Fi 密码不需要：iPhone 与 Mac 同网时直接连；特殊网络用 HOMEPLAY_WIFI_PASSPHRASE 显式提供。
/// pet 退出时一并结束自己拉起的 receiver；端口探测避免重复起。
