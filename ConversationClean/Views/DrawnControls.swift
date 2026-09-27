import SwiftUI

// MARK: - DrawnControls
//
// 全部控件手绘，视觉不依赖任何系统控件外观。
//
// 边界说明（很重要，别把它当漏洞）：
//   · 交互原语仍用 SwiftUI 的 `Button` / `TextField` / `Toggle(纯值绑定)`。
//     它们不是"系统控件外观"，只是布局与事件容器 —— 自绘 ButtonStyle 接管了
//     全部绘制（高光、描边、圆角、hover、press），系统外观一点不露。
//     如果连 `Button` 都换成 `onTapGesture`，会同时失去键盘可达、
//     VoiceOver 的 Button 角色、以及 macOS 的点击/触控板手势行为 —— 那是
//     拿可用性换一张皮，方向错了。
//   · `TextField` 的输入法（IME）、光标、选区、Dictation 无法自绘重写，
//     所以只自绘它的外壳（圆角、描边、focus ring、放大镜、清除钮），
//     内部用 `.textFieldStyle(.plain)` 剥掉系统外观。

// MARK: - 按钮

/// 按钮视觉变体。
enum DrawnButtonVariant {
    /// 无底色：工具栏图标、次要动作
    case flat
    /// 无底色 + 危险红：工具栏里的破坏性动作（如「清除全部」的垃圾桶）。
    /// 与 `.flat` 分开而不是复用 —— 破坏性动作的图标不该和「设置」长得一样重，
    /// 但顶栏只有 26pt 高度，实心红底会太扎眼，所以只借红色前景。
    case dangerQuiet
    /// 白底描边：需要和背景区分的次要动作
    case ghost
    /// 靛蓝渐变实心：全局主操作
    case primary
    /// 红色实心：不可逆动作（删除/清理）
    case danger

    var foreground: Color {
        switch self {
        case .flat: return Theme.t2
        case .dangerQuiet: return Theme.danger
        case .ghost: return Theme.t1
        case .primary: return .white
        case .danger: return .white
        }
    }

    var background: AnyShapeStyle {
        switch self {
        case .flat, .dangerQuiet: return AnyShapeStyle(Color.clear)
        case .ghost: return AnyShapeStyle(Theme.surface)
        case .primary: return AnyShapeStyle(LinearGradient(
            colors: [Theme.accentHi, Theme.accent],
            startPoint: .top, endPoint: .bottom))
        case .danger: return AnyShapeStyle(LinearGradient(
            colors: [Theme.danger.opacity(0.86), Theme.danger],
            startPoint: .top, endPoint: .bottom))
        }
    }

    var borderColor: Color? {
        switch self {
        case .flat, .dangerQuiet: return nil
        case .ghost: return Theme.lineStrong
        case .primary: return Color.black.opacity(0.08)
        case .danger: return Color.black.opacity(0.08)
        }
    }

    var shadow: Color? {
        switch self {
        case .primary: return Theme.accent.opacity(0.28)
        case .danger: return Theme.danger.opacity(0.30)
        default: return nil
        }
    }
}

/// 自绘按钮样式。hover 提亮、press 压暗、禁用降透明 —— 全部自己实现。
struct DrawnButtonStyle: ButtonStyle {
    var variant: DrawnButtonVariant = .flat
    var radius: CGFloat = Theme.Radius.control
    var horizontalPadding: CGFloat = Theme.Space.ms
    var enabled: Bool = true
    /// 紧凑模式：行高 22pt，用在批量条里
    var compact: Bool = false

    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        let h = compact ? 22 : Theme.Size.button
        configuration.label
            .foregroundStyle(enabled ? variant.foreground : Theme.t3)
            .padding(.horizontal, horizontalPadding)
            .frame(height: h)
            .background {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(hoveredFill(configuration: configuration))
            }
            .overlay {
                if let border = variant.borderColor, enabled {
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .strokeBorder(border, lineWidth: 1)
                }
            }
            .shadow(color: enabled ? (variant.shadow ?? .clear) : .clear,
                    radius: 1, y: 1)
            .opacity(enabled ? (hovering ? 0.88 : 1) : 0.4)
            .contentShape(Rectangle())
            .onHover { hovering = enabled && $0 }
            .animation(.easeOut(duration: 0.10), value: hovering)
    }

    /// hover 提亮 / press 压暗。flat 类变体没有底，所以用一层低透明度覆盖模拟。
    private func hoveredFill(configuration: Configuration) -> AnyShapeStyle {
        if variant == .flat || variant == .dangerQuiet {
            if configuration.isPressed { return AnyShapeStyle(Color.primary.opacity(0.09)) }
            if hovering { return AnyShapeStyle(Color.primary.opacity(0.05)) }
            return AnyShapeStyle(Color.clear)
        }
        if configuration.isPressed {
            return AnyShapeStyle(variant.foreground.opacity(0.22))
        }
        if hovering {
            return AnyShapeStyle(variant.foreground.opacity(0.10))
        }
        return variant.background
    }
}

