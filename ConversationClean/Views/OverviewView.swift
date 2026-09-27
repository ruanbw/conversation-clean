import SwiftUI

// MARK: - OverviewView（详情栏未选中态）
//
// 这一栏的语义是「现在该从谁开始删」。所以它不是一张统计报表，而是一份
// 按占用降序的待办清单：Top 5 大户，点一行直接选中它。
//
// 总量不放这里 —— 它是常量信息，在顶栏常驻（见 ContentView.topBar）。
// 把两个数字摊在整栏里既占地方又给不出下一步动作。
//
// 视觉基线 design-demos/ui-a-precision.html 的右栏（`.det` / `.det-scroll`）。
// 那一版修掉的正是本文件原来最丑的两处：
//
//   ① 分布配色。旧实现是 `ramp: [Double] = [1.00, 0.80, 0.63, 0.49, 0.38, …]`
//      配 `Color.primary.opacity(_:)`：浅色下是一条黑到灰的长条；**深色模式下
//      `Color.primary` 是白，整条变成白条**；6 段相邻灰阶肉眼分不出。
//      现在全部改走 `Theme.distColor(_:)`（同一 hue 250° 的明度阶梯，深浅色各有
//      降级值），堆叠条和横条列表用的是同一支色阶。
//   ② 层级倒置。旧实现标题 `.body.weight(.medium)`(13pt) 比体积
//      `.callout.weight(.semibold)`(12pt) 更重 —— 在一个「清理 99MB 垃圾」的
//      工具里这是反的。现在体积 13pt semibold（`Typo.sizeNumStrong`）压过
//      标题 12.5pt medium（`Typo.rowTitle`）。
//
// 硬约束：全部自绘。`Divider()` 的系统色、`ContentUnavailableView` 的系统插画、
// 按钮的系统外观，一个都不留。

struct OverviewView: View {
    @EnvironmentObject var viewModel: CleanViewModel

    private let topN = 5

    /// 堆叠总览条里段与段之间的发丝 gap（设计稿 `.stack{gap:2px}`）。
    /// 留 gap 是为了让两段同色阶相邻时仍能读出边界 —— 6 段挤在一起会糊成一条。
    private let stackGap: CGFloat = Theme.Space.xxs

    var body: some View {
        Group {
            if viewModel.hasScanned {
                scrolled
            } else {
                neverScanned
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.bg)
    }

    private var scrolled: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                // 设计稿 `.ph`：标题 15pt semibold + 右侧 11pt 计数。
                // 中栏/侧栏两处的区块标题都发过一次散，这栏是整页第一个视线落点，
                // 给足一级。
                HStack(alignment: .firstTextBaseline, spacing: Theme.Space.m) {
                    Text("占用大户")
                        .font(Theme.Typo.cardTitle)
                        .foregroundStyle(Theme.t1)
                    Spacer(minLength: Theme.Space.m)
                    Text("共 \(viewModel.conversations.count) 个会话")
                        .font(Theme.Typo.sectionHead)
                        .foregroundStyle(Theme.t3)
                }
                .padding(.bottom, Theme.Space.ll)

                biggestCard
                    .padding(.bottom, Theme.Space.xxl)

                distributionSection
            }
            // `.det-scroll{padding:20px 24px}`
            .padding(.horizontal, Theme.Space.huge)
            .padding(.vertical, Theme.Space.xxl)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - 占用大户

    /// 全库按体积降序取前 N。它是「先删谁」的答案，比任何图都直接。
    private var biggest: [ConversationItem] {
        Array(viewModel.conversations
            .sorted { $0.sizeInBytes > $1.sizeInBytes }
            .prefix(topN))
    }

    private var biggestCard: some View {
        VStack(spacing: 0) {
            if biggest.isEmpty {
                emptyBiggest
            } else {
                ForEach(biggest) { item in
                    BiggestRow(item: item,
                               total: viewModel.totalSize,
                               isLast: item.id == biggest.last?.id) {
                        viewModel.selectedConversationID = item.id
                    }
                }
            }
        }
        // 先裁内容再铺卡片面：hover 底色不会从 8pt 圆角里漏出来，
        // 而发丝描边（strokeBorder 画在外圈）不受裁切影响。
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .cardSurface()
    }

