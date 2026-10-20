// iAP2 文件传输会话（session 12）的接收状态机：手机用它把专辑封面推给车机。
// datagram 格式：u8 ftid | u8 control | payload。照 MacPlay file_transfer.rs 的位定义。
import Foundation

package final class FileTransferReceiver {
    package enum Output: Equatable {
        case reply([UInt8])
        case complete(id: UInt8, data: Data)
    }

    package static let maxBytesPerTransfer = 8 * 1024 * 1024

    private var buffers: [UInt8: [UInt8]] = [:]

    package init() {}

    package func feed(_ datagram: [UInt8]) -> [Output] {
        guard datagram.count >= 2 else { return [] }
        let id = datagram[0], control = datagram[1]
        let data = Array(datagram[2...])
        switch control {
        case 0x04:   // SETUP
            buffers[id] = []
            return [.reply([id, 0x01])]   // START
        case 0x80:   // FIRST_DATA
            buffers[id] = data
            return guardSize(id)
        case 0x00:   // DATA
            buffers[id, default: []].append(contentsOf: data)
            return guardSize(id)
        case 0xC0:   // FIRST_AND_ONLY_DATA
            return complete(id: id, data: data)
        case 0x40:   // LAST_DATA
            var buf = buffers.removeValue(forKey: id) ?? []
            buf.append(contentsOf: data)
            return complete(id: id, data: buf)
        case 0x02:   // CANCEL
            buffers.removeValue(forKey: id)
            return []
        default:
            return []
        }
    }

    /// 单个封面不应该无上限地吃内存；超了就丢掉这次传输，不占住后续转移。
    private func guardSize(_ id: UInt8) -> [Output] {
        if (buffers[id]?.count ?? 0) > Self.maxBytesPerTransfer {
            buffers.removeValue(forKey: id)
            return [.reply([id, 0x02])]   // CANCEL
        }
        return []
    }

    private func complete(id: UInt8, data: [UInt8]) -> [Output] {
        buffers.removeValue(forKey: id)
        guard data.count <= Self.maxBytesPerTransfer else { return [.reply([id, 0x02])] }
        return [.reply([id, 0x05]), .complete(id: id, data: Data(data))]   // SUCCESS
    }
}