// MARK: - 勾选框

/// 手绘勾选框，支持半选态（mixed）。
///
/// 原实现用系统 `Toggle(.checkbox)`，它带一个系统绘制的框；这里整块重画，
/// 尺寸按 A 版的 14pt，比系统默认小 1pt，密度更高。
struct DrawnCheckbox: View {
    @Binding var isOn: Bool
    var enabled: Bool = true
    /// 半选：整列操作时"部分已选"
    var isMixed: Bool = false
    var size: CGFloat = Theme.Size.checkbox
    var help: String?

    @State private var hovering = false

    var body: some View {
        Button {
            guard enabled else { return }
            isOn.toggle()
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous)
                    .fill(background)
                mark
            }
            .frame(width: size, height: size)
            .overlay {
                RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous)
                    .strokeBorder(border, lineWidth: 1.5)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .onHover { hovering = $0 }
        .help(help ?? (isOn ? "取消选择" : "选择"))
        .accessibilityValue(isMixed ? "部分选中" : (isOn ? "已选中" : "未选中"))
    }

    private var background: Color {
        if isOn || isMixed { return enabled ? Theme.accent : Theme.t3 }
        return hovering ? Theme.line : Theme.surface
    }

    private var border: Color {
        if isOn || isMixed { return enabled ? Theme.accent : Theme.t3 }
        return hovering ? Theme.t3 : Theme.lineStrong
    }

    @ViewBuilder
    private var mark: some View {
        if isMixed {
            // 半选：一条横杠，比画叉号更符合"部分"的语义
            Rectangle()
                .fill(Color.white)
                .frame(width: size * 0.5, height: 1.8)
        } else if isOn {
            // 对勾：两条边旋转拼出来，不依赖 SF Symbol
            Image(systemName: "checkmark")
                .font(.system(size: size * 0.62, weight: .black))
                .foregroundStyle(.white)
                .offset(y: -0.5)
        }
    }
}

// MARK: - 分段控件

/// 手绘分段控件。替代系统 `Picker(.segmented)`。
struct DrawnSegmented<Value: Hashable>: View {
    struct Item {
        let value: Value
        let label: String
        init(_ value: Value, _ label: String) {
            self.value = value
            self.label = label
        }
    }

    @Binding var selection: Value
    let items: [Item]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                let on = item.value == selection
                Text(item.label)
                    .font(Theme.Typo.sectionHead.weight(on ? .semibold : .medium))
                    .foregroundStyle(on ? Theme.t1 : Theme.t2)
                    .padding(.horizontal, 9)
                    .frame(height: 20)
                    .background {
                        RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous)
                            .fill(on ? Theme.surface : .clear)
                            .shadow(color: on ? .black.opacity(0.10) : .clear,
                                    radius: 1, y: 1)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        withAnimation(.easeOut(duration: 0.12)) { selection = item.value }
                    }
            }
        }
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                .fill(Color.primary.opacity(0.045))
        )
    }
}

// MARK: - 搜索框

/// 手绘搜索框。圆角、描边、focus ring、放大镜、清除钮全部自绘。
struct DrawnSearchField: View {
    @Binding var text: String
    var placeholder: String
    var onSubmit: (() -> Void)? = nil

    @FocusState private var focused: Bool
    @State private var hovering = false

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            // 放大镜：自绘，不引 SF Symbol（避免系统图标风格混入）
            Circle()
                .strokeBorder(Theme.t3, lineWidth: 1.4)
                .frame(width: 11, height: 11)
                .overlay(alignment: .bottomTrailing) {
                    Rectangle()
                        .fill(Theme.t3)
                        .frame(width: 1.4, height: 5)
                        .rotationEffect(.degrees(-45))
                        .offset(x: 3, y: 2.5)
                }
                .frame(width: 14, height: 14)

            // 唯一没法自绘的部分：输入法与光标。系统外观用 .plain 剥掉。
            TextField("", text: $text, prompt: Text(placeholder).foregroundStyle(Theme.t3))
                .textFieldStyle(.plain)
                .font(Theme.Typo.navItem)
                .foregroundStyle(Theme.t1)
                .focused($focused)
                .onSubmit { onSubmit?() }

