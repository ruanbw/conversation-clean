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
    /// 侧栏 / 检视器洗底：原型 `color-mix(in oklch, var(--bg) 42%, var(--surface))` ≈ #FBFDFE
    static let panel   = Color(hex: 0xFBFDFE)
    /// 标题栏洗底：同一公式但 bg 占 55%（原型 `.titlebar`），比侧栏略深一档。
    /// 之前两者共用一个 token，标题栏因此偏浅 —— 截图上一眼能看出顶部那条带子发白。
    static let panelStrong = Color(hex: 0xFAFCFD)
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
    /// 原型 `.scrim{background:color-mix(in oklch, var(--fg) 34%, transparent)}`。
    /// 之前写的是纯黑 28%，叠在界面上偏中性灰，与原型那种「冷调压深」差一档。
    static let scrim      = Color(hex: 0x121C23).opacity(0.34)

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
    }
}
