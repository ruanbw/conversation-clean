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

/// 没有 `.app` bundle 可查、但有官方品牌标记的 Agent。
///
/// 纯 CLI 装不出图标，而拿一个不相干的 SF Symbol 顶替是错的：侧栏一列下来，
/// 「Pi Agent」顶着个 `terminal` 符号，用户根本认不出那是哪个工具 —— 而
/// 「认得出」正是这一版把自绘彩色徽章换成真实 app 图标的目的。
enum AgentBrandMark {
    case pi

    static func mark(for category: ConversationCategory) -> AgentBrandMark? {
        switch category {
        case .piAgent: return .pi
        default:       return nil
        }
    }
}

/// Pi 官方品牌标记（<https://pi.dev/logo-auto.svg>）。
///
/// 官方 SVG 是 334 字节、三块纯色直角多边形，没有渐变也没有文字，深浅色模式通用。
/// 这里用 `Path` 复刻而**不**塞一张位图进 asset catalog：
///   · 矢量在 18pt（侧栏）和 64pt（详情栏头部）都实心，位图要么糊要么白占地方；
///   · 不必改 `project.pbxproj`、不必往包里塞 1×/2× 两套图。
/// 顶点直接照抄 SVG 的 `H`/`V` 指令（单位是 800×800 的 viewBox），改版时对着源文件核。
private struct PiMark: View {
    /// 官方 SVG 的三块 `fill`。
    private static let topStroke = Color(red: 240 / 255, green: 144 / 255, blue: 130 / 255)
    private static let midStroke = Color(red: 77 / 255, green: 154 / 255, blue: 191 / 255)
    private static let block     = Color(red: 241 / 255, green: 190 / 255, blue: 88 / 255)

    private static func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y) }

    private static let polys: [[CGPoint]] = [
        // M165.29 165.29 H517.36 V400 H400 V282.65 H165.29 Z
        [p(165.29, 165.29), p(517.36, 165.29), p(517.36, 400), p(400, 400), p(400, 282.65), p(165.29, 282.65)],
        // M165.29 282.65 H282.65 V400 H400 V517.36 H282.65 V634.72 H165.29 Z
        [p(165.29, 282.65), p(282.65, 282.65), p(282.65, 400), p(400, 400),
         p(400, 517.36), p(282.65, 517.36), p(282.65, 634.72), p(165.29, 634.72)],
        // M517.36 400 H634.72 V634.72 H517.36 Z
        [p(517.36, 400), p(634.72, 400), p(634.72, 634.72), p(517.36, 634.72)]
    ]
    private static let fills = [topStroke, midStroke, block]

    /// 图形自身包围盒（照 SVG 坐标）。
    private static let minX: CGFloat = 165.29
    private static let minY: CGFloat = 165.29
    private static let side: CGFloat = 634.72 - 165.29

    /// 官方 SVG 自带约 21% 留白，直接铺满框会比旁边那些真实 app 图标明显小一圈。
    /// 归一化到 88%，让 15 款图标在同一列里的视觉重量一致。
    private static let fill: CGFloat = 0.88

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height) * Self.fill
            let k = side / Self.side
            let ox = (geo.size.width - side) / 2 - Self.minX * k
            let oy = (geo.size.height - side) / 2 - Self.minY * k

            ZStack {
                ForEach(Array(Self.polys.enumerated()), id: \.offset) { index, poly in
                    Path { p in
                        for (i, v) in poly.enumerated() {
                            let pt = CGPoint(x: ox + v.x * k, y: oy + v.y * k)
                            if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
                        }
                        p.closeSubpath()
                    }
                    .fill(Self.fills[index])
                }
            }
        }
        .accessibilityHidden(true)
    }
}

/// 左侧 Agent 图标：真实 app 图标优先，其次官方品牌标记，最后 SF Symbol。
///
/// 图标一律用 `.system(size:)` 按调用方给的框算，**不换语义字体**：
/// SF Symbol 的字形是按 point size 等比缩放的，套 `.body`/`.caption` 只会让
/// 图标随系统字号漂移，而它旁边往往是固定尺寸的容器（22pt 行高、48pt 关于页图标）。
/// 视图层里剩下的 8 处硬编码字号全部是这一类，不是漏改。
struct AgentIconView: View {
    let category: ConversationCategory
    var size: CGFloat = 20

    var body: some View {
        Group {
            if let image = AgentIcon.image(for: category) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else if AgentBrandMark.mark(for: category) != nil {
                PiMark()
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
