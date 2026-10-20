// 配件长期身份（Ed25519 + 配对 ID）与已配对控制器（手机）的持久化。
// 参照 MacPlay identity.ts / pairings.ts，合并为一个文件：~/Library/Application Support/HomePlay/pairing.json，权限 0600。
import CryptoKit
import Foundation

package struct AccessoryIdentity {
    package let privateRaw: [UInt8]
    package let publicRaw: [UInt8]
    /// mDNS TXT 的 `pi`
    package let pairingId: String
    package init(privateRaw: [UInt8], publicRaw: [UInt8], pairingId: String) {
        self.privateRaw = privateRaw
        self.publicRaw = publicRaw
        self.pairingId = pairingId
    }

    /// 由 32 字节 Ed25519 种子建身份（测试与迁移用）。
    package init(seed: [UInt8], pairingId: String) throws {
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
        self.init(privateRaw: seed, publicRaw: Array(key.publicKey.rawRepresentation), pairingId: pairingId)
    }

    /// mDNS TXT 的 `pk`（小写十六进制）
    package var publicKeyHex: String { PairingStore.hex(publicRaw) }

    /// 由公钥得到稳定的、本地管理的设备地址（02:xx:xx:xx:xx:xx）。
    package var deviceId: String {
        ([2] + publicRaw.prefix(5)).map { String(format: "%02X", $0) }.joined(separator: ":")
    }
}

package final class PairingStore: @unchecked Sendable {
    private struct FileFormat: Codable {
        var priv: String
        var pub: String
        var pi: String
        var controllers: [String: String]
    }

    package static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("HomePlay", isDirectory: true)
    }

    private let lock = NSLock()
    private let file: URL
    private var state: FileFormat
    package let identity: AccessoryIdentity

    /// 读取或首次生成身份。文件损坏时重新生成（同 MacPlay）。`newIdentity` 只给测试固定首次生成的身份。
    package init(directory: URL = PairingStore.defaultDirectory, newIdentity: AccessoryIdentity? = nil) {
        file = directory.appendingPathComponent("pairing.json")
        if let data = try? Data(contentsOf: file),
           let f = try? JSONDecoder().decode(FileFormat.self, from: data),
           let priv = Self.unhex(f.priv), let pub = Self.unhex(f.pub), priv.count == 32, pub.count == 32 {
            state = f
            identity = AccessoryIdentity(privateRaw: priv, publicRaw: pub, pairingId: f.pi)
            return
        }
        let fresh: AccessoryIdentity
        if let newIdentity {
            fresh = newIdentity
        } else {
            let key = Curve25519.Signing.PrivateKey()
            fresh = AccessoryIdentity(privateRaw: Array(key.rawRepresentation),
                                      publicRaw: Array(key.publicKey.rawRepresentation),
                                      pairingId: UUID().uuidString.lowercased())
        }
        state = FileFormat(priv: Self.hex(fresh.privateRaw), pub: Self.hex(fresh.publicRaw),
                           pi: fresh.pairingId, controllers: [:])
        identity = fresh
        persist()
    }

    package func savePairing(identifier: String, ltpk: [UInt8]) {
        lock.lock(); defer { lock.unlock() }
        state.controllers[identifier] = Self.hex(ltpk)
        persist()
    }

    package func ltpk(for identifier: String) -> [UInt8]? {
        lock.lock(); defer { lock.unlock() }
        return state.controllers[identifier].flatMap(Self.unhex)
    }

    package func removePairing(identifier: String) {
        lock.lock(); defer { lock.unlock() }
        state.controllers[identifier] = nil
        persist()
    }

    package var pairedIdentifiers: [String] {
        lock.lock(); defer { lock.unlock() }
        return state.controllers.keys.sorted()
    }

    /// 原子写入（临时文件 0600 再改名）。
    private func persist() {
        do {
            let dir = file.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let enc = JSONEncoder()
            enc.outputFormatting = [.sortedKeys]
            let data = try enc.encode(state)
            let tmp = dir.appendingPathComponent(".pairing.json.\(UUID().uuidString).tmp")
            guard FileManager.default.createFile(atPath: tmp.path, contents: data,
                                                 attributes: [.posixPermissions: 0o600]) else {
                throw CocoaError(.fileWriteUnknown)
            }
            if rename(tmp.path, file.path) != 0 {
                try? FileManager.default.removeItem(at: tmp)
                throw CocoaError(.fileWriteUnknown)
            }
        } catch {
            FileHandle.standardError.write(Data("[PairingStore] 写入失败：\(error)\n".utf8))
        }
    }

    static func hex(_ b: [UInt8]) -> String { b.map { String(format: "%02x", $0) }.joined() }

    static func unhex(_ s: String) -> [UInt8]? {
        guard s.count % 2 == 0 else { return nil }
        var out: [UInt8] = []
        var i = s.startIndex
        while i < s.endIndex {
            let j = s.index(i, offsetBy: 2)
            guard let b = UInt8(s[i ..< j], radix: 16) else { return nil }
            out.append(b)
            i = j
        }
        return out
    }
}
