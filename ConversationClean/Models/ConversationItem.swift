import Foundation

enum ConversationCategory: String, CaseIterable, Identifiable {
    case all = "全部会话"
    case chatGPT = "ChatGPT"
    case claude = "Claude"
    case gemini = "Gemini"
    case cursor = "Cursor / Copilot"
    case other = "其他"

    var id: String { rawValue }

    var iconName: String {
        switch self {
        case .all: return "tray.2.fill"
        case .chatGPT: return "bubble.left.and.bubble.right.fill"
        case .claude: return "sparkles"
        case .gemini: return "bolt.fill"
        case .cursor: return "chevron.left.forwardslash.chevron.right"
        case .other: return "archivebox.fill"
        }
    }
}

struct ConversationItem: Identifiable, Hashable {
    let id: UUID
    var title: String
    var category: ConversationCategory
    var messageCount: Int
    var sizeInBytes: Int64
    var updatedAt: Date
    var isSelected: Bool = false
    var snippet: String

    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: sizeInBytes, countStyle: .file)
    }

    var formattedDate: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: updatedAt)
    }
}
