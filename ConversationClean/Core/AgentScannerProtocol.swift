import Foundation

// MARK: - 清理策略（设置面板 4 个开关的服务层读取入口）

/// 设置面板 4 个开关在服务层的**唯一**读取入口。
///
/// 两点约定：
/// 1. 键名必须与 `SettingsView` 里的 `@AppStorage` 字面量逐字一致，改一边就要改另一边。
/// 2. 全部现读 `UserDefaults`，不缓存成属性 —— `@AppStorage` 改动不会通知 ViewModel，
///    缓存下来会让「运行中改开关」要重启才生效。
enum CleanPrefs {
    enum Key {
        static let autoScanOnLaunch = "autoScanOnLaunch"
        static let confirmBeforeClean = "confirmBeforeClean"
        static let cleanFileHistorySnapshots = "cleanFileHistorySnapshots"
        static let cleanEmptyProjectFolders = "cleanEmptyProjectFolders"
    }

    private static var store: UserDefaults { .standard }

    /// 键不存在时按 true 返回：`@AppStorage(..., default: true)` 要等设置窗口被打开过
    /// 才把默认值落进 UserDefaults，服务层不能假设它已经存在。
    private static func flag(_ key: String) -> Bool {
        guard store.object(forKey: key) != nil else { return true }
        return store.bool(forKey: key)
    }

    /// 启动时自动扫描（只在启动那一刻读一次）
    static var autoScanOnLaunch: Bool { flag(Key.autoScanOnLaunch) }
    /// 清理前是否弹确认面板
    static var confirmBeforeClean: Bool { flag(Key.confirmBeforeClean) }
    /// 清理时是否连带删除文件改动快照
    static var cleanFileHistorySnapshots: Bool { flag(Key.cleanFileHistorySnapshots) }
    /// 删除会话后是否回收遗留的空目录
    static var cleanEmptyProjectFolders: Bool { flag(Key.cleanEmptyProjectFolders) }

    /// 会话「文件改动快照」的落盘目录名。
    ///
    /// 这些是 Agent 写文件前后留的回滚副本，与会话正文是两回事：
    ///   · `file-history`        Claude Code `~/.claude/file-history/<sessionId>/`
    ///   · `shell-snapshots`     Claude Code `~/.claude/shell-snapshots/`
    ///   · `backups`             Claude Code `~/.claude/backups/`
    ///   · `checkpoints`         Cline / Roo Code `…/checkpoints/<taskId>/`
    ///   · `chatEditingSessions` VS Code 系 `workspaceStorage/<hash>/chatEditingSessions/<sessionId>/`
    ///     （内含 `state.json` 的 `timeline.checkpoints` 与 `contents/` 里的文件版本）
    ///
    /// 反过来，`state.vscdb` / `session-store.db` 里的索引行、`chatSessions`、
    /// transcripts、subagent 目录都算「会话本体」，不受这个开关管 —— 删了正文却留着
    /// 索引行，只会在 Agent 侧留下永远查不到的幽灵会话。
    private static let snapshotDirNames: Set<String> = [
        "file-history", "shell-snapshots", "backups", "checkpoints", "chatEditingSessions"
    ]

    static func isSnapshotPath(_ path: String) -> Bool {
        path.split(separator: "/", omittingEmptySubsequences: true)
            .contains { snapshotDirNames.contains(String($0)) }
    }

    /// 一条会话本次真正要删的路径：开关关掉时剔除快照路径，只留会话主文件。
    static func deletionPaths(for item: ConversationItem) -> [String] {
        guard cleanFileHistorySnapshots else {
            return item.associatedPaths.filter { !isSnapshotPath($0) }
        }
        return item.associatedPaths
    }

    /// 被保留的快照并没有真的释放空间，从统计里扣掉，
    /// 否则确认面板的「预计释放」和成功横幅都会报一个比实际释放量更大的数。
    /// 必须在物理删除**之前**调用，否则路径已不存在、`sizeOf` 恒为 0。
    static func freedBytes(reported: Int64, for item: ConversationItem) -> Int64 {
        guard !cleanFileHistorySnapshots else { return reported }
        let kept = item.associatedPaths
            .filter(isSnapshotPath)
            .reduce(Int64(0)) { $0 + FileSizeHelper.sizeOf(path: $1) }
        return max(0, reported - kept)
    }
}

protocol AgentScanner {
    var category: ConversationCategory { get }
    var isInstalled: Bool { get }
    var storageURL: URL { get }

    func scan() async throws -> [ConversationItem]
    func delete(items: [ConversationItem]) async throws -> Int64
    func cleanAll() async throws -> Int64
}

enum FileSizeHelper {
    static func sizeOf(path: String) -> Int64 {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: path, isDirectory: &isDir) else { return 0 }

        if !isDir.boolValue {
            let attrs = try? fm.attributesOfItem(atPath: path)
            return (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        }

        var totalSize: Int64 = 0
        guard let enumerator = fm.enumerator(
            at: URL(fileURLWithPath: path),
            includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }

        for case let fileURL as URL in enumerator {
            guard let resourceValues = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey]),
                  let isDirectory = resourceValues.isDirectory, !isDirectory,
                  let fileSize = resourceValues.fileSize else {
                continue
            }
            totalSize += Int64(fileSize)
        }
        return totalSize
    }

    static func removeIfExists(path: String) -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: path) else { return false }
        do {
            try fm.removeItem(atPath: path)
            return true
        } catch {
            print("Failed to remove item at \(path): \(error)")
            return false
        }
    }

    static func removeIfEmptyDirectory(path: String) {
        // 「回收空项目目录」关掉时一个目录都不能删。这是所有「删空目录」的唯一原语，
        // 在这里收口，扫描器就不会漏掉某一处。
        guard CleanPrefs.cleanEmptyProjectFolders else { return }

        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else { return }
        if let contents = try? fm.contentsOfDirectory(atPath: path) {
            let nonHidden = contents.filter { !$0.hasPrefix(".") }
            if nonHidden.isEmpty {
                for file in contents {
                    try? fm.removeItem(atPath: (path as NSString).appendingPathComponent(file))
                }
                try? fm.removeItem(atPath: path)
            }
        }
    }
}
