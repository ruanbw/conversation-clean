import SwiftUI

// MARK: - CC · Shared components
//
// Every feature view composes from these. Nothing here reads the view model,
// so modules stay independent and can be developed in parallel.

// MARK: - Color / Font primitives

extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red:     Double((hex >> 16) & 0xFF) / 255,
            green:   Double((hex >>  8) & 0xFF) / 255,
            blue:    Double( hex        & 0xFF) / 255,
            opacity: 1
        )
    }
}

extension View {
    /// 1px hairline that stays 1px on Retina, like the prototype's `1px solid var(--border)`.
    func ccHairline(_ edges: Edge.Set = .horizontal, _ color: Color = CC.border) -> some View {
        overlay {
            ZStack {
                if edges.contains(.top) {
                    Rectangle().fill(color).frame(height: CC.M.hairline)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                }
                if edges.contains(.bottom) {
                    Rectangle().fill(color).frame(height: CC.M.hairline)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                }
                if edges.contains(.leading) {
                    Rectangle().fill(color).frame(width: CC.M.hairline)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                }
                if edges.contains(.trailing) {
                    Rectangle().fill(color).frame(width: CC.M.hairline)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                }
            }
            .allowsHitTesting(false)
        }
    }
}

// MARK: - Buttons

enum CCButtonKind {
    case primary, danger, outline, ghost
    /// outline 皮肤但整体转成 danger 色调：文字/图标 `danger`、描边 26% 危险色、
    /// hover 底 `dangerSoft`。原型在检视器的「删除此会话」上用的是
    /// `.btn-outline` 加内联 danger 覆盖，现有 4 个 kind 表达不了。
    case dangerOutline

    var bg: Color {
        switch self {
        case .primary: return CC.accent
        case .danger:  return CC.danger
        case .outline, .ghost, .dangerOutline: return .clear
        }
    }
    var fg: Color {
        switch self {
        case .primary, .danger: return .white
        case .dangerOutline:    return CC.danger
        case .outline, .ghost:  return CC.fg
        }
    }
    var stroke: Color {
        switch self {
        case .primary: return CC.accent
        case .danger:  return CC.danger
        case .dangerOutline: return CC.danger.opacity(0.26)
        case .outline: return CC.border
        case .ghost:   return .clear
        }
    }
    var hoverBg: Color {
        switch self {
        case .primary: return CC.accent.opacity(0.86)
        case .danger:  return CC.dangerDeep
        case .dangerOutline: return CC.dangerSoft
        case .outline: return CC.fillSoft
        case .ghost:   return CC.fillSoft
        }
    }
    var hoverFg: Color {
        switch self {
        case .danger:  return .white
        case .dangerOutline: return CC.danger
        default:       return fg
        }
    }
}

/// The prototype's `.btn` — one component, four skins, two sizes.
struct CCButton: View {
    let title: String
    var systemImage: String? = nil
    var kind: CCButtonKind = .outline
    var compact: Bool = false
    /// 显式高度。原型的 `.btn` 是 34px、`.btn-sm` 28px，但检视器动作区是 30px；
    /// 用 `.frame(height:)` 从外面套是压不住的 —— 内部 34pt 的 min 高度会把内容撑回去。
    var height: CGFloat? = nil
    var enabled: Bool = true
    var help: String? = nil
    let action: () -> Void

    @State private var hovering = false

    private var resolvedHeight: CGFloat { height ?? (compact ? CC.M.ctlSm : CC.M.ctl) }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let systemImage {
                    Image(systemName: systemImage)
                        // 原型 `.btn svg{width:15px}`，而 `.btn-sm` 并未覆盖 svg 尺寸，
                        // 所以 28pt 的小按钮图标也保持 15pt
                        .font(.system(size: 15, weight: .medium))
                }
                if !title.isEmpty {
                    Text(title).font(compact ? CC.F.label : CC.F.bodyEm)
                }
            }
            .foregroundStyle(enabled ? (hovering ? kind.hoverFg : kind.fg) : CC.fg.opacity(0.42))
            .frame(height: resolvedHeight)
            .padding(.horizontal, compact ? 10 : 13)
            .background(
                RoundedRectangle(cornerRadius: compact ? CC.R.sm : CC.R.md, style: .continuous)
                    .fill(enabled ? (hovering ? kind.hoverBg : kind.bg) : .clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: compact ? CC.R.sm : CC.R.md, style: .continuous)
                    .strokeBorder(kind.stroke, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .onHover { hovering = $0 }
        .help(help ?? title)
        .animation(CC.Mv.quick, value: hovering)
    }
}

