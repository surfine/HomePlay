import Foundation
import Security

// 系统 usbmuxd 客户端（macOS）：/var/run/usbmuxd 上的 plist 模式协议。
// ListDevices 找插着的 iPhone；Connect 在设备端口上开一条透明流（lockdownd、carkit 都走它）；
// ReadPairRecord 拿系统配对记录（不复制不重写，钥匙还在 usbmuxd 手里）。
// 头部 16 字节小端：总长 / version=1 / request=8 / tag；Connect 的 PortNumber 按 libusbmuxd
// 惯例存 htons 后的数值。帧格式已用 /tmp/usbmux_probe.py 对真机验证。

package enum Usbmuxd {
    package static let socketPath = "/var/run/usbmuxd"
    package static let lockdownPort: UInt16 = 62078

    package struct Device: Equatable, Sendable {
        package let id: UInt32
        package let serial: String   // UDID（Network 设备是 uuid，USB 是 24 位序列号/UDID）
    }

    package enum MuxError: Error, CustomStringConvertible {
        case socket(String)
        case proto(String)

        package var description: String {
            switch self {
            case .socket(let s): return "usbmuxd：\(s)"
            case .proto(let s): return "usbmuxd 协议：\(s)"
            }
        }
    }

    // MARK: 协议帧

    package static func encode(tag: UInt32, message: [String: Any]) -> [UInt8] {
        let data = try! PropertyListSerialization.data(fromPropertyList: message, format: .xml, options: 0)
        var out = [UInt8]()
        out.append(contentsOf: withUnsafeBytes(of: UInt32(16 + data.count).littleEndian) { Array($0) })
        out.append(contentsOf: withUnsafeBytes(of: UInt32(1).littleEndian) { Array($0) })   // version 1 = plist
        out.append(contentsOf: withUnsafeBytes(of: UInt32(8).littleEndian) { Array($0) })   // request 8 = plist 消息
        out.append(contentsOf: withUnsafeBytes(of: tag.littleEndian) { Array($0) })
        out.append(contentsOf: Array(data))
        return out
    }

    /// 读一条回复（头 16 + plist）。返回 plist。
    static func readReply(_ fd: Int32, tag: UInt32) throws -> [String: Any] {
        var header = [UInt8](repeating: 0, count: 16)
        try readFully(fd, &header)
        let length = UInt32(header[0]) | UInt32(header[1]) << 8 | UInt32(header[2]) << 16 | UInt32(header[3]) << 24
        let replyTag = UInt32(header[12]) | UInt32(header[13]) << 8 | UInt32(header[14]) << 16 | UInt32(header[15]) << 24
        guard length >= 16, length < 8 << 20 else { throw MuxError.proto("回复长度不合理：\(length)") }
        var body = [UInt8](repeating: 0, count: Int(length) - 16)
        if !body.isEmpty { try readFully(fd, &body) }
        guard replyTag == tag else { throw MuxError.proto("tag 对不上：\(replyTag) ≠ \(tag)") }
        guard let plist = try? PropertyListSerialization.propertyList(from: Data(body), options: [], format: nil),
              let dict = plist as? [String: Any] else { throw MuxError.proto("回复不是 plist 字典") }
        return dict
    }

    static func readFully(_ fd: Int32, _ buffer: inout [UInt8]) throws {
        var offset = 0
        while offset < buffer.count {
            let n = read(fd, &buffer + offset, buffer.count - offset)
            if n == 0 { throw MuxError.socket("连接被关（读了 \(offset)/\(buffer.count)）") }
            if n < 0 { throw MuxError.socket("read 出错：\(String(cString: strerror(errno)))") }
            offset += n
        }
    }

    // MARK: 设备列表

    /// 当前 USB 连接的设备（Network 的滤掉——有线 CarPlay 只认 USB）。
    package static func listDevices() throws -> [Device] {
        let fd = try openSocket()
        defer { close(fd) }
        var tag: UInt32 = 1
        let bytes = encode(tag: tag, message: [
            "MessageType": "ListDevices", "ClientVersionString": "HomePlay", "ProgName": "HomePlay"])
        try writeFully(fd, bytes)
        let reply = try readReply(fd, tag: tag); tag += 1
        return parseDeviceList(reply)
    }

    /// ListDevices 回复 → USB 设备。新版 macOS 把 SerialNumber/ConnectionType 放进 Properties，
    /// 旧版放在顶层；两处都认，否则插着线也会被当成"没设备"。
    package static func parseDeviceList(_ reply: [String: Any]) -> [Device] {
        let list = reply["DeviceList"] as? [[String: Any]] ?? []
        return list.compactMap { d in
            let props = d["Properties"] as? [String: Any] ?? [:]
            let connection = (props["ConnectionType"] as? String) ?? (d["ConnectionType"] as? String)
            let serial = (props["SerialNumber"] as? String) ?? (d["SerialNumber"] as? String)
            guard connection == "USB", let id = d["DeviceID"] as? Int, let serial else { return nil }
            return Device(id: UInt32(id), serial: serial)
        }
    }

    // MARK: 配对记录

    /// usbmuxd 里的配对记录 plist（HostID / SystemBUID / 证书）。只读。
    package static func pairRecord(udid: String) throws -> [String: Any] {
        let fd = try openSocket()
        defer { close(fd) }
        let bytes = encode(tag: 2, message: [
            "MessageType": "ReadPairRecord", "PairRecordID": udid,
            "ClientVersionString": "HomePlay", "ProgName": "HomePlay"])
        try writeFully(fd, bytes)
        let reply = try readReply(fd, tag: 2)
        return try parsePairRecord(reply)
    }

    /// ReadPairRecord 回复 → 配对记录字典。本机（macOS 26/27）成功回复里只有 PairRecordData，
    /// 没有 Number；旧版可能带 Number，两处都认。
    package static func parsePairRecord(_ reply: [String: Any]) throws -> [String: Any] {
        if let number = reply["Number"] as? Int, number != 0 {
            throw MuxError.proto("ReadPairRecord 被拒（Number \(number)）——先在 Finder 里信任这台 Mac")
        }
        guard let data = reply["PairRecordData"] as? Data,
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let dict = plist as? [String: Any] else {
            throw MuxError.proto("ReadPairRecord 没有 PairRecordData——先在 Finder 里信任这台 Mac")
        }
        return dict
    }

    // MARK: 连接（透明流）

    static func openSocket() throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw MuxError.socket("建 socket 失败") }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let path = Array(socketPath.utf8)
        guard path.count < MemoryLayout.size(ofValue: address.sun_path) else { close(fd); throw MuxError.socket("路径过长") }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: path + [0]) }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else {
            let message = String(cString: strerror(errno)); Darwin.close(fd)
            throw MuxError.socket("连不上 \(socketPath)：\(message)")
        }
        return fd
    }

    static func writeFully(_ fd: Int32, _ bytes: [UInt8]) throws {
        var offset = 0
        while offset < bytes.count {
            let n = bytes.withUnsafeBytes { raw in write(fd, raw.baseAddress!.advanced(by: offset), bytes.count - offset) }
            if n <= 0 { throw MuxError.socket("write 出错：\(String(cString: strerror(errno)))") }
            offset += n
        }
    }

    /// 已 Connect 到设备某端口的透明字节流（明文或 TLS）。
    package protocol MuxByteStream: AnyObject {
        var onBytes: (([UInt8]) -> Void)? { get set }
        var onClosed: (() -> Void)? { get set }
        func startReading()
        func send(_ bytes: [UInt8])
        func readExactly(_ count: Int) throws -> [UInt8]
        func close()
    }

    /// 发 Connect 并等 Result==0；返回的 socket 就是裸的字节通道（还没开始读）。
    package static func openConnected(deviceID: UInt32, port: UInt16) throws -> Int32 {
        let fd = try openSocket()
        let portBE = UInt16(port).bigEndian   // libusbmuxd 惯例：存 htons 后的数值
        let connect = encode(tag: 9, message: [
            "MessageType": "Connect", "DeviceID": Int(deviceID),
            "PortNumber": Int(portBE),
            "ClientVersionString": "HomePlay", "ProgName": "HomePlay"])
        do {
            try writeFully(fd, connect)
            let reply = try readReply(fd, tag: 9)
            guard (reply["Number"] as? Int) == 0 else {
                throw MuxError.proto("Connect 到 \(port) 被拒：\(reply)")
            }
        } catch {
            Darwin.close(fd)
            throw error
        }
        return fd
    }

    /// 已 Connect 到设备某端口的透明字节流。两种用法：
    /// 1) 请求-响应阶段（lockdown）：直接 send（带锁的同步写）+ readExactly（同步读）；
    /// 2) 流阶段（carkit/iAP2）：接好 onBytes 后 startReading()，读线程独立跑。
    package final class MuxStream: MuxByteStream, @unchecked Sendable {
        package var onBytes: (([UInt8]) -> Void)?
        package var onClosed: (() -> Void)?
        private let fd: Int32
        private let writeLock = NSRecursiveLock()   // 可重入：send 的错误路径会进 closeNow
        private var closed = false
        private var reading = false

        /// 发 Connect 并等 Result==0；成功后这条 socket 就是裸的字节通道（还没开始读）。
        package init(deviceID: UInt32, port: UInt16) throws {
            fd = try Usbmuxd.openConnected(deviceID: deviceID, port: port)
        }

        /// 接管一条已经 Connect 好的 socket（TLS 升级后沿用同一条链路）。
        package init(fd: Int32) {
            self.fd = fd
        }

        /// 进入回调模式：独立线程读，读到 EOF/错误时 onClosed（一次）。
        package func startReading() {
            guard !reading else { return }
            reading = true
            let thread = Thread { [weak self] in
                guard let self else { return }
                var buffer = [UInt8](repeating: 0, count: 64 * 1024)
                while true {
                    let n = read(self.fd, &buffer, buffer.count)
                    if n > 0 { self.onBytes?(Array(buffer[0..<n])); continue }
                    self.closeNow()
                    return
                }
            }
            thread.name = "usbmuxd-read"
            thread.start()
        }

        /// 发字节（带写锁，多线程安全）。
        package func send(_ bytes: [UInt8]) {
            writeLock.lock()
            defer { writeLock.unlock() }
            guard !closed else { return }
            do { try Usbmuxd.writeFully(fd, bytes) }
            catch { closeNow() }
        }

        /// 同步读（仅请求-响应阶段、startReading 之前用）
        package func readExactly(_ count: Int) throws -> [UInt8] {
            var buffer = [UInt8](repeating: 0, count: count)
            try Usbmuxd.readFully(fd, &buffer)
            return buffer
        }

        package func close() { closeNow() }

        private func closeNow() {
            writeLock.lock()
            defer { writeLock.unlock() }
            guard !closed else { return }
            closed = true
            Darwin.close(fd)
            let handler = onClosed
            DispatchQueue.main.async { handler?() }
        }
    }

    /// lockdown / carkit 的 TLS 客户端流。iOS 9+ 的 lockdown 在 StartSession 后要求 TLS，
    /// carkit 服务流（EnableServiceSSL）也要 TLS。证书/私钥直接来自配对记录（HostCertificate /
    /// HostPrivateKey），临时钥匙串只在本进程内存里用一次；链路本身已经由 usbmuxd 信任，链验证关掉
    /// （和 libimobiledevice 一样只做传输加密）。
    package final class TLSStream: MuxByteStream, @unchecked Sendable {
        package var onBytes: (([UInt8]) -> Void)?
        package var onClosed: (() -> Void)?
        private let fd: Int32
        private let readStream: CFReadStream
        private let writeStream: CFWriteStream
        private let writeLock = NSRecursiveLock()
        private var closed = false
        private var reading = false
        private var loggedFirstRead = false

        package var log: ((String) -> Void)?
        package var role = "TLS"

        package init(fd: Int32, pair: [String: Any]) throws {
            self.fd = fd
            let certificates = try TLSIdentity.certificates(from: pair)
            var readRef: Unmanaged<CFReadStream>?
            var writeRef: Unmanaged<CFWriteStream>?
            CFStreamCreatePairWithSocket(kCFAllocatorDefault, fd, &readRef, &writeRef)
            guard let r = readRef?.takeRetainedValue(), let w = writeRef?.takeRetainedValue() else {
                Darwin.close(fd)
                throw MuxError.proto("TLS：CFStream 创建失败")
            }
            readStream = r; writeStream = w
            let settings: [String: Any] = [
                kCFStreamSSLCertificates as String: certificates,
                kCFStreamSSLValidatesCertificateChain as String: false,
                kCFStreamSSLIsServer as String: false,
            ]
            _ = CFReadStreamSetProperty(r, CFStreamPropertyKey(kCFStreamPropertyShouldCloseNativeSocket), kCFBooleanFalse)
            _ = CFReadStreamSetProperty(r, CFStreamPropertyKey(kCFStreamPropertySSLSettings), settings as CFDictionary)
            _ = CFWriteStreamSetProperty(w, CFStreamPropertyKey(kCFStreamPropertyShouldCloseNativeSocket), kCFBooleanFalse)
            _ = CFWriteStreamSetProperty(w, CFStreamPropertyKey(kCFStreamPropertySSLSettings), settings as CFDictionary)
            guard CFReadStreamOpen(r), CFWriteStreamOpen(w) else {
                CFReadStreamClose(r); CFWriteStreamClose(w); Darwin.close(fd)
                throw MuxError.proto("TLS：打开失败")
            }
        }

        package func send(_ bytes: [UInt8]) {
            do { try writeExactly(bytes) }
            catch { closeNow() }
        }

        package func writeExactly(_ bytes: [UInt8]) throws {
            writeLock.lock(); defer { writeLock.unlock() }
            guard !closed else { throw MuxError.socket("TLS 流已关闭") }
            var offset = 0
            try bytes.withUnsafeBufferPointer { p in
                while offset < p.count {
                    let n = CFWriteStreamWrite(writeStream, p.baseAddress!.advanced(by: offset), p.count - offset)
                    if n <= 0 {
                        let e = CFWriteStreamGetError(writeStream)
                        throw MuxError.socket("TLS 写失败 \(e.error)")
                    }
                    offset += n
                }
            }
        }

        package func readExactly(_ count: Int) throws -> [UInt8] {
            var out = [UInt8](); out.reserveCapacity(count)
            var buf = [UInt8](repeating: 0, count: count)
            while out.count < count {
                let n = CFReadStreamRead(readStream, &buf, count - out.count)
                if n > 0 { out += buf[0..<n]; continue }
                if n == 0 { throw MuxError.proto("TLS：连接被关") }
                let e = CFReadStreamGetError(readStream)
                if e.error == 0 { continue }
                throw MuxError.proto("TLS 读错误 \(e.error)")
            }
            return out
        }

        package func startReading() {
            guard !reading else { return }
            reading = true
            let thread = Thread { [weak self] in
                guard let self else { return }
                var buffer = [UInt8](repeating: 0, count: 64 * 1024)
                while true {
                    let n = CFReadStreamRead(self.readStream, &buffer, buffer.count)
                    if n > 0 {
                        if !self.loggedFirstRead { self.loggedFirstRead = true; self.log?("\(self.role) 收到首包 \(n) 字节") }
                        self.onBytes?(Array(buffer[0..<n])); continue
                    }
                    if n < 0 {
                        let e = CFReadStreamGetError(self.readStream)
                        if e.error != 0 { self.log?("\(self.role) 读错误 \(e.error)") }
                    }
                    self.closeNow()
                    return
                }
            }
            thread.name = "usbmuxd-tls-read"
            thread.start()
        }

        package func close() { closeNow() }

        private func closeNow() {
            writeLock.lock()
            defer { writeLock.unlock() }
            guard !closed else { return }
            closed = true
            CFReadStreamClose(readStream)
            CFWriteStreamClose(writeStream)
            Darwin.close(fd)
            let handler = onClosed
            DispatchQueue.main.async { handler?() }
        }
    }

    /// 配对记录里的 host 证书/私钥 → SecIdentity（TLS 客户端身份）。
    enum TLSIdentity {
        static func certificates(from pair: [String: Any]) throws -> [Any] {
            guard let cert = pair["HostCertificate"] as? Data,
                  let key = pair["HostPrivateKey"] as? Data else {
                throw MuxError.proto("配对记录缺 HostCertificate/HostPrivateKey")
            }
            var pem = cert
            if pem.last != 0x0a { pem.append(0x0a) }
            pem.append(key)
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("homeplay-tls-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: dir) }
            var keychain: SecKeychain?
            let created = SecKeychainCreate(dir.appendingPathComponent("identity.keychain").path, 0, "", false, nil, &keychain)
            guard created == errSecSuccess, let keychain else {
                throw MuxError.proto("TLS：临时钥匙串创建失败 \(created)")
            }
            defer { SecKeychainDelete(keychain) }
            var format = SecExternalFormat.formatPEMSequence
            var type = SecExternalItemType.itemTypeAggregate
            var items: CFArray?
            let imported = SecItemImport(pem as CFData, nil, &format, &type, [], nil, keychain, &items)
            guard imported == errSecSuccess else {
                throw MuxError.proto("TLS：身份导入失败 \(imported)")
            }
            let query: [String: Any] = [
                kSecClass as String: kSecClassIdentity,
                kSecMatchSearchList as String: [keychain],
                kSecReturnRef as String: true,
                kSecMatchLimit as String: kSecMatchLimitAll,
            ]
            var result: CFTypeRef?
            let found = SecItemCopyMatching(query as CFDictionary, &result)
            guard found == errSecSuccess,
                  let identities = result as? [SecIdentity], let identity = identities.first else {
                throw MuxError.proto("TLS：找不到客户端身份 \(found)")
            }
            return [identity]
        }
    }
}

