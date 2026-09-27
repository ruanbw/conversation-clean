import SwiftUI

// MARK: - OverviewView（详情栏未选中态）
//
// 这一栏的语义是「现在该从谁开始删」。所以它不是一张统计报表，而是一份
// 按占用降序的待办清单：Top 5 大户，点一行直接选中它。
//
// 总量不放这里 —— 它是常量信息，在顶栏常驻（见 ContentView.topBar）。
// 把两个数字摊在整栏里既占地方又给不出下一步动作。

struct OverviewView: View {
    @EnvironmentObject var viewModel: CleanViewModel

    private let topN = 5

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
            VStack(alignment: .leading, spacing: 22) {
                biggestSection
                Divider()
                distributionSection
            }
            .padding(20)
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

    @ViewBuilder
    private var biggestSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("占用大户")
                    .font(.headline)
                Spacer()
                Text("共 \(viewModel.conversations.count) 个会话")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if biggest.isEmpty {
                Text("暂无可统计的会话。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 0) {
                    ForEach(biggest) { item in
                        Button {
                            viewModel.selectedConversationID = item.id
                        } label: {
                            BiggestRow(item: item, total: viewModel.totalSize)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    // MARK: - 存储分布

    /// 占用 > 0 的分类降序取前 5，其余合并成「其他 N 款」。
    private var distSegments: [Segment] {
        let ranked = allAgents
            .compactMap { cat -> (ConversationCategory, Int64)? in
                let bytes = viewModel.categoryStats[cat]?.sizeInBytes ?? 0
                return bytes > 0 ? (cat, bytes) : nil
            }
            .sorted { $0.1 > $1.1 }

        var out = ranked.prefix(5).enumerated().map { index, item in
            Segment(id: item.0.rawValue, name: item.0.rawValue,
                    bytes: item.1, opacity: ramp[min(index, ramp.count - 1)])
        }
        if ranked.count > 5 {
            let rest = ranked.dropFirst(5).reduce(Int64(0)) { $0 + $1.1 }
            out.append(Segment(id: "other", name: "其他 \(ranked.count - 5) 款",
                               bytes: rest, opacity: ramp[min(out.count, ramp.count - 1)]))
        }
        return Array(out)
    }

    private var allAgents: [ConversationCategory] {
        ConversationCategory.allCases.filter { $0 != .all }
    }

    private var total: Int64 { viewModel.totalSize }

    private var distributionSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("按 Agent 分布").font(.headline)

            if total > 0, !distSegments.isEmpty {
                bar
                VStack(spacing: 0) {
                    ForEach(distSegments) { seg in
                        HStack(spacing: 8) {
                            RoundedRectangle(cornerRadius: 2, style: .continuous)
                                .fill(Color.primary.opacity(seg.opacity))
                                .frame(width: 8, height: 8)
                            Text(seg.name).font(.callout).lineLimit(1)
                            Spacer(minLength: 8)
                            Text(percent(seg))
                                .font(.system(size: 10.5, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .frame(width: 38, alignment: .trailing)
                            Text(Fmt.bytes(seg.bytes))
                                .font(.system(size: 10.5, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .frame(width: 62, alignment: .trailing)
                        }
                        .padding(.vertical, 3)
                    }
                }
            } else {
                Text("暂无可统计的会话。").font(.callout).foregroundStyle(.secondary)
            }

            Text(viewModel.emptyFolderPolicyText)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .padding(.top, 4)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var bar: some View {
        GeometryReader { geo in
            HStack(spacing: 0) {
                ForEach(distSegments) { seg in
                    let share = Double(seg.bytes) / Double(total)
                    // 不足 1px 的段不画：给它一个最小宽度会把整条盖满
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

    private func percent(_ seg: Segment) -> String {
        guard total > 0 else { return "0%" }
        let pct = Double(seg.bytes) / Double(total) * 100
        // 0.4% 四舍五入成 0% 会读成「占 0 字节」，与右侧数字自相矛盾
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
            Button { Task { await viewModel.scanConversations() } } label: {
                Label("扫描", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.borderedProminent)
        }
    }
}

// MARK: - 大户行

private struct BiggestRow: View {
    let item: ConversationItem
    let total: Int64

    private var share: Double {
        total > 0 ? Double(item.sizeInBytes) / Double(total) * 100 : 0
    }

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                Text("\(item.category.rawValue) · \(Fmt.relative(item.updatedAt))")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // 占比条：一眼看出这块占全库多少
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.15))
                    Capsule().fill(Color.primary.opacity(0.55))
                        .frame(width: max(2, geo.size.width * share / 100))
                }
            }
            .frame(width: 72, height: 5)

            Text(shareText)
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 38, alignment: .trailing)

            Text(Fmt.bytes(item.sizeInBytes))
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .frame(width: 64, alignment: .trailing)
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(.quaternary))
        .contentShape(Rectangle())
    }

    private var shareText: String {
        share > 0 && share < 0.5 ? "<1%" : "\(Int(share.rounded()))%"
    }
}

private struct Segment: Identifiable {
    let id: String
    let name: String
    let bytes: Int64
    let opacity: Double
}

/// 存储分布的灰阶序列。段数多于 6 时继续往下取 20% / 14%。
private let ramp: [Double] = [1.00, 0.80, 0.63, 0.49, 0.38, 0.26, 0.20, 0.14]
