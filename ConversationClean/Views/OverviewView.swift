import SwiftUI

// MARK: - OverviewView
//
// 详情栏的「未选中」态：总占用、总会话数、存储分布。
// 这些原本挤在 272pt 的侧栏里（堆叠条 + 4 行图例 + 折行路径框），
// 搬进详情栏后终于有地方放了。
//
// 从未扫描过时整体降级为「去扫描」的空态，而不是显示一屏 0。

/// 存储分布的灰阶序列（前景色的不透明度）。
/// 段数多于 6 时继续往下取 20% / 14%。
private let distRamp: [Double] = [1.00, 0.80, 0.63, 0.49, 0.38, 0.26, 0.20, 0.14]

struct OverviewView: View {
    @EnvironmentObject var viewModel: CleanViewModel

    var body: some View {
        Group {
            if viewModel.hasScanned {
                scrolled
            } else {
                neverScanned
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var scrolled: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                figures
                Divider()
                distribution
                Text(viewModel.emptyFolderPolicyText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - 两个大数字

    private var figures: some View {
        HStack(alignment: .top, spacing: 32) {
            figure(Fmt.bytes(viewModel.totalSize), "总缓存占用")
            figure("\(viewModel.conversations.count)", "总会话数")
            Spacer(minLength: 0)
        }
    }

    private func figure(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.system(size: 22, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: - 存储分布

    /// 占用 > 0 的分类降序取前 5，其余合并成「其他 N 款」。
    private var distSegments: [Segment] {
        let ranked = sidebarOrder
            .compactMap { cat -> (ConversationCategory, Int64)? in
                let bytes = viewModel.categoryStats[cat]?.sizeInBytes ?? 0
                return bytes > 0 ? (cat, bytes) : nil
            }
            .sorted { $0.1 > $1.1 }

        var out = ranked.prefix(5).enumerated().map { index, item in
            Segment(
                id: item.0.rawValue,
                name: item.0.rawValue,
                bytes: item.1,
                opacity: distRamp[min(index, distRamp.count - 1)]
            )
        }
        if ranked.count > 5 {
            let rest = ranked.dropFirst(5).reduce(Int64(0)) { $0 + $1.1 }
            out.append(
                Segment(
                    id: "other",
                    name: "其他 \(ranked.count - 5) 款",
                    bytes: rest,
                    opacity: distRamp[min(out.count, distRamp.count - 1)]
                )
            )
        }
        return Array(out)
    }

    private var sidebarOrder: [ConversationCategory] {
        ConversationCategory.allCases.filter { $0 != .all }
    }

    @ViewBuilder
    private var distribution: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("存储分布")
                    .font(.headline)
                Spacer()
                Text(viewModel.totalSize > 0 ? Fmt.bytes(viewModel.totalSize) : "—")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            if viewModel.totalSize > 0, !distSegments.isEmpty {
                bar
                VStack(spacing: 0) {
                    ForEach(distSegments) { seg in
                        legendRow(seg)
                            .padding(.vertical, 3)
                    }
                }
            } else {
                Text("暂无可统计的会话。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var total: Int64 { viewModel.totalSize }

    private var bar: some View {
        GeometryReader { geo in
            HStack(spacing: 0) {
                ForEach(distSegments) { seg in
                    let share = Double(seg.bytes) / Double(total)
                    // 不足 1px 的段不画：原型里有 min-width:2px 下限，
                    // 一段占比 0.0004 时铺 2px 会把整条堆叠条盖满，看起来像「占一半」
                    if share * geo.size.width >= 1 {
                        Rectangle()
                            .fill(Color.primary.opacity(seg.opacity))
                            .frame(width: share * geo.size.width)
                    }
                }
            }
        }
        .frame(height: 10)
        .clipShape(Capsule())
        .accessibilityHidden(true)
    }

    private func legendRow(_ seg: Segment) -> some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(Color.primary.opacity(seg.opacity))
                .frame(width: 8, height: 8)

            Text(seg.name)
                .font(.callout)
                .lineLimit(1)

            Spacer(minLength: 8)

            Text(percent(seg))
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 38, alignment: .trailing)

            Text(Fmt.bytes(seg.bytes))
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 62, alignment: .trailing)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }

    private func percent(_ seg: Segment) -> String {
        guard total > 0 else { return "0%" }
        let pct = Double(seg.bytes) / Double(total) * 100
        // 0.4% 四舍五入成 0% 会读成「这个 Agent 占 0 字节」，与右侧的 3.4 KB 自相矛盾
        if pct > 0, pct < 0.5 { return "<1%" }
        return "\(Int(pct.rounded()))%"
    }

    // MARK: - 未扫描

    private var neverScanned: some View {
        ContentUnavailableView {
            Label("还没有扫描过会话", systemImage: "magnifyingglass")
        } description: {
            Text("已关闭「启动时自动扫描」，或本机尚未完成首次扫描。点下方按钮手动扫描本机各 Agent 的会话缓存。")
        } actions: {
            Button("扫描") {
                Task { await viewModel.scanConversations() }
            }
            .buttonStyle(.borderedProminent)
        }
    }
}

private struct Segment: Identifiable {
    let id: String
    let name: String
    let bytes: Int64
    let opacity: Double
}