            if !text.isEmpty {
                Button { text = "" } label: {
                    ZStack {
                        Circle().fill(Theme.t3)
                        Image(systemName: "xmark")
                            .font(.system(size: 6.5, weight: .black))
                            .foregroundStyle(Theme.surface)
                    }
                    .frame(width: 13, height: 13)
                }
                .buttonStyle(.plain)
                .help("清除搜索词")
            }
        }
        .padding(.horizontal, Theme.Space.m)
        .frame(height: 28)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.field, style: .continuous)
                .fill(Theme.sunken)
        )
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Radius.field, style: .continuous)
                .strokeBorder(border, lineWidth: 1)
        }
        .overlay {
            // focus ring：靛蓝 3px 外发光，与 HTML 稿的 box-shadow 一致
            if focused {
                RoundedRectangle(cornerRadius: Theme.Radius.field, style: .continuous)
                    .strokeBorder(Theme.accent.opacity(0.35), lineWidth: 3)
                    .padding(-2)
            }
        }
        .animation(.easeOut(duration: 0.12), value: focused)
        .animation(.easeOut(duration: 0.12), value: hovering)
    }

    private var border: Color {
        if focused { return Theme.accent }
        return hovering ? Theme.lineStrong : Theme.lineStrong.opacity(0.7)
    }
}

// MARK: - 通知条

/// 手绘通知条。替代原来那条 `tint.opacity(0.12)` 的绿色横条。
struct DrawnNotice<Tint: ShapeStyle & Equatable>: View {
    var icon: String
    var text: String
    var tint: Tint
    var tintText: Color
    var dismissTitle: String?
    var onDismiss: (() -> Void)?

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(tint)
            Text(text)
                .font(Theme.Typo.rowSub)
                .foregroundStyle(tintText)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: Theme.Space.m)
            if let dismissTitle, let onDismiss {
                Button(dismissTitle, action: onDismiss)
                    .buttonStyle(DrawnButtonStyle(variant: .flat, horizontalPadding: 6))
            }
        }
        .padding(.horizontal, Theme.Space.m)
        .padding(.vertical, 7)
        .background {
            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                .fill(tint.opacity(0.10))
        }
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                .strokeBorder(tint.opacity(0.22), lineWidth: 1)
        }
    }
}

extension DrawnNotice where Tint == Color {
    init(icon: String, text: String, success: Bool = true,
         dismissTitle: String? = nil, onDismiss: (() -> Void)? = nil) {
        self.init(icon: icon, text: text,
                  tint: success ? Theme.success : Theme.danger,
                  tintText: success ? Theme.successText : Theme.danger,
                  dismissTitle: dismissTitle, onDismiss: onDismiss)
    }
}

// MARK: - 占比条

/// 占比条。靛蓝渐变填充 —— 修掉原来 `Color.primary.opacity(0.55)` 的黑灰条。
struct ShareBar: View {
    /// 0...100
    var percent: Double
    var width: CGFloat?
    var height: CGFloat = 4
    var trackColor: Color = Theme.accent.opacity(0.11)

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(trackColor)
                Capsule()
                    .fill(LinearGradient(colors: [Theme.accentHi, Theme.accent],
                                         startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(2, geo.size.width * min(max(percent, 0), 100) / 100))
            }
        }
        .frame(width: width, height: height)
        .accessibilityHidden(true)
    }
}

// MARK: - 空态

/// 手绘空态。替代 `ContentUnavailableView`（它带系统插画与系统排版）。
struct DrawnEmptyState: View {
    var symbol: String
    var title: String
    var message: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: Theme.Space.l) {
            ZStack {
                Circle()
                    .fill(Theme.accentSoft)
                    .frame(width: 52, height: 52)
                Image(systemName: symbol)
                    .font(.system(size: 21, weight: .light))
                    .foregroundStyle(Theme.accent.opacity(0.8))
            }
            VStack(spacing: Theme.Space.s) {
                Text(title)
                    .font(Theme.Typo.cardTitle)
                    .foregroundStyle(Theme.t1)
                Text(message)
                    .font(Theme.Typo.rowSub)
                    .foregroundStyle(Theme.t2)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 280)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let actionTitle, let action {
                Button(action: action) {
                    Text(actionTitle)
                        .font(Theme.Typo.navItem.weight(.medium))
                }
                .buttonStyle(DrawnButtonStyle(variant: .primary, horizontalPadding: Theme.Space.xl))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(Theme.Space.xxl)
    }
}

// MARK: - 区块标题

/// 分区小标题。两种语气：
///   `.uppercase` — 侧栏那套 11pt 大写三级字（设计稿 `.side .sect`）
///   `.strong`    — 内容栏的 12pt semibold（设计稿 `.dt`）
/// 默认 `.uppercase`，加参数是向后兼容的。
struct SectionLabel: View {
    enum Style { case uppercase, strong }
    var text: String
    var paddingTop: CGFloat = Theme.Space.l
    var style: Style = .uppercase

    var body: some View {
        Text(style == .uppercase ? text.uppercased() : text)
            .font(style == .uppercase ? Theme.Typo.sectionHead : Theme.Typo.sectionHeadStrong)
            .foregroundStyle(style == .uppercase ? Theme.t3 : Theme.t1)
            .tracking(style == .uppercase ? 0.4 : 0)
            .padding(.horizontal, Theme.Space.s)
            .padding(.top, paddingTop)
            .padding(.bottom, Theme.Space.s)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
