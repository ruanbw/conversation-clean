import Foundation

enum ConversationCategory: String, CaseIterable, Identifiable {
    case all = "全部会话"
    case claudeCode = "Claude Code"
    case codex = "Codex"
    case piAgent = "Pi Agent"
    case cline = "Cline"
    case rooCode = "Roo Code"
    case continueDev = "Continue"
    case copilotChat = "Copilot / VS Code"
    case cursor = "Cursor"
    case windsurf = "Windsurf"
    case trae = "Trae"
    case aider = "Aider"
    case openViking = "OpenViking"
    case zed = "Zed AI"
    case openHands = "OpenHands"
    case antigravity = "Antigravity"

    var id: String { rawValue }

    /// 原型 `<defs>` 里 24 个图标的**唯一对应物**。
    ///
    /// 铁律：一律线性。原型的每个 glyph 都是
    /// `fill="none" stroke="currentColor" stroke-width="1.6"`，整套 UI 只靠 1.6px 描边
    /// 建立识别度；一旦混入 `.fill` 变体，描边语言就断了，侧栏 / 标题行 / 检视器 /
    /// 设置路径页会各自用不同粗细的符号。
    ///
    /// 取名对照（原型 id → SF Symbol，形状尽量贴近，线稿变体优先）：
    /// `i-tray→tray.2` `i-terminal→terminal` `i-code→chevron.left.forwardslash.chevron.right`
    /// `i-cpu→cpu` `i-bolt→bolt` `i-spark→sparkles` `i-play→play.rectangle`
    /// `i-chat→bubble.left.and.bubble.right` `i-cursor→cursorarrow.rays` `i-wind→wind`
    /// `i-ring→circle.hexagongrid` `i-layers→square.stack.3d.up` `i-shield→shield`
    /// `i-textbox→character.cursor.ibeam` `i-hand→hand.raised`
    ///
    /// 两处**刻意**不与原型同形，理由都是「SF Symbols 没有等价线稿」：
    ///   · Aider 原型复用 `i-terminal`（与 Claude Code 完全同形）。这里给
    ///     `terminal.badge.clock`，因为真实侧栏里两款会同时出现、同形等于没有区分。
    ///   · Zed AI 原型是 `i-textbox`。`character.textbox` 只有填充版，太重，
    ///     换成同为文本光标意象的线稿 `character.cursor.ibeam`。
    var iconName: String {
        switch self {
        case .all:
            return "tray.2"
        case .claudeCode:
            return "terminal"
        case .codex:
            return "chevron.left.forwardslash.chevron.right"
        case .piAgent:
            return "cpu"
        case .cline:
            return "bolt"
        case .rooCode:
            return "sparkles"
        case .continueDev:
            return "play.rectangle"
        case .copilotChat:
            return "bubble.left.and.bubble.right"
        case .cursor:
            return "cursorarrow.rays"
        case .windsurf:
            return "wind"
        case .trae:
            return "circle.hexagongrid"
        case .aider:
            return "terminal.badge.clock"
        case .openViking:
            return "shield"
        case .zed:
            return "character.cursor.ibeam"
        case .openHands:
            return "hand.raised"
        case .antigravity:
            return "square.stack.3d.up"
        }
    }
}

struct ConversationItem: Identifiable, Hashable {
    let id: UUID
    var sessionId: String
    var title: String
    var category: ConversationCategory
    var projectPath: String?
    var gitBranch: String?
    var messageCount: Int
    var sizeInBytes: Int64
    var updatedAt: Date
    var isSelected: Bool = false
    var snippet: String
    var associatedPaths: [String] = []

    /// 与原型 `fmtBytes` 同口径的 1024 进制（见 `Fmt.bytes`）。
    /// 不能用 `ByteCountFormatter`，它是 1000 进制，会把 2,411,724 字节打成 2.4 MB。
    var formattedSize: String {
        Fmt.bytes(sizeInBytes)
    }

    var formattedDate: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: updatedAt)
    }

    var displayProjectPath: String {
        guard let projectPath = projectPath, !projectPath.isEmpty else { return "" }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if projectPath.hasPrefix(home) {
            return "~" + projectPath.dropFirst(home.count)
        }
        return projectPath
    }

    var shortSessionId: String {
        if sessionId.count > 8 {
            return String(sessionId.prefix(8))
        }
        return sessionId
    }
}
