import Foundation
import SQLite3
import CryptoKit

extension PiAgentScanner {
    // MARK: - Pre-Indexing Tasks

    /// 预索引 `~/.pi/tasks` 下的任务产物目录，供 `parseSession` 关联子代理产物。
    /// 由 `scan()` 调用，因此需为 internal（跨文件 extension）。
    func preIndexTasks() -> TaskArtifacts {
        var artifacts = TaskArtifacts()
        let tasksURL = storageURL.appendingPathComponent("tasks")
        let fm = FileManager.default
        guard fm.fileExists(atPath: tasksURL.path),
              let entries = try? fm.contentsOfDirectory(at: tasksURL, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else {
            return artifacts
        }

        for entry in entries {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: entry.path, isDirectory: &isDir), isDir.boolValue else { continue }

            let dirName = entry.lastPathComponent
            guard dirName.count >= 36 else { continue }

            let prefix = String(dirName.prefix(36))
            if dirName == prefix || dirName.hasPrefix(prefix + "-") {
                let path = entry.path
                let size = FileSizeHelper.sizeOf(path: path)
                artifacts.pathsBySessionId[prefix, default: []].append(path)
                artifacts.sizeBySessionId[prefix, default: 0] += size
            }
        }

        return artifacts
    }

    // MARK: - Parsing

    func parseSession(target: SessionTarget, taskArtifacts: TaskArtifacts) -> ConversationItem {
        let fileManager = FileManager.default
        let fileAttrs = try? fileManager.attributesOfItem(atPath: target.fileURL.path)
        let mainFileSize = (fileAttrs?[.size] as? NSNumber)?.int64Value ?? FileSizeHelper.sizeOf(path: target.fileURL.path)

        var detectedSessionId = target.fileSessionId
        var detectedCwd: String?
        var detectedTimestamp: Date?
        var firstUserPrompt: String?
        var messageCount = 0
        var totalLineCount = 0

        if let fileHandle = try? FileHandle(forReadingFrom: target.fileURL) {
            defer { try? fileHandle.close() }
            let headerData = fileHandle.readData(ofLength: 512 * 1024)
            let headerString = String(decoding: headerData, as: UTF8.self)

            headerString.enumerateLines { line, _ in
                totalLineCount += 1
                guard let lineData = line.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
                    return
                }

                let type = json["type"] as? String

                if type == "session" {
                    if let sid = json["id"] as? String, !sid.isEmpty {
                        detectedSessionId = sid
                    }
                    if let cwd = json["cwd"] as? String, !cwd.isEmpty {
                        detectedCwd = cwd
                    }
                    if let tsStr = json["timestamp"] as? String {
                        detectedTimestamp = ISODate.parse(tsStr)
                    }
                } else if type == "message" {
                    messageCount += 1
                    if firstUserPrompt == nil,
                       let msg = json["message"] as? [String: Any],
                       let role = msg["role"] as? String, role == "user" {
                        if let prompt = Self.extractText(from: msg["content"]) {
                            firstUserPrompt = prompt
                        }
                    }
                }
            }

            // If file is larger than 512KB, stream-count remaining newlines
            if mainFileSize > 512 * 1024 {
                while autoreleasepool(invoking: {
                    let chunk = fileHandle.readData(ofLength: 256 * 1024)
                    if chunk.isEmpty { return false }
                    let newlines = chunk.reduce(0) { $0 + ($1 == 10 ? 1 : 0) }
                    messageCount += newlines
                    return true
                }) {}
            }
        }

        if messageCount == 0 {
            messageCount = max(1, totalLineCount)
        }

        // Fallback for cwd based on project directory name (--Users-ruanbw-projects-bennett--)
        if detectedCwd == nil || detectedCwd?.isEmpty == true {
            let dirName = target.projectDirURL.lastPathComponent
            if dirName.hasPrefix("--") && dirName.hasSuffix("--") {
                let inner = String(dirName.dropFirst(2).dropLast(2))
                if inner.isEmpty {
                    detectedCwd = "/"
                } else {
                    detectedCwd = "/" + inner.replacingOccurrences(of: "-", with: "/")
                }
            }
        }

        let modDate = (fileAttrs?[.modificationDate] as? Date) ?? detectedTimestamp ?? Date()

        let title: String
        if let prompt = firstUserPrompt, !prompt.isEmpty {
            title = prompt.prefix(80).replacingOccurrences(of: "\n", with: " ")
        } else {
            title = "Pi 会话 \(detectedSessionId.prefix(8))"
        }

        let snippet: String
        if let prompt = firstUserPrompt, !prompt.isEmpty {
            snippet = prompt.prefix(120).replacingOccurrences(of: "\n", with: " ")
        } else {
            snippet = "项目: \(detectedCwd ?? "未知")"
        }

        var associatedPaths: [String] = [target.fileURL.path]
        var totalBytes = mainFileSize

        // 1. Session subfolder by baseName (e.g. 2026-09-14T..._<sid>)
        let subfolderByBase = target.projectDirURL.appendingPathComponent(target.baseName)
        var visitedDirs = Set<String>()
        var isDir: ObjCBool = false

        if fileManager.fileExists(atPath: subfolderByBase.path, isDirectory: &isDir), isDir.boolValue {
            associatedPaths.append(subfolderByBase.path)
            visitedDirs.insert(subfolderByBase.path)
            totalBytes += FileSizeHelper.sizeOf(path: subfolderByBase.path)
        }

        // 2. Session subfolder by sessionId (if different and exists)
        let subfolderBySid = target.projectDirURL.appendingPathComponent(detectedSessionId)
        if !visitedDirs.contains(subfolderBySid.path),
           fileManager.fileExists(atPath: subfolderBySid.path, isDirectory: &isDir), isDir.boolValue {
            associatedPaths.append(subfolderBySid.path)
            visitedDirs.insert(subfolderBySid.path)
            totalBytes += FileSizeHelper.sizeOf(path: subfolderBySid.path)
        }

        // 3. Matching tasks in tasks/
        var matchedTaskPaths = Set<String>()
        if let taskPaths = taskArtifacts.pathsBySessionId[detectedSessionId] {
            for path in taskPaths {
                if !matchedTaskPaths.contains(path) {
                    matchedTaskPaths.insert(path)
                    associatedPaths.append(path)
                }
            }
            totalBytes += taskArtifacts.sizeBySessionId[detectedSessionId] ?? 0
        }

        if target.fileSessionId != detectedSessionId,
           let taskPaths = taskArtifacts.pathsBySessionId[target.fileSessionId] {
            for path in taskPaths {
                if !matchedTaskPaths.contains(path) {
                    matchedTaskPaths.insert(path)
                    associatedPaths.append(path)
                    totalBytes += FileSizeHelper.sizeOf(path: path)
                }
            }
        }

        return ConversationItem(
            id: UUID(),
            sessionId: detectedSessionId,
            title: title,
            category: .piAgent,
            projectPath: detectedCwd,
            gitBranch: nil,
            messageCount: messageCount,
            sizeInBytes: totalBytes,
            updatedAt: modDate,
            isSelected: false,
            snippet: snippet,
            associatedPaths: associatedPaths
        )
    }

    private static func extractText(from content: Any?) -> String? {
        if let str = content as? String {
            let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        if let array = content as? [[String: Any]] {
            var texts: [String] = []
            for item in array {
                if let text = item["text"] as? String {
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        texts.append(trimmed)
                    }
                }
            }
            if !texts.isEmpty {
                return texts.joined(separator: " ")
            }
        }
        return nil
    }

}
