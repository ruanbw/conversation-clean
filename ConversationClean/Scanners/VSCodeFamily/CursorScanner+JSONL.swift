import Foundation
import SQLite3

extension CursorScanner {
    // MARK: - JSONL Parsing

    func parseJsonlSession(target: ScanTarget) -> ConversationItem? {
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
}
