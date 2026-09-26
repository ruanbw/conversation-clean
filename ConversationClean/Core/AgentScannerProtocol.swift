import Foundation

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
