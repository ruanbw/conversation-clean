import Foundation
import SQLite3

final class CursorScanner: AgentScanner, @unchecked Sendable {
    let category: ConversationCategory = .cursor
    let customStorageURL: URL?

    init(baseURL: URL? = nil) {
        self.customStorageURL = baseURL
    }

    convenience init(storageURL: URL) {
        self.init(baseURL: storageURL)
    }

    var storageURL: URL {
        let base: URL
        if let custom = customStorageURL {
            base = custom
        } else if let env = ProcessInfo.processInfo.environment["CURSOR_HOME"], !env.isEmpty {
            base = URL(fileURLWithPath: env)
        } else {
            base = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/Cursor")
        }
        return (try? base.resourceValues(forKeys: [.canonicalPathKey]).canonicalPath).map { URL(fileURLWithPath: $0) } ?? base.standardized
    }

    var userDirectoryURL: URL {
        let directUser = storageURL.appendingPathComponent("User")
        let directWS = storageURL.appendingPathComponent("workspaceStorage")
        let fm = FileManager.default
        if fm.fileExists(atPath: directUser.path) {
            return directUser
        } else if fm.fileExists(atPath: directWS.path) {
            return storageURL
        }
        return directUser
    }

    var dotCursorURL: URL {
        if let custom = customStorageURL {
            let candidate = custom.appendingPathComponent(".cursor")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cursor")
    }

    var isInstalled: Bool {
        let fm = FileManager.default
        if fm.fileExists(atPath: storageURL.path) {
            return true
        }
        if customStorageURL != nil {
            return false
        }
        let dotCursor = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cursor")
        return fm.fileExists(atPath: dotCursor.path)
    }

    // MARK: - Scan

    private struct ScanTarget: Sendable {
        let fileURL: URL
        let projectPath: String?
        let editingDirURL: URL?
    }

    func scan() async throws -> [ConversationItem] {
        guard isInstalled else { return [] }

        let fileManager = FileManager.default
        var items: [ConversationItem] = []

        let userDir = userDirectoryURL
        let workspaceStorageDir = userDir.appendingPathComponent("workspaceStorage")

        // 1. Scan User/workspaceStorage/*/chatSessions/*.jsonl
        if fileManager.fileExists(atPath: workspaceStorageDir.path),
           let wsEntries = try? fileManager.contentsOfDirectory(
               at: workspaceStorageDir,
               includingPropertiesForKeys: [.isDirectoryKey],
               options: [.skipsHiddenFiles]
           ) {
            var jsonlTargets: [ScanTarget] = []

            for wsDir in wsEntries {
                var isDir: ObjCBool = false
                guard fileManager.fileExists(atPath: wsDir.path, isDirectory: &isDir), isDir.boolValue else {
                    continue
                }

                let wsJsonURL = wsDir.appendingPathComponent("workspace.json")
                let projectPath = Self.extractProjectPath(from: wsJsonURL)

                // Check chatSessions/
                let chatSessionsDir = wsDir.appendingPathComponent("chatSessions")
                let chatEditingDir = wsDir.appendingPathComponent("chatEditingSessions")

                if fileManager.fileExists(atPath: chatSessionsDir.path),
                   let sessionFiles = try? fileManager.contentsOfDirectory(
                       at: chatSessionsDir,
                       includingPropertiesForKeys: [.isRegularFileKey],
                       options: [.skipsHiddenFiles]
                   ) {
                    for sessionFile in sessionFiles where sessionFile.pathExtension.lowercased() == "jsonl" {
                        let sid = sessionFile.deletingPathExtension().lastPathComponent
                        let editingURL = chatEditingDir.appendingPathComponent(sid)
                        let matchingEdit = fileManager.fileExists(atPath: editingURL.path) ? editingURL : nil

                        jsonlTargets.append(ScanTarget(
                            fileURL: sessionFile,
                            projectPath: projectPath,
                            editingDirURL: matchingEdit
                        ))
                    }
                }

                // 2. Scan User/workspaceStorage/*/state.vscdb
                let stateDbURL = wsDir.appendingPathComponent("state.vscdb")
                if fileManager.fileExists(atPath: stateDbURL.path) {
                    let dbItems = parseStateDatabase(dbURL: stateDbURL, projectPath: projectPath)
                    items.append(contentsOf: dbItems)
                }
            }

            // Concurrently parse chatSessions jsonl
            let parsedJsonl: [ConversationItem] = await withTaskGroup(of: ConversationItem?.self) { group in
                for target in jsonlTargets {
                    group.addTask {
                        return self.parseJsonlSession(target: target)
                    }
                }

                var collected: [ConversationItem] = []
                for await item in group {
                    if let item = item {
                        collected.append(item)
                    }
                }
                return collected
            }
            items.append(contentsOf: parsedJsonl)
        }

        // 3. Scan User/globalStorage/
        let globalStorageDir = userDir.appendingPathComponent("globalStorage")
        let emptyWindowDir = globalStorageDir.appendingPathComponent("emptyWindowChatSessions")
        if fileManager.fileExists(atPath: emptyWindowDir.path),
           let emptyFiles = try? fileManager.contentsOfDirectory(
               at: emptyWindowDir,
               includingPropertiesForKeys: [.isRegularFileKey],
               options: [.skipsHiddenFiles]
           ) {
            for sessionFile in emptyFiles where sessionFile.pathExtension.lowercased() == "jsonl" {
                if let item = parseJsonlSession(target: ScanTarget(fileURL: sessionFile, projectPath: nil, editingDirURL: nil)) {
                    items.append(item)
                }
            }
        }

        // Scan globalStorage/cursor.cursor/
        let cursorExtDir = globalStorageDir.appendingPathComponent("cursor.cursor")
        if fileManager.fileExists(atPath: cursorExtDir.path) {
            let extItems = scanCursorExtensionStorage(dirURL: cursorExtDir)
            items.append(contentsOf: extItems)
        }

        // 4. Scan ~/.cursor/
        let dotCursor = dotCursorURL
        if fileManager.fileExists(atPath: dotCursor.path) {
            let dotItems = scanDotCursorDirectory(dotURL: dotCursor)
            items.append(contentsOf: dotItems)
        }

        return items.sorted(by: { $0.updatedAt > $1.updatedAt })
    }

    // MARK: - Delete & Clean

    func delete(items: [ConversationItem]) async throws -> Int64 {
        guard !items.isEmpty else { return 0 }

        var totalFreed: Int64 = 0
        var stateDbComposersToDelete: [String: Set<String>] = [:] // dbPath: Set<sessionId>

        for item in items {
            totalFreed += item.sizeInBytes

            for path in item.associatedPaths {
                if path.hasSuffix(".vscdb") {
                    stateDbComposersToDelete[path, default: []].insert(item.sessionId)
                } else {
                    _ = FileSizeHelper.removeIfExists(path: path)
                }
            }
        }

        // Handle state.vscdb composer deletions
        for (dbPath, sessionIds) in stateDbComposersToDelete {
            deleteComposersFromStateDb(dbPath: dbPath, sessionIds: sessionIds)
        }

        cleanEmptyWorkspaceStorageDirs()

        return totalFreed
    }

    func cleanAll() async throws -> Int64 {
        let items = try await scan()
        var freed = try await delete(items: items)

        let fileManager = FileManager.default
        let userDir = userDirectoryURL
        let workspaceStorageDir = userDir.appendingPathComponent("workspaceStorage")

        // Clean chatSessions & chatEditingSessions in workspaceStorage
        if fileManager.fileExists(atPath: workspaceStorageDir.path),
           let wsEntries = try? fileManager.contentsOfDirectory(
               at: workspaceStorageDir,
               includingPropertiesForKeys: [.isDirectoryKey],
               options: [.skipsHiddenFiles]
           ) {
            for wsDir in wsEntries {
                let chatDir = wsDir.appendingPathComponent("chatSessions")
                if fileManager.fileExists(atPath: chatDir.path) {
                    let sz = FileSizeHelper.sizeOf(path: chatDir.path)
                    if FileSizeHelper.removeIfExists(path: chatDir.path) {
                        freed += sz
                    }
                }

                let editDir = wsDir.appendingPathComponent("chatEditingSessions")
                if fileManager.fileExists(atPath: editDir.path) {
                    let sz = FileSizeHelper.sizeOf(path: editDir.path)
                    if FileSizeHelper.removeIfExists(path: editDir.path) {
                        freed += sz
                    }
                }

                // Clean state.vscdb composer keys
                let stateDb = wsDir.appendingPathComponent("state.vscdb")
                if fileManager.fileExists(atPath: stateDb.path) {
                    clearStateDatabaseChatData(dbURL: stateDb)
                }
            }
        }

        // Clean emptyWindowChatSessions
        let globalStorageDir = userDir.appendingPathComponent("globalStorage")
        let emptyWindowDir = globalStorageDir.appendingPathComponent("emptyWindowChatSessions")
        if fileManager.fileExists(atPath: emptyWindowDir.path) {
            let sz = FileSizeHelper.sizeOf(path: emptyWindowDir.path)
            if FileSizeHelper.removeIfExists(path: emptyWindowDir.path) {
                freed += sz
                try? fileManager.createDirectory(at: emptyWindowDir, withIntermediateDirectories: true)
            }
        }

        // Clean User/globalStorage/cursor.cursor/
        let cursorExtDir = globalStorageDir.appendingPathComponent("cursor.cursor")
        if fileManager.fileExists(atPath: cursorExtDir.path) {
            let sz = FileSizeHelper.sizeOf(path: cursorExtDir.path)
            if FileSizeHelper.removeIfExists(path: cursorExtDir.path) {
                freed += sz
                try? fileManager.createDirectory(at: cursorExtDir, withIntermediateDirectories: true)
            }
        }

        // Clean ~/.cursor/chats
        let dotCursorChats = dotCursorURL.appendingPathComponent("chats")
        if fileManager.fileExists(atPath: dotCursorChats.path) {
            let sz = FileSizeHelper.sizeOf(path: dotCursorChats.path)
            if FileSizeHelper.removeIfExists(path: dotCursorChats.path) {
                freed += sz
                try? fileManager.createDirectory(at: dotCursorChats, withIntermediateDirectories: true)
            }
        }

        cleanEmptyWorkspaceStorageDirs()

        return freed
    }

    // MARK: - JSONL Parsing

    private func parseJsonlSession(target: ScanTarget) -> ConversationItem? {
        let fileManager = FileManager.default
        let fileURL = target.fileURL
        guard fileManager.fileExists(atPath: fileURL.path) else { return nil }

        let fileAttrs = try? fileManager.attributesOfItem(atPath: fileURL.path)
        let mainFileSize = (fileAttrs?[.size] as? NSNumber)?.int64Value ?? FileSizeHelper.sizeOf(path: fileURL.path)
        let fallbackBaseName = fileURL.deletingPathExtension().lastPathComponent

        var detectedSessionId: String?
        var detectedCreationDateMs: Double?
        var detectedCustomTitle: String?
        var firstUserPrompt: String?
        var requestCount = 0

        if let content = try? String(contentsOf: fileURL, encoding: .utf8) {
            content.enumerateLines { line, _ in
                guard !line.isEmpty,
                      let data = line.data(using: .utf8),
                      let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                    return
                }

                let kind = json["kind"] as? Int
                let k = json["k"] as? [Any]
                let v = json["v"]

                if kind == 0, let vDict = v as? [String: Any] {
                    if let sid = vDict["sessionId"] as? String, !sid.isEmpty {
                        detectedSessionId = sid
                    }
                    if let cd = vDict["creationDate"] as? NSNumber {
                        detectedCreationDateMs = cd.doubleValue
                    }
                    if let ct = vDict["customTitle"] as? String, !ct.isEmpty {
                        detectedCustomTitle = ct
                    }
                    if let reqs = vDict["requests"] as? [[String: Any]] {
                        requestCount += reqs.count
                        for req in reqs {
                            if firstUserPrompt == nil {
                                firstUserPrompt = Self.extractPromptText(from: req)
                            }
                        }
                    }
                } else if kind == 1 {
                    if let kFirst = k?.first as? String {
                        if kFirst == "customTitle", let str = v as? String, !str.isEmpty {
                            detectedCustomTitle = str
                        } else if kFirst == "sessionId", let str = v as? String, !str.isEmpty {
                            detectedSessionId = str
                        }
                    }
                } else if kind == 2 {
                    if let k = k, k.count == 1, let kFirst = k.first as? String, kFirst == "requests", let reqs = v as? [[String: Any]] {
                        requestCount += reqs.count
                        for req in reqs {
                            if firstUserPrompt == nil {
                                firstUserPrompt = Self.extractPromptText(from: req)
                            }
                        }
                    }
                }

                if detectedSessionId == nil, let sid = json["sessionId"] as? String, !sid.isEmpty {
                    detectedSessionId = sid
                }
                if detectedCreationDateMs == nil, let cd = json["creationDate"] as? NSNumber {
                    detectedCreationDateMs = cd.doubleValue
                }
            }
        }

        let sessionId = detectedSessionId ?? fallbackBaseName

        let finalTitle: String
        if let prompt = firstUserPrompt, !prompt.isEmpty {
            let singleLine = prompt.components(separatedBy: .newlines).first?.trimmingCharacters(in: .whitespaces) ?? prompt
            finalTitle = singleLine.isEmpty ? "Cursor 对话" : String(singleLine.prefix(80))
        } else if let custom = detectedCustomTitle, !custom.isEmpty {
            let singleLine = custom.components(separatedBy: .newlines).first?.trimmingCharacters(in: .whitespaces) ?? custom
            finalTitle = singleLine.isEmpty ? "Cursor 对话" : String(singleLine.prefix(80))
        } else {
            finalTitle = "Cursor 对话"
        }

        let snippet: String
        if let prompt = firstUserPrompt, !prompt.isEmpty {
            let singleLine = prompt.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
            snippet = String(singleLine.prefix(160))
        } else {
            snippet = finalTitle
        }

        let updatedDate: Date
        if let ms = detectedCreationDateMs, ms > 0 {
            updatedDate = Date(timeIntervalSince1970: ms / 1000.0)
        } else if let modDate = fileAttrs?[.modificationDate] as? Date {
            updatedDate = modDate
        } else {
            updatedDate = Date()
        }

        var associatedPaths: [String] = [fileURL.path]
        var totalSize = mainFileSize

        if let editingDir = target.editingDirURL, fileManager.fileExists(atPath: editingDir.path) {
            associatedPaths.append(editingDir.path)
            totalSize += FileSizeHelper.sizeOf(path: editingDir.path)
        }

        return ConversationItem(
            id: UUID(),
            sessionId: sessionId,
            title: finalTitle,
            category: self.category,
            projectPath: target.projectPath,
            gitBranch: nil,
            messageCount: requestCount,
            sizeInBytes: totalSize,
            updatedAt: updatedDate,
            isSelected: false,
            snippet: snippet,
            associatedPaths: associatedPaths
        )
    }

