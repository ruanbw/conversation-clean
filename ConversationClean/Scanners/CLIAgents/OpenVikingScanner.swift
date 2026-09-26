import Foundation

final class OpenVikingScanner: AgentScanner, @unchecked Sendable {
    let category: ConversationCategory = .openViking
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
        } else if let env = ProcessInfo.processInfo.environment["OPENVIKING_HOME"], !env.isEmpty {
            base = URL(fileURLWithPath: env)
        } else {
            base = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".openviking")
        }
        return (try? base.resourceValues(forKeys: [.canonicalPathKey]).canonicalPath).map { URL(fileURLWithPath: $0) } ?? base.standardized
    }

    var isInstalled: Bool {
        FileManager.default.fileExists(atPath: storageURL.path)
    }

    // MARK: - Record Types

    private struct PendingRecord: Sendable {
        let fileURL: URL
        let fileSize: Int64
        let fileModDate: Date
        let sessionId: String
        let createdAt: Date?
        let role: String?
        let text: String?
        let peerId: String?
    }

    // MARK: - Scan

    func scan() async throws -> [ConversationItem] {
        guard isInstalled else { return [] }

        let fileManager = FileManager.default
        let pendingDir = storageURL.appendingPathComponent("pending")
        guard fileManager.fileExists(atPath: pendingDir.path) else { return [] }

        let fileURLs = (try? fileManager.contentsOfDirectory(
            at: pendingDir,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        let jsonFiles = fileURLs.filter { $0.pathExtension.lowercased() == "json" }
        guard !jsonFiles.isEmpty else { return [] }

        // Parse pending json files concurrently in TaskGroup
        let records: [PendingRecord] = await withTaskGroup(of: PendingRecord?.self) { group in
            for url in jsonFiles {
                group.addTask {
                    return self.parsePendingFile(fileURL: url)
                }
            }

            var results: [PendingRecord] = []
            results.reserveCapacity(jsonFiles.count)
            for await record in group {
                if let record = record {
                    results.append(record)
                }
            }
            return results
        }

        guard !records.isEmpty else { return [] }

        // Group files by sessionId
        let grouped = Dictionary(grouping: records, by: { $0.sessionId })

        var items: [ConversationItem] = []
        items.reserveCapacity(grouped.count)

        for (sessionId, sessionRecords) in grouped {
            guard !sessionId.isEmpty else { continue }

            let totalBytes = sessionRecords.reduce(0) { $0 + $1.fileSize }
            let messageCount = sessionRecords.count
            let associatedPaths = sessionRecords.map { $0.fileURL.path }.sorted()

            // Sort chronologically to find the earliest prompt and latest timestamp
            let sortedByTime = sessionRecords.sorted {
                let d1 = $0.createdAt ?? $0.fileModDate
                let d2 = $1.createdAt ?? $1.fileModDate
                return d1 < d2
            }

            let latestDate = sortedByTime.last?.createdAt ?? sortedByTime.last?.fileModDate ?? Date()

            // Find first user message prompt, or first prompt from parts, or session ID
            var firstUserPrompt: String?
            var firstAnyText: String?
            var detectedPeerId: String?

            for record in sortedByTime {
                if detectedPeerId == nil, let peer = record.peerId, !peer.isEmpty {
                    detectedPeerId = peer
                }

                if let text = record.text, !text.isEmpty {
                    if firstAnyText == nil {
                        firstAnyText = text
                    }
                    if record.role == "user" && firstUserPrompt == nil {
                        firstUserPrompt = text
                        break
                    }
                }
            }

            let title: String
            if let userPrompt = firstUserPrompt, !userPrompt.isEmpty {
                title = String(userPrompt.prefix(80)).replacingOccurrences(of: "\n", with: " ")
            } else if let anyText = firstAnyText, !anyText.isEmpty {
                title = String(anyText.prefix(80)).replacingOccurrences(of: "\n", with: " ")
            } else {
                title = "OpenViking 会话 \(sessionId.prefix(8))"
            }

            let snippet: String
            if let userPrompt = firstUserPrompt, !userPrompt.isEmpty {
                snippet = String(userPrompt.prefix(120)).replacingOccurrences(of: "\n", with: " ")
            } else if let anyText = firstAnyText, !anyText.isEmpty {
                snippet = String(anyText.prefix(120)).replacingOccurrences(of: "\n", with: " ")
            } else {
                snippet = "包含 \(messageCount) 条待处理消息与操作记录"
            }

            let projectPath = resolveProjectPath(from: detectedPeerId)

            items.append(ConversationItem(
                id: UUID(),
                sessionId: sessionId,
                title: title,
                category: .openViking,
                projectPath: projectPath,
                gitBranch: nil,
                messageCount: messageCount,
                sizeInBytes: totalBytes,
                updatedAt: latestDate,
                isSelected: false,
                snippet: snippet,
                associatedPaths: associatedPaths
            ))
        }

        return items.sorted(by: { $0.updatedAt > $1.updatedAt })
    }

    // MARK: - Deletion & Clean

    func delete(items: [ConversationItem]) async throws -> Int64 {
        guard !items.isEmpty else { return 0 }

        var totalBytesFreed: Int64 = 0

        for item in items {
            totalBytesFreed += item.sizeInBytes
            for path in item.associatedPaths {
                _ = FileSizeHelper.removeIfExists(path: path)
            }
        }

        let pendingDir = storageURL.appendingPathComponent("pending")
        FileSizeHelper.removeIfEmptyDirectory(path: pendingDir.path)

        return totalBytesFreed
    }

    func cleanAll() async throws -> Int64 {
        guard isInstalled else { return 0 }

        var totalBytesFreed: Int64 = 0
        let pendingDir = storageURL.appendingPathComponent("pending")

        if FileManager.default.fileExists(atPath: pendingDir.path) {
            totalBytesFreed += FileSizeHelper.sizeOf(path: pendingDir.path)
            _ = FileSizeHelper.removeIfExists(path: pendingDir.path)
            try? FileManager.default.createDirectory(at: pendingDir, withIntermediateDirectories: true)
        }

        return totalBytesFreed
    }

    // MARK: - File Parsing Helpers

    private func parsePendingFile(fileURL: URL) -> PendingRecord? {
        let fileManager = FileManager.default
        let attrs = try? fileManager.attributesOfItem(atPath: fileURL.path)
        let fileSize = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        let modDate = (attrs?[.modificationDate] as? Date) ?? Date()

        guard let data = try? Data(contentsOf: fileURL, options: .mappedIfSafe),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let sessionId = json["sessionId"] as? String, !sessionId.isEmpty else {
            return nil
        }

        // Parse createdAt
        var createdAtDate: Date?
        if let tsNum = json["createdAt"] as? NSNumber {
            let val = tsNum.doubleValue
            if val > 1_000_000_000_000 {
                createdAtDate = Date(timeIntervalSince1970: val / 1000.0)
            } else if val > 1_000_000_000 {
                createdAtDate = Date(timeIntervalSince1970: val)
            }
        } else if let tsStr = json["createdAt"] as? String {
            createdAtDate = ISODate.parse(tsStr)
        }

        // Parse payload
        let payload = json["payload"] as? [String: Any]
        let role = payload?["role"] as? String
        let peerId = payload?["peer_id"] as? String

        if createdAtDate == nil, let pCreated = payload?["created_at"] as? String {
            createdAtDate = ISODate.parse(pCreated)
        }

        let extractedText = extractText(from: payload)

        return PendingRecord(
            fileURL: fileURL,
            fileSize: fileSize,
            fileModDate: modDate,
            sessionId: sessionId,
            createdAt: createdAtDate,
            role: role,
            text: extractedText,
            peerId: peerId
        )
    }

    private func extractText(from payload: [String: Any]?) -> String? {
        guard let payload = payload else { return nil }

        // Check parts array
        if let parts = payload["parts"] as? [[String: Any]] {
            for part in parts {
                if let partType = part["type"] as? String, partType == "text",
                   let text = part["text"] as? String {
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        return trimmed
                    }
                }
            }
            // Fallback: any text field in parts
            for part in parts {
                if let text = part["text"] as? String {
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        return trimmed
                    }
                }
            }
        }

        // Check text / content / prompt direct keys
        if let text = payload["text"] as? String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }

        if let content = payload["content"] as? String {
            let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }

        if let prompt = payload["prompt"] as? String {
            let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }

        return nil
    }

    private func resolveProjectPath(from peerId: String?) -> String? {
        guard let peerId = peerId, peerId.hasPrefix("-") else { return nil }
        let directCandidate = "/" + peerId.dropFirst().replacingOccurrences(of: "-", with: "/")
        let fm = FileManager.default
        if fm.fileExists(atPath: directCandidate) {
            return directCandidate
        }

        // Try filesystem matching if directory names contain hyphens (e.g. flow-filtering-system)
        let segments = peerId.split(separator: "-").map(String.init)
        guard !segments.isEmpty else { return directCandidate }

        var current = ""
        for seg in segments {
            if current.isEmpty {
                current = "/" + seg
            } else {
                let slashPath = current + "/" + seg
                let hyphenPath = current + "-" + seg
                if fm.fileExists(atPath: slashPath) {
                    current = slashPath
                } else if fm.fileExists(atPath: hyphenPath) {
                    current = hyphenPath
                } else {
                    current = slashPath
                }
            }
        }

        return fm.fileExists(atPath: current) ? current : directCandidate
    }
}
