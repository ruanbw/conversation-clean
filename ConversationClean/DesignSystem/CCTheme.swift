import SwiftUI

// MARK: - CC · Design tokens
//
// Ported verbatim from the Open Design HTML prototype's oklch token set
// (design direction: "tech-utility" — near-neutral surfaces, 1px hairlines,
// monospaced tabular numerals, one green accent + one red danger).
// Converted to sRGB because SwiftUI on macOS 14 has no oklch initializer.

enum CC {

    // MARK: Surfaces & text

    static let bg      = Color(hex: 0xF6F9FC)
    static let surface = Color(hex: 0xFFFFFF)
    static let panel   = Color(hex: 0xFAFBFC)   // sidebar wash (bg 42% over surface)
    static let fg      = Color(hex: 0x121C23)
    static let muted   = Color(hex: 0x5A656D)
    static let border  = Color(hex: 0xD9DFE3)

    // MARK: State colors

    static let accent     = Color(hex: 0x299236)   // oklch 58% .16 145
    static let danger     = Color(hex: 0xC92F33)   // oklch 55% .19 25
    static let dangerDeep = Color(hex: 0xAC011A)
    static let warn       = Color(hex: 0xB37903)
    static let ok         = Color(hex: 0x14874E)

    // MARK: Derived washes

    static let accentSoft = Color(hex: 0xE3F1E5)  // accent 13%
    static let accentLine = Color(hex: 0xB6DABB)  // accent 34%
    static let dangerSoft = Color(hex: 0xFAEAEB)  // danger 10%
    static let fillSoft   = Color(hex: 0xF1F1F2)  // fg 6%
    static let fillHair   = Color(hex: 0xF6F6F6)  // fg 4%
    /// outline 按钮 hover 时的边框加深，对应
    /// `color-mix(in oklch, var(--fg) 20%, var(--border))`
    static let hoverBorder = Color(hex: 0xB1B8BD)
    static let scrim      = Color.black.opacity(0.28)

    // MARK: Radii

    enum R {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 6
        static let md: CGFloat = 8
        static let lg: CGFloat = 12
        static let xl: CGFloat = 16
        static let pill: CGFloat = 999
    }

    // MARK: Metrics

    enum M {
        static let ctl      : CGFloat = 34   // standard control height
        static let ctlSm    : CGFloat = 28
        static let ctlIcon  : CGFloat = 32
        static let hairline : CGFloat = 1
        static let sidebar  : CGFloat = 272  // matches prototype grid
        static let inspector: CGFloat = 324
        static let gutter   : CGFloat = 20
    }

    // MARK: Typography
    //
    // `.num` is the prototype's `.num` class: monospaced, tabular, tight tracking.
    // It is used for every figure the eye compares vertically.

    enum F {
        static let display = Font.system(size: 19, weight: .semibold)
        static let title   = Font.system(size: 15, weight: .semibold)
        static let body    = Font.system(size: 13)
        static let bodyEm  = Font.system(size: 13, weight: .medium)
        static let label   = Font.system(size: 12)
        static let caption = Font.system(size: 11)
        static let micro   = Font.system(size: 10)

        /// Monospaced tabular figure — the prototype's `.num`.
        static func num(_ size: CGFloat, _ weight: Font.Weight = .semibold) -> Font {
            .system(size: size, weight: weight, design: .monospaced).monospacedDigit()
        }
        /// Small monospaced text for paths, ids, pill labels.
        static let mono = Font.system(size: 10.5, design: .monospaced)
        /// 小号等宽文本。原型里 `.sb-h` / `.insp-l` / `.tag` / `.pill` 一律 10px，
        /// 所以这里取 10 而不是 9.5。
        static let monoSm = Font.system(size: 10, design: .monospaced)
    }

    // MARK: Motion

    enum Mv {
        static let quick = Animation.easeOut(duration: 0.14)
        static let base  = Animation.easeInOut(duration: 0.18)
        static let ring  = Animation.easeOut(duration: 0.35)
    }
}

// MARK: - Category identity

/// One tint per agent, drawn from a single-hue oklch(145) ramp so the whole UI
/// stays monochrome-green and only the destructive red breaks out of it.
private let ramp: [Color] = [
    Color(hex: 0x9EB19E), Color(hex: 0x93AA93), Color(hex: 0x88A288), Color(hex: 0x7E9B7E),
    Color(hex: 0x739374), Color(hex: 0x698C69), Color(hex: 0x5F855F), Color(hex: 0x547E55),
    Color(hex: 0x4A774B), Color(hex: 0x3F6F41), Color(hex: 0x346837), Color(hex: 0x29612D),
    Color(hex: 0x1C5A22), Color(hex: 0x0B5317), Color(hex: 0x004C09)
]