/// Square icon-only button, `.btn-sm` proportions.
struct CCIconButton: View {
    let systemImage: String
    var active: Bool = false
    var tint: Color = CC.fg
    /// hover 配色可覆写：原型 `.r-acts .btn:hover` 是 dangerSoft 底 + danger 图标，
    /// 而默认的 ghost 按钮是 fillSoft 底 + fg 图标。
    var hoverBackground: Color = CC.fillSoft
    var hoverForeground: Color? = nil
    var enabled: Bool = true
    var size: CGFloat = CC.M.ctlIcon
    var help: String = ""
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(enabled ? (active ? tint : (hovering ? (hoverForeground ?? CC.fg) : CC.muted)) : CC.muted.opacity(0.4))
                .frame(width: size, height: size)
                .background(
                    RoundedRectangle(cornerRadius: CC.R.sm, style: .continuous)
                        .fill(active ? CC.fillSoft : (hovering && enabled ? hoverBackground : .clear))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .onHover { hovering = $0 }
        .help(help)
        .animation(CC.Mv.quick, value: hovering)
    }
}

// MARK: - Surfaces

/// Surface + 1px border + `--r-lg`. The prototype's card.
struct CCCard<Content: View>: View {
    var padding: CGFloat = 12
    var radius: CGFloat = CC.R.lg
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(CC.surface))
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(CC.border, lineWidth: 1)
            )
    }
}

/// Monospaced all-caps section label with an optional trailing accessory.
struct CCSectionHeader<Accessory: View>: View {
    let title: String
    @ViewBuilder var accessory: Accessory

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(CC.F.monoSm.weight(.medium))
                .tracking(0.9)
                .textCase(.uppercase)
                .foregroundStyle(CC.muted)
            Spacer(minLength: 4)
            accessory
        }
    }
}

extension CCSectionHeader where Accessory == EmptyView {
    init(_ title: String) { self.init(title: title) { EmptyView() } }
}

/// Small status pill — `.pill` in the prototype.
///
/// `outlined: true` 对应原型的 `.tag` / `.demo-tag`：1px 描边 + 透明底 + 胶囊
/// 或小圆角，而不是填充底。
struct CCBadge: View {
    enum Tone { case neutral, accent, danger, warn }
    let text: String
    var tone: Tone = .neutral
    var mono: Bool = true
    var outlined: Bool = false
    var cornerRadius: CGFloat = CC.R.pill

    private var bg: Color {
        if outlined { return .clear }
        switch tone {
        case .neutral: return CC.fillSoft
        case .accent:  return CC.accentSoft
        case .danger:  return CC.dangerSoft
        case .warn:    return CC.warn.opacity(0.14)
        }
    }
    private var fg: Color {
        switch tone {
        case .neutral: return CC.muted
        case .accent:  return CC.accent
        case .danger:  return CC.danger
        case .warn:    return CC.warn
        }
    }

    var body: some View {
        Text(text)
            .font(mono ? CC.F.monoSm : CC.F.micro)
            .tracking(0.2)                    // 原型 .tag/.pill letter-spacing:.02em
            .foregroundStyle(fg)
            .padding(.horizontal, 6)
            .padding(.vertical, outlined ? 2 : 1)   // 原型 .tag 2px、.pill 1px
            .background(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).fill(bg))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(outlined ? CC.border : .clear, lineWidth: 1)
            )
    }
}

// MARK: - Circular identity

/// Circular agent mark with an optional share ring drawn around it.
struct CCAgentBadge: View {
    let category: ConversationCategory
    var diameter: CGFloat = 30
    /// 0…1 share of total storage; `nil` hides the ring.
    var share: Double? = nil
    var selected: Bool = false

    var body: some View {
        ZStack {
            Circle()
                .fill(selected ? category.tint.opacity(0.18) : category.tintSoft)
            Image(systemName: category.glyph)
                .font(.system(size: diameter * 0.44, weight: .regular))
                .foregroundStyle(selected ? CC.fg : category.tint)
            if let share, share > 0 {
                Circle()
                    .trim(from: 0, to: max(0.02, min(1, share)))
                    .stroke(category.tint, style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .padding(-2.5)
            }
        }
        .frame(width: diameter, height: diameter)
        .overlay(Circle().strokeBorder(CC.border, lineWidth: 1))
    }
}

// MARK: - Circular data display

/// Track + progress arc. Rotated so 0% is at 12 o'clock.
struct CCRing: View {
    var progress: Double
    var lineWidth: CGFloat = 8
    var tint: Color = CC.accent
    var track: Color = CC.fillHair

