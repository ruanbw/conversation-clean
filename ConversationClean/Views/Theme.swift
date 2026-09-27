import SwiftUI
import AppKit

// MARK: - Theme
//
// 视觉基线：design-demos/ui-a-precision.html（Linear 系精密密度，已锁定）。
// 本文件把那版 HTML 里的 CSS 变量原样搬成 Swift token ——
// 后面所有视图只读这里的 token，不允许就地写颜色与字号字面量。
//
// 配色取自三处真实设计系统，不是凭空：
//   · 主色靛蓝 #5B5BD6 ← Linear 设计系统 #5e6ad2
//   · 发丝线 #E9E9ED / 四级表面梯 ← Linear
//   · 8pt baseline grid（1/4/6/8/10/12/16/20/24/32）← Apple HIG
//   · 控件圆角 6-8pt、卡片 8pt、窗口 10pt ← Apple HIG
//   · 正文 13pt（macOS 的 .body 值，不是 iOS 的 17pt）← Apple HIG
//
// 深浅色：设计稿主体是浅色（用户明选「浅色精致 + 克制强调色」）。
// 但硬编码浅色在系统深色模式下会瞎眼，所以每个颜色都给出深色降级值 ——
// 深色下保可用，浅色下完全等于设计稿。

enum Theme {

    // MARK: 间距（8pt baseline grid）
    //
    // Apple HIG：macOS 间距是 8pt 基准网格，标准值都是 4 的倍数或整数倍。
    // 允许 2/10/14 是因为行内元素间距与 13pt 字号行高需要，这些仍落在
    // 4pt 网格的半格上，与 HIG 的 xxs(1)/xs(4)/s(6)/m(8) 序列一致。

    enum Space {
        static let hair: CGFloat = 1     // 分隔线
        static let xxs: CGFloat = 2      // 徽章内文字与图标
        static let xs: CGFloat = 4       // 段内元素最小间距
        static let s: CGFloat = 6        // 图标与文字
        static let m: CGFloat = 8        // 行内元素
        static let ms: CGFloat = 10      // 筛选栏内边距
        static let l: CGFloat = 12       // 分区块内边距
        static let ll: CGFloat = 14      // 卡片内边距
        static let xl: CGFloat = 16      // 列表/搜索内边距
        static let xxl: CGFloat = 20     // 详情栏内边距
        static let huge: CGFloat = 24    // 详情栏外边距
        static let giant: CGFloat = 32
    }

    // MARK: 圆角

    enum Radius {
        static let fine: CGFloat = 1.5     // 极细元素（微型条端点）
        static let chipSmall: CGFloat = 2   // 分布图里的小色块
        static let micro: CGFloat = 3      // 小圆角条
        static let chip: CGFloat = 4     // 徽章、色块
        static let control: CGFloat = 6  // 按钮、勾选框、分段项
        static let field: CGFloat = 7    // 搜索框
        static let card: CGFloat = 8     // 卡片
        static let window: CGFloat = 10
    }

    // MARK: 排版
    //
    // macOS 语义字体的真实 pt 值：body 13 / callout 12 / subheadline 11 /
    // caption 10。设计稿里的 12.5 / 10.5 是这两档之间的视觉微调，
    // 统一走 .system(size:) 以便精确命中（11.5/12.5 这类值语义字体给不了）。

