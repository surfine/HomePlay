// CarPlay 的 HID 设备：多点触控、旋钮、媒体键、电话键（对应 MacPlay protocol/hid.ts）。
import Foundation

package struct HIDContact: Equatable {
    package var id: Int
    package var x: Double      // 流像素
    package var y: Double
    package var down: Bool
    package init(id: Int, x: Double, y: Double, down: Bool) { self.id = id; self.x = x; self.y = y; self.down = down }
}

package struct KnobState: Equatable {
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

    /// 桌寵的旋鈕鍵（CarPlay 畫面上的鍵盤）→ 一次旋鈕報告：`{"type":"knob","command":"select|back|left|right|up|down|cw|ccw"}`。
    /// 方向＝搖桿 x／y ±1、cw／ccw＝wheel ±1、select／back＝按鍵；送法照 EventChannel.sendKnob（按下或脈衝之後緊跟全零的放開）。別的回 nil
    package static func knobState(forPetMessage text: String) -> KnobState? {
        guard let o = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any], o["type"] as? String == "knob",
              let c = o["command"] as? String else { return nil }
        switch c {
        case "select": return KnobState(select: true)
        case "back": return KnobState(back: true)
        case "left": return KnobState(x: -1)
        case "right": return KnobState(x: 1)
        case "up": return KnobState(y: -1)
        case "down": return KnobState(y: 1)
        case "cw": return KnobState(wheel: 1)
        case "ccw": return KnobState(wheel: -1)
        default: return nil
        }
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

    /// 两个手指槽，每槽 [槽号][touch 位][X u16 LE][Y u16 LE]，坐标是流像素。
    /// 依触点 id 放槽（不连续记忆，每次都是新的一组）；要跨报告记住哪根手指在哪一槽用 `TouchSlots`。
    package static func touchReport(_ contacts: [HIDContact]) -> Data {
        var slots = TouchSlots()
        return slots.report(contacts)
    }

    /// 依触点 id 分槽、跨报告记住：第一指先放开时第二指留在原槽（手机才不会当成一指跳位）。
    /// 每次传进来的是「这一刻所有手指」：按着的占槽；`down == false` 的送一次那一槽放开（保留最后坐标）后让出；
    /// 上一份还按着、这一份没出现的也当放开。放开后不再有手指按着、而这一份放开了两槽以上时送全零报告（槽号保留）。
    /// 只有一指的序列跟改之前逐字节相同。槽满时多出来的手指忽略。
    package struct TouchSlots {
        private var held: [HIDContact?] = Array(repeating: nil, count: HID.touchContacts)
        package init() {}

        package mutating func report(_ contacts: [HIDContact]) -> Data {
            var out: [HIDContact?] = Array(repeating: nil, count: touchContacts)
            var seen = Set<Int>()
            var pending: [HIDContact] = []
            // 已经有槽的 id 留在原槽
            for c in contacts where !seen.contains(c.id) {
                seen.insert(c.id)
                if let i = held.firstIndex(where: { $0?.id == c.id }) { out[i] = c } else { pending.append(c) }
            }
            // 新的 id：自己的号码在范围内又空着就用，否则用最小的空槽；都满就忽略
            func free(_ i: Int) -> Bool { out[i] == nil && held[i] == nil }
            var rest: [HIDContact] = []
            for c in pending {
                if (0..<touchContacts).contains(c.id), free(c.id) { out[c.id] = c } else { rest.append(c) }
            }
            for c in rest { if let i = (0..<touchContacts).first(where: free) { out[i] = c } }
            // 上一份按着、这一份没出现的：这一份送放开
            for i in 0..<touchContacts where out[i] == nil {
                if var h = held[i] { h.down = false; out[i] = h }
            }
            held = out.map { $0?.down == true ? $0 : nil }
            if held.allSatisfy({ $0 == nil }), out.compactMap({ $0 }).count > 1 { return encode([]) }
            return encode(out)
        }

        /// 0..1 的触点 + 流像素尺寸 → 报告
        package mutating func report(normalized: [(id: Int, x: Double, y: Double, down: Bool)], streamWidth: Int, streamHeight: Int) -> Data {
            report(normalized.map { HIDContact(id: $0.id, x: $0.x * Double(streamWidth), y: $0.y * Double(streamHeight), down: $0.down) })
        }
    }

    private static func encode(_ slots: [HIDContact?]) -> Data {
        var r = [UInt8](repeating: 0, count: bytesPerFinger * touchContacts)
        for i in 0..<touchContacts {
            let off = i * bytesPerFinger
            r[off] = UInt8(i)
            guard i < slots.count, let c = slots[i] else { continue }
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
        var slots = TouchSlots()
        return slots.report(normalized: normalized, streamWidth: streamWidth, streamHeight: streamHeight)
    }

    /// 桌寵的觸控訊息 → 0..1 的觸點（最多 `touchContacts` 個）：
    /// `{"type":"touch","contacts":[{"id":0,"x":..,"y":..,"down":..}, …]}`。沒有 id 的用它在陣列裡的位置；
    /// 缺 x 或 y 的觸點略過；一個能用的觸點都沒有回 nil。座標夾到 0...1，down 預設 false。
    package static func touchContacts(forPetMessage text: String) -> [(id: Int, x: Double, y: Double, down: Bool)]? {
        guard let o = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any], o["type"] as? String == "touch",
              let list = o["contacts"] as? [[String: Any]] else { return nil }
        var out: [(id: Int, x: Double, y: Double, down: Bool)] = []
        for (i, c) in list.enumerated() {
            guard out.count < touchContacts else { break }
            guard let x = (c["x"] as? NSNumber)?.doubleValue, let y = (c["y"] as? NSNumber)?.doubleValue else { continue }
            out.append((id: (c["id"] as? NSNumber)?.intValue ?? i, x: min(1, max(0, x)), y: min(1, max(0, y)), down: (c["down"] as? Bool) ?? false))
        }
        return out.isEmpty ? nil : out
    }

    package static func knobReport(_ s: KnobState) -> Data {
        func clamp(_ v: Int) -> UInt8 { UInt8(bitPattern: Int8(max(-127, min(127, v)))) }
        return Data([(s.select ? 1 : 0) | (s.home ? 2 : 0) | (s.back ? 4 : 0), clamp(s.x), clamp(s.y), clamp(s.wheel)])
    }
    package static func mediaReport(_ index: UInt8) -> Data { Data([index]) }
    package static func telephonyReport(_ index: UInt8) -> Data { Data([index]) }
}
