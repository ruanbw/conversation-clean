import Foundation

/// 断言结果收集、控制台输出与临时目录工具。
///
/// 由 `TestCase` 调用，不直接在各测试中裸用 `assertTest`，以便测试名自动随用例走。
struct TestRunner {
    static var passedCount = 0
    static var failedCount = 0
    static var failures: [String] = []

    static func assertTest(_ condition: Bool, _ message: String, testName: String) {
        if condition {
            passedCount += 1
            print("  \u{001B}[32m[PASS]\u{001B}[0m \(message)")
        } else {
            failedCount += 1
            let failMsg = "[\(testName)] \(message)"
            failures.append(failMsg)
            print("  \u{001B}[31m[FAIL]\u{001B}[0m \(message)")
        }
    }

    static func printSection(_ title: String) {
        print("\n\u{001B}[1;36m==================================================================")
        print(">>> \(title)")
        print("==================================================================\u{001B}[0m")
    }

    static func printSubSection(_ title: String) {
        print("\n\u{001B}[1;33m--- \(title) ---\u{001B}[0m")
    }

    static func canonicalPath(_ path: String) -> String {
        (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.canonicalPathKey]).canonicalPath) ??
        URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }

    static func createTempDirectory(prefix: String) -> URL {
        let raw = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("\(prefix)_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: raw, withIntermediateDirectories: true)
        let resolved = (try? raw.resourceValues(forKeys: [.canonicalPathKey]).canonicalPath).map { URL(fileURLWithPath: $0) } ?? raw
        return resolved
    }

    /// 顺序执行整套用例并输出汇总。全部通过返回 0，否则返回 1。
    static func run(_ suite: [TestEntry]) async -> Int32 {
        print("\n\u{001B}[1;35m==================================================================")
        print("  CONVERSATION CLEAN: AGENT SCANNER VERIFICATION SUITE")
        print("==================================================================\u{001B}[0m")

        let startTime = Date()
        for entry in suite {
            await entry.run()
        }
        let elapsed = Date().timeIntervalSince(startTime)

        print("\n\u{001B}[1;35m==================================================================")
        print("  VERIFICATION SUMMARY")
        print("==================================================================\u{001B}[0m")
        print("Total Passed: \u{001B}[32m\(passedCount)\u{001B}[0m")
        print("Total Failed: \(failedCount > 0 ? "\u{001B}[31m\(failedCount)\u{001B}[0m" : "\u{001B}[32m0\u{001B}[0m")")
        print(String(format: "Execution Time: %.2f seconds", elapsed))

        guard failures.isEmpty else {
            print("\n\u{001B}[1;31mFailed Assertions:\u{001B}[0m")
            for failure in failures {
                print("  \u{001B}[31m• \(failure)\u{001B}[0m")
            }
            return 1
        }

        print("\n\u{001B}[1;32m>>> ALL AGENT SCANNER TESTS PASSED SUCCESSFULLY! <<<\u{001B}[0m\n")
        return 0
    }
}
