import Foundation

/// 单个测试用例的上下文。
///
/// 承担三件事，替代原先在每个测试里逐行重复的样板：
/// 1. 输出 section / subsection 标题；
/// 2. 断言时自动带上用例名（原先每处断言都要手写 `testName: testName`）；
/// 3. 提供 `sub(_:)` 输出子阶段标题。
struct TestCase {
    /// 失败信息中显示的用例名。
    let name: String

    /// - Parameters:
    ///   - name: 用例名，出现在失败汇总里。
    ///   - section: 非空时立即打印一级标题。
    ///   - subsection: 非空时立即打印二级标题。
    init(_ name: String, section: String? = nil, subsection: String? = nil) {
        self.name = name
        if let section {
            TestRunner.printSection(section)
        }
        if let subsection {
            TestRunner.printSubSection(subsection)
        }
    }

    /// 断言并自动归集失败信息。
    @discardableResult
    func assert(_ condition: Bool, _ message: String) -> Bool {
        TestRunner.assertTest(condition, message, testName: name)
        return condition
    }

    /// 打印子阶段标题。
    func sub(_ title: String) {
        TestRunner.printSubSection(title)
    }

    /// 失败断言（`assert(false, ...)` 的可读写法）。
    func fail(_ message: String) {
        TestRunner.assertTest(false, message, testName: name)
    }
}
