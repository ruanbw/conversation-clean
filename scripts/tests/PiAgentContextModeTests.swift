import Foundation
import SQLite3

func testMockPiAgentContextModeSync() async {
    let t = TestCase("MockPiContextModeSync", section: "Test: Pi Agent context-mode 双层索引同步（幽灵会话修复）")

    let tempDir = TestRunner.createTempDirectory(prefix: "pi_cm_sync")
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let fm = FileManager.default
    let projectDir = tempDir.appendingPathComponent("agent/sessions/--Users-mock-cm--")
    let cmSessionsDir = tempDir.appendingPathComponent("context-mode/sessions")
    let cmContentDir = tempDir.appendingPathComponent("context-mode/content")
    let acpDir = tempDir.appendingPathComponent("pi-acp")

    for dir in [projectDir, cmSessionsDir, cmContentDir, acpDir] {
        Fixture.dir(dir)
    }

    t.sub("构造 Pi 会话文件 + context-mode 索引库")

    let sid1 = "01a0d1cc-4a16-74c5-bfbe-b36a0224af90"
    let sid2 = "01a0d1cc-4a16-74c5-bfbe-b36a0224af91"
    let jsonl1 = projectDir.appendingPathComponent("2026-09-10T10-00-00-000Z_\(sid1).jsonl")
    let jsonl2 = projectDir.appendingPathComponent("2026-09-11T11-00-00-000Z_\(sid2).jsonl")

    try? """
    {"type":"session","version":3,"id":"\(sid1)","timestamp":"2026-09-10T10:00:00.000Z","cwd":"/Users/mock/cm"}
    {"type":"message","id":"m1","message":{"role":"user","content":[{"type":"text","text":"context-mode 幽灵会话测试 A"}]}}
    """.write(to: jsonl1, atomically: true, encoding: .utf8)

    try? """
    {"type":"session","version":3,"id":"\(sid2)","timestamp":"2026-09-11T11:00:00.000Z","cwd":"/Users/mock/cm"}
    {"type":"message","id":"m2","message":{"role":"user","content":[{"type":"text","text":"context-mode 幽灵会话测试 B"}]}}
    """.write(to: jsonl2, atomically: true, encoding: .utf8)

    // 子代理嵌套会话（旧版 Pi 布局：<sessionDir>/<uuid>/run-0/session.jsonl）
    let nestedSessionDir = projectDir.appendingPathComponent("2026-09-10T10-00-00-000Z_\(sid1)")
    let nestedRunDir = nestedSessionDir.appendingPathComponent("4b0172f1-647c-452f-82fd-b53e43777777/run-0")
    Fixture.dir(nestedRunDir)
    let nestedJsonl = nestedRunDir.appendingPathComponent("session.jsonl")
    Fixture.write("{\"type\":\"session\",\"version\":3,\"id\":\"\(sid1)\"}", to: nestedJsonl)

    // 索引侧 session_id：sha256(会话文件绝对路径) 的前 16 位小写十六进制
    let cmId1 = PiAgentScanner.contextModeSessionId(forSessionFilePath: jsonl1.path)
    let cmId2 = PiAgentScanner.contextModeSessionId(forSessionFilePath: jsonl2.path)
    let cmIdNested = PiAgentScanner.contextModeSessionId(forSessionFilePath: nestedJsonl.path)
    let cmIdOther = "ffffffffffffffff"

    t.assert(cmId1.count == 16 && cmId1 == cmId1.lowercased(), "contextModeSessionId 产出 16 位小写十六进制")
    t.assert(
        PiAgentScanner.contextModeSessionId(forSessionFilePath: "/tmp/cc-ghost/sessions/--Users-mock-cm--/2026-09-10T10-00-00-000Z_01a0d1cc-4a16-74c5-bfbe-b36a0224af90.jsonl") == "bf05d5e4e506b232",
        "contextModeSessionId 与 context-mode 的 sha256[:16] 规则一致（回归基线值）")
    t.assert(Set([cmId1, cmId2, cmIdNested]).count == 3, "不同会话文件推导出不同索引 ID")

    // ── 共享的项目索引库（context-mode 当前 schema，含 4 张会话表）──
    let sessionsDb1 = cmSessionsDir.appendingPathComponent("aaaaaaaaaaaaaaaa.db")
    var db1: OpaquePointer?
    if sqlite3_open(sessionsDb1.path, &db1) == SQLITE_OK, let db1 = db1 {
        Fixture.exec(db1, "CREATE TABLE session_meta (session_id TEXT PRIMARY KEY, project_dir TEXT NOT NULL, started_at TEXT NOT NULL DEFAULT (datetime('now')), last_event_at TEXT, event_count INTEGER NOT NULL DEFAULT 0, compact_count INTEGER NOT NULL DEFAULT 0, usage_cursor TEXT);")
        Fixture.exec(db1, "CREATE TABLE session_events (id INTEGER PRIMARY KEY AUTOINCREMENT, session_id TEXT NOT NULL, type TEXT NOT NULL, category TEXT NOT NULL, priority INTEGER NOT NULL DEFAULT 2, data TEXT NOT NULL, created_at TEXT NOT NULL DEFAULT (datetime('now')));")
        Fixture.exec(db1, "CREATE TABLE session_resume (id INTEGER PRIMARY KEY AUTOINCREMENT, session_id TEXT NOT NULL UNIQUE, snapshot TEXT NOT NULL, event_count INTEGER NOT NULL, consumed INTEGER NOT NULL DEFAULT 0);")
        Fixture.exec(db1, "CREATE TABLE tool_calls (session_id TEXT NOT NULL, tool TEXT NOT NULL, calls INTEGER NOT NULL DEFAULT 0);")

        for sid in [cmId1, cmIdNested, cmIdOther] {
            Fixture.exec(db1, "INSERT OR REPLACE INTO session_meta (session_id, project_dir, event_count) VALUES ('\(sid)', '/Users/mock/cm', 3);")
            Fixture.exec(db1, "INSERT INTO session_events (session_id, type, category, data) VALUES ('\(sid)', 'decision', 'decision', 'payload');")
            Fixture.exec(db1, "INSERT OR REPLACE INTO session_resume (session_id, snapshot, event_count) VALUES ('\(sid)', 'snapshot', 3);")
            Fixture.exec(db1, "INSERT INTO tool_calls (session_id, tool, calls) VALUES ('\(sid)', 'bash', 2);")
        }
        sqlite3_close(db1)
    } else {
        t.assert(false, "无法创建 context-mode sessions 索引库")
    }

    // ── 旧版 schema 的独立索引库，仅含 sid2 行：清空后应连带删除文件 ──
    let sessionsDb2 = cmSessionsDir.appendingPathComponent("bbbbbbbbbbbbbbbb.db")
    var db2: OpaquePointer?
    if sqlite3_open(sessionsDb2.path, &db2) == SQLITE_OK, let db2 = db2 {
        Fixture.exec(db2, "CREATE TABLE session_meta (session_id TEXT PRIMARY KEY, cwd TEXT, created_at TEXT, updated_at TEXT, event_count INTEGER, is_archived INTEGER, title TEXT);")
        Fixture.exec(db2, "CREATE TABLE session_events (id INTEGER PRIMARY KEY AUTOINCREMENT, session_id TEXT NOT NULL, data TEXT);")
        Fixture.exec(db2, "INSERT INTO session_meta VALUES ('\(cmId2)', '/Users/mock/cm', '2026-09-11T11:00:00Z', '2026-09-11T11:00:00Z', 1, 0, 'legacy schema');")
        Fixture.exec(db2, "INSERT INTO session_events (session_id, data) VALUES ('\(cmId2)', 'legacy-event');")
        sqlite3_close(db2)
    } else {
        t.assert(false, "无法创建旧版 schema 的 context-mode 索引库")
    }

    // ── content/ 内容索引库（fts5 chunks，与真实环境一致）──
    let contentDb = cmContentDir.appendingPathComponent("cccccccccccccccc.db")
    var cdb: OpaquePointer?
    if sqlite3_open(contentDb.path, &cdb) == SQLITE_OK, let cdb = cdb {
        Fixture.exec(cdb, "CREATE TABLE sources (id INTEGER PRIMARY KEY AUTOINCREMENT, label TEXT NOT NULL, chunk_count INTEGER NOT NULL DEFAULT 0);")
        let ftsResult = Fixture.exec(cdb, "CREATE VIRTUAL TABLE chunks USING fts5(title, content, source_id UNINDEXED, session_id UNINDEXED, event_id UNINDEXED, tokenize='porter unicode61');")
        t.assert(ftsResult == SQLITE_OK, "测试环境支持 fts5 内容索引（与 context-mode content/*.db 一致）")
        Fixture.exec(cdb, "INSERT INTO sources (label, chunk_count) VALUES ('other-source', 1);")
        Fixture.exec(cdb, "INSERT INTO chunks (title, content, source_id, session_id, event_id) VALUES ('t1', 'c1', '1', '\(cmId1)', 'e1');")
        Fixture.exec(cdb, "INSERT INTO chunks (title, content, source_id, session_id, event_id) VALUES ('t2', 'c2', '1', '\(cmIdOther)', 'e2');")
        sqlite3_close(cdb)
    } else {
        t.assert(false, "无法创建 context-mode content 索引库")
    }

    // ── stats-pid 进程统计缓存 ──
    let statsLinked = cmSessionsDir.appendingPathComponent("stats-pid-4242.json")
    let statsUnlinked = cmSessionsDir.appendingPathComponent("stats-pid-4343.json")
    Fixture.write("{\"schemaVersion\":2,\"session\":\"\(cmId1)\"}", to: statsLinked)
    Fixture.write("{\"schemaVersion\":2,\"session\":\"\(cmIdOther)\"}", to: statsUnlinked)

    // ── pi-acp 会话映射表（ACP 客户端的会话索引）──
    let acpMapURL = acpDir.appendingPathComponent("session-map.json")
    let unrelatedJsonl = tempDir.appendingPathComponent("unrelated/other-session.jsonl")
    Fixture.dir(unrelatedJsonl.deletingLastPathComponent())
    Fixture.write("{\"type\":\"session\",\"id\":\"other-session\"}", to: unrelatedJsonl)
    let ghostJsonlPath = tempDir.appendingPathComponent("ghost-dangling.jsonl").path
    let acpMapJSON = """
    {
      "version": 1,
      "sessions": {
        "\(sid1)": {"sessionId": "\(sid1)", "cwd": "/Users/mock/cm", "sessionFile": "\(jsonl1.path)"},
        "\(sid2)": {"sessionId": "\(sid2)", "cwd": "/Users/mock/cm", "sessionFile": "\(jsonl2.path)"},
        "other-session": {"sessionId": "other-session", "cwd": "/tmp", "sessionFile": "\(unrelatedJsonl.path)"},
        "ghost-dangling": {"sessionId": "ghost-dangling", "cwd": "/tmp", "sessionFile": "\(ghostJsonlPath)"}
      }
    }
    """
    Fixture.write(acpMapJSON, to: acpMapURL)

    func scalarCount(_ dbURL: URL, _ sql: String) -> Int? {
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbURL.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db = db else { return nil }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return Int(sqlite3_column_int(stmt, 0))
    }

    let scanner = PiAgentScanner(storageURL: tempDir)

    do {
        let items = try await scanner.scan()
        t.assert(items.count == 2, "扫描到 2 个 Pi 会话（实际 \(items.count)）")

        guard let item1 = items.first(where: { $0.sessionId == sid1 }),
              let item2 = items.first(where: { $0.sessionId == sid2 }) else {
            t.assert(false, "未找到预期的两个 Pi 会话")
            return
        }

        t.sub("删除单个会话：物理文件 + context-mode 索引同步")
        let freed = try await scanner.delete(items: [item1])
        t.assert(freed == item1.sizeInBytes, "delete([item1]) 释放字节数等于 item1.sizeInBytes")
        t.assert(!fm.fileExists(atPath: jsonl1.path), "sid1 会话文件已从磁盘删除")
        t.assert(!fm.fileExists(atPath: nestedSessionDir.path), "sid1 子代理嵌套会话目录已删除")
        t.assert(fm.fileExists(atPath: jsonl2.path), "sid2 会话文件未被误删")

        // context-mode sessions 索引库（当前 schema）
        t.assert(scalarCount(sessionsDb1, "SELECT COUNT(*) FROM session_meta WHERE session_id = '\(cmId1)';") == 0, "session_meta 中 sid1 索引行已清除")
        t.assert(scalarCount(sessionsDb1, "SELECT COUNT(*) FROM session_events WHERE session_id = '\(cmId1)';") == 0, "session_events 中 sid1 行已清除")
        t.assert(scalarCount(sessionsDb1, "SELECT COUNT(*) FROM session_resume WHERE session_id = '\(cmId1)';") == 0, "session_resume 中 sid1 行已清除")
        t.assert(scalarCount(sessionsDb1, "SELECT COUNT(*) FROM tool_calls WHERE session_id = '\(cmId1)';") == 0, "tool_calls 中 sid1 行已清除")
        t.assert(scalarCount(sessionsDb1, "SELECT COUNT(*) FROM session_meta WHERE session_id = '\(cmIdNested)';") == 0, "子代理嵌套会话索引行已清除")
        t.assert(scalarCount(sessionsDb1, "SELECT COUNT(*) FROM session_meta WHERE session_id = '\(cmIdOther)';") == 1, "其他会话 session_meta 行被保留")
        t.assert(scalarCount(sessionsDb1, "SELECT COUNT(*) FROM tool_calls WHERE session_id = '\(cmIdOther)';") == 1, "其他会话 tool_calls 行被保留")
        t.assert(fm.fileExists(atPath: sessionsDb1.path), "仍含其他会话的索引库文件被保留")

        // content/ 内容索引（fts5）
        t.assert(scalarCount(contentDb, "SELECT COUNT(*) FROM chunks WHERE session_id = '\(cmId1)';") == 0, "content fts5 chunks 中 sid1 行已清除")
        t.assert(scalarCount(contentDb, "SELECT COUNT(*) FROM chunks WHERE session_id = '\(cmIdOther)';") == 1, "content fts5 chunks 保留其他来源")
        t.assert(scalarCount(contentDb, "SELECT COUNT(*) FROM sources;") == 1, "content sources 表未被误删")

        // stats 缓存与 pi-acp 映射
        t.assert(!fm.fileExists(atPath: statsLinked.path), "引用被删会话的 stats-pid 缓存已清理")
        t.assert(fm.fileExists(atPath: statsUnlinked.path), "无关 stats-pid 缓存被保留")

        let acpAfterDelete = (try? String(contentsOf: acpMapURL, encoding: .utf8)) ?? ""
        t.assert(!acpAfterDelete.contains(sid1), "pi-acp session-map 中 sid1 条目已剪除")
        t.assert(acpAfterDelete.contains(sid2), "pi-acp session-map 保留 sid2 条目")
        t.assert(acpAfterDelete.contains("other-session"), "pi-acp session-map 保留其他有效条目")
        t.assert(!acpAfterDelete.contains("ghost-dangling"), "pi-acp session-map 中指向已不存在文件的幽灵条目已剪除")

        t.sub("删除最后一个会话：清空后的索引库连带清理")
        let freed2 = try await scanner.delete(items: [item2])
        t.assert(freed2 == item2.sizeInBytes, "delete([item2]) 释放字节数正确")
        t.assert(scalarCount(sessionsDb1, "SELECT COUNT(*) FROM session_meta WHERE session_id = '\(cmId2)';") == 0, "共享库中不存在 sid2 残留行")
        t.assert(fm.fileExists(atPath: sessionsDb1.path) && scalarCount(sessionsDb1, "SELECT COUNT(*) FROM session_meta WHERE session_id = '\(cmIdOther)';") == 1, "共享库仍保留其他项目会话（不误删）")
        t.assert(!fm.fileExists(atPath: sessionsDb2.path), "旧 schema 且已被清空的索引库文件被删除")
        let acpAfterSecondDelete = (try? String(contentsOf: acpMapURL, encoding: .utf8)) ?? ""
        t.assert(!acpAfterSecondDelete.contains(sid2), "pi-acp session-map 中 sid2 条目已剪除")
        t.assert(acpAfterSecondDelete.contains("other-session") && !acpAfterSecondDelete.contains("ghost-dangling"), "pi-acp session-map 仅保留有效条目")

        t.sub("cleanAll：context-mode / pi-acp 全量清理")
        let allFreed = try await scanner.cleanAll()
        t.assert(allFreed > 0, "cleanAll() 释放字节数 > 0（\(allFreed)）")
        let cmSessionEntries = (try? fm.contentsOfDirectory(at: cmSessionsDir, includingPropertiesForKeys: nil)) ?? []
        t.assert(cmSessionEntries.filter { $0.pathExtension == "db" }.isEmpty, "cleanAll 后 context-mode/sessions 无残留索引库")
        t.assert(cmSessionEntries.filter { $0.lastPathComponent.hasPrefix("stats-pid-") }.isEmpty, "cleanAll 后 stats-pid-*.json 全部清理")
        let cmContentEntries = (try? fm.contentsOfDirectory(at: cmContentDir, includingPropertiesForKeys: nil)) ?? []
        t.assert(cmContentEntries.isEmpty, "cleanAll 后 context-mode/content 清空")
        t.assert(!fm.fileExists(atPath: acpMapURL.path), "cleanAll 后 pi-acp session-map.json 已清理")

        let postScan = try await scanner.scan()
        t.assert(postScan.isEmpty, "cleanAll 后重扫结果为 0（无幽灵会话）")
    } catch {
        t.assert(false, "context-mode 双层索引同步测试抛出异常: \(error)")
    }
}
