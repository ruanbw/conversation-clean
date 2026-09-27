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
    /// 开启态（非实心按钮）：原型 `#btnPanel[aria-pressed=true]` 会额外拿到
    /// `background:var(--fg-soft); color:var(--fg)`，即用洗底而不是换色来表达「已打开」。
    var onBg: Color {
        switch self {
        case .primary, .danger: return bg
        default:                return CC.fillSoft
        }
    }
    var onFg: Color {
        switch self {
        case .primary: return .white
        case .danger:  return .white
        default:       return CC.fg
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
    /// 切换态：标题栏「检视器」用它。实心皮肤（primary / danger）忽略该值 ——
    /// 它们本身就是常开外观，再加洗底只会糊掉。
    var isOn: Bool = false
    var help: String? = nil
    let action: () -> Void

    @State private var hovering = false

    private var resolvedHeight: CGFloat { height ?? (compact ? CC.M.ctlSm : CC.M.ctl) }
    private var showsOnSkin: Bool { isOn && kind != .primary && kind != .danger }

    private var fgColor: Color {
        guard enabled else { return CC.fg.opacity(0.42) }
        if showsOnSkin { return kind.onFg }
        return hovering ? kind.hoverFg : kind.fg
    }
    private var bgColor: Color {
        guard enabled else { return .clear }
        if showsOnSkin { return kind.onBg }
        return hovering ? kind.hoverBg : kind.bg
    }

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
            .foregroundStyle(fgColor)
            .frame(height: resolvedHeight)
            .padding(.horizontal, compact ? 10 : 13)
            .background(
                RoundedRectangle(cornerRadius: compact ? CC.R.sm : CC.R.md, style: .continuous)
                    .fill(bgColor)
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
        .animation(CC.Mv.quick, value: isOn)
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

// MARK: - Data display

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
    /// 焦点由外部驱动，供菜单里的 ⌘F「聚焦搜索框」使用
    /// （原型 `document.addEventListener("keydown")` 里的 ⌘F 分支）。
    /// 不传时退化为组件自持的 `@FocusState`，行为不变。
    var focusBinding: FocusState<Bool>.Binding? = nil

    @State private var hovering = false
    @FocusState private var localFocused: Bool

    private var isFocused: Bool {
        focusBinding.map { $0.wrappedValue } ?? localFocused
    }

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(CC.muted)
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(CC.F.body)
                .focused(focusBinding ?? $localFocused)
            if !text.isEmpty {
                CCIconButton(systemImage: "xmark", size: 22, help: "清除搜索") { text = "" }
            }
        }
        .padding(.horizontal, 10)
        .frame(height: CC.M.ctl)
        .background(
            RoundedRectangle(cornerRadius: CC.R.md, style: .continuous)
                .fill(isFocused ? CC.surface : CC.fillHair)
        )
        .overlay(
            RoundedRectangle(cornerRadius: CC.R.md, style: .continuous)
                .strokeBorder(isFocused ? CC.fg : (hovering ? CC.fg.opacity(0.22) : CC.border), lineWidth: 1)
        )
        // 弹性但有上限：原型 `.search{flex:1; max-width:420px}`。
        // 宽度约束必须放在背景/描边「之后」—— 否则后续任何拉伸 frame 都会把
        // 已经上好色的矩形一起拉宽，搜索框就会铺满整条工具条。
        .frame(maxWidth: width ?? maxWidth, alignment: .leading)
        .animation(CC.Mv.quick, value: isFocused)
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
    /// 横幅背景：ok 用 accent-soft（原型 `.banner.ok{background:var(--accent-soft)}`），
    /// 其他色调用 7% 透明底。
    var background: Color {
        switch self {
        case .ok: return CC.accentSoft
        case .info: return CC.accentSoft
        case .danger: return CC.dangerSoft
        }
    }
    var icon: String {
        switch self {
        case .ok: return "checkmark"
        case .info: return "info.circle"
        case .danger: return "exclamationmark.triangle"
        }
    }
    /// 图标尺寸：原型 `.banner .bi{width:16px}`。
    var iconSize: CGFloat { 16 }
}

struct CCBanner<Trailing: View>: View {
    let tone: CCBannerTone
    let text: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: tone.icon)
                .font(.system(size: tone.iconSize, weight: .semibold))
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
        .background(tone.background)
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
                .font(.system(size: tone.iconSize, weight: .semibold))
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
        .background(tone.background)
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
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(CC.muted.opacity(0.7))
                .padding(.bottom, 16)
            Text(title)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(CC.fg)
                .padding(.bottom, 7)
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

/// 扫描 / 清理进度条 —— 原型 `.sbar`。
/// 2pt 高的细条，背景 fg-hair、填充 fg，无文案。
///
/// 填充从 0 走到 100% 再归零，**不接 ViewModel**：原型 `runBusy()` 同样是
/// `setInterval` 每 90ms 随机 +7~20% 的假进度，扫描器本身也不上报进度。
/// 之前这条画的是写死的 60% —— 看着像卡在 60% 不动，比没有进度条更糟。
struct CCProgressLine: View {
    var tint: Color = CC.fg
    /// 走满一整轮的时间。原型 7~20% / 90ms 平均约 13.5%，即约 0.67s 一轮；
    /// 这里取 1.2s，慢一点，避免快扫时一闪而过。
    var duration: Double = 1.2

    @State private var phase: Double = 0

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Rectangle().fill(CC.fillHair)
                Rectangle()
                    .fill(tint)
                    .frame(width: geo.size.width * phase)
            }
        }
        .frame(height: 2)
        .task(id: duration) {
            // 循环推进：每次归零后立刻重新起跑，进度条在长任务里不会「走完就停」。
            while !Task.isCancelled {
                withAnimation(.linear(duration: duration)) { phase = 1 }
                try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
                guard !Task.isCancelled else { break }
                phase = 0
            }
        }
        .onDisappear { phase = 0 }
        .accessibilityHidden(true)
    }
}

