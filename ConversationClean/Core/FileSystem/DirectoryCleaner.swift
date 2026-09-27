import Foundation

/// 跨 scanner 共享的「清理空目录」逻辑。
///
/// 这些实现此前在多个 scanner 中逐字复制（`cleanEmptyWorkspaceStorageDirs` 有 4 份完全相同的
/// 副本，`cleanEmptyDirectories` 有 2 份等价副本），差异仅在于传给它们的根目录。
enum DirectoryCleaner {
    /// 清理 VS Code 系 `workspaceStorage/<hash>/` 下残留的空 `chatSessions` 与
    /// `chatEditingSessions` 目录。
    ///
    /// - Parameter root: workspace 数据根目录，通常是 `<userDir>/User`。
    static func cleanEmptyWorkspaceStorageDirs(under root: URL) {
        // 开关关掉时整个方法空转：下面那层 removeIfEmptyDirectory 也会拦一道，
        // 这里提前 return 是为了不白跑一遍 workspaceStorage 的目录枚举。
        guard CleanPrefs.cleanEmptyProjectFolders else { return }

        let fileManager = FileManager.default
        let workspaceStorageDir = root.appendingPathComponent("workspaceStorage")
        guard fileManager.fileExists(atPath: workspaceStorageDir.path),
              let wsEntries = try? fileManager.contentsOfDirectory(
                  at: workspaceStorageDir,
                  includingPropertiesForKeys: [.isDirectoryKey],
                  options: [.skipsHiddenFiles]
              ) else { return }

        for wsDir in wsEntries {
            FileSizeHelper.removeIfEmptyDirectory(
                path: wsDir.appendingPathComponent("chatSessions").path
            )
            FileSizeHelper.removeIfEmptyDirectory(
                path: wsDir.appendingPathComponent("chatEditingSessions").path
            )
        }
    }

    /// 递归删除 `root` 下所有空目录，从最深层开始向上收缩。
    ///
    /// - Parameter root: 要清理的根目录；不存在时直接返回。
    static func cleanEmptyDirectories(in root: URL) {
        guard CleanPrefs.cleanEmptyProjectFolders else { return }

        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: root.path),
              let enumerator = fileManager.enumerator(
                  at: root,
                  includingPropertiesForKeys: [.isDirectoryKey],
                  options: [.skipsHiddenFiles]
              ) else { return }

        var subdirectories: [URL] = []
        while let url = enumerator.nextObject() as? URL {
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
                subdirectories.append(url)
            }
        }

        // 先处理最深的目录，父目录才能在子目录清空后一并移除。
        for directory in subdirectories.sorted(by: { $0.path.count > $1.path.count }) {
            FileSizeHelper.removeIfEmptyDirectory(path: directory.path)
        }
    }
}
