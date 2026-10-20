// CarPlay 会话控制面（Swift 重写，行为参照 MacPlay / LIVI，见 NOTICE）。
// 配对与加密：TLV8、SRP、PairSetup、PairVerify、ControlCipher（Crypto 分支）。
// 传输：RTSP、bplist、HID、ScreenStream、Discovery、事件消息（Transport 分支）。
import Foundation

package enum SessionInfo {
    package static let version = "0.1"
}