    private var emptyBiggest: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xxs) {
            Text("没有扫描到任何会话")
                .font(Theme.Typo.rowTitle)
                .foregroundStyle(Theme.t2)
            Text("本机这 15 款 Agent 都没有可读的会话记录，或记录已被清理干净。")
                .font(Theme.Typo.rowSub)
                .foregroundStyle(Theme.t3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Theme.Space.ll)
        .padding(.vertical, Theme.Space.xl)
    }

    // MARK: - 存储分布

    /// 占用 > 0 的分类降序取前 5，其余合并成「其他 N 款」。
    ///
    /// 颜色索引直接吃 `Theme.distColor(_:)`：这是同 hue 的 8 级明度阶梯，
    /// 深色模式里 Theme 给的是提亮降饱和版，所以浅色深色都不会出现反色条。
    private var distSegments: [Segment] {
        let ranked = allAgents
            .compactMap { cat -> (ConversationCategory, Int64)? in
                let bytes = viewModel.categoryStats[cat]?.sizeInBytes ?? 0
                return bytes > 0 ? (cat, bytes) : nil
            }
            .sorted { $0.1 > $1.1 }

        // 分母用全库总量（`updateCachedStats` 保证它等于各分类之和），
        // 于是百分比、堆叠条、横条三者天然对得上。
        let total = Double(max(viewModel.totalSize, 0))

        var out = ranked.prefix(topN).enumerated().map { index, item in
            Segment(id: item.0.rawValue,
                    name: item.0.rawValue,
                    bytes: item.1,
                    color: Theme.distColor(index),
                    share: total > 0 ? Double(item.1) / total : 0)
        }
        if ranked.count > topN {
            let rest = ranked.dropFirst(topN).reduce(Int64(0)) { $0 + $1.1 }
            // 「其他」落在阶梯的下一级（与前 5 段必然不同色），
            // 段数超过色阶长度时 Theme.distColor 自己夹到末级。
            out.append(Segment(id: "other",
                               name: "其他 \(ranked.count - topN) 款",
                               bytes: rest,
                               color: Theme.distColor(out.count),
                               share: total > 0 ? Double(rest) / total : 0))
        }
        return out
    }

    private var allAgents: [ConversationCategory] {
        ConversationCategory.allCases.filter { $0 != .all }
    }

    private var distributionSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("按 Agent 分布")
                .font(Theme.Typo.sectionHeadStrong)
                .foregroundStyle(Theme.t1)
                .padding(.bottom, Theme.Space.ms)

            if distSegments.isEmpty || viewModel.totalSize <= 0 {
                emptyDistribution
            } else {
                stackBar
                    .padding(.bottom, Theme.Space.ll)

                VStack(spacing: 0) {
                    ForEach(distSegments) { seg in
                        DistRow(segment: seg, total: viewModel.totalSize)
                    }
                }
            }

            policyNote
                .padding(.top, Theme.Space.xxl)
        }
    }

    /// 全库 0 字节时：没有一根条值得画，硬画一条空轨反而像坏了。
    private var emptyDistribution: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xxs) {
            Text("没有可统计的占用")
                .font(Theme.Typo.rowTitle)
                .foregroundStyle(Theme.t2)
            Text("扫到的会话都是 0 KB，或本机一个会话都没有。")
                .font(Theme.Typo.rowSub)
                .foregroundStyle(Theme.t3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Theme.Space.ll)
        .padding(.vertical, Theme.Space.l)
        .cardSurface()
    }

    // MARK: - 堆叠总览条
    //
    // 8pt 高胶囊 + 2px 底色 gap。一眼看到「谁占了半条」，
    // 这是原实现那条 10pt 灰长条唯一没做到的事（它有长度没颜色秩序）。

    private var stackBar: some View {
        GeometryReader { geo in
            let count = distSegments.count
            let gap: CGFloat = count > 1 ? stackGap : 0
            // gap 先从可用宽度里扣掉，剩下的才是段的总长 —— 否则最后一段会顶出胶囊。
            let usable = max(0, geo.size.width - gap * CGFloat(count - 1))
            let widths = stackWidths(count: count, usable: usable)

            ZStack(alignment: .leading) {
                Capsule().fill(Theme.sunken)
                HStack(spacing: gap) {
                    ForEach(distSegments.indices, id: \.self) { i in
                        Rectangle()
                            .fill(distSegments[i].color)
                            .frame(width: widths[i])
                    }
                }
            }
        }
        .frame(height: 8)
        .clipShape(Capsule())
        .accessibilityHidden(true)
    }

    /// 段宽严格按占比分配。
    ///
    /// 唯一一处不诚实的地方是 1pt 的**可见性下限**：0.4% 的 Agent 在 600pt 宽的
    /// 条上是 0.24pt，不画就等于它不存在（横条列表里还会被误读成「没扫到」）。
    /// 下限造成的多余像素从最宽的那段扣回来，保证总和恰好等于 usable ——
    /// 不然圆角裁切处会露出一截底色，看起来像条画歪了。
    private func stackWidths(count: Int, usable: CGFloat) -> [CGFloat] {
        guard count > 0 else { return [] }
        // GeometryReader 的首帧宽度可能是 0。这里必须返回 count 个 0 而不是空数组 ——
        // 调用方按 `distSegments.indices` 下标取宽度，长度对不上就是运行时越界。
        guard usable > 0 else { return Array(repeating: 0, count: count) }
        let minDot = min(1, usable / CGFloat(count * 4))
        var widths = distSegments.map { max(minDot, usable * CGFloat($0.share)) }
        let sum = widths.reduce(0, +)
        if sum > usable, let widest = widths.indices.max(by: { widths[$0] < widths[$1] }) {
            widths[widest] = max(0, widths[widest] - (sum - usable))
        }
        return widths
    }

    // MARK: - 说明块

    /// 空目录策略跟着设置开关走，所以文案只能现取（见 ViewModel.emptyFolderPolicyText）。
    private var policyNote: some View {
        HStack(alignment: .top, spacing: Theme.Space.m) {
            Image(systemName: "info.circle")
                .font(Theme.Typo.body12)
                .foregroundStyle(Theme.accent)
                .frame(width: 14)

            (Text("清理说明").foregroundStyle(Theme.t1)
             + Text("：" + viewModel.emptyFolderPolicyText))
                .font(Theme.Typo.sectionHead)
                .foregroundStyle(Theme.t2)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.Space.ll)
        .padding(.vertical, Theme.Space.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .tintedSurface()
    }

    // MARK: - 未扫描

    private var neverScanned: some View {
        DrawnEmptyState(
            symbol: "magnifyingglass",
            title: "还没有扫描过会话",
            message: "已关闭「启动时自动扫描」，或本机尚未完成首次扫描。点下方按钮手动扫描本机各 Agent 的会话缓存。",
            actionTitle: "一键扫描"
        ) { Task { await viewModel.scanConversations() } }
    }
}

