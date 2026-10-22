// CarPlay 的 HID 设备：多点触控、旋钮、媒体键、电话键（对应 MacPlay protocol/hid.ts）。
import Foundation

package struct HIDContact: Equatable {
    package var id: Int
    package var x: Double      // 流像素
    package var y: Double
    package var down: Bool
    package init(id: Int, x: Double, y: Double, down: Bool) { self.id = id; self.x = x; self.y = y; self.down = down }
}

package struct KnobState {
    package var select = false, home = false, back = false
    package var x = 0, y = 0, wheel = 0
    package init(select: Bool = false, home: Bool = false, back: Bool = false, x: Int = 0, y: Int = 0, wheel: Int = 0) {
        self.select = select; self.home = home; self.back = back; self.x = x; self.y = y; self.wheel = wheel
    }
}

package enum HID {
    package static let touchUID: UInt32 = 0x2a2a2a2a
    package static let knobUID: UInt32 = 0x2a2a2a2b
    package static let mediaUID: UInt32 = 0x2a2a2a2c
    package static let telephonyUID: UInt32 = 0x2a2a2a2d
    package static let touchContacts = 2
    static let bytesPerFinger = 6

    package enum MediaButton: UInt8 { case none = 0, play, pause, playPause, next, prev, navGuidance }
    package enum TelephonyButton: UInt8 {
        case none = 0, hookSwitch, flash, drop, mute, key0, key1, key2, key3, key4, key5, key6, key7, key8, key9, star, pound, del
    }

    /// 桌寵來電卡的按鍵 → 電話 HID：接聽＝hookSwitch（摘機），拒接／掛斷＝drop（MacPlay sendTelephony 同款）。
    /// 輸入是 `{"type":"telephony","command":"answer"|"decline"|"hangup"}`；別的回 nil。
    package static func telephonyButton(forPetMessage text: String) -> TelephonyButton? {
        guard text.contains("\"type\":\"telephony\"") else { return nil }
        if text.contains("\"command\":\"answer\"") { return .hookSwitch }
        if text.contains("\"command\":\"decline\"") || text.contains("\"command\":\"hangup\"") { return .drop }
        return nil
    }

    // MARK: 描述符

    private static func fingerCollection(xMax: Int, yMax: Int) -> [UInt8] {
        [0x05, 0x0d, 0x09, 0x22, 0xa1, 0x02,
         0x09, 0x38, 0x75, 0x08, 0x95, 0x01, 0x81, 0x02,
         0x15, 0x00, 0x25, 0x01, 0x09, 0x33, 0x75, 0x01, 0x95, 0x01, 0x81, 0x02,
         0x95, 0x07, 0x81, 0x03,
         0x05, 0x01, 0x26, UInt8(xMax & 0xff), UInt8((xMax >> 8) & 0xff), 0x09, 0x30, 0x75, 0x10, 0x95, 0x01, 0x81, 0x02,
         0x26, UInt8(yMax & 0xff), UInt8((yMax >> 8) & 0xff), 0x09, 0x31, 0x81, 0x02,
         0xc0]
    }

    package static func touchDescriptor(xMax: Int, yMax: Int) -> Data {
        var b: [UInt8] = [0x05, 0x0d, 0x09, 0x04, 0xa1, 0x01]
        for _ in 0..<touchContacts { b += fingerCollection(xMax: xMax, yMax: yMax) }
        b.append(0xc0)
        return Data(b)
    }

    package static let knobDescriptor = Data([
        0x05, 0x01, 0x09, 0x08, 0xa1, 0x01, 0x05, 0x09, 0x09, 0x01, 0x15, 0x00, 0x25, 0x01, 0x75, 0x01, 0x95, 0x01, 0x81, 0x02,
        0x05, 0x0c, 0x0a, 0x23, 0x02, 0x0a, 0x24, 0x02, 0x95, 0x02, 0x81, 0x02, 0x95, 0x05, 0x81, 0x01,
        0x05, 0x01, 0x09, 0x01, 0xa1, 0x00, 0x09, 0x30, 0x09, 0x31, 0x15, 0x81, 0x25, 0x7f, 0x75, 0x08, 0x95, 0x02, 0x81, 0x02, 0xc0,
        0x09, 0x38, 0x15, 0x81, 0x25, 0x7f, 0x75, 0x08, 0x95, 0x01, 0x81, 0x06, 0xc0])

    package static let mediaDescriptor = Data([
        0x05, 0x0c, 0x09, 0x01, 0xa1, 0x01, 0x15, 0x00, 0x25, 0x06, 0x05, 0x0c,
        0x0a, 0x00, 0x00, 0x0a, 0xb0, 0x00, 0x0a, 0xb1, 0x00, 0x0a, 0xcd, 0x00, 0x0a, 0xb5, 0x00, 0x0a, 0xb6, 0x00, 0x0a, 0x9e, 0x02,
        0x75, 0x08, 0x95, 0x01, 0x81, 0x00, 0xc0])

    package static let telephonyDescriptor = Data([
        0x05, 0x0b, 0x09, 0x07, 0xa1, 0x01, 0x15, 0x00, 0x25, 0x11, 0x05, 0x0b,
        0x09, 0x00, 0x09, 0x20, 0x09, 0x21, 0x09, 0x26, 0x09, 0x2f,
        0x09, 0xb0, 0x09, 0xb1, 0x09, 0xb2, 0x09, 0xb3, 0x09, 0xb4, 0x09, 0xb5, 0x09, 0xb6, 0x09, 0xb7, 0x09, 0xb8, 0x09, 0xb9,
        0x09, 0xba, 0x09, 0xbb, 0x05, 0x07, 0x09, 0x2a, 0x75, 0x08, 0x95, 0x01, 0x81, 0x00, 0xc0])

    // MARK: /info 的 hidDevices 条目

    private static func entry(_ uid: UInt32, _ name: String, _ descriptor: Data, _ displayUUID: String) -> [String: Any] {
        ["hidProductID": 1, "hidVendorID": 2, "hidCountryCode": 0, "uuid": String(uid, radix: 16),
         "name": name, "displayUUID": displayUUID, "hidDescriptor": descriptor]
    }
    package static func touchDevice(xMax: Int, yMax: Int, displayUUID: String) -> [String: Any] {
        entry(touchUID, "LIVI Touchscreen", touchDescriptor(xMax: xMax, yMax: yMax), displayUUID)
    }
    package static func knobDevice(displayUUID: String) -> [String: Any] { entry(knobUID, "LIVI Knob", knobDescriptor, displayUUID) }
    package static func mediaDevice(displayUUID: String) -> [String: Any] { entry(mediaUID, "LIVI Media", mediaDescriptor, displayUUID) }
    package static func telephonyDevice(displayUUID: String) -> [String: Any] { entry(telephonyUID, "LIVI Telephony", telephonyDescriptor, displayUUID) }

    // MARK: 报告

    /// 两个手指槽，每槽 [槽号][touch 位][X u16 LE][Y u16 LE]，坐标是流像素。第 i 个触点占第 i 槽。
    package static func touchReport(_ contacts: [HIDContact]) -> Data {
        var r = [UInt8](repeating: 0, count: bytesPerFinger * touchContacts)
        for i in 0..<touchContacts {
            let off = i * bytesPerFinger
            r[off] = UInt8(i)
            guard i < contacts.count else { continue }
            let c = contacts[i]
            r[off + 1] = c.down ? 1 : 0
            let x = axis(c.x), y = axis(c.y)
            r[off + 2] = UInt8(x & 0xff); r[off + 3] = UInt8(x >> 8)
            r[off + 4] = UInt8(y & 0xff); r[off + 5] = UInt8(y >> 8)
        }
        return Data(r)
    }
    /// JS Math.round（半数向上）并夹到 0...65535
    private static func axis(_ v: Double) -> Int { Int(min(65535, max(0, (v + 0.5).rounded(.down)))) }

    /// 我们这边 0..1 的触点 + 流像素尺寸 → 报告（对应 cpStack.sendTouches）
    package static func touchReport(normalized: [(id: Int, x: Double, y: Double, down: Bool)], streamWidth: Int, streamHeight: Int) -> Data {
        touchReport(normalized.map { HIDContact(id: $0.id, x: $0.x * Double(streamWidth), y: $0.y * Double(streamHeight), down: $0.down) })
    }

    package static func knobReport(_ s: KnobState) -> Data {
        func clamp(_ v: Int) -> UInt8 { UInt8(bitPattern: Int8(max(-127, min(127, v)))) }
        return Data([(s.select ? 1 : 0) | (s.home ? 2 : 0) | (s.back ? 4 : 0), clamp(s.x), clamp(s.y), clamp(s.wheel)])
    }
    package static func mediaReport(_ index: UInt8) -> Data { Data([index]) }
    package static func telephonyReport(_ index: UInt8) -> Data { Data([index]) }
}
