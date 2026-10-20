// 蓝牙「可被发现」的私有 API 封装（blueutil 同款函数）。
// macOS 自 10.9 起把可发现性绑在「系统设置 › 蓝牙」面板打开状态上；这个 API 在
// macOS 26 上是否仍有效需要用真实状态（system_profiler）验证，不能只看它自己的 getter
// （blueutil 文档明确说该 getter 会过时）。
// 只在诊断/自愈路径里用；失败不致命。
import Foundation

enum BluetoothDiscoverable {
    private typealias GetFn = @convention(c) () -> Int32
    private typealias SetFn = @convention(c) (Int32) -> Void

    private static let api: (get: GetFn, set: SetFn)? = {
        guard let h = dlopen("/System/Library/Frameworks/IOBluetooth.framework/IOBluetooth", RTLD_LAZY),
              let g = dlsym(h, "IOBluetoothPreferenceGetDiscoverableState"),
              let s = dlsym(h, "IOBluetoothPreferenceSetDiscoverableState") else { return nil }
        return (unsafeBitCast(g, to: GetFn.self), unsafeBitCast(s, to: SetFn.self))
    }()

    static var available: Bool { api != nil }

    /// 私有 getter 的读数（可能过时；真实状态看 system_profiler）。
    static func rawState() -> Int32? { api?.get() }

    /// 设置可发现状态，最多等 5 秒看私有 getter 是否变化；返回 getter 的最终读数。
    static func set(_ on: Bool) -> Int32? {
        guard let api else { return nil }
        api.set(on ? 1 : 0)
        for _ in 0..<50 {
            usleep(100_000)
            if (api.get() == 1) == on { break }
        }
        return api.get()
    }
}
