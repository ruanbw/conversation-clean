import Foundation
import SQLite3
import CryptoKit

final class PiAgentScanner: AgentScanner, @unchecked Sendable {
    let category: ConversationCategory = .piAgent
    let customStorageURL: URL?

    init(storageURL: URL? = nil) {
        self.customStorageURL = storageURL
    }

    var storageURL: URL {
        let base: URL
        if let custom = customStorageURL {
            base = custom
        } else if let env = ProcessInfo.processInfo.environment["PI_HOME"], !env.isEmpty {
            base = URL(fileURLWithPath: env)
        } else {
            base = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".pi")
        }
        return (try? base.resourceValues(forKeys: [.canonicalPathKey]).canonicalPath).map { URL(fileURLWithPath: $0) } ?? base.standardized
    }

    var isInstalled: Bool {
        FileManager.default.fileExists(atPath: storageURL.path)
    }

    struct SessionTarget: Sendable {
        let fileURL: URL
        let projectDirURL: URL
        let baseName: String
        let fileSessionId: String
    }

    struct TaskArtifacts: Sendable {
        var pathsBySessionId: [String: [String]] = [:]
        var sizeBySessionId: [String: Int64] = [:]
    }

    func scan() async throws -> [ConversationItem] {
        guard isInstalled else { return [] }

        let fileManager = FileManager.default
        let sessionsURL = storageURL.appendingPathComponent("agent").appendingPathComponent("sessions")
        guard fileManager.fileExists(atPath: sessionsURL.path) else { return [] }

        let projectDirs = (try? fileManager.contentsOfDirectory(
            at: sessionsURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        var targets: [SessionTarget] = []

        for projectDir in projectDirs {
            var isDir: ObjCBool = false
            guard fileManager.fileExists(atPath: projectDir.path, isDirectory: &isDir), isDir.boolValue else {
                continue
            }

            let entries = (try? fileManager.contentsOfDirectory(
                at: projectDir,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            )) ?? []

            for entry in entries where entry.pathExtension == "jsonl" {
                let baseName = entry.deletingPathExtension().lastPathComponent
                guard !baseName.isEmpty else { continue }

                let fileSessionId: String
                if let lastUnderscore = baseName.range(of: "_", options: .backwards) {
                    fileSessionId = String(baseName[lastUnderscore.upperBound...])
                } else {
                    fileSessionId = baseName
                }

                targets.append(SessionTarget(
                    fileURL: entry,
                    projectDirURL: projectDir,
                    baseName: baseName,
                    fileSessionId: fileSessionId
                ))
            }
        }

        guard !targets.isEmpty else { return [] }

        let taskArtifacts = preIndexTasks()

        let items: [ConversationItem] = await withTaskGroup(of: ConversationItem.self) { group in
            for target in targets {
                group.addTask {
                    return self.parseSession(target: target, taskArtifacts: taskArtifacts)
                }
            }

            var collected: [ConversationItem] = []
            collected.reserveCapacity(targets.count)
            for await item in group {
                collected.append(item)
            }
            return collected
        }

        return items.sorted(by: { $0.updatedAt > $1.updatedAt })
    }

    func delete(items: [ConversationItem]) async throws -> Int64 {
        guard !items.isEmpty else { return 0 }

        let fileManager = FileManager.default
        var totalBytesFreed: Int64 = 0

        // 1. 先收集所有待删除的会话文件（含子目录里的子代理会话），再做物理删除
        var sessionFilePaths = Set<String>()
        var deletedPaths = Set<String>()

        for item in items {
            totalBytesFreed += item.sizeInBytes
            for path in item.associatedPaths {
                deletedPaths.insert(path)
                if path.hasSuffix(".jsonl") {
                    sessionFilePaths.insert(path)
                }
                var isDirectory: ObjCBool = false
                if fileManager.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue {
                    sessionFilePaths.formUnion(Self.jsonlPaths(under: URL(fileURLWithPath: path)))
                }
            }
        }

        for item in items {
            for path in item.associatedPaths {
                _ = FileSizeHelper.removeIfExists(path: path)
            }
        }

        // 2. 同步双层索引：context-mode SQLite 索引行 + pi-acp 会话映射表
        purgeContextModeArtifacts(sessionFilePaths: sessionFilePaths)
        pruneACPSessionMap(sessionIds: Set(items.map { $0.sessionId }), deletedPaths: deletedPaths)

        cleanEmptyProjectDirectories()

        return totalBytesFreed
    }

    func cleanAll() async throws -> Int64 {
        let items = try await scan()
        var freed = try await delete(items: items)

        let extraDirsToRecreate = [
            storageURL.appendingPathComponent("agent").appendingPathComponent("sessions"),
            storageURL.appendingPathComponent("tasks"),
            storageURL.appendingPathComponent("context-mode"),
            storageURL.appendingPathComponent("pi-acp"),
            storageURL.appendingPathComponent("web-search-cache"),
            storageURL.appendingPathComponent("agent").appendingPathComponent("web-search-cache")
        ]

        for dirURL in extraDirsToRecreate {
            let path = dirURL.path
            if FileManager.default.fileExists(atPath: path) {
                let size = FileSizeHelper.sizeOf(path: path)
                if FileSizeHelper.removeIfExists(path: path) {
                    freed += size
                    try? FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)
                }
            }
        }

        let runHistoryURL = storageURL.appendingPathComponent("agent").appendingPathComponent("run-history.jsonl")
        if FileManager.default.fileExists(atPath: runHistoryURL.path) {
            let size = FileSizeHelper.sizeOf(path: runHistoryURL.path)
            if FileSizeHelper.removeIfExists(path: runHistoryURL.path) {
                freed += size
            }
        }

        return freed
    }

}
