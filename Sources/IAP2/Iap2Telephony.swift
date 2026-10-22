import Foundation

// iAP2 通話狀態（0x4155 CallStateUpdate）與通訊狀態（0x4158 CommunicationsUpdate）的解析。
// 欄位編號照 MacPlay iap2-csm messages/communications.rs（訂閱見 Iap2Csm.startCallStateUpdates）：
//   0x4155：0 remoteID（號碼，str）、1 displayName（str）、2 status（u8）、3 direction（u8）、
//           4 callUUID（str）、11 disconnectReason（u8）
//   0x4158：0 signalStrength（u8，0–5）、1 registrationStatus（u8）、2 airplaneMode（bool）、
//           4 carrierName（str）、5 cellularSupported（bool）
// 一通電話一個 callUUID；同時兩通（插撥）時各自更新，CallBook 合併後挑「最該給人看的那通」。

extension Iap2Csm {

    package enum Communications {
        package static let startCallStateUpdates: UInt16 = 0x4154
        package static let callStateUpdate: UInt16 = 0x4155
        package static let startUpdates: UInt16 = 0x4157
        package static let update: UInt16 = 0x4158
    }

    package struct CallState: Equatable {
        /// iAP2 CallStateStatus
        package enum Status: UInt8 {
            case disconnected = 0, sending, ringing, connecting, active, held, disconnecting
        }
        /// 給桌寵的階段：只分它要不同畫面的幾種
        package enum Phase: String {
            case idle, ringing, dialing, active, held
        }

        package var remoteID: String?
        package var displayName: String?
        package var status: UInt8?
        package var direction: UInt8?      // 0 未知、1 來電、2 撥出
        package var callUUID: String?
        package var disconnectReason: UInt8?

        package init() {}

        package var incoming: Bool { direction == 1 }

        package var phase: Phase {
            switch status.flatMap(Status.init(rawValue:)) {
            case .ringing: return .ringing
            case .sending: return .dialing
            // 接起之後的「連接中」對使用者就是在通話；撥出的則還在撥
            case .connecting: return incoming ? .active : .dialing
            case .active: return .active
            case .held: return .held
            case .disconnected, .disconnecting, .none: return .idle
            }
        }

        package mutating func merge(_ n: CallState) {
            if let v = n.remoteID { remoteID = v }
            if let v = n.displayName { displayName = v }
            if let v = n.status { status = v }
            if let v = n.direction { direction = v }
            if let v = n.callUUID { callUUID = v }
            if let v = n.disconnectReason { disconnectReason = v }
        }
    }

    package static func callState(_ frame: Frame) -> CallState? {
        guard frame.messageId == Communications.callStateUpdate else { return nil }
        let p = frame.parameters
        var out = CallState()
        out.remoteID = telString(p, 0)
        out.displayName = telString(p, 1)
        out.status = telU8(p, 2)
        out.direction = telU8(p, 3)
        out.callUUID = telString(p, 4)
        out.disconnectReason = telU8(p, 11)
        return out
    }

    package struct CommunicationsState: Equatable {
        package var signalStrength: UInt8?
        package var registrationStatus: UInt8?
        package var airplaneMode: Bool?
        package var carrierName: String?
        package var cellularSupported: Bool?

        package init() {}

        package mutating func merge(_ n: CommunicationsState) {
            if let v = n.signalStrength { signalStrength = v }
            if let v = n.registrationStatus { registrationStatus = v }
            if let v = n.airplaneMode { airplaneMode = v }
            if let v = n.carrierName { carrierName = v }
            if let v = n.cellularSupported { cellularSupported = v }
        }

        /// 給桌寵：`{"type":"cellular",...}`；一個欄位都沒有就 nil
        package var json: String? {
            var d: [String: Any] = ["type": "cellular"]
            if let v = signalStrength { d["signal"] = Int(v) }
            if let v = carrierName, !v.isEmpty { d["carrier"] = v }
            if let v = airplaneMode { d["airplane"] = v }
            if let v = cellularSupported { d["cellularSupported"] = v }
            guard d.count > 1 else { return nil }
            return telJSON(d)
        }
    }

    package static func communications(_ frame: Frame) -> CommunicationsState? {
        guard frame.messageId == Communications.update else { return nil }
        let p = frame.parameters
        var out = CommunicationsState()
        out.signalStrength = p.first { $0.id == 0 }?.payload.first
        out.registrationStatus = p.first { $0.id == 1 }?.payload.first
        out.airplaneMode = telU8(p, 2).map { $0 != 0 }
        out.carrierName = telString(p, 4)
        out.cellularSupported = telU8(p, 5).map { $0 != 0 }
        return out
    }

    /// 每通電話（callUUID）的最新狀態。掛掉的移除；沒有 UUID 的更新算在「無名」那一通。
    package struct CallBook: Equatable {
        package private(set) var calls: [String: CallState] = [:]

        package init() {}

        package mutating func apply(_ update: CallState) {
            let key = update.callUUID ?? ""
            var call = calls[key] ?? CallState()
            call.merge(update)
            if call.phase == .idle { calls[key] = nil } else { calls[key] = call }
        }

        package mutating func reset() { calls = [:] }

        /// 最該給人看的那通：響鈴 > 通話中 > 保留 > 撥出中；同級按 UUID 排，結果穩定
        package var current: CallState? {
            let rank: [CallState.Phase: Int] = [.ringing: 0, .active: 1, .held: 2, .dialing: 3]
            return calls.values.sorted {
                let a = rank[$0.phase] ?? 9, b = rank[$1.phase] ?? 9
                return a != b ? a < b : ($0.callUUID ?? "") < ($1.callUUID ?? "")
            }.first
        }

        /// 給桌寵：`{"type":"call","state":"ringing","name":…,"number":…,"incoming":true,"uuid":…}`；
        /// 沒有通話時 `state` 是 idle
        package var json: String {
            guard let c = current else { return telJSON(["type": "call", "state": "idle"]) ?? #"{"type":"call","state":"idle"}"# }
            var d: [String: Any] = ["type": "call", "state": c.phase.rawValue, "incoming": c.incoming]
            if let v = c.displayName, !v.isEmpty { d["name"] = v }
            if let v = c.remoteID, !v.isEmpty { d["number"] = v }
            if let v = c.callUUID, !v.isEmpty { d["uuid"] = v }
            if calls.count > 1 { d["calls"] = calls.count }
            return telJSON(d) ?? #"{"type":"call","state":"idle"}"#
        }
    }

    private static func telString(_ params: [Parameter], _ id: UInt16) -> String? {
        guard let b = params.first(where: { $0.id == id })?.payload else { return nil }
        let cut = b.last == 0 ? b.dropLast() : b[...]
        return String(bytes: cut, encoding: .utf8)
    }

    private static func telU8(_ params: [Parameter], _ id: UInt16) -> UInt8? {
        guard let b = params.first(where: { $0.id == id })?.payload, b.count == 1 else { return nil }
        return b[0]
    }

    private static func telJSON(_ d: [String: Any]) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: d, options: [.sortedKeys]) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
