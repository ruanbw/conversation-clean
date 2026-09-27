import Foundation

// MARK: - Formatting helpers

enum Fmt {
    /// 与原型 `fmtBytes` 同口径：**1024 进制**、小于 10 保留 1 位小数、
    /// ≥10 四舍五入为整数、0 输出「0 KB」。
    ///
    /// 不能用 `ByteCountFormatter`，它是 1000 进制：同一条 2,411,724 字节的会话
    /// 会打成 2.4 MB，而磁盘工具（`du` / `df` / `ls -h`）与原型都显示 2.3 MB。
    /// 这个应用通篇在讲磁盘占用，用的必须是 1024。
    static func bytes(_ n: Int64) -> String {
        guard n != 0 else { return "0 KB" }
        let units = ["KB", "MB", "GB", "TB"]
        var value = Double(max(n, 0))
        var index = -1
        repeat {
            value /= 1024
            index += 1
        } while value >= 1024 && index < units.count - 1
        let text = value < 10 ? String(format: "%.1f", value) : String(Int(value.rounded()))
        return "\(text) \(units[index])"
    }

    /// 原型 `fmtFull`：`2026-09-26 19:54`。
    /// 检视器的「最后更新」用它（要精确到分），列表行第 3 行的「今天 19:26」用 `relative`。
    static func full(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.string(from: date)
    }

    /// 把 home 目录缩写成 `~`，供存储路径、关联文件这类长路径显示。
    static func abbreviateHome(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    /// 原型 `fmtDate(it)`：今天 HH:mm / 昨天 HH:mm / N 天前 / M月D日
    static func relative(_ date: Date, now: Date = Date()) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return "今天 " + hhmm(date) }
        if cal.isDateInYesterday(date) { return "昨天 " + hhmm(date) }
        let days = cal.dateComponents(
            [.day],
            from: cal.startOfDay(for: date),
            to: cal.startOfDay(for: now)
        ).day ?? 0
        if days > 0 && days < 7 { return "\(days) 天前" }
        return "\(cal.component(.month, from: date))月\(cal.component(.day, from: date))日"
    }

    private static func hhmm(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm"
        return f.string(from: date)
    }

    /// 原型 `shortPath()`：只保留路径末两级，前面加省略号。
    ///
    ///   `~/projects/conversation-clean` → `…/projects/conversation-clean`
    ///   `~/Developer/atlas-api`          → `…/atlas-api`
    ///
    /// 列表行第 3 行的项目路径用它，而不是整条路径 + `.tail` 截断 ——
    /// 后者砍掉的恰恰是末段，而末段才是区分两个同名项目的东西
    /// （`~/Library/Application Support/Open…` 在真实数据里占满整列，全都一样没用）。
    static func pathTail(_ path: String) -> String {
        let parts = path.split(separator: "/").map(String.init)
        guard parts.count > 2 else { return path }
        return "…/" + parts.suffix(2).joined(separator: "/")
    }
}
