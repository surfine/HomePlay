// Bonjour 广播 `_airplay._tcp`（对应 MacPlay discovery.ts 里的 TXT 记录）。
// 用 NWListener 的服务广告：监听口就是 SRV 端口，TXT 由我们给。
import Foundation
import Network

package struct DiscoveryTXT: Sendable {
    package var deviceid: String
    package var features = "0x44540380,0x61"
    package var flags = "0x4"
    package var model = "MacPlay"
    package var srcvers = "950.7.1"
    package var protovers = "1.1"
    package var pi: String
    package var pk: String
    package init(deviceid: String, pi: String, pk: String) { self.deviceid = deviceid; self.pi = pi; self.pk = pk }

    package var entries: [String: String] {
        ["deviceid": deviceid, "features": features, "flags": flags, "model": model,
         "srcvers": srcvers, "protovers": protovers, "pi": pi, "pk": pk]
    }
}

package final class Discovery {
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "session.discovery")
    package let serviceName: String
    package let txt: DiscoveryTXT

    package init(serviceName: String = "MacPlay", txt: DiscoveryTXT) { self.serviceName = serviceName; self.txt = txt }

    /// 在指定端口广播。port 就是 SRV 端口（MacPlay 用 17000）。TCP 连接本身交给 `onConnection`。
    package func start(port: UInt16 = 0, onConnection: ((NWConnection) -> Void)? = nil, timeout: TimeInterval = 5) throws -> UInt16 {
        let l: NWListener
        if port == 0 { l = try NWListener(using: .tcp) }
        else { l = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: port)!) }
        var record = NWTXTRecord()
        for (k, v) in txt.entries { record[k] = v }
        l.service = NWListener.Service(name: serviceName, type: "_airplay._tcp", txtRecord: record)
        l.newConnectionHandler = { c in if let onConnection { onConnection(c) } else { c.cancel() } }
        let p = try listenAndWait(l, queue: queue, timeout: timeout)
        listener = l
        return p
    }

    package func stop() { listener?.cancel(); listener = nil }
}