    // MARK: - SQLite state.vscdb Parsing

    private func parseStateDatabase(dbURL: URL, projectPath: String?) -> [ConversationItem] {
        var items: [ConversationItem] = []
        let dbPath = dbURL.path
        let fileSize = FileSizeHelper.sizeOf(path: dbPath)

        // Try SQLite first
        var db: OpaquePointer?
        if sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK {
            defer { sqlite3_close(db) }

            let query = "SELECT key, value FROM ItemTable WHERE key IN ('composer.composerData', 'workbench.panel.aichat.view.aichat.chatdata');"
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK {
                defer { sqlite3_finalize(stmt) }

                while sqlite3_step(stmt) == SQLITE_ROW {
                    guard let keyPtr = sqlite3_column_text(stmt, 0),
                          let valPtr = sqlite3_column_text(stmt, 1) else { continue }

                    let key = String(cString: keyPtr)
                    let valueStr = String(cString: valPtr)

                    if key == "composer.composerData" {
                        let parsed = parseComposerDataString(valueStr, dbURL: dbURL, totalDbSize: fileSize, projectPath: projectPath)
                        items.append(contentsOf: parsed)
                    } else if key == "workbench.panel.aichat.view.aichat.chatdata" {
                        let parsed = parseAiChatDataString(valueStr, dbURL: dbURL, totalDbSize: fileSize, projectPath: projectPath)
                        items.append(contentsOf: parsed)
                    }
                }
            }
        }

        // Fallback for mock test fixture files (plain JSON or non-SQLite)
        if items.isEmpty {
            if let data = try? Data(contentsOf: dbURL),
               let jsonStr = String(data: data, encoding: .utf8) {
                let parsed = parseComposerDataString(jsonStr, dbURL: dbURL, totalDbSize: fileSize, projectPath: projectPath)
                items.append(contentsOf: parsed)
            }
        }

        return items
    }