    var body: some View {
        ZStack {
            Circle().stroke(track, lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0.0001, min(1, progress)))
                .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .animation(CC.Mv.ring, value: progress)
    }
}

/// A fraction row: label, figure, thin bar. Used in breakdowns and legends.
struct CCFractionRow: View {
    let label: String
    let value: String
    var caption: String? = nil
    var fraction: Double
    var tint: Color = CC.accent

    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 8) {
                Text(label)
                    .font(CC.F.label)
                    .foregroundStyle(CC.fg)
                    .lineLimit(1)
                Spacer(minLength: 6)
                if let caption {
                    Text(caption)
                        .font(CC.F.num(10.5, .regular))
                        .foregroundStyle(CC.muted)
                }
                Text(value)
                    .font(CC.F.num(10.5, .medium))
                    .foregroundStyle(CC.muted)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(CC.fillHair)
                    Capsule()
                        .fill(tint)
                        .frame(width: max(2, geo.size.width * min(1, max(0, fraction))))
                }
            }
            .frame(height: 4)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Monochrome stacked bar — the prototype's `.d-bar2`.
struct CCStackBar: View {
    struct Slice: Identifiable {
        let id: String
        let value: Double
        let tint: Color
    }
    let slices: [Slice]
    var height: CGFloat = 10

    private var total: Double { max(slices.reduce(0) { $0 + $1.value }, 0.0001) }

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 0) {
                ForEach(slices) { s in
                    Rectangle()
                        .fill(s.tint)
                        .frame(width: max(1.5, geo.size.width * (s.value / total)))
                }
            }
            .clipShape(Capsule())
        }
        .frame(height: height)
        .background(Capsule().fill(CC.fillHair))
        .accessibilityHidden(true)
    }
}

/// Large figure over a caption, mono + tabular.
///
/// `labelFirst` 对应原型 `.ov-cell`：侧栏统计是「标签在上、数字在下」，
/// 而「关于」页的 `.about .facts` 是「数字在上、标签在下」—— 两种都存在，
/// 所以由参数决定而不是全局改一边倒。
struct CCStatCell: View {
    let value: String
    let label: String
    var tint: Color = CC.fg
    var size: CGFloat = 19
    var labelFirst: Bool = false

    private var figure: some View {
        Text(value)
            .font(CC.F.num(size))
            .foregroundStyle(tint)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
    }
    private var caption: some View {
        Text(label)
            .font(CC.F.caption)
            .foregroundStyle(CC.muted)
            .lineLimit(1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            if labelFirst {
                caption
                figure
            } else {
                figure
                caption
            }
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Controls

struct CCSearchField: View {
    @Binding var text: String
    var placeholder: String = "搜索"
    /// 传 nil 则为弹性宽度（占满可用空间、但不超过 `maxWidth`），
    /// 对应原型 `.search{flex:1; max-width:420px}`。
    var width: CGFloat? = nil
    var maxWidth: CGFloat = 420

    @State private var hovering = false
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(CC.muted)
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(CC.F.body)
                .focused($focused)
            if !text.isEmpty {
                CCIconButton(systemImage: "xmark", size: 22, help: "清除搜索") { text = "" }
            }
        }
        .padding(.horizontal, 10)
        .frame(height: CC.M.ctl)
        .background(
            RoundedRectangle(cornerRadius: CC.R.md, style: .continuous)
                .fill(focused ? CC.surface : CC.fillHair)
        )
        .overlay(
            RoundedRectangle(cornerRadius: CC.R.md, style: .continuous)
                .strokeBorder(focused ? CC.fg : (hovering ? CC.fg.opacity(0.22) : CC.border), lineWidth: 1)
        )
        // 弹性但有上限：原型 `.search{flex:1; max-width:420px}`。
        // 宽度约束必须放在背景/描边「之后」—— 否则后续任何拉伸 frame 都会把
        // 已经上好色的矩形一起拉宽，搜索框就会铺满整条工具条。
        .frame(maxWidth: width ?? maxWidth, alignment: .leading)
        .animation(CC.Mv.quick, value: focused)
        .onHover { hovering = $0 }
    }
}

/// `.seg` — the prototype's segmented control.
struct CCSegmented<Value: Hashable>: View {
    struct Option {
        let value: Value
        let label: String
    }
    let options: [Option]
    @Binding var selection: Value
    var compact: Bool = true

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.value) { opt in
                let on = opt.value == selection
                Button {
                    selection = opt.value
                } label: {
                    Text(opt.label)
                        .font(on ? CC.F.bodyEm : CC.F.label)
                        .foregroundStyle(on ? CC.fg : CC.muted)
                        .frame(height: 26)
                        .padding(.horizontal, 10)
                        .background(
                            RoundedRectangle(cornerRadius: CC.R.xs, style: .continuous)
                                .fill(on ? CC.surface : .clear)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: CC.R.xs, style: .continuous)
                                .fill(Color.black.opacity(on ? 0.06 : 0))
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(opt.label)
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: CC.R.sm, style: .continuous).fill(CC.fillHair))
    }
}

