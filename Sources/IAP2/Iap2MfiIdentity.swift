import Foundation
import Security
import CryptoKit

// MFi 配件身份：identity.pk8（PKCS#8 EC P-256 私钥）+ certificate.p7b（裸 X.509 或 PKCS#7 容器）。
// HomePlay 自带公开实验性身份（identity/ 目录，见 SOURCE.txt）；--identity-dir / $HOMEPLAY_IDENTITY_DIR 可换自备的。
// 工具不打印身份内容。证书原样放进 0xAA01 参数 0，由 iPhone 验证链；签名是“对已给摘要的 ECDSA”，输出 64 字节 r||s。

package struct Iap2MfiIdentity {

    package enum LoadError: Error, CustomStringConvertible {
        case missing(String)
        case tooLarge(String)
        case malformed(String)
        case keyMismatch

        package var description: String {
            switch self {
            case .missing(let file): return "缺 \(file)"
            case .tooLarge(let file): return "\(file) 超过 16 KiB"
            case .malformed(let what): return "解析失败：\(what)"
            case .keyMismatch: return "私钥与证书的公钥不匹配"
            }
        }
    }

    package static let maximumFileBytes = 16 * 1024

    package let certificate: [UInt8]
    private let key: SecKey

    /// 从目录加载并当场自检：私钥能签、证书公钥能验、两者匹配。
    package init(directory: String) throws {
        let url = URL(fileURLWithPath: directory)
        let keyBytes = try Self.readBounded(url.appendingPathComponent("identity.pk8"))
        let certificate = try Self.readBounded(url.appendingPathComponent("certificate.p7b"))
        guard let scalar = Self.ecPrivateKeyScalar(pkcs8: keyBytes) else {
            throw LoadError.malformed("identity.pk8 不是 PKCS#8 EC P-256 私钥")
        }
        // 私钥导入要完整外部表示 04||标量||X||Y；X||Y 从证书公钥取，顺带证明两份文件属于同一身份。
        guard let certificateKey = Self.certificatePublicKey(certificate),
              let point = [UInt8]((SecKeyCopyExternalRepresentation(certificateKey, nil) as Data?) ?? Data()) as [UInt8]?,
              point.count == 65, point.first == 0x04 else {
            throw LoadError.malformed("certificate.p7b 里取不到 P-256 公钥")
        }
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateWithData(
            Data(point + scalar) as CFData, // 外部表示 04||X||Y||标量
            [kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
             kSecAttrKeyClass as String: kSecAttrKeyClassPrivate] as CFDictionary,
            &error) else {
            throw LoadError.malformed("私钥导入失败：\(error?.takeRetainedValue().localizedDescription ?? "?")")
        }
        self.key = key
        self.certificate = certificate
        // 自检：固定摘要签名，用证书公钥验。
        guard Self.verify(signed: try sign(digest: Self.testDigest), of: Self.testDigest, with: certificateKey)
        else { throw LoadError.keyMismatch }
    }

    package static let testDigest: [UInt8] = Array(SHA256.hash(data: Data("windowshade iap2 self check".utf8)))

    /// 签 iPhone 给的摘要（上游已算好 SHA-256，这里不再哈希），输出 64 字节 r||s。
    package func sign(digest: [UInt8]) throws -> [UInt8] {
        guard digest.count == 32 else { throw LoadError.malformed("摘要不是 32 字节") }
        var error: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(
            key,
            SecKeyAlgorithm.ecdsaSignatureDigestX962SHA256,
            Data(digest) as CFData,
            &error) as Data? else {
            throw LoadError.malformed("签名失败：\(error?.takeRetainedValue().localizedDescription ?? "?")")
        }
        guard let raw = Self.rawRS(fromDer: [UInt8](signature)) else {
            throw LoadError.malformed("签名 DER 转换失败")
        }
        return raw
    }

    // MARK: 文件

    private static func readBounded(_ url: URL) throws -> [UInt8] {
        guard let data = try? Data(contentsOf: url) else { throw LoadError.missing(url.lastPathComponent) }
        guard !data.isEmpty else { throw LoadError.missing(url.lastPathComponent) }
        guard data.count <= maximumFileBytes else { throw LoadError.tooLarge(url.lastPathComponent) }
        return [UInt8](data)
    }

    // MARK: DER 解析

    /// 走 PKCS#8 → SEC1，取出 32 字节私钥标量。只认 P-256 的 OID。
    package static func ecPrivateKeyScalar(pkcs8: [UInt8]) -> [UInt8]? {
        guard let outer = DER.element(at: 0, in: pkcs8[0...]), outer.tag == 0x30 else { return nil }
        let content = outer.content
        guard DER.element(at: 0, in: content)?.tag == 0x02 else { return nil } // 版本
        guard let algorithm = DER.element(at: 1, in: content), algorithm.tag == 0x30 else { return nil }
        // OID 序列之后应是 OCTET STRING（SEC1 私钥 DER）。
        guard let algorithmOID = DER.element(at: 0, in: algorithm.content), algorithmOID.tag == 0x06 else { return nil }
        // 1.2.840.10045.2.1（id-ecPublicKey）
        guard Array(algorithmOID.content) == [0x2a, 0x86, 0x48, 0xce, 0x3d, 0x02, 0x01] else { return nil }
        if let curve = DER.element(at: 1, in: algorithm.content), curve.tag == 0x06 {
            // 1.2.840.10045.3.1.7（prime256v1）
            guard Array(curve.content) == [0x2a, 0x86, 0x48, 0xce, 0x3d, 0x03, 0x01, 0x07] else { return nil }
        }
        guard let octet = DER.octetStringPrivateKey(pkcs8) else { return nil }
        // 三种布局都认：SEC1 SEQUENCE；Security 的 04||标量32||公钥65（97 字节）；裸 32 字节标量。
        if let sec1 = DER.element(at: 0, in: octet[...]), sec1.tag == 0x30,
           DER.element(at: 0, in: sec1.content)?.tag == 0x02,
           let scalarElement = DER.element(at: 1, in: sec1.content), scalarElement.tag == 0x04,
           Array(scalarElement.content).count == 32 {
            return Array(scalarElement.content)
        }
        if octet.count == 97, octet[0] == 0x04 {
            // Security 的外部表示是 04||X||Y||标量：标量在最后 32 字节。
            return Array(octet[65...96])
        }
        return octet.count == 32 ? octet : nil
    }

    /// 从证书字节里取公钥。认三种：裸 X.509（DER/PEM）、PKCS#7 容器（.p7b 的 SignedData，
    /// MacPlay/DiPlay 带的就是这种）、PEM 的 PKCS#7。公钥只用于自检和密钥匹配；
    /// 0xAA01 / auth-setup 里送出去的始终是文件原样字节（iPhone 自己解容器）。
    package static func certificatePublicKey(_ certificate: [UInt8]) -> SecKey? {
        let der = Self.pemToDer(certificate)
        // 裸证书：顶层就是 Certificate ::= SEQUENCE { tbs, alg, BIT STRING }。
        if let top = DER.element(at: 0, in: der[...]), DER.isCertificate(top) {
            return Self.publicKey(ofCertificate: top)
        }
        // PKCS#7 容器：ContentInfo ::= SEQUENCE { OID, [0] { SignedData { …, [0] { 证书 } } } }。
        guard let cert = DER.firstCertificate(in: der[...]) else { return nil }
        return Self.publicKey(ofCertificate: cert)
    }

    private static func publicKey(ofCertificate cert: DER.Node) -> SecKey? {
        // TBSCertificate：[0]版本、[1]序列号、[2]签名算法、[3]颁发者、[4]有效期、[5]主体、[6]公钥信息
        guard let tbs = DER.element(at: 0, in: cert.content), tbs.tag == 0x30 else { return nil }
        guard let publicKeyInfo = DER.element(at: 6, in: tbs.content), publicKeyInfo.tag == 0x30 else { return nil }
        guard let keyBits = DER.element(at: 1, in: publicKeyInfo.content), keyBits.tag == 0x03 else { return nil }
        var bits = Array(keyBits.content)
        guard bits.first == 0x00 else { return nil } // 未压缩点前面有一个 0 字节数
        bits.removeFirst()
        var error: Unmanaged<CFError>?
        return SecKeyCreateWithData(
            Data(bits) as CFData,
            [kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
             kSecAttrKeyClass as String: kSecAttrKeyClassPublic] as CFDictionary,
            &error)
    }

    package static func verify(signed: [UInt8], of digest: [UInt8], with publicKey: SecKey) -> Bool {
        let der = Self.derFromRawRS(signed)
        guard !der.isEmpty else { return false }
        return SecKeyVerifySignature(
            publicKey,
            SecKeyAlgorithm.ecdsaSignatureDigestX962SHA256,
            Data(digest) as CFData,
            Data(der) as CFData,
            nil)
    }

    // MARK: 签名格式

    /// DER SEQUENCE(INTEGER r, INTEGER s) → 64 字节大端 r||s。
    package static func rawRS(fromDer der: [UInt8]) -> [UInt8]? {
        guard let seq = DER.element(at: 0, in: der[...]), seq.tag == 0x30 else { return nil }
        guard let r = DER.element(at: 0, in: seq.content), r.tag == 0x02,
              let s = DER.element(at: 1, in: seq.content), s.tag == 0x02
        else { return nil }
        func pad(_ bytes: [UInt8]) -> [UInt8]? {
            var value = bytes
            if value.first == 0 { value.removeFirst() } // 正数前导 0
            guard value.count <= 32 else { return nil }
            return [UInt8](repeating: 0, count: 32 - value.count) + value
        }
        guard let rPadded = pad(Array(r.content)), let sPadded = pad(Array(s.content)) else { return nil }
        return rPadded + sPadded
    }

    /// 64 字节 r||s → DER（测试里把签名喂回 Security 验证用）。
    package static func derFromRawRS(_ raw: [UInt8]) -> [UInt8] {
        guard raw.count == 64 else { return [] }
        func integer(_ bytes: [UInt8]) -> [UInt8] {
            var value = bytes
            while value.first == 0, value.count > 1 { value.removeFirst() }
            if value.first! & 0x80 != 0 { value = [0] + value }
            return [0x02, UInt8(value.count)] + value
        }
        let body = integer(Array(raw[0..<32])) + integer(Array(raw[32..<64]))
        return [0x30, UInt8(body.count)] + body
    }

    private static func pemToDer(_ bytes: [UInt8]) -> [UInt8] {
        // PEM 是 ASCII；直接搜 base64 段。DER 就原样返回。
        guard bytes.allSatisfy({ $0 < 0x80 }),
              let text = String(bytes: bytes, encoding: .utf8),
              text.contains("-----BEGIN")
        else { return bytes }
        let lines = text.split(separator: "\n").filter { line in
            !line.hasPrefix("-----") && !line.trimmingCharacters(in: .whitespaces).isEmpty
        }
        guard let data = Data(base64Encoded: lines.joined()) else { return bytes }
        return [UInt8](data)
    }
}

