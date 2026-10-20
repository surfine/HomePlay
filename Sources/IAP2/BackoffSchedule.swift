// 蓝牙重连退避策略（对齐 MacPlay ConnectionPolicy 与桌宠端）：梯子 5/10/20/30/60 之后保持 60；
// 会话 live 时固定慢速 60 且不推进梯子；连接曾认证成功（0xAA05）则归零。
// 纯策略：调度与计时由调用方负责，离线测试直接驱动。

import Foundation

package struct BackoffSchedule: Sendable, Equatable {
    package let ladder: [TimeInterval]
    package let slow: TimeInterval
    package private(set) var step = 0

    package init(ladder: [TimeInterval], slow: TimeInterval) {
        precondition(!ladder.isEmpty)
        self.ladder = ladder
        self.slow = slow
    }

    /// 下一次重连的等待秒数。live 期间走慢速、不推进；否则沿梯子推进并在顶端保持。
    package mutating func next(live: Bool) -> TimeInterval {
        if live { return slow }
        let delay = ladder[min(step, ladder.count - 1)]
        step += 1
        return delay
    }

    /// 连接健康过（认证通过）就归零，下次断开从梯子头开始。
    package mutating func reset() { step = 0 }
}
