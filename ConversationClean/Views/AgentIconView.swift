import SwiftUI
import AppKit

// MARK: - Agent 图标
//
// 用**产品自己的图标**，不是自绘徽章。照 DefaultAppManager 的 AppIconView：
// 它每行左侧放的就是 Xcode / VS Code / Sublime Text 的真实 app 图标。
//
// 真实图标本身就是色彩与识别度的锚点 —— 之前我拿「彩色字母块」替代它，
// 既丢了识别度，又得靠一堆语义色去补，色板自然就花。
//
// CLI 工具（Codex / Aider / Pi Agent）与 VS Code 扩展（Cline / Roo / Continue）
// 本身没有独立 app 图标，这类回退到 SF Symbol，不会硬凑。

/// 按 bundle 名解析本机已安装的 app，并把图标缓存在进程内。
///
/// 解析只在第一次用到时做一次：扫 /Applications 要读目录，15 款 Agent 逐个
/// 查会让首次渲染卡一下，之后全程走缓存。
enum AgentIcon {
    private static var cache: [String: NSImage] = [:]
    private static let lock = NSLock()

    /// 找不到返回 nil，调用方回退到 SF Symbol。
    static func image(for category: ConversationCategory) -> NSImage? {
        for bundle in category.appBundleNames {
            guard let icon = image(forBundleName: bundle), icon.size.width > 0 else { continue }
            return icon
        }
        return nil
    }

    static func image(forBundleName bundle: String) -> NSImage? {
        lock.lock()
        defer { lock.unlock() }
        if let hit = cache[bundle] { return hit }

        // 记一个「查过且没有」的空占位，避免每帧重扫三个目录
        guard let url = locate(bundle) else {
            cache[bundle] = NSImage()
            return nil
        }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        cache[bundle] = icon
        return icon
    }

    /// 应用可能装在系统区、用户区或 Utilities 里，三个位置都找。
    private static func locate(_ bundle: String) -> URL? {
        let fm = FileManager.default
        let home = URL(fileURLWithPath: NSHomeDirectory())
        let roots = [
            URL(fileURLWithPath: "/Applications"),
            home.appendingPathComponent("Applications"),
            // 系统自带工具（如 Xcode）在 Utilities 下
            URL(fileURLWithPath: "/Applications/Utilities"),
            home.appendingPathComponent("Applications/Utilities")
        ]
        for root in roots {
            let candidate = root.appendingPathComponent(bundle)
            if fm.fileExists(atPath: candidate.path) { return candidate }
        }
        return nil
    }
}

/// 左侧 Agent 图标：真实 app 图标优先，否则 SF Symbol。
struct AgentIconView: View {
    let category: ConversationCategory
    var size: CGFloat = 20

    var body: some View {
        Group {
            if let image = AgentIcon.image(for: category) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: category.iconName)
                    .font(.system(size: size * 0.8, weight: .regular))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .help(category.rawValue)
    }
}
