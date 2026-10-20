// TLV8 编解码（HAP / AirPlay 配对消息）。行为参照 MacPlay native/Engine/protocol/tlv8.ts。
// 每项 [1 字节类型][1 字节长度][值]；超过 255 字节的值拆成连续同类型项，解码时合并。
import Foundation

/// 配对消息里用到的 TLV 类型码。
package enum TLV8Tag {
    package static let method: UInt8 = 0x00
    package static let identifier: UInt8 = 0x01
    package static let salt: UInt8 = 0x02
    package static let publicKey: UInt8 = 0x03
    package static let proof: UInt8 = 0x04
    package static let encryptedData: UInt8 = 0x05
    package static let state: UInt8 = 0x06
    package static let error: UInt8 = 0x07
    package static let signature: UInt8 = 0x0a
    /// 相邻同类型项之间的分隔符（零长度）。
    package static let separator: UInt8 = 0xff
}

package struct TLV8Item: Equatable {
    package var type: UInt8
    package var value: [UInt8]
    package init(_ type: UInt8, _ value: [UInt8]) {
        self.type = type
        self.value = value
    }
}

package enum TLV8 {
    package static func encode(_ items: [TLV8Item]) -> [UInt8] {
        var out: [UInt8] = []
        var previous: UInt8?
        for item in items {
            // 两个相邻的同类型项之间插一个零长度分隔符，避免解码时被并成一个分片值。
            if previous == item.type { out.append(contentsOf: [TLV8Tag.separator, 0]) }
            var offset = 0
            repeat {
                let length = min(255, item.value.count - offset)
                out.append(item.type)
                out.append(UInt8(length))
                out.append(contentsOf: item.value[offset ..< offset + length])
                offset += length
            } while offset < item.value.count
            previous = item.type
        }
        return out
    }

    /// 解成 类型 -> 值；紧邻的同类型分片只在前一项恰为 255 字节时才拼接。
    package static func decode(_ bytes: [UInt8]) -> [UInt8: [UInt8]] {
        var out: [UInt8: [UInt8]] = [:]
        var p = 0
        var lastType: UInt8?
        var lastLength = 0
        while p + 2 <= bytes.count {
            let type = bytes[p]
            let length = Int(bytes[p + 1])
            let end = min(bytes.count, p + 2 + length)
            let value = Array(bytes[p + 2 ..< end])
            p += 2 + length
            if type == lastType, lastLength == 255 {
                out[type, default: []].append(contentsOf: value)
            } else {
                out[type] = value
            }
            lastType = type
            lastLength = length
        }
        return out
    }
}
