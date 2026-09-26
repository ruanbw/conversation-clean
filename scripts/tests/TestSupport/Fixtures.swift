import Foundation
import SQLite3

/// 测试夹具构造助手。
///
/// 替代原先在每个 mock 测试里逐行重复的 `try? fm.createDirectory(...)`、
/// `try? content.write(to:atomically:encoding:)` 与 sqlite3 开关库样板。
enum Fixture {
    /// 创建（必要时递归创建）目录。
    @discardableResult
    static func dir(_ url: URL) -> URL {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// 按顺序创建多个目录。
    static func dirs(_ urls: URL...) {
        for url in urls { dir(url) }
    }

    /// 写入 UTF-8 文本。
    @discardableResult
    static func write(_ content: String, to url: URL) -> URL {
        try? content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// 在 `parent` 下以 `name` 写入 UTF-8 文本并返回文件 URL。
    @discardableResult
    static func write(_ content: String, to parent: URL, name: String) -> URL {
        write(content, to: parent.appendingPathComponent(name))
    }

    /// 创建带随机后缀的临时目录（已解析符号链接，避免 `/var` 与 `/private/var` 不一致）。
    static func tempDirectory(prefix: String) -> URL {
        TestRunner.createTempDirectory(prefix: prefix)
    }

    /// 无返回值地执行一条 SQL。
    @discardableResult
    static func exec(_ db: OpaquePointer, _ sql: String) -> Int32 {
        sqlite3_exec(db, sql, nil, nil, nil)
    }

    /// 打开（必要时创建）SQLite 库、执行 `body`、随后关闭。
    ///
    /// 替代原先每个建库点都要重复的 `var db: OpaquePointer?` / `if sqlite3_open(...) == SQLITE_OK`
    /// / `else { 断言失败 }` / `sqlite3_close(...)` 样板。
    ///
    /// - Parameters:
    ///   - url: 数据库文件路径。
    ///   - test: 用于在打开失败时记录断言的用例上下文。
    ///   - failureMessage: 打开失败时的断言信息。
    ///   - body: 在库上执行建表/写入的闭包。
    @discardableResult
    static func sqlite(
        at url: URL,
        test: TestCase? = nil,
        failureMessage: String,
        _ body: (OpaquePointer) -> Void
    ) -> Bool {
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK, let db else {
            test?.fail(failureMessage)
            return false
        }
        body(db)
        sqlite3_close(db)
        return true
    }
}