// MARK: - lockdownd 上的最小客户端（开 carkit 用）

package enum Lockdown {
    package struct Carkit: @unchecked Sendable {
        package let stream: any Usbmuxd.MuxByteStream
    }

    package enum LdError: Error, CustomStringConvertible {
        case stage(String, String)
        package var description: String {
            switch self { case .stage(let s, let d): return "lockdown \(s)：\(d)" }
        }
    }

    /// 走完 QueryType→ProductType→配对记录→StartSession→（需要时 TLS）→StartService(com.apple.carkit.service)。
    /// iOS 15+ 的 StartSession 回复是 `SessionID + EnableSessionSSL`（没有 Result），carkit 服务流也带
    /// `EnableServiceSSL`；两条流都必须切 TLS，carkit 才肯跑 iAP2。
    package static func openCarkit(device: Usbmuxd.Device, log: @escaping (String) -> Void) throws -> Carkit {
        let fd = try Usbmuxd.openConnected(deviceID: device.id, port: Usbmuxd.lockdownPort)
        var handedOff = false
        defer { if !handedOff { Darwin.close(fd) } }

        func fdSend(_ bytes: [UInt8]) throws { try Usbmuxd.writeFully(fd, bytes) }
        func fdRead(_ count: Int) throws -> [UInt8] {
            var buffer = [UInt8](repeating: 0, count: count)
            try Usbmuxd.readFully(fd, &buffer)
            return buffer
        }
        func framed(send: ([UInt8]) throws -> Void, read: (Int) throws -> [UInt8],
                    _ dict: [String: Any]) throws -> [String: Any] {
            let payload = try PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
            var bytes = withUnsafeBytes(of: UInt32(payload.count).bigEndian) { Array($0) }
            bytes.append(contentsOf: Array(payload))
            try send(bytes)
            let header = try read(4)
            let length = UInt32(header[0]) << 24 | UInt32(header[1]) << 16 | UInt32(header[2]) << 8 | UInt32(header[3])
            guard length > 0, length < 4 << 20 else { throw LdError.stage("帧长", "不合理：\(length)") }
            let body = try read(Int(length))
            guard let plist = try? PropertyListSerialization.propertyList(from: Data(body), options: [], format: nil),
                  let reply = plist as? [String: Any] else { throw LdError.stage("回复", "不是 plist") }
            return reply
        }

        let product = try framed(send: fdSend, read: fdRead,
                                 ["Request": "GetValue", "Key": "ProductType", "Label": "HomePlay"])["Value"] as? String
        guard let product, product.hasPrefix("iPhone") else {
            throw LdError.stage("ProductType", "USB 设备不是 iPhone（\(product ?? "nil")）")
        }
        log("lockdown：\(product)")

        let pair = try Usbmuxd.pairRecord(udid: device.serial)
        guard let hostID = pair["HostID"] as? String, let buid = pair["SystemBUID"] as? String else {
            throw LdError.stage("配对记录", "缺 HostID/SystemBUID——先在 Finder 里信任")
        }
        let session = try framed(send: fdSend, read: fdRead,
                                 ["Request": "StartSession", "HostID": hostID, "SystemBUID": buid, "Label": "HomePlay"])
        if let result = session["Result"] as? String, result != "Success" {
            throw LdError.stage("StartSession", "\(result)——信任过期，重新信任一次")
        }
        if session["Result"] == nil, session["SessionID"] == nil, (session["EnableSessionSSL"] as? Bool) != true {
            throw LdError.stage("StartSession", "回复没有 SessionID：\(session.keys.sorted().joined(separator: ","))——信任过期，重新信任一次")
        }

        let tls: Usbmuxd.TLSStream?
        if (session["EnableSessionSSL"] as? Bool) == true {
            let stream = try Usbmuxd.TLSStream(fd: fd, pair: pair)
            stream.log = log
            stream.role = "lockdown TLS"
            tls = stream
            handedOff = true   // TLSStream 接管 fd，defer 不再关
            log("lockdown 会话已加密（TLS）")
        } else {
            tls = nil
        }

        let service: [String: Any]
        if let tls {
            service = try framed(send: { try tls.writeExactly($0) }, read: { try tls.readExactly($0) },
                                 ["Request": "StartService", "Service": "com.apple.carkit.service", "Label": "HomePlay"])
        } else {
            service = try framed(send: fdSend, read: fdRead,
                                 ["Request": "StartService", "Service": "com.apple.carkit.service", "Label": "HomePlay"])
        }
        if let error = service["Error"] as? String {
            throw LdError.stage("StartService", error)
        }
        guard let port = service["Port"] as? Int else {
            throw LdError.stage("StartService", "没有 Port：\(service.keys.sorted().joined(separator: ","))")
        }
        log("carkit 端口 \(port)")

        // 关掉 lockdown 那条流，开真正的 carkit 流；服务要求 TLS 时同样包装
        if let tls { tls.close() }
        let carkitFD = try Usbmuxd.openConnected(deviceID: device.id, port: UInt16(port))
        let stream: any Usbmuxd.MuxByteStream
        if (service["EnableServiceSSL"] as? Bool) == true {
            let t = try Usbmuxd.TLSStream(fd: carkitFD, pair: pair)
            t.log = log
            t.role = "carkit TLS"
            stream = t
        } else {
            stream = Usbmuxd.MuxStream(fd: carkitFD)
        }
        return Carkit(stream: stream)
    }
}
