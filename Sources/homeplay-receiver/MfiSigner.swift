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

/// Iap2MfiIdentity → 会话 auth-setup 要的签名器（协议 3：对 SHA-256 摘要签名，64 字节 r||s）
struct MfiSigner: AccessorySigner {
    let identity: Iap2MfiIdentity
    var certificate: [UInt8] { identity.certificate }
    func sign(_ digest: [UInt8]) throws -> [UInt8] { try identity.sign(digest: digest) }
}
