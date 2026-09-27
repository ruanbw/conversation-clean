import Foundation
import SQLite3

extension PiAgentScanner {
    // MARK: - pi-acp 会话映射表同步

    /// 裁剪 `~/.pi/pi-acp/session-map.json`，避免 ACP 客户端侧边栏残留幽灵会话
    func pruneACPSessionMap(sessionIds: Set<String>, deletedPaths: Set<String>) {
        guard !sessionIds.isEmpty || !deletedPaths.isEmpty else { return }

        let mapURL = storageURL.appendingPathComponent("pi-acp").appendingPathComponent("session-map.json")
        guard let data = try? Data(contentsOf: mapURL),
              var root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let sessions = root["sessions"] as? [String: Any] else {
            return
        }

        var staleKeys: [String] = []
        for (key, value) in sessions {
            var isStale = sessionIds.contains(key)
            if !isStale, let entry = value as? [String: Any] {
                if let sid = entry["sessionId"] as? String, sessionIds.contains(sid) {
                    isStale = true
                } else if let file = entry["sessionFile"] as? String {
                    // 指向已删除或已不存在的会话文件的条目本身就是幽灵条目
                    if deletedPaths.contains(file) || (!file.isEmpty && !FileManager.default.fileExists(atPath: file)) {
                        isStale = true
                    }
                }
            }
            if isStale {
                staleKeys.append(key)
            }
        }

        guard !staleKeys.isEmpty else { return }

        var remaining = sessions
        for key in staleKeys {
            remaining.removeValue(forKey: key)
        }

        if remaining.isEmpty {
            try? FileManager.default.removeItem(at: mapURL)
            return
        }

        root["sessions"] = remaining
        if let updated = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys]) {
            try? updated.write(to: mapURL, options: .atomic)
        }
    }

    func cleanEmptyProjectDirectories() {
        // 「回收空项目目录」关掉时磁盘上保留空 project 目录。
        guard CleanPrefs.cleanEmptyProjectFolders else { return }

        let sessionsURL = storageURL.appendingPathComponent("agent").appendingPathComponent("sessions")
        let fm = FileManager.default
        guard fm.fileExists(atPath: sessionsURL.path),
              let projectDirs = try? fm.contentsOfDirectory(at: sessionsURL, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else {
            return
        }

        for dir in projectDirs {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else { continue }

            if let contents = try? fm.contentsOfDirectory(atPath: dir.path) {
                let sessionFiles = contents.filter { $0.hasSuffix(".jsonl") }
                if sessionFiles.isEmpty {
                    try? fm.removeItem(at: dir)
                }
            }
        }
    }
}
