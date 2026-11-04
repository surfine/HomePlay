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

/// 让系统重查一台设备的 SDP 记录（照 MacPlay：iAP2 服务记录可能过期，刷新后再 locate）。
/// 完成回调是 target 上的 -sdpQueryComplete:status:（IOBluetooth 没有正式协议）；20s 兜底（MacPlay 25s）。
final class SDPRefresh: NSObject {
    /// 同时可以有好几个在跑（以前只有一个槽位，第二个会让第一个的 completion 永远不来）
    private static nonisolated(unsafe) var inflight: [SDPRefresh] = []
    private var completion: (() -> Void)?

    static func refresh(address: String, timeout: TimeInterval = 20, then done: @escaping () -> Void) {
        let normalized = address.replacingOccurrences(of: ":", with: "-").lowercased()
        guard let device = IOBluetoothDevice(addressString: normalized) else { done(); return }
        let ref = SDPRefresh()
        ref.completion = done
        inflight.append(ref)
        device.performSDPQuery(ref, uuids: [Iap2BluetoothAccessory.iap2ServiceUUID])
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak ref] in
            guard let ref, ref.completion != nil else { return }
            ref.fire()
        }
    }

    @objc func sdpQueryComplete(_ device: IOBluetoothDevice!, status: IOReturn) { fire() }
    private func fire() {
        let done = completion
        completion = nil
        Self.inflight.removeAll { $0 === self }
        done?()
    }
}
