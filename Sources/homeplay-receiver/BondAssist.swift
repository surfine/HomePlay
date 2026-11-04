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

/// 首插配对：向手机发起经典蓝牙配对（手机上弹一次确认）。妙控配件式的第一次——
/// 之后系统里就有这台手机，拔线即无线。已配对时调用方不会走到这里。
final class BondAssist: NSObject, IOBluetoothDevicePairDelegate {
    private static nonisolated(unsafe) var current: BondAssist?
    /// 进入数字比对时把 6 位数字交给调用方（桌宠显示，让用户和 iPhone 上的核对）
    static nonisolated(unsafe) var onConfirmCode: ((String) -> Void)?
    private var completion: ((Bool, String) -> Void)?
    private var pair: IOBluetoothDevicePair?

    static func pair(address: String, then done: @escaping (Bool, String) -> Void) {
        let normalized = address.replacingOccurrences(of: ":", with: "-").lowercased()
        guard let device = IOBluetoothDevice(addressString: normalized) else {
            done(false, "构造设备对象失败"); return
        }
        guard let pair = IOBluetoothDevicePair(device: device) else {
            done(false, "IOBluetoothDevicePair 创建失败"); return
        }
        let ref = BondAssist()
        ref.completion = done
        ref.pair = pair
        current = ref
        pair.delegate = ref
        let status = pair.start()
        if status != kIOReturnSuccess {
            current = nil
            ref.pair = nil
            done(false, "start 失败（0x\(String(status, radix: 16))）")
        }
        // 60s 没结果就当失败收场（手机上没人点）
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) { [weak ref] in
            guard let ref, ref.completion != nil else { return }
            ref.finish(ok: false, "60s 没确认")
        }
    }

    func devicePairingStarted(_ sender: Any!) {
        Wireless.note("蓝牙配对：开始")
    }

    func devicePairingConnected(_ sender: Any!) {
        Wireless.note("蓝牙配对：已连接，等待手机确认")
    }

    /// iPhone 的 Secure Simple Pairing 会做数字比较。以前没实现这个委托，Mac 侧可能一直不回复，
    /// 手机上的配对窗就超时；这里自动接受 Mac 这一侧，手机上仍然需要用户点「配对」。
    func devicePairingUserConfirmationRequest(_ sender: Any!, numericValue: BluetoothNumericValue) {
        Self.onConfirmCode?(String(format: "%06u", numericValue))
        Wireless.note("蓝牙配对：自动确认 Mac 侧数字码（手机仍需点配对）")
        pair?.replyUserConfirmation(true)
    }

    /// 传统 PIN 配对：回一个固定 PIN，避免 Mac 侧静默超时。内容不打印。
    func devicePairingPINCodeRequest(_ sender: Any!) {
        var pin = BluetoothPINCode()
        withUnsafeMutableBytes(of: &pin.data) { raw in
            raw[0] = 0x30; raw[1] = 0x30; raw[2] = 0x30; raw[3] = 0x30   // "0000"
        }
        pair?.replyPINCode(4, pinCode: &pin)
        Wireless.note("蓝牙配对：已回复 Mac 侧 PIN（手机仍需确认）")
    }

    func devicePairingUserPasskeyNotification(_ sender: Any!, passkey: BluetoothPasskey) {
        Wireless.note("蓝牙配对：请在 iPhone 上输入显示的 passkey")
    }

    func deviceSimplePairingComplete(_ sender: Any!, status: BluetoothHCIEventStatus) {
        Wireless.note("蓝牙配对：SSP 完成（status \(status)）")
    }

    func devicePairingFinished(_ sender: Any!, error: IOReturn) {
        finish(ok: error == kIOReturnSuccess, "0x\(String(error, radix: 16))")
    }

    private func finish(ok: Bool, _ detail: String) {
        completion?(ok, detail)
        completion = nil
        pair = nil
        Self.current = nil
    }
}
