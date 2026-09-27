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

    struct ScanTarget: Sendable {
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
        var stateDbToSessions: [URL: Set<String>] = [:]
        let userDir = userDirectoryURL

        for item in items {
            totalFreed += CleanPrefs.freedBytes(reported: item.sizeInBytes, for: item)

            // state.vscdb 索引行不属于快照，始终跟着删；只有文件删除受开关控制。
            let pathsToDelete = Set(CleanPrefs.deletionPaths(for: item))
            for path in item.associatedPaths {
                let fileURL = URL(fileURLWithPath: path)
                if path.hasSuffix(".vscdb") {
                    stateDbToSessions[fileURL, default: []].insert(item.sessionId)
                } else {
                    if path.contains("chatSessions") {
                        let wsDir = fileURL.deletingLastPathComponent().deletingLastPathComponent()
                        let stateDbURL = wsDir.appendingPathComponent("state.vscdb")
                        stateDbToSessions[stateDbURL, default: []].insert(item.sessionId)
                    } else if path.contains("emptyWindowChatSessions") {
                        let globalDb = userDir.appendingPathComponent("globalStorage/state.vscdb")
                        stateDbToSessions[globalDb, default: []].insert(item.sessionId)
                    }
                    if pathsToDelete.contains(path) {
                        _ = FileSizeHelper.removeIfExists(path: path)
                    }
                }
            }
        }

        // Atomically sync state.vscdb: completely cleans both composer.composerData and chat.ChatSessionStore.index
        for (stateDbURL, sessionIds) in stateDbToSessions {
            VSCDBHelper.removeChatSessions(from: stateDbURL, sessionIds: sessionIds)
            deleteComposersFromStateDb(dbPath: stateDbURL.path, sessionIds: sessionIds)
        }

        DirectoryCleaner.cleanEmptyWorkspaceStorageDirs(under: userDirectoryURL)

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
                if CleanPrefs.cleanFileHistorySnapshots, fileManager.fileExists(atPath: editDir.path) {
                    let sz = FileSizeHelper.sizeOf(path: editDir.path)
                    if FileSizeHelper.removeIfExists(path: editDir.path) {
                        freed += sz
                    }
                }

                // Clean state.vscdb composer keys and chat session indexes completely using VSCDBHelper
                let stateDb = wsDir.appendingPathComponent("state.vscdb")
                if fileManager.fileExists(atPath: stateDb.path) {
                    VSCDBHelper.clearAllChatSessions(from: stateDb)
                }
            }
        }

        // Clean globalStorage/state.vscdb chat indexes completely using VSCDBHelper
        let globalStateDb = userDir.appendingPathComponent("globalStorage/state.vscdb")
        if fileManager.fileExists(atPath: globalStateDb.path) {
            VSCDBHelper.clearAllChatSessions(from: globalStateDb)
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

        DirectoryCleaner.cleanEmptyWorkspaceStorageDirs(under: userDirectoryURL)

        return freed
    }


    // MARK: - Helpers

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
}
