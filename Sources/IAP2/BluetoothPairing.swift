// 蓝牙首次配对的纯规则：不碰 IOBluetooth，离线测试可直接验。
// 「有没有 iPhone 配对过」决定是引导手机去系统蓝牙里配对，还是刷新已配对手机的 SDP。
import Foundation

package enum PairingAction: Equatable {
    /// 已经有一台 iPhone 配对：刷新它的 SDP 再查 iAP2 服务。
    case refreshSDP(String)
    /// 一台 iPhone 都没配对：打开系统蓝牙设置，让用户在 iPhone 上配这台 Mac。
    case pairOnPhone
}

package enum PairingRules {
    package static func action(pairedPhones: [(address: String, name: String)],
                               preferred: String?) -> PairingAction {
        guard !pairedPhones.isEmpty else { return .pairOnPhone }
        if let preferred,
           pairedPhones.contains(where: { sameAddress($0.address, preferred) }) {
            return .refreshSDP(normalize(preferred))
        }
        return .refreshSDP(normalize(pairedPhones[0].address))
    }

    /// 引导开始后新出现的手机；按地址不区分大小写比较（IOBluetooth 可能给短横线格式）。
    package static func newlyPaired(_ current: [(address: String, name: String)],
                                    baseline: Set<String>) -> [(address: String, name: String)] {
        let seen = Set(baseline.map { normalize($0) })
        return current.filter { !seen.contains(normalize($0.address)) }
    }

    /// 手机主动连进来时是否接管：必须是已配对手机；平时还必须是当前选定的那台，
    /// 配对引导期间放宽——任何新连入都接管（刚配对的新手机可能还没进入 pairedPhones，
    /// 设备类/SDP 尚未解析）。**不靠名字**：iPhone 可以被命名成任意字符串。
    package static func acceptsIncoming(address: String,
                                        pairedPhones: [(address: String, name: String)],
                                        preferred: String?,
                                        pairingGuide: Bool) -> Bool {
        let normalized = normalize(address)
        let known = pairedPhones.contains { normalize($0.address) == normalized }
        guard known || pairingGuide else { return false }
        if let preferred, normalize(preferred) != normalized, !pairingGuide { return false }
        return true
    }

    /// 蓝牙地址统一成 12 位大写十六进制、冒号分隔（IOBluetooth 可能给短横线格式）。
    package static func normalize(_ address: String) -> String {
        let hex = address.uppercased().filter(\.isHexDigit)
        guard hex.count == 12 else { return address.uppercased().replacingOccurrences(of: "-", with: ":") }
        var parts: [String] = []
        var i = hex.startIndex
        while i < hex.endIndex {
            let j = hex.index(i, offsetBy: 2)
            parts.append(String(hex[i..<j]))
            i = j
        }
        return parts.joined(separator: ":")
    }

    private static func sameAddress(_ a: String, _ b: String) -> Bool {
        normalize(a) == normalize(b)
    }
}
