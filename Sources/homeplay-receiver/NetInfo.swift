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

enum NetInfo {
    /// 本机所有 IPv4（网卡名 → 地址、掩码），跳过回环与 169.254 链路本地（USB NCM 那种）
    static func allIPv4() -> [(iface: String, addr: in_addr, mask: in_addr)] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0 else { return [] }
        defer { freeifaddrs(head) }
        var out: [(String, in_addr, in_addr)] = []
        var p = head
        while let a = p {
            defer { p = a.pointee.ifa_next }
            guard let sa = a.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET),
                  a.pointee.ifa_flags & UInt32(IFF_UP) != 0, a.pointee.ifa_flags & UInt32(IFF_LOOPBACK) == 0,
                  let nm = a.pointee.ifa_netmask else { continue }
            let addr = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
            let mask = nm.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
            if UInt32(bigEndian: addr.s_addr) >> 16 == 0xA9FE { continue }   // 169.254/16
            out.append((String(cString: a.pointee.ifa_name), addr, mask))
        }
        return out
    }
    static func text(_ a: in_addr) -> String {
        var a = a
        var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        return inet_ntop(AF_INET, &a, &buf, socklen_t(buf.count)).map { String(cString: $0) } ?? ""
    }
    /// 内核往这个地址发包时会用的本机来源 IPv4（UDP connect 不发任何封包，只查路由）
    static func sourceIPv4(toward host: in_addr) -> String? {
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var dst = sockaddr_in()
        dst.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); dst.sin_family = sa_family_t(AF_INET)
        dst.sin_port = in_port_t(9).bigEndian; dst.sin_addr = host
        let ok = withUnsafePointer(to: &dst) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard ok == 0 else { return nil }
        var me = sockaddr_in(); var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        guard withUnsafeMutablePointer(to: &me, { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) } }) == 0 else { return nil }
        return text(me.sin_addr)
    }
    /// 无线版 0x4301 要给手机的地址，按优先顺序。Mac 同时有有线和 Wi-Fi、而且在同一个网段时
    ///（真机 2026-10-24：en5 2.5G 网卡 192.168.5.25 ＋ en0 Wi-Fi 192.168.5.9，路由走 en5），
    /// 手机连 Wi-Fi 那个地址的话，进来走 Wi-Fi、Mac 回包却从有线出去，同一个 IP 在网上对应两个 MAC。
    /// 所以先给内核往这个网段回包时真正会用的来源地址（进出同一张网卡），再给 Wi-Fi 的，再给其他同网段的。
    static func lanAddresses(wifi iface: String) -> [String] {
        let all = allIPv4()
        guard let w = all.first(where: { $0.iface == iface }) else { return all.first.map { [text($0.addr)] } ?? [] }
        let net = w.addr.s_addr & w.mask.s_addr
        var probe = in_addr(s_addr: net | UInt32(2).bigEndian)   // 网段里的一个地址，只拿来查路由
        if probe.s_addr == w.addr.s_addr { probe.s_addr = net | UInt32(3).bigEndian }
        var out: [String] = []
        if let src = sourceIPv4(toward: probe), all.contains(where: { text($0.addr) == src }) { out.append(src) }
        out.append(text(w.addr))
        for x in all where x.addr.s_addr & w.mask.s_addr == net { out.append(text(x.addr)) }
        var seen = Set<String>()
        return out.filter { seen.insert($0).inserted }
    }
    static func ipv4(_ iface: String) -> String? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0 else { return nil }
        defer { freeifaddrs(head) }
        var p = head
        while let a = p {
            defer { p = a.pointee.ifa_next }
            guard String(cString: a.pointee.ifa_name) == iface, let sa = a.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                return String(cString: host)
            }
        }
        return nil
    }
    /// 链路本地 IPv6（fe80::/10），无线回连的备用地址；去掉 %scope，和 MacPlay 发给手机的格式一致。
    static func linkLocalIPv6(_ iface: String) -> String? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0 else { return nil }
        defer { freeifaddrs(head) }
        var p = head
        while let a = p {
            defer { p = a.pointee.ifa_next }
            guard String(cString: a.pointee.ifa_name) == iface, let sa = a.pointee.ifa_addr,
                  sa.pointee.sa_family == UInt8(AF_INET6) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let full = String(cString: host)
            let addr = full.split(separator: "%").first.map(String.init) ?? full
            let p3 = addr.lowercased().prefix(3)
            if ["fe8", "fe9", "fea", "feb"].contains(p3) { return addr }
        }
        return nil
    }

    /// Wi-Fi 网卡先问 CoreWLAN（getifaddrs 的 AF_LINK 在新系统上会给 02:00:00:00:00:00 的遮罩值）
    static func mac(_ iface: String) -> String? {
        if let hw = CWWiFiClient.shared().interface(withName: iface)?.hardwareAddress(), !hw.hasPrefix("02:00:00") {
            return hw.uppercased()
        }
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0 else { return nil }
        defer { freeifaddrs(head) }
        var p = head
        while let a = p {
            defer { p = a.pointee.ifa_next }
            guard String(cString: a.pointee.ifa_name) == iface, let sa = a.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_LINK) else { continue }
            return sa.withMemoryRebound(to: sockaddr_dl.self, capacity: 1) { dl -> String? in
                let len = Int(dl.pointee.sdl_alen), off = Int(dl.pointee.sdl_nlen)
                guard len == 6 else { return nil }
                let bytes = withUnsafeBytes(of: dl.pointee.sdl_data) { Array($0) }
                guard off + 6 <= bytes.count else { return nil }
                return bytes[off..<(off + 6)].map { String(format: "%02X", $0) }.joined(separator: ":")
            }
        }
        return nil
    }
}
