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

    var iconName: String {
        switch self {
        case .all:
            return "tray.2.fill"
        case .claudeCode:
            return "terminal.fill"
        case .codex:
            return "chevron.left.forwardslash.chevron.right"
        case .piAgent:
            return "cpu"
        case .cline:
            return "bolt.horizontal.fill"
        case .rooCode:
            return "sparkles"
        case .continueDev:
            return "play.rectangle.fill"
        case .copilotChat:
            return "bubble.left.and.exclamationmark.bubble.right.fill"
        case .cursor:
            return "cursorarrow.rays"
        case .windsurf:
            return "wind"
        case .trae:
            return "bolt.ring.closed"
        case .aider:
            return "terminal"
        case .openViking:
            return "shield.lefthalf.filled"
        case .zed:
            return "character.textbox"
        case .openHands:
            return "hand.raised.fill"
        case .antigravity:
            return "sparkles.rectangle.stack"
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

    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: sizeInBytes, countStyle: .file)
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