extension ConversationCategory {

    /// Stable tint for this agent. `.all` is neutral on purpose.
    var tint: Color {
        guard self != .all else { return CC.fg }
        let i = ConversationCategory.allCases.firstIndex(of: self) ?? 0
        return ramp[min(max(i - 1, 0), ramp.count - 1)]
    }

    /// Soft wash of the tint, for badge fills.
    var tintSoft: Color { tint.opacity(0.12) }

    /// The circular identity mark. Line-style symbol, never filled-heavy.
    var glyph: String {
        switch self {
        case .all:          return "tray.2"
        case .claudeCode:   return "terminal"
        case .codex:        return "chevron.left.forwardslash.chevron.right"
        case .piAgent:      return "cpu"
        case .cline:        return "bolt"
        case .rooCode:      return "sparkles"
        case .continueDev:  return "play.rectangle"
        case .copilotChat:  return "bubble.left.and.bubble.right"
        case .cursor:       return "cursorarrow.rays"
        case .windsurf:     return "wind"
        case .trae:         return "circle.hexagongrid"
        case .aider:        return "terminal.badge.clock"
        case .openViking:   return "shield"
        case .zed:          return "character.cursor.ibeam"
        case .openHands:    return "hand.raised"
        case .antigravity:  return "square.stack.3d.up"
        }
    }

    /// 1–2 character mark for the circular badge fallback.
    var badgeText: String {
        let words = rawValue
            .replacingOccurrences(of: "/", with: " ")
            .split(whereSeparator: { $0 == " " })
            .map(String.init)
            .filter { !$0.isEmpty && $0.first!.isLetter }
        if words.count >= 2 { return (words[0].prefix(1) + words[1].prefix(1)).uppercased() }
        if words.count == 1 { return String(words[0].prefix(2)).uppercased() }
        return "?"
    }
}

extension AgentInfo {
    var tint: Color { category.tint }
    var tintSoft: Color { category.tintSoft }
}

// MARK: - Formatting helpers

enum Fmt {
    /// 与原型 `fmtBytes` 同口径：**1024 进制**、小于 10 保留 1 位小数、
    /// ≥10 四舍五入为整数、0 输出「0 KB」。
    ///
    /// 不能用 `ByteCountFormatter`，它是 1000 进制：同一条 2,411,724 字节的会话
    /// 会打成 2.4 MB，而磁盘工具（`du` / `df` / `ls -h`）与原型都显示 2.3 MB。
    /// 这个应用通篇在讲磁盘占用，用的必须是 1024。
    static func bytes(_ n: Int64) -> String {
        guard n != 0 else { return "0 KB" }
        let units = ["KB", "MB", "GB", "TB"]
        var value = Double(max(n, 0))
        var index = -1
        repeat {
            value /= 1024
            index += 1
        } while value >= 1024 && index < units.count - 1
        let text = value < 10 ? String(format: "%.1f", value) : String(Int(value.rounded()))
        return "\(text) \(units[index])"
    }

    /// 原型 `fmtFull`：`2026-09-26 19:54`。
    /// 检视器的「最后更新」用它（要精确到分），列表行第 3 行的「今天 19:26」用 `relative`。
    static func full(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.string(from: date)
    }

    /// 把 home 目录缩写成 `~`，供存储路径、关联文件这类长路径显示。
    static func abbreviateHome(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    /// 原型 `fmtDate(it)`：今天 HH:mm / 昨天 HH:mm / N 天前 / M月D日
    static func relative(_ date: Date, now: Date = Date()) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return "今天 " + hhmm(date) }
        if cal.isDateInYesterday(date) { return "昨天 " + hhmm(date) }
        let days = cal.dateComponents(
            [.day],
            from: cal.startOfDay(for: date),
            to: cal.startOfDay(for: now)
        ).day ?? 0
        if days > 0 && days < 7 { return "\(days) 天前" }
        return "\(cal.component(.month, from: date))月\(cal.component(.day, from: date))日"
    }

    private static func hhmm(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm"
        return f.string(from: date)
    }

    /// Compact trailing path segment, e.g. "conversation-clean".
    static func pathTail(_ path: String, _ keep: Int = 1) -> String {
        let parts = path.split(separator: "/").map(String.init).filter { !$0.isEmpty }
        guard parts.count > keep else { return path }
        return parts.suffix(keep).joined(separator: "/")
    }
}
