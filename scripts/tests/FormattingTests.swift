import Foundation

/// `Fmt` 的特征测试。
///
/// 这些断言锁的是行为本身，不是实现细节 —— 尤其锁住 1024 进制：
/// 同一条 2,411,724 字节的会话，1000 进制会打成 2.4 MB（`ByteCountFormatter`
/// 的口径），1024 进制打成 2.3 MB，后者才与 `du` / `df` / `ls -h` 一致。
/// 换成 `ByteCountFormatter` 会静默把这个应用通篇的磁盘占用数字都改掉，
/// 现有断言（2411724 → 2.3 MB）会立刻变红。
func testFormatting() async {
    TestRunner.printSection("Test: Fmt Formatting Helpers (Characterization)")

    let t = TestCase("Formatting")

    // ------------------------------------------------------------------------
    // Fmt.bytes —— 1024 进制，这是本次搬家最需要锁住的属性
    // ------------------------------------------------------------------------
    t.assert(Fmt.bytes(0) == "0 KB", "0 → 0 KB")
    t.assert(Fmt.bytes(1023) == "1.0 KB", "1023 → 1.0 KB（<10 保留 1 位小数）")
    t.assert(Fmt.bytes(1024) == "1.0 KB", "1024 → 1.0 KB")
    t.assert(Fmt.bytes(34 * 1024) == "34 KB", "34816 → 34 KB（≥10 四舍五入为整数）")
    t.assert(Fmt.bytes(2_411_724) == "2.3 MB", "2411724 → 2.3 MB（1024 而非 1000 进制）")
    t.assert(Fmt.bytes(1024 * 1024 * 1024) == "1.0 GB", "1 GiB → 1.0 GB")

    // ------------------------------------------------------------------------
    // Fmt.pathTail —— 只保留末两级
    // ------------------------------------------------------------------------
    t.assert(Fmt.pathTail("/Users/tester/projects/conversation-clean") == "…/projects/conversation-clean", "长路径保留末两级")
    t.assert(Fmt.pathTail("/a/b/c") == "…/b/c", "3 段路径保留末两级")
    t.assert(Fmt.pathTail("/foo") == "/foo", "≤2 段原样返回")

    // ------------------------------------------------------------------------
    // Fmt.abbreviateHome
    // ------------------------------------------------------------------------
    t.assert(Fmt.abbreviateHome("/opt/x") == "/opt/x", "非 home 前缀原样返回")
    // home 前缀：用当前用户的 home 现场构造输入，期望值只写死 home 之后的后缀，
    // 不把某个用户名写死在测试里。
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    t.assert(Fmt.abbreviateHome(home + "/Library/Caches/app") == "~/Library/Caches/app", "home 前缀缩写成 ~")

    // ------------------------------------------------------------------------
    // Fmt.relative —— 显式传 now，保证确定性
    // ------------------------------------------------------------------------
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let threeDaysAgo = now.addingTimeInterval(-3 * 86_400)
    t.assert(Fmt.relative(threeDaysAgo, now: now) == "3 天前", "3 天前 → 「3 天前」")

    // 30 天前已经越过 7 天窗口，形如 "M月D日"；月日用 Calendar 现算，不写死。
    let cal = Calendar.current
    let thirtyDaysAgo = now.addingTimeInterval(-30 * 86_400)
    let monthDay = "\(cal.component(.month, from: thirtyDaysAgo))月\(cal.component(.day, from: thirtyDaysAgo))日"
    t.assert(Fmt.relative(thirtyDaysAgo, now: now) == monthDay, "30 天前 → 「\(monthDay)」")

    // `isDateInToday` 走的是真实时钟，所以这一条只能用真实当前时间来构造。
    let realNow = Date()
    t.assert(Fmt.relative(realNow, now: realNow).hasPrefix("今天 "), "今天的日期以「今天 」开头")

    // ------------------------------------------------------------------------
    // Fmt.full —— 检视器「最后更新」用，精确到分
    // ------------------------------------------------------------------------
    // 固定 pattern（en_US_POSIX + "yyyy-MM-dd HH:mm"），与时区无关：
    // 断言的是形状而不是某个具体时刻的字符串。
    let stamp = Fmt.full(Date(timeIntervalSince1970: 0))
    let halves = stamp.split(separator: " ")
    let ymd = halves.count > 0 ? halves[0].split(separator: "-") : []
    let hm = halves.count > 1 ? halves[1].split(separator: ":") : []
    let allDigits = ymd.allSatisfy { $0.allSatisfy(\.isNumber) } && hm.allSatisfy { $0.allSatisfy(\.isNumber) }
    t.assert(ymd.count == 3 && ymd[0].count == 4 && ymd[1].count == 2 && ymd[2].count == 2
                && hm.count == 2 && hm[0].count == 2 && hm[1].count == 2 && allDigits,
             "full 形如 yyyy-MM-dd HH:mm（实际 \(stamp)）")
}
