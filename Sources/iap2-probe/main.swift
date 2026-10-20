import Foundation
import IOBluetooth
import IAP2

// iAP2/MFi 探针（隔离工具，不进 App）：对一台已配对的 iPhone 打开 iAP2 RFCOMM 通道，
// 走 marker 探测 → 链路同步 → 识别（0x1D）→ MFi 认证（0xAA），只汇报阶段，不接媒体、不 CarPlay。
//
// 用法：
//   iap2-probe --list
//   iap2-probe --identity-dir <dir> --address <AA:BB:CC:DD:EE:FF> [--seconds 60] [--ssid <名称>]
// 身份目录放用户自备的 identity.pk8 与 certificate.p7b；工具不检查来源，也不打印身份内容。
// 需要终端有蓝牙权限（系统设置 > 隐私与安全 > 蓝牙）。

func note(_ text: String) {
    FileHandle.standardError.write(("iap2: " + text + "\n").data(using: .utf8)!)
}

// MARK: 入口

let arguments = CommandLine.arguments
func flagValue(_ name: String) -> String? {
    guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
    return arguments[index + 1]
}

if arguments.contains("--list") {
    for d in Iap2BluetoothAccessory.pairedDevices() { print("\(d.address) \(d.name)") }
    exit(0)
}

guard let identityDir = flagValue("--identity-dir") else {
    note("需要 --identity-dir（用户自备 identity.pk8 + certificate.p7b）")
    exit(64)
}
guard let address = flagValue("--address") else {
    note("需要 --address（已配对 iPhone 的蓝牙地址，--list 可列）")
    exit(64)
}
let seconds = Double(flagValue("--seconds") ?? "60") ?? 60
let ssid = flagValue("--ssid") ?? "WindowShade"

let identity: Iap2MfiIdentity
do {
    identity = try Iap2MfiIdentity(directory: identityDir)
    note("身份自检通过：私钥能签、证书公钥能验（证书 \(identity.certificate.count) 字节）")
} catch {
    note("身份加载失败：\(error)")
    exit(2)
}

let device: IOBluetoothDevice, channelID: BluetoothRFCOMMChannelID
switch Iap2BluetoothAccessory.locate(address: address) {
case .success(let found): (device, channelID) = found
case .failure(let error): note(error.description); exit(error == .notPaired ? 2 : 3)
}
note("iAP2 SDP 记录在，RFCOMM 通道 \(channelID)")

var info = Iap2AccessoryCore.Info()
info.name = "HomePlay Probe"; info.serialNumber = "HOMEPLAY-PROBE-1"; info.ssid = ssid
let probe = Iap2BluetoothAccessory(identity: identity, info: info, stopAfterAuth: true)
probe.onLog = { note($0) }
guard probe.start(device: device, channelID: channelID) else { exit(3) }

let deadline = Date().addingTimeInterval(seconds)
while !probe.finished, Date() < deadline {
    RunLoop.current.run(until: Date().addingTimeInterval(0.2))
}

if probe.core.phase == .authenticated {
    print("RESULT authenticated")
} else {
    print("RESULT incomplete phase=\(probe.phase.rawValue) exit=\(probe.core.exitCode)")
}
exit(probe.core.phase == .authenticated ? 0 : Int32(probe.core.exitCode == 0 ? 9 : probe.core.exitCode))
