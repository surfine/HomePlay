// iAP2 探针离线测试：CSM 编解码、链路包编解码与同步交换、MFi 身份加载与签名。
// 全部离线：身份材料现场生成（自签测试身份），不碰蓝牙、不连 iPhone。
import Foundation
import Security
import IAP2
import CryptoKit

func hexBytes(_ s: String) -> [UInt8] {
    var out: [UInt8] = []
    var i = s.startIndex
    while i < s.endIndex {
        let j = s.index(i, offsetBy: 2)
        out.append(UInt8(s[i..<j], radix: 16)!)
        i = j
    }
    return out
}

@main struct Iap2OfflineTests {
    nonisolated(unsafe) static var failures = 0
    static func expect(_ condition: Bool, _ message: String) {
        if condition { print("ok   \(message)") } else { failures += 1; print("FAIL \(message)") }
    }

    static func main() {
        // Wi-Fi 資訊分享：0x5700 沒有參數；0x5701 回狀態＋名稱＋密碼（字串可能帶 NUL）
        do {
            expect(Iap2Csm.requestWiFiInformationFrame().messageId == 0x5700, "wifi info request is 0x5700")
            let reply = Iap2Csm.Frame(messageId: 0x5701, parameters: [
                Iap2Csm.Parameter(id: 0, payload: [0]), Iap2Csm.Parameter(id: 1, payload: [2]),
                Iap2Csm.Parameter(id: 2, payload: Array("家裡".utf8) + [0]), Iap2Csm.Parameter(id: 3, payload: Array("pw".utf8) + [0])])
            let (parsed, _) = Iap2Csm.parse(from: reply.encoded)
            let r = parsed.first.map(Iap2Csm.parseWiFiInformation)
            expect(r?.status == 0 && r?.ssid == "家裡" && r?.passphrase == "pw", "wifi info reply parses status, NUL-terminated ssid, passphrase")
            let declined = Iap2Csm.parseWiFiInformation(Iap2Csm.Frame(messageId: 0x5701, parameters: [Iap2Csm.Parameter(id: 0, payload: [1])]))
            expect(declined.status == 1 && declined.ssid == nil, "declined wifi share has no ssid")
            expect(Iap2Csm.messagesSentByAccessory.contains(0x5700) && Iap2Csm.messagesReceivedFromPhone.contains(0x5701), "wifi info sharing declared in identification")
        }
        // 无线 CarPlay 交接：0x5703 与 0x4301 的字节布局（对照 MacPlay iap2-csm 的编码规则手算）
        do {
            let wifi = Iap2Csm.accessoryWiFiConfiguration(ssid: "AB", passphrase: "pw", security: .wpaWpa2, channel: 36)
            let (parsed, _) = Iap2Csm.parse(from: wifi.encoded)
            expect(parsed.first?.messageId == 0x5703, "wifi config message id")
            let p = parsed.first?.parameters ?? []
            expect(p.map(\.id) == [1, 2, 3, 4], "wifi config parameter ids 1-4")
            expect(p.first?.payload == [0x41, 0x42, 0], "ssid is NUL terminated")
            expect(p.count == 4 && p[2].payload == [2] && p[3].payload == [36], "security wpa/wpa2 = 2, channel 36 as u8")
            // 参数头 = 2 字节长度（含头）+ 2 字节 id：ssid 参数 = 00 07 00 01 41 42 00
            expect(Array(Iap2Csm.Parameter(id: 1, payload: [0x41, 0x42, 0]).encoded) == [0, 7, 0, 1, 0x41, 0x42, 0], "parameter header length includes itself")

            let start = Iap2Csm.carPlayStartSessionWireless(
                ssid: "AB", passphrase: "pw", channel: 149, ipAddresses: ["10.0.0.2", "fe80::1"], security: .wpa3Transition,
                port: 7000, deviceIdentifier: "AA:BB:CC:DD:EE:FF", publicKey: "pk", sourceVersion: "950.7.1")
            let (sp, _) = Iap2Csm.parse(from: start.encoded)
            let top = sp.first?.parameters ?? []
            expect(sp.first?.messageId == 0x4301, "start session message id")
            expect(top.map(\.id) == [1, 2, 3, 4, 5], "start session top-level ids")
            expect(top.count == 5 && top[1].payload == [0, 0, 0x1b, 0x58], "port 7000 as u32 big-endian")
            let group = top.first.flatMap { Iap2Csm.parseParameters($0.payload) } ?? []
            expect(group.map(\.id) == [0, 1, 2, 3, 4], "wireless group ids 0-4")
            expect(group.count == 5 && group[2].payload == [149], "channel 149 as u8")
            expect(group.count == 5 && group[3].payload == Array("10.0.0.2".utf8) + [0] + Array("fe80::1".utf8) + [0], "ip list concatenated in one parameter")
            expect(group.count == 5 && group[4].payload == [3], "security wpa3 transition = 3")

            let avail = Iap2Csm.Frame(messageId: 0x4300, parameters: [
                Iap2Csm.Parameter(id: 1, payload: Iap2Csm.encodeParameters([Iap2Csm.Parameter(id: 0, payload: [1])]))])
            expect(Iap2Csm.wirelessCarPlayAvailable(avail) == true, "availability wireless=true parses")
            expect(Iap2Csm.wirelessCarPlayAvailable(Iap2Csm.Frame(messageId: 0x4300)) == nil, "availability without wireless group is nil")

            // 0x4300 两组属性（有线组 0／无线组 1，各含 available + transport id）：
            // 布局对照 MacPlay iap2-csm car_play.rs 的 CarPlayAvailability。
            let both = Iap2Csm.Frame(messageId: 0x4300, parameters: [
                Iap2Csm.Parameter(id: 0, payload: Iap2Csm.encodeParameters([
                    Iap2Csm.Parameter(id: 0, payload: [1]),
                    Iap2Csm.Parameter(id: 1, payload: Iap2Csm.nul("usb-1")),
                ])),
                Iap2Csm.Parameter(id: 1, payload: Iap2Csm.encodeParameters([
                    Iap2Csm.Parameter(id: 0, payload: [0]),
                    Iap2Csm.Parameter(id: 1, payload: Iap2Csm.nul("bt-1")),
                ])),
            ])
            let decoded = Iap2Csm.carPlayAvailability(both)
            expect(decoded?.wiredAvailable == true && decoded?.wiredTransportId == "usb-1",
                   "0x4300 wired group parses available + transport id")
            expect(decoded?.wirelessAvailable == false && decoded?.wirelessTransportId == "bt-1",
                   "0x4300 wireless group parses available + transport id")
            expect(Iap2Csm.carPlayAvailability(Iap2Csm.Frame(messageId: 0x4300))?.isEmpty == true,
                   "0x4300 without groups is empty")
            expect(Iap2Csm.carPlayAvailability(Iap2Csm.Frame(messageId: 0x4301)) == nil,
                   "non-0x4300 is not decoded")

            // 0x5000 订阅与 0x5001 更新：字节由 MacPlay iap2-csm 编码器生成
            let sub = Iap2Csm.startNowPlayingUpdates()
            // 播放组只发规范里的 0/1/7/16；旧版照 MacPlay 带 12/13，真机 2026-10-20 验证
            // iPhone 会对整条订阅不响应（一个 0x5001 都不来），去掉后立刻恢复。
            expect(sub.encoded.map { String(format: "%02x", $0) }.joined() ==
                   "4040003e500000240000000400000004000100040004000400060004000c0004000e000400100004001a0014000100040000000400010004000700040010",
                   "0x5000 subscription uses only valid iAP2 attribute ids")
            let updateHex = "40400075500100360000000c0000112233445566778800090001536f6e6700000800040002bf20000a0006416c62756d00000b000c41727469737400003900010005000001000800010000a410000a00074d75736963000006000c00640004000d00140010636f6d2e6170706c652e4d7573696300"
            let (frames, _) = Iap2Csm.parse(from: hexBytes(updateHex))
            var np = frames.first.flatMap(Iap2Csm.phoneNowPlaying)
            expect(np?.trackId == 0x1122334455667788 && np?.title == "Song" && np?.artist == "Artist",
                   "0x5001 decodes track identity/title/artist")
            expect(np?.album == "Album" && np?.durationMs == 180000 && np?.elapsedMs == 42000,
                   "0x5001 decodes album/duration/elapsed")
            expect(np?.playing == true && np?.canSeek == true && np?.appBundleID == "com.apple.Music",
                   "0x5001 decodes playback state/app")
            var partial = Iap2Csm.PhoneNowPlaying()
            partial.elapsedMs = 43000; partial.status = 2
            np?.merge(partial)
            expect(np?.title == "Song" && np?.playing == false, "partial update keeps title and updates pause")
            var next = Iap2Csm.PhoneNowPlaying()
            next.trackId = 99; next.title = "Next"
            np?.merge(next)
            expect(np?.title == "Next" && np?.artist == nil, "track change clears stale metadata")
            expect(Iap2Csm.setNowPlayingInformation(elapsedMs: 42000).encoded.map { String(format: "%02x", $0) }.joined() ==
                   "4040000e5003000800000000a410", "0x5003 seek encodes absolute milliseconds (MacPlay fixture)")
        }

        // CSM：帧编码与解析往返
        do {
            let frame = Iap2Csm.identificationInformation(
                name: "Probe", model: "WS2", manufacturer: "WindowShade",
                serialNumber: "S1", firmwareVersion: "0.1", hardwareVersion: "0.1",
                externalAccessoryProtocol: "me.test", bluetoothMac: "AA:BB:CC:DD:EE:FF", ssid: "net")
            let encoded = frame.encoded
            let (parsed, consumed) = Iap2Csm.parse(from: encoded)
            expect(consumed == encoded.count, "identification frame consumes exactly")
            expect(parsed.count == 1 && parsed[0].messageId == 0x1d01, "identification message id parses")
            expect(parsed[0].parameters.count == frame.parameters.count, "identification parameters survive roundtrip")
            expect(parsed[0].parameters.first?.payload == Array("Probe".utf8) + [0], "strings are NUL terminated")
            let macParam = parsed[0].parameters.first { $0.id == 17 }
            let macGroup = macParam.flatMap { Iap2Csm.parseParameters($0.payload) }?.first { $0.id == 3 }
            expect(macGroup?.payload == [0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff], "bluetooth mac group roundtrips")
        }

        // CSM：分块与垃圾字节
        do {
            let frame = Iap2Csm.authenticationResponse(Array(repeating: 0x5a, count: 64))
            let encoded = frame.encoded
            var buffer: [UInt8] = [0x00, 0xff, 0x12] // 垃圾前缀
            for byte in encoded { buffer.append(byte) }
            buffer += [0x40, 0x40, 0x00] // 残缺尾
            let (parsed, consumed) = Iap2Csm.parse(from: buffer)
            expect(parsed.count == 1 && parsed[0].messageId == 0xaa03, "garbage before frame is skipped")
            expect(consumed == buffer.count - 3, "trailing partial frame stays in buffer")
        }

        // 链路：包编码校验为 0，标记与确认
        do {
            let data = Iap2Link.encode(payload: [1, 2, 3, 4], sequence: 100, control: Iap2Link.controlData,
                                       session: Iap2Link.controlSessionId, acknowledgement: 7)
            expect(data[0] == 0xff && data[1] == 0x5a, "packet starts with FF 5A")
            expect(Iap2Link.checksumValid(data), "packet bytes sum to zero")
            let ack = Iap2Link.encode(payload: nil, sequence: 100, control: Iap2Link.controlData,
                                      session: 0, acknowledgement: 7)
            expect(ack.count == 9 && Iap2Link.checksumValid(ack), "ack-only packet is 9 bytes and valid")
        }

        // 链路握手（照 MacPlay LinkEngine 语义）：start＝marker＋SYNC 主动发起；
        // 对端 SYNC → 立刻回 ACK（关键回归：缺这步手机永远进不了控制会话）；
        // 我们的 SYNC 被 ACK 才 ready；数据按序交付。
        do {
            var now: UInt64 = 1000
            var link = Iap2Link(clock: { now })
            link.start()
            var out = link.takeOutput()
            expect(out.starts(with: Iap2Link.marker) && out.count > Iap2Link.marker.count + 9,
                   "start emits marker + sync (initiate)")
            // 对端 marker + 同步
            let peerSync = Iap2Link.Synchronization(maxOutgoing: 12, maxFrameBytes: 4096, sessions: [(10, 0, 1)])
            let peerPacket = Iap2Link.encode(payload: peerSync.encoded, sequence: 50,
                                             control: Iap2Link.controlSynchronize, session: 0, acknowledgement: 0)
            link.feed(Iap2Link.marker + peerPacket)
            out = link.takeOutput()
            expect(out.count == 9 && out[4] & Iap2Link.controlData != 0 && out[6] == 50,
                   "peer sync is answered with a 9-byte ACK carrying their psn")
            var sawReady = false
            while let event = link.pollEvent() {}
            expect(link.state == .negotiating, "still negotiating until OUR sync is acked")
            // 对端 ACK 我们的 SYNC（seq 99）
            let peerAck = Iap2Link.encode(payload: nil, sequence: 50, control: Iap2Link.controlData,
                                          session: 0, acknowledgement: Iap2Link.initialSequence)
            link.feed(peerAck)
            while let event = link.pollEvent() {
                if case .ready = event { sawReady = true }
            }
            expect(sawReady && link.state == .running, "ack of our sync completes negotiation")
            expect(link.peerSynchronization?.maxOutgoing == 12, "peer lsp adopted wholesale")
            // 对方发一条控制会话数据（= 一个 CSM 帧）
            let csm = Iap2Csm.Frame(messageId: Iap2Csm.Mfi.requestCertificate, parameters: []).encoded
            let peerData = Iap2Link.encode(payload: csm, sequence: 51, control: Iap2Link.controlData,
                                           session: Iap2Link.controlSessionId, acknowledgement: 99)
            link.feed(peerData)
            var control: [UInt8]?
            while let event = link.pollEvent() {
                if case .control(let payload) = event { control = payload }
            }
            expect(control == csm, "session-10 payload surfaces as control event")
            let ft = Iap2Link.encode(payload: [7, 0xC0, 0xAA], sequence: 52, control: Iap2Link.controlData,
                                     session: Iap2Link.fileTransferSessionId, acknowledgement: 99)
            link.feed(ft)
            var fileData: [UInt8]?
            while let event = link.pollEvent() {
                if case .fileTransfer(let payload) = event { fileData = payload }
            }
            expect(fileData == [7, 0xC0, 0xAA], "session-12 payload surfaces as fileTransfer event")
            // 我们回包：进窗口、递增序号、按对方参数跟踪
            link.sendControl(Iap2Csm.accessoryCertificate([0x01, 0x02]).encoded)
            out = link.takeOutput()
            expect(out.contains(where: { $0 == 0xaa }) && Iap2Link.checksumValidValid(out), "our reply frames as valid packets")
        }

        // 链路重传：SYNC 没被 ACK 前，每 500ms 重发（marker 不再重复——已进入协商）
        do {
            var now: UInt64 = 0
            var link = Iap2Link(clock: { now })
            link.start()
            _ = link.takeOutput()
            now += 499
            link.tick()
            expect(link.takeOutput().isEmpty, "no resend before the 500ms deadline")
            now += 2
            link.tick()
            let out = link.takeOutput()
            expect(out.count > 9 && out[4] & Iap2Link.controlSynchronize != 0, "sync resent on the 500ms tick")
            expect(out.contains(Iap2Link.marker) == false, "marker is not repeated once negotiating")
        }

        // 文件传输（专辑封面）：单包、分片、取消
        do {
            let single = FileTransferReceiver().feed([7, 0xC0, 0xAA, 0xBB])
            expect(single == [.reply([7, 0x05]), .complete(id: 7, data: Data([0xAA, 0xBB]))],
                   "file transfer FIRST_AND_ONLY_DATA completes with SUCCESS")
            let r = FileTransferReceiver()
            expect(r.feed([3, 0x04]) == [.reply([3, 0x01])], "file transfer SETUP replies START")
            expect(r.feed([3, 0x80, 1, 2]).isEmpty, "file transfer FIRST_DATA buffers")
            expect(r.feed([3, 0x00, 3, 4]).isEmpty, "file transfer DATA buffers")
            expect(r.feed([3, 0x40, 5]) == [.reply([3, 0x05]), .complete(id: 3, data: Data([1, 2, 3, 4, 5]))],
                   "file transfer LAST_DATA reassembles")
            let c = FileTransferReceiver()
            _ = c.feed([9, 0x80, 1])
            expect(c.feed([9, 0x02]).isEmpty && c.feed([9, 0x40, 2]).last != nil, "file transfer CANCEL drops the buffer")
        }

        // MFi：现场生成身份 → pk8/证书文件 → 加载自检 → 签名/验签往返
        do {
            let (pkcs8, certificateDer) = Self.generateTestIdentity()
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("iap2-test-\(UUID().uuidString)", isDirectory: true)
            try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try! Data(pkcs8).write(to: dir.appendingPathComponent("identity.pk8"))
            try! Data(certificateDer).write(to: dir.appendingPathComponent("certificate.p7b"))
            defer { try? FileManager.default.removeItem(at: dir) }

            let identity = try? Iap2MfiIdentity(directory: dir.path)
            expect(identity != nil, "self-generated identity loads and self-checks")
            guard let identity else { return }
            let digest = Array(SHA256.hash(data: Data("challenge from phone".utf8)))
            let raw = try? identity.sign(digest: digest)
            expect(raw?.count == 64, "signature is 64-byte raw r||s")
            // 用证书公钥验证
            let publicKey = Iap2MfiIdentity.certificatePublicKey(identity.certificate)
            expect(publicKey != nil, "certificate public key extracts")
            if let publicKey, let raw {
                expect(Iap2MfiIdentity.verify(signed: raw, of: digest, with: publicKey),
                       "raw signature verifies against certificate key")
            }
            // 坏摘要签名验证必须失败
            if let publicKey, let raw {
                let other = Array(SHA256.hash(data: Data("other".utf8)))
                expect(!Iap2MfiIdentity.verify(signed: raw, of: other, with: publicKey),
                       "signature fails against a different digest")
            }
            // 缺文件拒绝
            let empty = FileManager.default.temporaryDirectory
                .appendingPathComponent("iap2-empty-\(UUID().uuidString)", isDirectory: true)
            try! FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: empty) }
            expect((try? Iap2MfiIdentity(directory: empty.path)) == nil, "missing files refuse to load")
        }

        // MFi：PKCS#7 容器（.p7b）——MacPlay/DiPlay 带的格式。证书原样字节保留，
        // 公钥从容器里的 X.509 取出来做自检（对照 MacPlay iap2-mfi/local.rs：证书不拆包、原样进 0xAA01）。
        do {
            let (pkcs8, certificateDer) = Self.generateTestIdentity()
            func tlv(_ tag: UInt8, _ content: [UInt8]) -> [UInt8] {
                [tag] + Self.DERLength(content.count) + content
            }
            let oidSignedData = tlv(0x06, [0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x07, 0x02]) // 1.2.840.113549.1.7.2
            let oidData = tlv(0x06, [0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x07, 0x01])        // 1.2.840.113549.1.7.1
            // SignedData ::= SEQUENCE { INTEGER 1, SET {}, SEQUENCE{OID data}, [0]{ cert } }
            let signedData = tlv(0x30, tlv(0x02, [0x01]) + tlv(0x31, []) + tlv(0x30, oidData) + tlv(0xa0, certificateDer))
            let container = tlv(0x30, oidSignedData + tlv(0xa0, signedData))
            expect(container.count > certificateDer.count, "p7b container wraps the certificate")

            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("iap2-p7b-\(UUID().uuidString)", isDirectory: true)
            try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try! Data(pkcs8).write(to: dir.appendingPathComponent("identity.pk8"))
            try! Data(container).write(to: dir.appendingPathComponent("certificate.p7b"))
            defer { try? FileManager.default.removeItem(at: dir) }

            let identity = try? Iap2MfiIdentity(directory: dir.path)
            expect(identity != nil, "p7b-container identity loads and self-checks")
            guard let identity else { return }
            expect(identity.certificate == container, "certificate bytes stay verbatim (what goes into 0xAA01)")
            let digest = Array(SHA256.hash(data: Data("p7b challenge".utf8)))
            let raw = try? identity.sign(digest: digest)
            let publicKey = Iap2MfiIdentity.certificatePublicKey(identity.certificate)
            if let publicKey, let raw {
                expect(Iap2MfiIdentity.verify(signed: raw, of: digest, with: publicKey),
                       "p7b signature verifies against key extracted from container")
            }
        }

        // usbmuxd：plist 模式帧头（小端：总长/version=1/request=8/tag）与 Connect 的端口字节序
        do {
            let bytes = Usbmuxd.encode(tag: 7, message: ["MessageType": "ListDevices", "ProgName": "T"])
            func le32(_ o: Int) -> UInt32 {
                UInt32(bytes[o]) | UInt32(bytes[o+1]) << 8 | UInt32(bytes[o+2]) << 16 | UInt32(bytes[o+3]) << 24
            }
            expect(le32(4) == 1 && le32(8) == 8 && le32(12) == 7, "usbmuxd header version/request/tag little-endian")
            expect(le32(0) == bytes.count, "usbmuxd header length includes 16-byte header")
            guard let plist = try? PropertyListSerialization.propertyList(from: Data(bytes[16...]), options: [], format: nil),
                  let dict = plist as? [String: Any] else { expect(false, "usbmuxd body is a plist"); return }
            expect((dict["MessageType"] as? String) == "ListDevices", "usbmuxd body carries MessageType")

            // Connect 的 PortNumber 按 libusbmuxd 惯例存 htons 后的数值（62078=0xF27E → 0x7EF2=32498）
            let connect = Usbmuxd.encode(tag: 9, message: ["MessageType": "Connect", "PortNumber": Int(UInt16(62078).bigEndian)])
            guard let cp = try? PropertyListSerialization.propertyList(from: Data(connect[16...]), options: [], format: nil),
                  let cd = cp as? [String: Any] else { expect(false, "connect body is a plist"); return }
            expect((cd["PortNumber"] as? Int) == 32498, "Connect PortNumber is the htons value (32498)")
        }

        // usbmuxd ListDevices：新系统把 SerialNumber/ConnectionType 放在 Properties，旧系统在顶层
        do {
            let modern: [String: Any] = ["DeviceList": [[
                "DeviceID": 18,
                "Properties": ["SerialNumber": "a5a492cc2405feb6c108a72a17a2b5664cfde865", "ConnectionType": "USB"],
            ]]]
            let legacy: [String: Any] = ["DeviceList": [[
                "DeviceID": 7, "SerialNumber": "00008030-0000000000000001", "ConnectionType": "USB",
            ]]]
            let network: [String: Any] = ["DeviceList": [[
                "DeviceID": 9,
                "Properties": ["SerialNumber": "00008120-0000000000000002", "ConnectionType": "Network"],
            ]]]
            let modernDevices = Usbmuxd.parseDeviceList(modern)
            expect(modernDevices.count == 1 && modernDevices[0].serial.hasPrefix("a5a492cc") && modernDevices[0].id == 18,
                   "usbmuxd Properties-format USB device is listed")
            let legacyDevices = Usbmuxd.parseDeviceList(legacy)
            expect(legacyDevices.count == 1 && legacyDevices[0].id == 7, "usbmuxd legacy top-level USB device is listed")
            expect(Usbmuxd.parseDeviceList(network).isEmpty, "usbmuxd Network device is filtered out")

            // ReadPairRecord：本机成功回复只有 PairRecordData（没有 Number）
            let inner = try! PropertyListSerialization.data(
                fromPropertyList: ["HostID": "H", "SystemBUID": "B"], format: .xml, options: 0)
            let modernPair = try? Usbmuxd.parsePairRecord(["PairRecordData": inner])
            expect(modernPair?["HostID"] as? String == "H", "ReadPairRecord without Number parses PairRecordData")
            let legacyPair = try? Usbmuxd.parsePairRecord(["Number": 0, "PairRecordData": inner])
            expect(legacyPair?["HostID"] as? String == "H", "ReadPairRecord with Number 0 parses PairRecordData")
            var rejected = false
            do { _ = try Usbmuxd.parsePairRecord(["Number": 5]) } catch { rejected = true }
            expect(rejected, "ReadPairRecord non-zero Number is rejected")
        }

        // 有线版 0x4301：参数 0＝有线组（子 0＝IP 列表 NUL 连接）、2＝端口 BE、3/4/5＝deviceID/公钥/版本
        do {
            let frame = Iap2Csm.carPlayStartSessionWired(
                ipAddresses: ["fe80::1a:2b"], port: 17000, deviceIdentifier: "AA:BB:CC:DD:EE:FF",
                publicKey: "pk", sourceVersion: "950.7.1")
            let (parsed, consumed) = Iap2Csm.parse(from: frame.encoded)
            expect(consumed == frame.encoded.count, "wired start session consumes exactly")
            expect(parsed.first?.messageId == 0x4301, "wired start session message id")
            let top = parsed.first?.parameters ?? []
            expect(top.map(\.id) == [0, 2, 3, 4, 5], "wired top-level ids (no wireless group)")
            expect(top.count > 1 && top[1].payload == [0, 0, 0x42, 0x68], "port 17000 big-endian")
            let group = top.first.flatMap { Iap2Csm.parseParameters($0.payload) } ?? []
            expect(group.map(\.id) == [0], "wired group has only the ip list child")
            expect(group.first?.payload == Array("fe80::1a:2b".utf8) + [0], "wired ip list NUL terminated")
        }

        // 退避策略（车机式蓝牙重连）：梯子 5/10/20/30/60 之后保持 60；live 慢速不推进；认证成功归零
        do {
            var b = BackoffSchedule(ladder: [5, 10, 20, 30, 60], slow: 60)
            var delays: [TimeInterval] = []
            for _ in 0..<7 { delays.append(b.next(live: false)) }
            expect(delays == [5, 10, 20, 30, 60, 60, 60], "backoff ladder then cap at 60: \(delays)")
            expect(b.step == 7, "step advances beyond ladder")

            b.reset()
            expect(b.next(live: false) == 5, "reset restarts the ladder")

            b = BackoffSchedule(ladder: [5, 10, 20, 30, 60], slow: 60)
            expect(b.next(live: true) == 60 && b.step == 0, "live uses slow delay without advancing")
            expect(b.next(live: true) == 60 && b.step == 0, "live stays at slow and never advances")
            expect(b.next(live: false) == 5, "after live window, ladder starts from the top")
        }

        // 蓝牙首次配对规则：没配过 iPhone → 引导手机去系统蓝牙配对；配过 → 刷新那台的 SDP
        do {
            let phone = (address: "AA:BB:CC:DD:EE:FF", name: "Aaron’s iPhone")
            let headphones = (address: "11:22:33:44:55:66", name: "AirPods")
            expect(PairingRules.action(pairedPhones: [], preferred: nil) == .pairOnPhone,
                   "no paired phone → Bluetooth pairing guide")
            expect(PairingRules.action(pairedPhones: [], preferred: phone.address) == .pairOnPhone,
                   "stale preferred address is not a pairing")
            expect(PairingRules.action(pairedPhones: [phone], preferred: nil) == .refreshSDP(phone.address),
                   "paired phone → refresh its SDP")
            expect(PairingRules.action(pairedPhones: [phone], preferred: headphones.address) == .refreshSDP(phone.address),
                   "preferred address from another device is ignored")
            expect(PairingRules.action(pairedPhones: [phone],
                                       preferred: phone.address.lowercased()) == .refreshSDP(phone.address),
                   "preferred address is normalized")

            let baseline: Set<String> = [headphones.address]
            let fresh = PairingRules.newlyPaired([headphones, phone], baseline: baseline)
            expect(fresh.count == 1 && fresh.first?.address == phone.address,
                   "only the newly paired phone is picked up")
            expect(PairingRules.newlyPaired([headphones], baseline: baseline).isEmpty,
                   "old devices are not mistaken for a new pairing")
            expect(PairingRules.newlyPaired([phone], baseline: [phone.address.replacingOccurrences(of: ":", with: "-").lowercased()])
                   .isEmpty, "baseline comparison ignores separators and case")
            expect(PairingRules.normalize("50-3b-70-cb-ae-56") == "50:3B:70:CB:AE:56",
                   "dash-form Bluetooth address normalizes to colon form")
            expect(PairingRules.normalize("aa:bb:cc:dd:ee:ff") == "AA:BB:CC:DD:EE:FF",
                   "address normalization uppercases")

            // 手机主动连入：必须是已配对手机；平时只接受当前选定，配对引导期间放宽。
            // 不靠名字判断（iPhone 可以被命名成任意字符串）：引导期间任何新连入都接管，
            // 因为那时它一定是刚配对、设备类/SDP 还没进 pairedPhones 的新设备。
            expect(!PairingRules.acceptsIncoming(address: phone.address, pairedPhones: [], preferred: nil, pairingGuide: false),
                   "incoming from an unknown phone is rejected")
            expect(PairingRules.acceptsIncoming(address: phone.address, pairedPhones: [phone], preferred: nil, pairingGuide: false),
                   "incoming from a paired phone is accepted when nothing is chosen")
            expect(PairingRules.acceptsIncoming(address: phone.address.lowercased(), pairedPhones: [phone],
                                                preferred: phone.address, pairingGuide: false),
                   "incoming from the selected phone is accepted across formats")
            let secondPhone = (address: "22:33:44:55:66:77", name: "iPhone 15")
            expect(!PairingRules.acceptsIncoming(address: secondPhone.address, pairedPhones: [phone],
                                                  preferred: phone.address, pairingGuide: false),
                   "incoming from a different paired phone is rejected")
            expect(PairingRules.acceptsIncoming(address: secondPhone.address, pairedPhones: [phone, secondPhone],
                                                preferred: phone.address, pairingGuide: true),
                   "pairing guide accepts a newly paired phone")
            expect(PairingRules.acceptsIncoming(address: "33:44:55:66:77:88",
                                                pairedPhones: [phone], preferred: phone.address, pairingGuide: true),
                   "pairing guide accepts a just-paired device before the cache updates (any name)")
            expect(PairingRules.acceptsIncoming(address: "33:44:55:66:77:89",
                                                pairedPhones: [phone], preferred: phone.address, pairingGuide: true),
                   "pairing guide acceptance does not depend on the device name")
        }

        // CarPlay 传输策略（纯规则）：USB 链路上 0x4300 回哪种 0x4301、拔线怎么处理、另一台手机插线要不要顶掉
        do {
            typealias P = CarPlayTransportPolicy
            // 0x4301 的选择
            expect(P.startReply(wiredAvailable: true, wirelessAvailable: true, wifiReady: true, wifiConfigSent: true,
                                ncmReady: true, wirelessTried: false) == .wireless,
                   "wireless available + Wi-Fi ready → wireless 0x4301 even when NCM is ready")
            expect(P.startReply(wiredAvailable: true, wirelessAvailable: true, wifiReady: true, wifiConfigSent: false,
                                ncmReady: true, wirelessTried: false) == .pushWiFiConfigThenWireless,
                   "no 0x5703 given yet → push Wi-Fi config first, then wireless 0x4301")
            expect(P.startReply(wiredAvailable: true, wirelessAvailable: false, wifiReady: true, wifiConfigSent: true,
                                ncmReady: true, wirelessTried: false) == .wired,
                   "phone reports wired only → wired 0x4301")
            expect(P.startReply(wiredAvailable: true, wirelessAvailable: true, wifiReady: false, wifiConfigSent: true,
                                ncmReady: true, wirelessTried: false) == .wired,
                   "Mac has no Wi-Fi → wired 0x4301")
            expect(P.startReply(wiredAvailable: true, wirelessAvailable: false, wifiReady: true, wifiConfigSent: true,
                                ncmReady: false, wirelessTried: false) == .waitNCM,
                   "wired only but NCM not ready → waitNCM")
            expect(P.startReply(wiredAvailable: true, wirelessAvailable: true, wifiReady: true, wifiConfigSent: true,
                                ncmReady: true, wirelessTried: true) == .wired,
                   "wireless tried and no reconnect → fall back to wired 0x4301")
            expect(P.startReply(wiredAvailable: false, wirelessAvailable: true, wifiReady: true, wifiConfigSent: true,
                                ncmReady: false, wirelessTried: true) == .wireless,
                   "wireless only and already tried → retry wireless (nothing to fall back to)")
            expect(P.startReply(wiredAvailable: false, wirelessAvailable: false, wifiReady: true, wifiConfigSent: true,
                                ncmReady: true, wirelessTried: false) == .none,
                   "nothing available → none")
            expect(P.startReply(wiredAvailable: false, wirelessAvailable: true, wifiReady: false, wifiConfigSent: false,
                                ncmReady: false, wirelessTried: false) == .none,
                   "wireless only but Mac has no Wi-Fi → none")
            // 拔线
            expect(P.onCableGone(live: true, transport: .wifi) == [.resumeBluetooth, .keepSession],
                   "cable gone during a Wi-Fi session: no freeze, Bluetooth standby, keep the session")
            expect(P.onCableGone(live: true, transport: .usbNCM) == [.freezeFrame, .resumeBluetooth, .expectReconnect],
                   "cable gone during a USB NCM session: freeze, Bluetooth standby, expect reconnect")
            expect(P.onCableGone(live: true, transport: nil) == [.freezeFrame, .resumeBluetooth, .expectReconnect],
                   "cable gone with unknown transport behaves like NCM")
            expect(P.onCableGone(live: false, transport: nil) == [.resumeBluetooth],
                   "cable gone with no session: only Bluetooth standby")
            // 另一台 USB 手机
            expect(P.onNewUSBPhone(liveOwner: nil, newPhone: "E0:C7:67:DE:D7:CE") == .ignore,
                   "no live owner → nothing to switch")
            expect(P.onNewUSBPhone(liveOwner: "e0:c7:67:de:d7:ce", newPhone: "E0-C7-67-DE-D7-CE") == .ignore,
                   "same phone in other case/dash format → ignore")
            expect(P.onNewUSBPhone(liveOwner: "E0:C7:67:DE:D7:CE", newPhone: "50:3B:70:CB:AE:56") == .switchPhone,
                   "different phone → switchPhone")
            expect(P.onNewUSBPhone(liveOwner: "a5a492cc2405feb6c108a72a17a2b5664cfde865",
                                   newPhone: "a5a492cc2405feb6c108a72a17a2b5664cfde865") == .ignore,
                   "USB serial compares as-is (same)")
            expect(P.onNewUSBPhone(liveOwner: "a5a492cc2405feb6c108a72a17a2b5664cfde865",
                                   newPhone: "000081600006205C1AC00036") == .switchPhone,
                   "USB serial compares as-is (different)")
            // 对端地址 → 传输
            expect(P.transport(forPeer: "fe80::14ca:10ff:7e2f:e038%en13", ncmInterfaces: ["en13"]) == .usbNCM,
                   "fe80 on the phone's NCM interface → USB NCM")
            expect(P.transport(forPeer: "fe80::14ca:10ff:7e2f:e038%en0", ncmInterfaces: ["en13"]) == .wifi,
                   "fe80 on en0 (Wi-Fi link-local fallback) → Wi-Fi")
            expect(P.transport(forPeer: "192.168.5.28", ncmInterfaces: ["en13"]) == .wifi,
                   "plain IPv4 → Wi-Fi")
            expect(P.transport(forPeer: "fe80::1%en13", ncmInterfaces: []) == .wifi,
                   "no NCM interfaces known → Wi-Fi")
            // 拔线去抖
            var cable = CableDebounce(misses: 2)
            expect(cable.observe(present: true) == true, "device seen → present")
            expect(cable.observe(present: false) == true, "one empty poll is a glitch, still present")
            expect(cable.observe(present: false) == false, "two empty polls → unplugged")
            expect(cable.observe(present: false) == false, "stays unplugged")
            expect(cable.observe(present: true) == true, "device back → present immediately")
            expect(cable.observe(present: false) == true && cable.observe(present: false) == false,
                   "miss counter was reset by the reappearance")
            var fresh = CableDebounce()
            expect(fresh.observe(present: false) == false, "never seen a device → not present")
        }

        // MFi：仓库自带的真实身份（identity/，DiPlay 公开实验性身份，2026-10-18 起 HomePlay 自带；
        // 旧约定"不带身份、不读其他项目附带的身份"已由 Aaron 推翻，见 docs/plan.md 边界段）。
        // HOMEPLAY_IDENTITY_DIR 可指向别的目录覆盖。
        do {
            let defaultDir = URL(fileURLWithPath: #filePath)          // …/Sources/iap2-offline-tests/OfflineTests.swift
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("identity")
            let identityDir = ProcessInfo.processInfo.environment["HOMEPLAY_IDENTITY_DIR"] ?? defaultDir.path
            let identity = try? Iap2MfiIdentity(directory: identityDir)
            expect(identity != nil, "bundled identity at \(identityDir) loads and self-checks")
            if let identity {
                let digest = Array(SHA256.hash(data: Data("real identity check".utf8)))
                let raw = try? identity.sign(digest: digest)
                let publicKey = Iap2MfiIdentity.certificatePublicKey(identity.certificate)
                expect(raw?.count == 64 && publicKey != nil, "bundled identity signs and its certificate key extracts")
                if let publicKey, let raw {
                    expect(Iap2MfiIdentity.verify(signed: raw, of: digest, with: publicKey),
                           "bundled identity signature verifies")
                }
            }
        }

        // 通話狀態 0x4155／通訊狀態 0x4158。receiver.log 只記了訊息 ID（2026-10-22：0x4155 76 次、0x4158 311 次，
        // 都在訂閱後立刻來、當天沒有電話），沒有位元組；這裡用 MacPlay iap2-csm tests/vectors.txt 的向量，
        // 加上訂閱後那筆「沒有通話」的形狀（status 0）。之後的 0x4155 會以 raw= 記進 log，可補真機樣本。
        do {
            let ringing = Iap2Csm.parse(from: hexBytes(
                "404000324155001200002b34393137303132333435363700000a0001416c696365000005000202000b0004757569642d3100")).frames
            expect(ringing.count == 1 && ringing.first?.messageId == Iap2Csm.Communications.callStateUpdate, "0x4155 sample parses as one frame")
            let call = ringing.first.flatMap(Iap2Csm.callState)
            expect(call?.remoteID == "+491701234567" && call?.displayName == "Alice" && call?.callUUID == "uuid-1",
                   "0x4155 remote id, display name and call uuid (NUL stripped)")
            expect(call?.status == 2 && call?.phase == .ringing && call?.direction == nil, "0x4155 status 2 = ringing")
            let idle = Iap2Csm.parse(from: hexBytes("4040001641550005000200000b0004757569642d3100")).frames
            expect(idle.first.flatMap(Iap2Csm.callState)?.phase == .idle, "0x4155 status 0 after subscribe = idle")
            expect(Iap2Csm.callState(Iap2Csm.Frame(messageId: 0x5001)) == nil, "callState ignores other messages")

            func update(_ uuid: String, status: UInt8, direction: UInt8? = nil, name: String? = nil) -> Iap2Csm.CallState {
                var params = [Iap2Csm.Parameter(id: 2, payload: [status]),
                              Iap2Csm.Parameter(id: 4, payload: Array(uuid.utf8) + [0])]
                if let direction { params.append(Iap2Csm.Parameter(id: 3, payload: [direction])) }
                if let name { params.append(Iap2Csm.Parameter(id: 1, payload: Array(name.utf8) + [0])) }
                let encoded = Iap2Csm.Frame(messageId: 0x4155, parameters: params).encoded
                return Iap2Csm.parse(from: encoded).frames.first.flatMap(Iap2Csm.callState) ?? Iap2Csm.CallState()
            }
            var book = Iap2Csm.CallBook()
            expect(book.json == #"{"state":"idle","type":"call"}"#, "empty call book → idle json")
            if let first = ringing.first.flatMap(Iap2Csm.callState) { book.apply(first) }
            book.apply(update("uuid-1", status: 2, direction: 1))
            expect(book.current?.phase == .ringing && book.current?.displayName == "Alice" && book.current?.incoming == true,
                   "incremental update keeps the caller name")
            expect(book.json == #"{"incoming":true,"name":"Alice","number":"+491701234567","state":"ringing","type":"call","uuid":"uuid-1"}"#,
                   "ringing json for the pet")
            book.apply(update("uuid-1", status: 3, direction: 1))
            expect(book.current?.phase == .active, "incoming call connecting after answer = active")
            book.apply(update("uuid-2", status: 2, direction: 1, name: "Bob"))
            expect(book.current?.displayName == "Bob" && book.calls.count == 2, "second incoming call (call waiting) wins while ringing")
            book.apply(update("uuid-2", status: 0))
            expect(book.current?.callUUID == "uuid-1" && book.calls.count == 1, "declined second call drops out")
            book.apply(update("uuid-1", status: 6))
            expect(book.current == nil && book.json.contains(#""state":"idle""#), "disconnecting = idle")
            book.apply(update("uuid-3", status: 1, direction: 2))
            expect(book.current?.phase == .dialing, "outgoing sending = dialing")
            book.apply(update("uuid-3", status: 3, direction: 2))
            expect(book.current?.phase == .dialing, "outgoing connecting is still dialing")

            let comm = Iap2Csm.parse(from: hexBytes("40400017415800050000040005000200000700046f3200")).frames
            let c = comm.first.flatMap(Iap2Csm.communications)
            expect(c?.signalStrength == 4 && c?.airplaneMode == false && c?.carrierName == "o2",
                   "0x4158 signal, airplane mode and carrier")
            expect(c?.json == #"{"airplane":false,"carrier":"o2","signal":4,"type":"cellular"}"#, "cellular json for the pet")
            var merged = c ?? Iap2Csm.CommunicationsState()
            var signalOnly = Iap2Csm.CommunicationsState(); signalOnly.signalStrength = 2
            merged.merge(signalOnly)
            expect(merged.carrierName == "o2" && merged.signalStrength == 2, "0x4158 incremental update keeps carrier")
            expect(Iap2Csm.CommunicationsState().json == nil, "empty communications → no json")
        }

        // disableBluetooth 之後：手機沒 SETUP 流 130 就留藍牙 iAP2，斷了也快速重連
        do {
            typealias P = CarPlayTransportPolicy
            expect(P.bluetoothAfterDisable(tunnelSetUp: false) == .keep, "no stream 130 → keep Bluetooth iAP2")
            expect(P.bluetoothAfterDisable(tunnelSetUp: true) == .tunnelCarries, "stream 130 set up → tunnel carries iAP2")
            expect(P.bluetoothRetryIsSlow(live: true, keepBluetooth: false), "live session with tunnel → slow Bluetooth keepalive")
            expect(!P.bluetoothRetryIsSlow(live: true, keepBluetooth: true), "Bluetooth is the only iAP2 path → fast retry while live")
            expect(!P.bluetoothRetryIsSlow(live: false, keepBluetooth: false), "no session → normal backoff")
        }

        // 连线状态机情境（docs/design-drafts/連線狀態機.md）
        ConnectionMachineTests.run(expect)
        // 首次配对连不上：失败树与诊断报告
        ConnectDiagnosticsTests.run(expect)

        if failures > 0 { print("\(failures) FAILED"); exit(1) }
        print("PASS iap2 offline")
    }

    /// 生成一份测试身份：PKCS#8 EC P-256 私钥 + 自签证书（DER）。
    /// 只用于离线验证签路；不代表任何真实 MFi 身份。
    static func generateTestIdentity() -> (pkcs8: [UInt8], certificate: [UInt8]) {
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256,
        ]
        var error: Unmanaged<CFError>?
        let key = SecKeyCreateRandomKey(attributes as CFDictionary, &error)!

        // Security 的私钥外部表示是 04||标量32||X||Y64（97 字节）。
        let sec1 = [UInt8]((SecKeyCopyExternalRepresentation(key, nil) as Data?) ?? Data())
        let publicKey = [UInt8]((SecKeyCopyExternalRepresentation(SecKeyCopyPublicKey(key)!, nil) as Data?) ?? Data())

        // 全部用 tlv 拼装，不手写长度字节。
        func tlv(_ tag: UInt8, _ content: [UInt8]) -> [UInt8] {
            [tag] + DERLength(content.count) + content
        }
        let oidEC = tlv(0x06, [0x2a, 0x86, 0x48, 0xce, 0x3d, 0x02, 0x01])          // id-ecPublicKey
        let oidP256 = tlv(0x06, [0x2a, 0x86, 0x48, 0xce, 0x3d, 0x03, 0x01, 0x07])   // prime256v1
        let alg = tlv(0x30, oidEC + oidP256)

        // PKCS#8：SEQUENCE{ INTEGER 0, alg, OCTET STRING sec1 }
        let pkcs8 = tlv(0x30, tlv(0x02, [0x00]) + alg + tlv(0x04, sec1))

        // 最小 X.509 自签证书：取公钥用，验真交给 iPhone。
        let name = tlv(0x30, tlv(0x31, tlv(0x30, tlv(0x06, [0x55, 0x04, 0x03]) + tlv(0x0c, Array("probe".utf8)))))
        let utc = Array("260101000000Z".utf8)
        let utc2 = Array("460101000000Z".utf8)
        let validity = tlv(0x30, tlv(0x17, utc) + tlv(0x17, utc2))
        let spki = tlv(0x30, alg + tlv(0x03, [0x00] + publicKey))
        let tbs = tlv(0x30, [
            tlv(0xa0, tlv(0x02, [0x02])),   // 版本 3
            tlv(0x02, [0x01]),              // 序列号 1
            alg,
            name, validity, name, spki,
        ].flatMap { $0 })
        let tbsDigest = Array(SHA256.hash(data: Data(tbs)))
        let sigDer = [UInt8]((SecKeyCreateSignature(key, SecKeyAlgorithm.ecdsaSignatureDigestX962SHA256,
                                                    Data(tbsDigest) as CFData, nil) as Data?) ?? Data())
        let certificate = tlv(0x30, tbs + alg + tlv(0x03, [0x00] + sigDer))

        return (pkcs8, certificate)
    }

    static func DERLength(_ count: Int) -> [UInt8] {
        if count < 0x80 { return [UInt8(count)] }
        if count <= 0xff { return [0x81, UInt8(count)] }
        return [0x82, UInt8(count >> 8), UInt8(count & 0xff)]
    }
}

// 链路包整体校验的辅助：写出的字节流里每个 FF 5A 包都要过校验。
extension Iap2Link {
    static func checksumValidValid(_ stream: [UInt8]) -> Bool {
        var index = 0
        var checked = 0
        while index + 2 <= stream.count {
            guard stream[index] == 0xff, stream[index + 1] == 0x5a else { index += 1; continue }
            guard index + 4 <= stream.count else { return false }
            let length = Int(stream[index + 2]) << 8 | Int(stream[index + 3])
            guard length >= 9, index + length <= stream.count else { return false }
            if !checksumValid(Array(stream[index..<(index + length)])) { return false }
            index += length
            checked += 1
        }
        return checked > 0
    }
}