// MARK: - 大户行
//
// 设计稿 `.brow`：44pt 行高，标题 12.5 medium / 副标题 10.5 t3 /
// 76pt 占比条 / 34pt 百分比（t3）/ 58pt 体积（13 semibold）。
//
// 注意体积那一格是全行最重的元素 —— 这是 A 版的层级修正，
// 原实现标题 13pt medium 压过体积 12pt semibold，在清理工具里是反的。

private struct BiggestRow: View {
    let item: ConversationItem
    let total: Int64
    let isLast: Bool
    let action: () -> Void

    @State private var hovering = false

    private var share: Double {
        total > 0 ? Double(item.sizeInBytes) / Double(total) * 100 : 0
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Space.l) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.title)
                        .font(Theme.Typo.rowTitle)
                        .foregroundStyle(Theme.t1)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text("\(item.category.rawValue) · \(Fmt.relative(item.updatedAt))")
                        .font(Theme.Typo.rowSub)
                        .foregroundStyle(Theme.t3)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                // 占比条：靛蓝渐变填充（ShareBar）。旧实现是
                // `Color.primary.opacity(0.55)` 的黑灰条，看着像禁用态。
                ShareBar(percent: share, width: 76, height: 4)

                Text(shareText)
                    .font(Theme.Typo.num(11, .medium))
                    .foregroundStyle(Theme.t3)
                    .frame(width: 34, alignment: .trailing)

                // 体积 = 第一视觉层级，比标题更重
                Text(Fmt.bytes(item.sizeInBytes))
                    .font(Theme.Typo.sizeNumStrong)
                    .foregroundStyle(item.sizeInBytes > 0 ? Theme.t1 : Theme.t3)
                    .frame(width: 58, alignment: .trailing)
                    .lineLimit(1)
            }
            .padding(.horizontal, Theme.Space.ll)
            .frame(height: 44)
            .background(hovering ? Theme.sunken : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .bottom) {
            if !isLast { Rectangle().fill(Theme.line).frame(height: Theme.Space.hair) }
        }
        .onHover { hovering = $0 }
        // 0 KB 的会话删了不省空间，压暗一档让它自动退出视线
        .opacity(item.sizeInBytes > 0 ? 1 : 0.55)
        .help("查看「\(item.title)」")
        .accessibilityLabel(item.title)
        .accessibilityValue("\(Fmt.bytes(item.sizeInBytes))，占全库 \(shareText)")
        .accessibilityHint("打开该会话详情")
    }

    /// 0.4% 以下四舍五入成 0% 会读成「占 0 字节」，与右侧数字自相矛盾。
    private var shareText: String {
        share > 0 && share < 0.5 ? "<1%" : "\(Int(share.rounded()))%"
    }
}