// MARK: - 最小 DER 走读器

package enum DER {
    package struct Node {
        package var tag: UInt8
        package var content: ArraySlice<UInt8>
        /// 元素整体在原缓冲里的字节跨度（解析 sibling 时用）。
        package var range: Range<Int>
    }

    package static func element(at index: Int, in body: ArraySlice<UInt8>) -> Node? {
        var cursor = 0
        var offset = body.startIndex
        while offset < body.endIndex {
            guard let element = parse(at: offset, in: body) else { return nil }
            if cursor == index { return element }
            cursor += 1
            offset = body.startIndex + element.range.upperBound
        }
        return nil
    }

    private static func parse(at offset: Int, in body: ArraySlice<UInt8>) -> Node? {
        let bytes = body
        let base = bytes.startIndex
        let start = offset - base
        guard start >= 0, start + 2 <= bytes.count else { return nil }
        let tag = bytes[bytes.startIndex + start]
        let firstLength = bytes[bytes.startIndex + start + 1]
        var length = 0
        var header = 2
        if firstLength & 0x80 == 0 {
            length = Int(firstLength)
        } else {
            let count = Int(firstLength & 0x7f)
            guard count > 0, count <= 4, start + 2 + count <= bytes.count else { return nil }
            for index in 0..<count {
                length = length << 8 | Int(bytes[bytes.startIndex + start + 2 + index])
            }
            header = 2 + count
        }
        let contentStart = start + header
        guard contentStart + length <= bytes.count else { return nil }
        let contentRange = (base + contentStart)..<(base + contentStart + length)
        return Node(tag: tag, content: bytes[contentRange],
                       range: start..<(contentStart + length))
    }

    /// PKCS#8 最外层 SEQUENCE 里第三个元素（OCTET STRING，SEC1 私钥）。
    package static func octetStringPrivateKey(_ pkcs8: [UInt8]) -> [UInt8]? {
        guard let outer = element(at: 0, in: pkcs8[...]), outer.tag == 0x30 else { return nil }
        guard let octet = element(at: 2, in: outer.content), octet.tag == 0x04 else { return nil }
        return Array(octet.content)
    }

    /// 依次列出 body 里的顶层元素；个别元素解析失败就跳过剩下的（尽力而为，容器解包用）。
    package static func allElements(in body: ArraySlice<UInt8>) -> [Node] {
        var nodes: [Node] = []
        var offset = body.startIndex
        while offset < body.endIndex {
            guard let element = parse(at: offset, in: body) else { break }
            nodes.append(element)
            offset = body.startIndex + element.range.upperBound
        }
        return nodes
    }

    /// X.509 证书形状：SEQUENCE 且恰好三个孩子（tbs SEQUENCE、算法、签名 BIT STRING）。
    /// 证书内部的 TBS、SPKI 等都凑不齐这个形状，不会误认。
    package static func isCertificate(_ node: Node) -> Bool {
        guard node.tag == 0x30 else { return false }
        let children = allElements(in: node.content)
        return children.count == 3 && children[0].tag == 0x30 && children[2].tag == 0x03
    }

    /// 深度优先找第一张 X.509——PKCS#7 容器里证书在 SignedData 的 [0] 里，
    /// 苹果的 .p7b 实测为 1 张叶子证书（IPA_，Apple Accessories CA 签发）。
    package static func firstCertificate(in body: ArraySlice<UInt8>) -> Node? {
        for node in allElements(in: body) {
            if isCertificate(node) { return node }
            if let found = firstCertificate(in: node.content) { return found }
        }
        return nil
    }
}
