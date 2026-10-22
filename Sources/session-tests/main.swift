// Session 模块离线测试（向量与差分）。每个分支把自己的测试函数加进各自的文件，在这里调用。
import Foundation
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

suite("audio") { failures += runAudioTests() }

print(failures == 0 ? "PASS session" : "FAIL session (\(failures))")
exit(failures == 0 ? 0 : 1)