// MARK: - 分布行
//
// 设计稿 `.distrow`：8pt 色块 + 112pt 名字 + 占满剩余的横条 + 34pt 百分比 +
// 54pt 体积。旧实现这排只有「色块 + 名字 + 两个数字」，看不出量的对比 ——
// 用户点名的第三个硬伤「数据可视化难看」主要就出在这。

private struct DistRow: View {
    let segment: Segment
    let total: Int64

    var body: some View {
        HStack(spacing: Theme.Space.ms) {
            // 8pt 色块。用 Radius.chipSmall(2) —— 设计稿 `.sw{border-radius:2px}` 的原值。
            // 它是方块不是圆点，圆形会被读成「状态指示器」而不是「这一段的颜色」。
            RoundedRectangle(cornerRadius: Theme.Radius.chipSmall, style: .continuous)
                .fill(segment.color)
                .frame(width: 8, height: 8)

            Text(segment.name)
                .font(Theme.Typo.navItem)
                .foregroundStyle(Theme.t2)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: 112, alignment: .leading)

            bar
                .frame(maxWidth: .infinity)

            Text(percentText)
                .font(Theme.Typo.num(11, .medium))
                .foregroundStyle(Theme.t2)
                .frame(width: 34, alignment: .trailing)

            Text(Fmt.bytes(segment.bytes))
                .font(Theme.Typo.num(11, .medium))
                .foregroundStyle(Theme.t3)
                .frame(width: 54, alignment: .trailing)
                .lineLimit(1)
        }
        .padding(.vertical, 5)
    }

    private var bar: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.sunken)
                Capsule()
                    .fill(segment.color)
                    .frame(width: max(1.5, geo.size.width * CGFloat(segment.share)))
            }
        }
        .frame(height: 5)
        .accessibilityHidden(true)
    }

    private var percentText: String {
        guard total > 0 else { return "0%" }
        let pct = Double(segment.bytes) / Double(total) * 100
        if pct > 0, pct < 0.5 { return "<1%" }
        return "\(Int(pct.rounded()))%"
    }
}

// MARK: - 分布段

private struct Segment: Identifiable {
    let id: String
    let name: String
    let bytes: Int64
    /// 取自 `Theme.distColor(_:)` —— 靛蓝明度阶梯，深浅色各自降级
    let color: Color
    /// 0...1，占全库总量的比例（堆叠条与横条共用同一个分母）
    let share: Double
}
