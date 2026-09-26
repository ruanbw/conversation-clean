import Foundation
import SQLite3

extension CursorScanner {
    // MARK: - Global and Home Directory Scans

    func scanCursorExtensionStorage(dirURL: URL) -> [ConversationItem] {
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

    func scanDotCursorDirectory(dotURL: URL) -> [ConversationItem] {
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

}