    enum Typo {
        /// 列表行主标题（设计稿 12.5pt）
        static let rowTitle = Font.system(size: 12.5, weight: .medium)
        static let rowTitleActive = Font.system(size: 12.5, weight: .semibold)
        /// 列表行副标题（设计稿 10.5pt）
        static let rowSub = Font.system(size: 10.5)
        /// 体积数字 —— 刻意比 rowTitle 更重，这是 A 版的层级修正
        static let sizeNum = Font.system(size: 12.5, weight: .semibold)
        static let sizeNumStrong = Font.system(size: 13, weight: .semibold)
        /// 侧栏分类名
        static let navItem = Font.system(size: 13)
        static let navItemActive = Font.system(size: 13, weight: .medium)
        static let navCount = Font.system(size: 11, weight: .medium)
        /// 区块标题（设计稿 11/12pt）
        static let sectionHead = Font.system(size: 11)
        static let sectionHeadStrong = Font.system(size: 12, weight: .semibold)
        static let cardTitle = Font.system(size: 15, weight: .semibold)
        /// 侧栏体检卡的 22pt 大号读数
        static let gauge = Font.system(size: 22, weight: .semibold)
        static let gaugeUnit = Font.system(size: 12, weight: .medium)
        /// 详情栏头部的大号体积读数（21pt）+ 单位（10pt）。
        /// 侧栏体检卡用 22pt、详情栏用 21pt：详情栏栏宽更大，同号数字显得小一号。
        static let gaugeLarge = Font.system(size: 21, weight: .semibold)
        static let gaugeLargeUnit = Font.system(size: 10, weight: .medium)
        /// 卡片/摘要正文。语义上不属于「导航项」，别拿 navItem 顶替。
        static let bodyText = Font.system(size: 13)
        /// 12pt 常规：分布图里的 Agent 名等中等长度标签
        static let body12 = Font.system(size: 12)
        /// 10pt 常规：极小辅助文字
        static let tiny = Font.system(size: 10)
        /// 弹层主标题 17pt / 大标题 20pt —— 二次确认弹层用
        static let hero = Font.system(size: 17, weight: .medium)
        static let display = Font.system(size: 20)
        /// 11.5pt 说明块正文
        static let note = Font.system(size: 11.5)
        /// 顶栏
        static let brand = Font.system(size: 13, weight: .semibold)
        /// 路径 / ID 一律等宽
        static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
            .system(size: size, weight: weight, design: .monospaced)
        }
        /// 数字列一律 tabular-nums，否则右对齐时会跳
        static func num(_ size: CGFloat, _ weight: Font.Weight = .medium) -> Font {
            .system(size: size, weight: weight).monospacedDigit()
        }
    }

    // MARK: 尺寸常量

    enum Size {
        /// 顶栏高（hiddenTitleBar 自绘，48pt 比原 44 更透气）
        static let topBar: CGFloat = 48
        /// 红绿灯让位：三个 12pt 圆点 + 两个 8pt gap + 左右各 16pt 外边距
        static let trafficLightInset: CGFloat = 78
        /// 列表行高（A 版核心：32pt）
        static let row: CGFloat = 32
        static let rowCompact: CGFloat = 28
        /// 批量条 / 顶栏
        static let bar: CGFloat = 44
        /// 勾选框
        static let checkbox: CGFloat = 14
        /// 通用按钮
        static let button: CGFloat = 26
        static let buttonIcon: CGFloat = 26
    }

    // MARK: 颜色
    //
    // 全部走 NSColor 动态色：浅色分支给设计稿色值，深色分支给等效降级。
    // 为什么不让深色模式"原样"：设计稿的白底 #FFF 在深色窗口里是块光板。

    /// 动态色构造。light 给设计稿值，dark 给降级值。
    private static func dyn(light: (Double, Double, Double),
                            dark: (Double, Double, Double)) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let c = isDark ? dark : light
            return NSColor(srgbRed: c.0 / 255, green: c.1 / 255, blue: c.2 / 255, alpha: 1)
        })
    }

    // 表面梯：深色下不用纯白，浅色下不用纯黑，四级台阶都留出来。
    static let bg        = dyn(light: (250, 250, 251), dark: (24, 24, 27))   // 窗口底
    static let surface   = dyn(light: (255, 255, 255), dark: (39, 39, 43))   // 内容面（最亮）
    static let sidebar   = dyn(light: (246, 246, 248), dark: (32, 32, 36))   // 侧栏
    static let raised    = dyn(light: (255, 255, 255), dark: (46, 46, 51))   // 浮起卡片
    static let sunken    = dyn(light: (243, 243, 246), dark: (28, 28, 31))   // 凹陷（搜索框底）

    // 发丝线
    static let line      = dyn(light: (233, 233, 237), dark: (56, 56, 62))
    static let lineStrong = dyn(light: (220, 222, 227), dark: (74, 74, 82))

    // 文字三级
    static let t1 = dyn(light: (23, 23, 26),    dark: (240, 240, 244))
    static let t2 = dyn(light: (107, 110, 118), dark: (166, 168, 176))
    static let t3 = dyn(light: (154, 157, 165), dark: (120, 122, 130))

    // 强调色（Linear #5e6ad2 系）
    static let accent    = dyn(light: (91, 91, 214),  dark: (124, 124, 240))
    static let accentHi  = dyn(light: (124, 124, 240),dark: (148, 148, 248))
    /// 选中行的淡靛蓝底
    static let accentWash = dyn(light: (244, 244, 254), dark: (45, 44, 72))
    /// 靛蓝 12% 底（体检卡、路径卡）
    static let accentSoft = Color.accentColor.opacity(0.06)
    /// 靛蓝 13% 描边
    static let accentEdge = Color.accentColor.opacity(0.14)

    // 语义色
    static let danger      = dyn(light: (229, 72, 77),   dark: (242, 85, 90))
    static let dangerSoft  = danger.opacity(0.12)
    static let success     = dyn(light: (48, 164, 108),  dark: (61, 214, 140))
    static let successSoft = success.opacity(0.10)
    static let successEdge = success.opacity(0.20)
    static let successText = dyn(light: (31, 122, 79),   dark: (110, 210, 160))

    // MARK: 分布色阶
    //
    // 修掉的硬伤：原实现是 [1.00, 0.80, 0.63, 0.49, 0.38, 0.26, 0.20, 0.14]
    // 的 `Color.primary.opacity()` 灰阶 —— 浅色下是一条黑到灰的长条，
    // 深色模式下 Color.primary 变白，整条变成白条，且 6 段相邻肉眼分不出。
    //
    // 换成同一 hue（250°）的明度阶梯：相邻段亮度差 ≥ 12%，可区分；
    // 又因为同 hue，堆叠起来是一族颜色而不是彩虹（彩虹是 slop）。
    // 深色下整体提亮 + 降低饱和，避免在深背景上糊成一片。

    static let distRamp: [Color] = [
        dyn(light: (63, 63, 191),  dark: (129, 129, 245)),
        dyn(light: (82, 82, 206),  dark: (146, 146, 242)),
        dyn(light: (106, 106, 221),dark: (162, 162, 239)),
        dyn(light: (131, 131, 228),dark: (178, 178, 236)),
        dyn(light: (155, 155, 234),dark: (193, 193, 233)),
        dyn(light: (180, 180, 239),dark: (208, 208, 230)),
        dyn(light: (205, 205, 244),dark: (222, 222, 227)),
        dyn(light: (224, 224, 248),dark: (236, 236, 240))
    ]

    static func distColor(_ index: Int) -> Color {
        distRamp[min(max(index, 0), distRamp.count - 1)]
    }
}

