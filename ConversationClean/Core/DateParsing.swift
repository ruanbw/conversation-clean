import Foundation

/// 进程级共享的 ISO8601 时间解析。
///
/// 背景：`ISO8601DateFormatter` 的构造成本远高于单次解析本身，而 `AgentScanService.scanAll()`
/// 会通过 `withTaskGroup` 并发调用全部 scanner。此前 6 个 scanner 各自持有配置完全相同的
/// formatter 副本（另有 5 处每次调用都新建实例），因此这里统一为两个静态实例，
/// 并用锁串行化访问 —— 既消除重复，也消除并发共享可变 formatter 的隐患。
///
/// 覆盖了原先散落各处的两组配置：
/// - 带小数秒：`[.withInternetDateTime, .withFractionalSeconds]`
/// - 不带小数秒：`[.withInternetDateTime]`
enum ISODate {
    private static let lock = NSLock()

    private static let fractionalFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let plainFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    /// 依次尝试「带小数秒」与「不带小数秒」解析，空串返回 nil。
    ///
    /// 这是各 scanner 唯一实际使用的模式，替代原先的
    /// `fractional.date(from:) ?? plain.date(from:)` 写法。
    static func parse(_ string: String) -> Date? {
        guard !string.isEmpty else { return nil }
        lock.lock()
        defer { lock.unlock() }
        return fractionalFormatter.date(from: string) ?? plainFormatter.date(from: string)
    }
}
