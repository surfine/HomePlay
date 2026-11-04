import AppKit
import Foundation
import QuartzCore
import Network
import CoreWLAN
import IOBluetooth
import IAP2
import Session
import H264
import Wire
import IOKit

/// USB 侧的网络面：手机的 CarPlay AV 网口（macOS 自己绑的 AppleUSBNCMData enX，按序列号找），
/// 照 MacPlay iap2-wired/mac_network.rs 的做法解析 ioreg。
enum UsbNet {
    /// USB 匯流排上有幾台 iPhone（只看 IOUSBHostDevice 的產品名，不讀序號）。
    /// usbmuxd 看不到、這裡卻有＝有電沒資料：鎖著（USB 限制模式）、沒點「允許」、或線／擴充座只供電。
    static func iPhonesOnBus() -> Int {
        var it: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOUSBHostDevice"), &it) == KERN_SUCCESS else { return 0 }
        defer { IOObjectRelease(it) }
        var n = 0
        while true {
            let s = IOIteratorNext(it)
            guard s != 0 else { break }
            defer { IOObjectRelease(s) }
            if let name = IORegistryEntryCreateCFProperty(s, "USB Product Name" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String,
               name == "iPhone" { n += 1 }
        }
        return n
    }

    /// 这台 iPhone 的 AppleUSBNCMData 接口（enX）。通常是两个，AV 用第一个。
    /// 呼叫它的地方在主執行緒上的 iAP2 訊息處理裡，而 ioreg 是外部程序：只讀背景快照。
    static func ncmInterfaces(udid: String) -> [String] {
        NcmSnapshot.shared.interfaces(for: udid)
    }

    fileprivate static func probeNcmInterfaces(udid: String) -> [String] {
        let want = udid.lowercased().filter { $0.isLetter || $0.isNumber }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/ioreg")
        p.arguments = ["-r", "-n", "iPhone", "-l", "-w", "0"]
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return [] }
        p.waitUntilExit()
        // ioreg 会带 MAC 地址等原始字节（如 IOMACAddress = <"R;p\x90 0d">），整段不是合法
        // UTF-8；严格 UTF-8 解码会一步返回 nil，把「有网口」误判成「没有」。
        // 用 Latin-1 无损解码（每个字节都有映射），与 MacPlay from_utf8_lossy 的语义一致。
        // 真机样本 2026-10-19：新 iPhone 的 MAC 含 0x90/0xb1，旧 SE 碰巧全是 ASCII。
        guard p.terminationStatus == 0,
              let text = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .isoLatin1) else { return [] }
        for block in text.components(separatedBy: "+-o iPhone@").dropFirst() {
            func quoted(_ line: String, _ key: String) -> String? {
                guard let r = line.range(of: "\"\(key)\" = \"") else { return nil }
                return String(line[r.upperBound...].prefix { $0 != "\"" })
            }
            let lines = block.components(separatedBy: "\n")
            let serial = lines.first { quoted($0, "USB Serial Number") != nil }.flatMap { quoted($0, "USB Serial Number") }
            guard serial?.lowercased().filter({ $0.isLetter || $0.isNumber }) == want else { continue }
            var ifaces: [String] = []
            var underNcm = false
            for line in lines {
                switch quoted(line, "IOClass") {
                case "AppleUSBNCMData", "AppleUSBNCM11Data": underNcm = true
                case "AppleUSBEthernetHostAQM": underNcm = false
                default: break
                }
                if underNcm, let name = quoted(line, "BSD Name") {
                    ifaces.append(name)
                    underNcm = false
                }
            }
            return ifaces
        }
        return []
    }

    /// ioreg 一次几十到几百毫秒，而调用点都在主执行绪的 iAP2 讯息处理里。
    /// 背景每 0.5 秒刷一次快照，调用端只做一次加锁读取（最多旧半秒，够用）。
    fileprivate final class NcmSnapshot {
        static let shared = NcmSnapshot()
        private let queue = DispatchQueue(label: "homeplay.ncm", qos: .utility)
        private let lock = NSLock()
        private var byUDID: [String: [String]] = [:]
        private var timer: DispatchSourceTimer?
        private var watching = ""
        private var lastRequest: Double = 0

        func interfaces(for udid: String) -> [String] {
            let key = Self.key(udid)
            lock.lock(); let hit = byUDID[key]; lastRequest = CACurrentMediaTime(); lock.unlock()
            start(udid)
            return hit ?? []
        }

        private static func key(_ udid: String) -> String {
            udid.lowercased().filter { $0.isLetter || $0.isNumber }
        }

        /// 只监视当前这台：换机时重建计时器，旧机的值留在字典里也没人再读。
        private func start(_ udid: String) {
            lock.lock()
            let changed = watching != udid
            if changed { watching = udid }
            lock.unlock()
            guard changed else { return }
            queue.async { [self] in
                lock.lock(); timer?.cancel(); lock.unlock()
                let t = DispatchSource.makeTimerSource(queue: queue)
                t.schedule(deadline: .now(), repeating: 0.5, leeway: .milliseconds(200))
                t.setEventHandler { [weak self] in
                    guard let self else { return }
                    // 没人再问了（有线会话结束）就停下来：ioreg 是外部程序，不能让它常驻轮询。
                    self.lock.lock()
                    let idle = CACurrentMediaTime() - self.lastRequest > 30
                    if idle { self.timer?.cancel(); self.timer = nil; self.watching = "" }
                    self.lock.unlock()
                    guard !idle else { return }
                    let value = UsbNet.probeNcmInterfaces(udid: udid)
                    self.lock.lock(); self.byUDID[Self.key(udid)] = value; self.lock.unlock()
                }
                lock.lock(); timer = t; lock.unlock()
                t.resume()
            }
        }
    }

    /// 接口的 IPv6 链路本地地址（fe80::），有线 AV 回连靠它。
    static func linkLocalV6(_ iface: String) -> String? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0 else { return nil }
        defer { freeifaddrs(head) }
        var p = head
        while let a = p {
            defer { p = a.pointee.ifa_next }
            guard String(cString: a.pointee.ifa_name) == iface, let sa = a.pointee.ifa_addr,
                  sa.pointee.sa_family == UInt8(AF_INET6) else { continue }
            var host = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
            let sin6 = sa.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0 }
            var addr = sin6.pointee.sin6_addr
            if inet_ntop(AF_INET6, &addr, &host, socklen_t(INET6_ADDRSTRLEN)) != nil {
                return String(cString: host)
            }
        }
        return nil
    }
}