// MARK: - 弹层宿主

/// 原型 `.scrim` 的原生等价物：铺满窗口的遮罩 + 居中弹层。
///
/// 之前用 SwiftUI `.sheet` 实现，形态对不上：`.sheet` 会另开一个附着窗口、
/// 从标题栏滑下，还把窗口的 key 状态抢走；原型是**窗口内**的一层遮罩 ——
/// 弹层盖在内容上，但红黄绿交通灯仍然可见可用（`.scrim` 是 `position:fixed;
/// inset:0`，罩的是 `.desk` 里的内容区，不是整个浏览器视口）。
///
/// 关闭方式对齐原型：点遮罩空白处，或按 Esc（`onExitCommand`）。
/// 原型的 Esc 有优先级（ctx → 设置 → 确认），这里由调用方串起来。
struct ModalScrim<Content: View>: View {
    /// 弹层的最大高度 = 视口高 - 上下留白。
    /// 原型的 `.sheet-b{max-height:min(58vh,520px)}` 需要 vh，SwiftUI 没有，
    /// 所以由宿主把可用高度量出来传下去。
    let viewportHeight: CGFloat
    let onDismiss: () -> Void
    @ViewBuilder var content: (CGFloat) -> Content

    var body: some View {
        // 可用高度：视口减上下各 20pt 内边距（原型 `.scrim{padding:20px}`）。
        let available = max(0, viewportHeight - 40)

        ZStack {
            CC.scrim
                .background(.ultraThinMaterial)
                .ignoresSafeArea()
                // 只吃掉落在遮罩自身上的点击；弹层内的点击由 SwiftUI 自行截断。
                .onTapGesture(perform: onDismiss)

            content(available)
        }
        .onExitCommand(perform: onDismiss)
    }
}