// MARK: - 通用修饰符

extension View {
    /// 1px 发丝线（Linear 风格：不用 Divider 的默认色，自己控制）。
    ///
    /// 🔴 本函数踩过一个很隐蔽的坑，记在这里免得再踩：
    /// **不能用 `edges.contains(.vertical)` 判断某条边属于「水平线还是垂直线」。**
    /// `Edge.Set.vertical` 是**集合**（== [.top, .bottom]）而不是单个 edge，
    /// 所以 `Edge.Set.top.contains(.vertical)` 恒为 **false**（已实测）。
    /// 写完看着挺顺、类型也对，跑起来 width/height 全是 nil，
    /// Rectangle 照样填满整个父视图 —— 顶栏 48pt、批量条 44pt 全被一条同色系的
    /// `Theme.line` 盖平，看上去只是「那里什么都没有」。
    ///
    /// 正确做法：逐个查单边 `edges.contains(.top)` / `.leading`。
    /// 另一个关键：线条用 `Color` + `.frame(height: 1)` 而不是
    /// `Rectangle().fill(color).frame(...)` —— Shape 会铺满建议尺寸，Color 不会。
    func hairline(_ edges: Edge.Set = .bottom, color: Color = Theme.line) -> some View {
        overlay {
            VStack(spacing: 0) {
                if edges.contains(.top) {
                    color.frame(height: 1)
                    Spacer(minLength: 0)
                }
                if edges.contains(.bottom) {
                    Spacer(minLength: 0)
                    color.frame(height: 1)
                }
                HStack(spacing: 0) {
                    if edges.contains(.leading) { color.frame(width: 1) }
                    if edges.contains(.trailing) { Spacer(minLength: 0); color.frame(width: 1) }
                }
            }
            .allowsHitTesting(false)
        }
    }

    /// 卡片面：白底 + 发丝边，A 版的克制做法（不用阴影）
    func cardSurface(_ radius: CGFloat = Theme.Radius.card) -> some View {
        background(
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(Theme.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(Theme.line, lineWidth: 1)
        )
    }

    /// 靛蓝淡底 + 靛蓝淡边（体检卡 / 路径卡 / 说明块）
    func tintedSurface(_ radius: CGFloat = Theme.Radius.card) -> some View {
        background(
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(Theme.accentSoft)
        )
        .overlay(
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(Theme.accentEdge, lineWidth: 1)
        )
    }
}