/// Titled switch row, prototype `.tgl`.
struct CCSwitchRow: View {
    let title: String
    let subtitle: String
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(CC.F.bodyEm).foregroundStyle(CC.fg)
                Text(subtitle)
                    .font(CC.F.caption)
                    .foregroundStyle(CC.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // 必须撑满：否则 Toggle 会随文案长度改变自身宽度，
            // 开关不会靠右、且行底发丝线的长度也会逐行不同。
            // 原型 `.tgl .tt{flex:1; min-width:0}` 就是这个作用。
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .toggleStyle(SwitchToggleStyle(tint: CC.accent))
        .padding(.vertical, 5)
    }
}

// MARK: - Feedback

enum CCBannerTone {
    case ok, info, danger
    var tint: Color {
        switch self {
        case .ok: return CC.ok
        case .info: return CC.accent
        case .danger: return CC.danger
        }
    }
    var icon: String {
        switch self {
        case .ok: return "checkmark"
        case .info: return "info.circle"
        case .danger: return "exclamationmark.triangle"
        }
    }
}

struct CCBanner<Trailing: View>: View {
    let tone: CCBannerTone
    let text: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: tone.icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(tone.tint)
            Text(text)
                .font(CC.F.label)
                .foregroundStyle(CC.fg)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            trailing
        }
        .padding(.horizontal, CC.M.gutter)
        .padding(.vertical, 9)
        .background(tone.tint.opacity(0.07))
        .ccHairline(.bottom)
    }
}

extension CCBanner where Trailing == EmptyView {
    init(tone: CCBannerTone, text: String) { self.init(tone: tone, text: text) { EmptyView() } }
}

/// `CCBanner` 的富文本变体：横幅文案需要用等宽/强调色突出某个数字时用它
/// （原型 `.banner b` 就是等宽 semibold）。视觉与 `CCBanner` 完全一致。
struct CCRichBanner<Trailing: View>: View {
    let tone: CCBannerTone
    @ViewBuilder var text: () -> Text
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: tone.icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(tone.tint)
            text()
                .font(CC.F.label)
                .foregroundStyle(CC.fg)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            trailing
        }
        .padding(.horizontal, CC.M.gutter)
        .padding(.vertical, 9)
        .background(tone.tint.opacity(0.07))
        .ccHairline(.bottom)
    }
}

struct CCEmptyState<Action: View>: View {
    let systemImage: String
    let title: String
    let message: String
    var path: String? = nil
    /// 原型空态里路径前有「存储路径：」四个字，与路径本身同一行
    var pathLabel: String? = nil
    @ViewBuilder var action: Action

    var body: some View {
        VStack(spacing: 0) {
            Image(systemName: systemImage)
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(CC.muted.opacity(0.7))
                .padding(.bottom, 14)
            Text(title)
                .font(CC.F.title)
                .foregroundStyle(CC.fg)
                .padding(.bottom, 6)
            Text(message)
                .font(CC.F.label)
                .foregroundStyle(CC.muted)
                .multilineTextAlignment(.center)
                // 原型是 `max-width: 44ch`（44 个字符宽），不是 44 点；
                // 写成 44 会把文案压成每行一个字。按 13pt 字号折算约 7.1pt/字符，取 320。
                .frame(maxWidth: 320)
                .fixedSize(horizontal: false, vertical: true)
            if let path, !path.isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    if let pathLabel {
                        Text(pathLabel)
                            .font(CC.F.label)
                            .foregroundStyle(CC.muted)
                    }
                    Text(path)
                        .font(CC.F.mono)
                        .foregroundStyle(CC.fg)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(RoundedRectangle(cornerRadius: CC.R.xs, style: .continuous).fill(CC.fillSoft))
                }
                .padding(.top, 10)
            }
            action.padding(.top, 16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(28)
    }
}

extension CCEmptyState where Action == EmptyView {
    init(systemImage: String, title: String, message: String, path: String? = nil, pathLabel: String? = nil) {
        self.init(systemImage: systemImage, title: title, message: message, path: path, pathLabel: pathLabel) { EmptyView() }
    }
}

/// Scanning / cleaning progress strip, hairline thin.
struct CCProgressLine: View {
    let label: String
    var tint: Color = CC.accent

    var body: some View {
        HStack(spacing: 9) {
            ProgressView()
                .controlSize(.small)
                .scaleEffect(0.8)
            Text(label)
                .font(CC.F.label)
                .foregroundStyle(CC.muted)
        }
        .padding(.horizontal, CC.M.gutter)
        .padding(.vertical, 7)
        .background(CC.fillHair)
        .ccHairline(.bottom)
    }
}
