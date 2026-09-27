import Foundation

final class AiderScanner: AgentScanner, @unchecked Sendable {
    let category: ConversationCategory = .aider
    let customStorageURL: URL?

    init(storageURL: URL? = nil) {
        self.customStorageURL = storageURL
    }

    convenience init(baseURL: URL?) {
        self.init(storageURL: baseURL)
    }

    var storageURL: URL {
        let base: URL
        if let custom = customStorageURL {
            base = custom
        } else if let env = ProcessInfo.processInfo.environment["AIDER_HOME"], !env.isEmpty {
            base = URL(fileURLWithPath: env)
        } else {
            base = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".aider")
        }
        return (try? base.resourceValues(forKeys: [.canonicalPathKey]).canonicalPath).map { URL(fileURLWithPath: $0) } ?? base.standardized
    }

    var isInstalled: Bool {
        let fm = FileManager.default
        if fm.fileExists(atPath: storageURL.path) { return true }

        let home = fm.homeDirectoryForCurrentUser
        let indicators = [
            ".aider.conf.yml",
            ".aider.input.history",
            ".aider.chat.history.md",
            ".aider.tags.cache.v3"
        ]

        for ind in indicators {
            if fm.fileExists(atPath: home.appendingPathComponent(ind).path) {
                return true
            }
        }

        if let contents = try? fm.contentsOfDirectory(atPath: home.path),
           contents.contains(where: { $0.hasPrefix(".aider") }) {
            return true
        }

        return false
    }

    // MARK: - Scan

    func scan() async throws -> [ConversationItem] {
        guard isInstalled else { return [] }

        var items: [ConversationItem] = []
        let fm = FileManager.default

        // 1. Scan global Aider history in home directory and ~/.aider
        if let globalItem = scanGlobalAider() {
            items.append(globalItem)
        }

        // 2. Scan ~/projects for project-level .aider history up to depth 3
        let projectsURL: URL
        if let custom = customStorageURL {
            let customProjects = custom.appendingPathComponent("projects")
            projectsURL = fm.fileExists(atPath: customProjects.path) ? customProjects : custom
        } else {
            projectsURL = fm.homeDirectoryForCurrentUser.appendingPathComponent("projects")
        }

        if fm.fileExists(atPath: projectsURL.path) {
            let projectDirs = findAiderProjectDirectories(root: projectsURL, maxDepth: 3)
            for projectDir in projectDirs {
                if let item = parseProjectAider(projectDir: projectDir) {
                    items.append(item)
                }
            }
        }

        return items.sorted(by: { $0.updatedAt > $1.updatedAt })
    }

    // MARK: - Deletion & Clean

    func delete(items: [ConversationItem]) async throws -> Int64 {
        guard !items.isEmpty else { return 0 }

        var totalBytesFreed: Int64 = 0

        for item in items {
            totalBytesFreed += CleanPrefs.freedBytes(reported: item.sizeInBytes, for: item)
            for path in CleanPrefs.deletionPaths(for: item) {
                guard isSafeToDelete(path: path) else { continue }
                _ = FileSizeHelper.removeIfExists(path: path)
            }
        }

        return totalBytesFreed
    }

    func cleanAll() async throws -> Int64 {
        let items = try await scan()
        var totalFreed = try await delete(items: items)

        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser

        // Clear ~/.aider folder contents
        if fm.fileExists(atPath: storageURL.path) {
            let size = FileSizeHelper.sizeOf(path: storageURL.path)
            if FileSizeHelper.removeIfExists(path: storageURL.path) {
                totalFreed += size
                try? fm.createDirectory(at: storageURL, withIntermediateDirectories: true)
            }
        }

        // Clear any leftover global aider history/cache files in home
        let globalFiles = [
            ".aider.chat.history.md",
            ".aider.input.history",
            ".aider.tags.cache.v3"
        ]

        for file in globalFiles {
            let path = home.appendingPathComponent(file).path
            if fm.fileExists(atPath: path) {
                let size = FileSizeHelper.sizeOf(path: path)
                if FileSizeHelper.removeIfExists(path: path) {
                    totalFreed += size
                }
            }
        }

        return totalFreed
    }

    // MARK: - Global Aider Scanner

    private func scanGlobalAider() -> ConversationItem? {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        var associatedPaths: [String] = []
        var totalBytes: Int64 = 0
        var latestDate = Date.distantPast
        var promptCount = 0
        var firstPrompt: String?

        // 1. ~/.aider directory (cache & model history)
        if fm.fileExists(atPath: storageURL.path) {
            let size = FileSizeHelper.sizeOf(path: storageURL.path)
            if size > 0 {
                associatedPaths.append(storageURL.path)
                totalBytes += size
                if let attrs = try? fm.attributesOfItem(atPath: storageURL.path),
                   let mod = attrs[.modificationDate] as? Date, mod > latestDate {
                    latestDate = mod
                }
            }
        }

        // 2. Global files in home
        let checkFiles = [
            ".aider.chat.history.md",
            ".aider.input.history",
            ".aider.tags.cache.v3"
        ]

        for fileName in checkFiles {
            let fileURL = home.appendingPathComponent(fileName)
            let path = fileURL.path
            guard fm.fileExists(atPath: path) else { continue }

            let size = FileSizeHelper.sizeOf(path: path)
            guard size > 0 else { continue }

            associatedPaths.append(path)
            totalBytes += size

            if let attrs = try? fm.attributesOfItem(atPath: path),
               let mod = attrs[.modificationDate] as? Date, mod > latestDate {
                latestDate = mod
            }

            if fileName == ".aider.chat.history.md" {
                let parsed = parseChatHistory(fileURL: fileURL)
                promptCount += parsed.messageCount
                if firstPrompt == nil {
                    firstPrompt = parsed.firstPrompt
                }
            } else if fileName == ".aider.input.history" {
                if let content = try? String(contentsOf: fileURL, encoding: .utf8) {
                    promptCount += max(1, content.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.count)
                }
            }
        }

        // Check for any other .aider.tags.cache.* in home
        if let homeContents = try? fm.contentsOfDirectory(atPath: home.path) {
            for entry in homeContents where entry.hasPrefix(".aider.tags.cache.") && entry != ".aider.tags.cache.v3" {
                let p = home.appendingPathComponent(entry).path
                if !associatedPaths.contains(p) {
                    let size = FileSizeHelper.sizeOf(path: p)
                    associatedPaths.append(p)
                    totalBytes += size
                }
            }
        }

        guard !associatedPaths.isEmpty && totalBytes > 0 else { return nil }

        let date = latestDate == Date.distantPast ? Date() : latestDate
        let title = firstPrompt ?? "Aider 全局历史与模型缓存"
        let snippet = firstPrompt ?? "包含 Aider 全局缓存、代码标签索引及输入历史"

        return ConversationItem(
            id: UUID(),
            sessionId: "aider-global",
            title: title,
            category: .aider,
            projectPath: home.path,
            gitBranch: nil,
            messageCount: max(1, promptCount),
            sizeInBytes: totalBytes,
            updatedAt: date,
            isSelected: false,
            snippet: snippet,
            associatedPaths: associatedPaths
        )
    }

    // MARK: - Project Level Scanner

    private func findAiderProjectDirectories(root: URL, maxDepth: Int) -> [URL] {
        let fm = FileManager.default
        var results: [URL] = []
        let skipDirs: Set<String> = [
            ".git", ".svn", ".hg", "node_modules", "Pods", "DerivedData",
            ".build", "vendor", ".venv", "venv", "env", "dist", "build",
            "target", ".next", ".nuxt", "Caches", ".cache"
        ]

        var queue: [(url: URL, depth: Int)] = [(root, 1)]

        while !queue.isEmpty {
            let current = queue.removeFirst()
            guard current.depth <= maxDepth else { continue }

            guard let entries = try? fm.contentsOfDirectory(
                at: current.url,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: []
            ) else {
                continue
            }

            var hasAiderInCurrent = false

            for entry in entries {
                let name = entry.lastPathComponent
                if name == ".aider.chat.history.md" || name == ".aider.input.history" || name.hasPrefix(".aider.tags.cache") {
                    hasAiderInCurrent = true
                    break
                }
            }

            if hasAiderInCurrent {
                results.append(current.url)
            }

            for entry in entries {
                let name = entry.lastPathComponent
                guard !skipDirs.contains(name) && !name.hasPrefix(".") else { continue }

                var isDir: ObjCBool = false
                if fm.fileExists(atPath: entry.path, isDirectory: &isDir), isDir.boolValue {
                    queue.append((entry, current.depth + 1))
                }
            }
        }

        return results
    }

    private func parseProjectAider(projectDir: URL) -> ConversationItem? {
        let fm = FileManager.default
        let chatHistoryURL = projectDir.appendingPathComponent(".aider.chat.history.md")
        let inputHistoryURL = projectDir.appendingPathComponent(".aider.input.history")

        var associatedPaths: [String] = []
        var totalBytes: Int64 = 0
        var latestDate = Date.distantPast
        var messageCount = 0
        var firstPrompt: String?

        // Check chat history
        if fm.fileExists(atPath: chatHistoryURL.path) {
            let path = chatHistoryURL.path
            let size = FileSizeHelper.sizeOf(path: path)
            associatedPaths.append(path)
            totalBytes += size

            if let attrs = try? fm.attributesOfItem(atPath: path),
               let mod = attrs[.modificationDate] as? Date, mod > latestDate {
                latestDate = mod
            }

            let parsed = parseChatHistory(fileURL: chatHistoryURL)
            messageCount += parsed.messageCount
            firstPrompt = parsed.firstPrompt
        }

        // Check input history
        if fm.fileExists(atPath: inputHistoryURL.path) {
            let path = inputHistoryURL.path
            let size = FileSizeHelper.sizeOf(path: path)
            associatedPaths.append(path)
            totalBytes += size

            if let attrs = try? fm.attributesOfItem(atPath: path),
               let mod = attrs[.modificationDate] as? Date, mod > latestDate {
                latestDate = mod
            }

            if let content = try? String(contentsOf: inputHistoryURL, encoding: .utf8) {
                let lines = content.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                messageCount += max(1, lines.count)
                if firstPrompt == nil, let first = lines.first {
                    firstPrompt = first
                }
            }
        }

        // Check tags cache files in project directory
        if let contents = try? fm.contentsOfDirectory(atPath: projectDir.path) {
            for entry in contents where entry.hasPrefix(".aider.tags.cache") {
                let p = projectDir.appendingPathComponent(entry).path
                if !associatedPaths.contains(p) {
                    let size = FileSizeHelper.sizeOf(path: p)
                    associatedPaths.append(p)
                    totalBytes += size

                    if let attrs = try? fm.attributesOfItem(atPath: p),
                       let mod = attrs[.modificationDate] as? Date, mod > latestDate {
                        latestDate = mod
                    }
                }
            }
        }

        guard !associatedPaths.isEmpty && totalBytes > 0 else { return nil }

        let projectName = projectDir.lastPathComponent
        let date = latestDate == Date.distantPast ? Date() : latestDate
        let title = firstPrompt.map { String($0.prefix(80)).replacingOccurrences(of: "\n", with: " ") } ?? "Aider: \(projectName)"
        let snippet = firstPrompt.map { String($0.prefix(120)).replacingOccurrences(of: "\n", with: " ") } ?? "项目: \(projectDir.path)"

        let shortHash = String(abs(projectDir.path.hashValue)).prefix(6)
        let sessionId = "aider-\(projectName)-\(shortHash)"

        return ConversationItem(
            id: UUID(),
            sessionId: sessionId,
            title: title,
            category: .aider,
            projectPath: projectDir.path,
            gitBranch: nil,
            messageCount: max(1, messageCount),
            sizeInBytes: totalBytes,
            updatedAt: date,
            isSelected: false,
            snippet: snippet,
            associatedPaths: associatedPaths
        )
    }

    private func parseChatHistory(fileURL: URL) -> (firstPrompt: String?, messageCount: Int) {
        guard let fileHandle = try? FileHandle(forReadingFrom: fileURL) else {
            return (nil, 1)
        }
        defer { try? fileHandle.close() }

        // Read up to first 64KB for prompt extraction
        let initialData = fileHandle.readData(ofLength: 64 * 1024)
        let text = String(decoding: initialData, as: UTF8.self)

        var firstPrompt: String?
        var promptCount = 0

        text.enumerateLines { line, stop in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#### ") {
                promptCount += 1
                if firstPrompt == nil {
                    let prompt = String(trimmed.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                    if !prompt.isEmpty {
                        firstPrompt = prompt
                    }
                }
            } else if trimmed.hasPrefix("> ") && !trimmed.hasPrefix("> /") {
                promptCount += 1
                if firstPrompt == nil {
                    let prompt = String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                    if !prompt.isEmpty {
                        firstPrompt = prompt
                    }
                }
            }
        }

        // Count additional lines if file is large
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? NSNumber)?.int64Value ?? 0
        if fileSize > 64 * 1024 {
            let estimatedExtra = Int((fileSize - 64 * 1024) / 1024 / 4)
            promptCount += max(1, estimatedExtra)
        }

        return (firstPrompt, max(1, promptCount))
    }

    // MARK: - Safety Checks

    private func isSafeToDelete(path: String) -> Bool {
        let url = URL(fileURLWithPath: path)
        let name = url.lastPathComponent

        // Explicitly NEVER delete configuration file
        if name == ".aider.conf.yml" {
            return false
        }

        // Inside ~/.aider/ directory is safe to delete
        let standardStorage = storageURL.standardized.path
        if url.standardized.path.hasPrefix(standardStorage) {
            return true
        }

        // Specific Aider conversation and cache files only
        if name == ".aider.chat.history.md" ||
           name == ".aider.input.history" ||
           name.hasPrefix(".aider.tags.cache") {
            return true
        }

        return false
    }
}
