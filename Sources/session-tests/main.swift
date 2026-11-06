// Session 模块离线测试（向量与差分）。每个分支把自己的测试函数加进各自的文件，在这里调用。
import Foundation
import Wire
import Session

nonisolated(unsafe) var failures = 0
func expect(_ condition: Bool, _ message: String) {
    if condition { print("ok   \(message)") } else { failures += 1; print("FAIL \(message)") }
}

let filter = CommandLine.arguments.dropFirst().first
func suite(_ name: String, _ body: () throws -> Void) {
    if let filter, !name.localizedCaseInsensitiveContains(filter) { return }
    print("== \(name)")
    do { try body() } catch { failures += 1; print("FAIL \(name) threw \(error)") }
}

runCryptoSuites()
runTransportSuites()
runSessionE2ESuites()
runPhoneSuites()
runCarVideoSuites()
runTouchSlotsSuites()

suite("audio") { failures += runAudioTests() }

// 2026-11-07：8788 監聽器失效後要自己重建（不能讓接收端活著卻不聽埠）
suite("ws listener rebuild backoff") {
    expect(WSServer.rebuildDelays(7) == [1, 2, 4, 8, 16, 30, 30], "退避 1、2、4、8、16 秒，之後封頂 30 秒")
}

print(failures == 0 ? "PASS session" : "FAIL session (\(failures))")
exit(failures == 0 ? 0 : 1)