    private func parseComposerDataString(_ str: String, dbURL: URL, totalDbSize: Int64, projectPath: String?) -> [ConversationItem] {
        guard let data = str.data(using: .utf8),
              let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let composers = dict["allComposers"] as? [[String: Any]], !composers.isEmpty else {
            return []
        }

        var results: [ConversationItem] = []
        let count = Int64(composers.count)
        let perComposerSize = max(1, totalDbSize / count)

        for composer in composers {
            let cid = composer["composerId"] as? String ?? UUID().uuidString
            let name = composer["name"] as? String
            let text = composer["text"] as? String
            let richText = composer["richText"] as? String

            let rawTitle = name ?? text ?? richText ?? "Cursor Composer"
            let singleLine = rawTitle.components(separatedBy: .newlines).first?.trimmingCharacters(in: .whitespaces) ?? rawTitle
            let title = singleLine.isEmpty ? "Cursor Composer" : String(singleLine.prefix(80))

            var msgCount = 1
            if let msgs = composer["conversation"] as? [Any] {
                msgCount = msgs.count
            } else if let msgs = composer["messages"] as? [Any] {
                msgCount = msgs.count
            }

            let date: Date
            if let lastUpdated = (composer["lastUpdatedAt"] as? NSNumber)?.doubleValue, lastUpdated > 0 {
                date = Date(timeIntervalSince1970: lastUpdated > 1_000_000_000_000 ? lastUpdated / 1000.0 : lastUpdated)
            } else if let created = (composer["createdAt"] as? NSNumber)?.doubleValue, created > 0 {
                date = Date(timeIntervalSince1970: created > 1_000_000_000_000 ? created / 1000.0 : created)
            } else {
                date = (try? dbURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
            }

            results.append(ConversationItem(
                id: UUID(),
                sessionId: cid,
                title: title,
                category: self.category,
                projectPath: projectPath,
                gitBranch: nil,
                messageCount: msgCount,
                sizeInBytes: perComposerSize,
                updatedAt: date,
                isSelected: false,
                snippet: title,
                associatedPaths: [dbURL.path]
            ))
        }

        return results
    }

    private func parseAiChatDataString(_ str: String, dbURL: URL, totalDbSize: Int64, projectPath: String?) -> [ConversationItem] {
        guard let data = str.data(using: .utf8),
              let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let tabs = dict["tabs"] as? [[String: Any]], !tabs.isEmpty else {
            return []
        }

        var results: [ConversationItem] = []
        let count = Int64(tabs.count)
        let perTabSize = max(1, totalDbSize / count)

        for tab in tabs {
            let tid = tab["id"] as? String ?? tab["tabId"] as? String ?? UUID().uuidString
            let chatTitle = tab["chatTitle"] as? String ?? "Cursor 对话"
            let bubbles = tab["bubbles"] as? [[String: Any]] ?? []

            results.append(ConversationItem(
                id: UUID(),
                sessionId: tid,
                title: String(chatTitle.prefix(80)),
                category: self.category,
                projectPath: projectPath,
                gitBranch: nil,
                messageCount: bubbles.count,
                sizeInBytes: perTabSize,
                updatedAt: (try? dbURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date(),
                isSelected: false,
                snippet: chatTitle,
                associatedPaths: [dbURL.path]
            ))
        }

        return results
    }

    private func deleteComposersFromStateDb(dbPath: String, sessionIds: Set<String>) {
        var db: OpaquePointer?
        if sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK {
            defer { sqlite3_close(db) }

            let selectQuery = "SELECT value FROM ItemTable WHERE key = 'composer.composerData';"
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, selectQuery, -1, &stmt, nil) == SQLITE_OK {
                if sqlite3_step(stmt) == SQLITE_ROW, let valPtr = sqlite3_column_text(stmt, 0) {
                    let valueStr = String(cString: valPtr)
                    sqlite3_finalize(stmt)
                    stmt = nil

                    if let data = valueStr.data(using: .utf8),
                       var dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                       var composers = dict["allComposers"] as? [[String: Any]] {

                        composers.removeAll { c in
                            guard let id = c["composerId"] as? String else { return false }
                            return sessionIds.contains(id)
                        }

                        dict["allComposers"] = composers

                        if composers.isEmpty {
                            let delQuery = "DELETE FROM ItemTable WHERE key = 'composer.composerData';"
                            sqlite3_exec(db, delQuery, nil, nil, nil)
                        } else if let updatedData = try? JSONSerialization.data(withJSONObject: dict),
                                  let updatedStr = String(data: updatedData, encoding: .utf8) {
                            let updateQuery = "UPDATE ItemTable SET value = ? WHERE key = 'composer.composerData';"
                            var updateStmt: OpaquePointer?
                            if sqlite3_prepare_v2(db, updateQuery, -1, &updateStmt, nil) == SQLITE_OK {
                                sqlite3_bind_text(updateStmt, 1, (updatedStr as NSString).utf8String, -1, nil)
                                sqlite3_step(updateStmt)
                                sqlite3_finalize(updateStmt)
                            }
                        }
                    }
                } else {
                    sqlite3_finalize(stmt)
                }
            }
        }

        // Also handle plain JSON fixture files
        let dbURL = URL(fileURLWithPath: dbPath)
        if let data = try? Data(contentsOf: dbURL),
           var dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           var composers = dict["allComposers"] as? [[String: Any]] {
            composers.removeAll { c in
                guard let id = c["composerId"] as? String else { return false }
                return sessionIds.contains(id)
            }
            if composers.isEmpty {
                _ = FileSizeHelper.removeIfExists(path: dbPath)
            } else {
                dict["allComposers"] = composers
                if let updatedData = try? JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted]) {
                    try? updatedData.write(to: dbURL, options: .atomic)
                }
            }
        }
    }

    private func clearStateDatabaseChatData(dbURL: URL) {
        var db: OpaquePointer?
        if sqlite3_open_v2(dbURL.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK {
            defer { sqlite3_close(db) }

            let query = "DELETE FROM ItemTable WHERE key IN ('composer.composerData', 'workbench.panel.aichat.view.aichat.chatdata');"
            if sqlite3_exec(db, query, nil, nil, nil) == SQLITE_OK {
                sqlite3_exec(db, "VACUUM;", nil, nil, nil)
                return
            }
        }
        _ = FileSizeHelper.removeIfExists(path: dbURL.path)
    }

    // MARK: - Global and Home Directory Scans

    private func scanCursorExtensionStorage(dirURL: URL) -> [ConversationItem] {
        let fm = FileManager.default
        var items: [ConversationItem] = []

        let candidateSubdirs = ["composer", "chats", "workspaces"]
        for sub in candidateSubdirs {
            let subURL = dirURL.appendingPathComponent(sub)
            guard fm.fileExists(atPath: subURL.path),
                  let files = try? fm.contentsOfDirectory(at: subURL, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else {
                continue
            }

            for file in files where file.pathExtension.lowercased() == "json" || file.pathExtension.lowercased() == "jsonl" {
                let sid = file.deletingPathExtension().lastPathComponent
                let size = FileSizeHelper.sizeOf(path: file.path)
                let date = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()

                items.append(ConversationItem(
                    id: UUID(),
                    sessionId: sid,
                    title: "Cursor 对话 \(sid.prefix(8))",
                    category: self.category,
                    projectPath: nil,
                    gitBranch: nil,
                    messageCount: 1,
                    sizeInBytes: size,
                    updatedAt: date,
                    isSelected: false,
                    snippet: "Cursor 扩展历史会话",
                    associatedPaths: [file.path]
                ))
            }
        }

        return items
    }

    private func scanDotCursorDirectory(dotURL: URL) -> [ConversationItem] {
        let fm = FileManager.default
        var items: [ConversationItem] = []

        let chatsDir = dotURL.appendingPathComponent("chats")
        if fm.fileExists(atPath: chatsDir.path),
           let files = try? fm.contentsOfDirectory(at: chatsDir, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) {
            for file in files where file.pathExtension.lowercased() == "json" || file.pathExtension.lowercased() == "jsonl" {
                let sid = file.deletingPathExtension().lastPathComponent
                let size = FileSizeHelper.sizeOf(path: file.path)
                let date = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()

                items.append(ConversationItem(
                    id: UUID(),
                    sessionId: sid,
                    title: "Cursor 会话 \(sid.prefix(8))",
                    category: self.category,
                    projectPath: nil,
                    gitBranch: nil,
                    messageCount: 1,
                    sizeInBytes: size,
                    updatedAt: date,
                    isSelected: false,
                    snippet: "Cursor 用户目录会话",
                    associatedPaths: [file.path]
                ))
            }
        }

        return items
    }

    // MARK: - Helpers

    private static func extractPromptText(from req: [String: Any]) -> String? {
        if let msg = req["message"] as? [String: Any] {
            if let text = msg["text"] as? String {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
            if let parts = msg["parts"] as? [[String: Any]] {
                var combined = ""
                for part in parts {
                    if let text = part["text"] as? String {
                        combined += text
                    }
                }
                let trimmed = combined.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
        } else if let msgStr = req["message"] as? String {
            let trimmed = msgStr.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        } else if let text = req["text"] as? String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        } else if let prompt = req["prompt"] as? String {
            let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
    }

    private static func extractProjectPath(from workspaceJSONURL: URL) -> String? {
        guard let data = try? Data(contentsOf: workspaceJSONURL),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return nil
        }
        guard let uriString = json["folder"] as? String ?? json["workspace"] as? String else {
            return nil
        }
        if uriString.hasPrefix("file://") {
            if let url = URL(string: uriString) {
                return url.path
            }
            let stripped = String(uriString.dropFirst(7))
            return stripped.removingPercentEncoding ?? stripped
        }
        return uriString
    }

    private func cleanEmptyWorkspaceStorageDirs() {
        let fileManager = FileManager.default
        let workspaceStorageDir = userDirectoryURL.appendingPathComponent("workspaceStorage")
        guard fileManager.fileExists(atPath: workspaceStorageDir.path),
              let wsEntries = try? fileManager.contentsOfDirectory(
                  at: workspaceStorageDir,
                  includingPropertiesForKeys: [.isDirectoryKey],
                  options: [.skipsHiddenFiles]
              ) else { return }

        for wsDir in wsEntries {
            let chatDir = wsDir.appendingPathComponent("chatSessions")
            FileSizeHelper.removeIfEmptyDirectory(path: chatDir.path)

            let editDir = wsDir.appendingPathComponent("chatEditingSessions")
            FileSizeHelper.removeIfEmptyDirectory(path: editDir.path)
        }
    }
}
