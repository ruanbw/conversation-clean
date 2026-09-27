import SwiftUI
import Combine

// MARK: - 排序方式
//
// `filteredConversations` 本身无序，排序完全在列表模块本地完成，不污染数据层。
private enum ListSortMode: String, CaseIterable, Hashable, Identifiable {
    case date, size, msgs

    var id: String { rawValue }

    var label: String {
        switch self {
        case .date: return "最近更新"
        case .size: return "占用空间"
        case .msgs: return "对话轮数"
        }
    }
}

// MARK: - 会话列表
//
// 选中由 `List(selection:)` 直接驱动 `viewModel.selectedConversationID`，
// 详情栏据此切换。批量勾选走 `ConversationItem.isSelected`，与列表选中是两件
// 独立的事：前者管「待清理的一批」，后者管「右侧正在看的那一条」。

struct ConversationListView: View {
    @EnvironmentObject var viewModel: CleanViewModel

    /// 排序方式，持久化。非法值（UserDefaults 里是旧版本留下的）回落默认。
    @AppStorage("listSortMode") private var sortRaw: String = ListSortMode.date.rawValue

    private var sort: ListSortMode { ListSortMode(rawValue: sortRaw) ?? .date }

    private var isBusy: Bool { viewModel.isScanning || viewModel.isCleaning }
    private var rows: [ConversationItem] { sorted }
    private var allSelected: Bool { !rows.isEmpty && rows.allSatisfy { $0.isSelected } }

    var body: some View {
        VStack(spacing: 0) {
            banner
            if rows.isEmpty {
                emptyState
            } else {
                list
            }
            batchBar
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .searchable(text: $viewModel.searchText, placement: .toolbar,
                    prompt: "搜索标题、摘要、项目路径或会话 ID")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Picker("排序", selection: sortBinding) {
                    ForEach(ListSortMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .help("排序方式")
            }
        }
    }

    private var sortBinding: Binding<ListSortMode> {
        Binding(get: { sort }, set: { sortRaw = $0.rawValue })
    }

    // MARK: - 列表

    private var list: some View {
        List(selection: $viewModel.selectedConversationID) {
            ForEach(rows) { item in
                ConversationRow(item: item, isBusy: isBusy)
                    .tag(item.id)
                    .contextMenu { rowMenu(item) }
            }
        }
        .listStyle(.inset(alternatesRowBackgrounds: true))
    }

    private var sorted: [ConversationItem] {
        switch sort {
        case .date: return viewModel.filteredConversations.sorted { $0.updatedAt > $1.updatedAt }
        case .size: return viewModel.filteredConversations.sorted { $0.sizeInBytes > $1.sizeInBytes }
        case .msgs: return viewModel.filteredConversations.sorted { $0.messageCount > $1.messageCount }
        }
    }

    @ViewBuilder
    private func rowMenu(_ item: ConversationItem) -> some View {
        Button("在 Finder 中显示", systemImage: "folder") {
            viewModel.revealInFinder(item: item)
        }
        Button("复制项目路径", systemImage: "doc.on.doc") {
            viewModel.copyToClipboard(text: item.displayProjectPath)
        }
        Button("复制会话 ID", systemImage: "number") {
            viewModel.copyToClipboard(text: item.sessionId)
        }
        Divider()
        Button("删除此会话", systemImage: "trash", role: .destructive) {
            Task { await viewModel.deleteSingle(item: item) }
        }
    }

    // MARK: - 成功横幅

    @ViewBuilder
    private var banner: some View {
        if viewModel.showCleanSuccessAlert {
            notice(
                icon: "checkmark.circle.fill",
                text: "清理完成 · 删除 \(viewModel.lastCleanedCount) 个会话，释放 "
                    + Fmt.bytes(viewModel.lastCleanedBytes)
                    + " 磁盘空间，剩余 \(viewModel.conversations.count) 个会话。"
            ) { viewModel.showCleanSuccessAlert = false }
        } else if viewModel.showScanSuccessAlert {
            notice(
                icon: "checkmark.circle.fill",
                text: "扫描完成 · 命中 \(viewModel.scanSuccessCount) 个会话，合计 "
                    + Fmt.bytes(viewModel.scanSuccessBytes) + "。"
            ) { viewModel.showScanSuccessAlert = false }
        }
    }

    private func notice(
        icon: String,
        text: String,
        dismiss: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).foregroundStyle(.green)
            Text(text).font(.callout)
            Spacer(minLength: 8)
            Button("知道了", action: dismiss).controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color.green.opacity(0.12))
    }

    // MARK: - 空态

    @ViewBuilder
    private var emptyState: some View {
        if viewModel.isScanning {
            ContentUnavailableView(
                "正在扫描本机会话…",
                systemImage: "arrow.triangle.2.circlepath",
                description: Text("正在查找本机各 Agent 的会话缓存，请稍候。")
            )
        } else if !viewModel.hasScanned {
            // 「启动时自动扫描」关掉时的落点：列表从未被填充过，
            // 文案要告诉用户是还没扫，而不是扫完空空如也。
            ContentUnavailableView {
                Label("还没有扫描过会话", systemImage: "magnifyingglass")
            } description: {
                Text("已关闭「启动时自动扫描」。点下方按钮手动扫描本机各 Agent 的会话缓存。")
            } actions: {
                rescanButton
            }
        } else if hasQuery {
            ContentUnavailableView.search(text: viewModel.searchText.trimmed)
        } else {
            ContentUnavailableView(
                "暂无 \(viewModel.selectedCategory.rawValue) 会话记录",
                systemImage: viewModel.selectedCategory.iconName,
                description: Text("未在本地检测到该 Agent 的历史会话文件，或所有会话均已被清理。")
            )
        }
    }

    private var hasQuery: Bool {
        !viewModel.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var rescanButton: some View {
        Button {
            Task { await viewModel.scanConversations() }
        } label: {
            Label("重新扫描", systemImage: "arrow.clockwise")
        }
        .buttonStyle(.borderedProminent)
    }

    // MARK: - 批量条（常驻，0 选中时只是禁用灰态）

    private var batchBar: some View {
        let disabled = viewModel.selectedItems.isEmpty || isBusy
        return HStack(spacing: 10) {
            (Text("已选中 ")
                + Text("\(viewModel.selectedItems.count)").bold()
                + Text(" 项 · ")
                + Text(Fmt.bytes(viewModel.selectedSize)).bold())
                .font(.callout)
                .foregroundStyle(.secondary)

            Button(allSelected ? "取消全选" : "全选当前") {
                viewModel.selectAll(!allSelected)
            }
            .controlSize(.small)
            .disabled(rows.isEmpty)

            Spacer(minLength: 8)

            Button {
                viewModel.selectAll(false)
            } label: {
                Label("取消选择", systemImage: "xmark")
            }
            .controlSize(.small)
            .disabled(disabled)

            Button {
                // NSWorkspace 一次只能定位一个文件，逐个调用由系统堆叠为连续定位
                for item in viewModel.selectedItems { viewModel.revealInFinder(item: item) }
            } label: {
                Label("在 Finder 中显示", systemImage: "folder")
            }
            .controlSize(.small)
            .disabled(disabled)

            Button {
                viewModel.requestCleanSelected()
            } label: {
                Label(cleanSelectedTitle, systemImage: "trash")
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .controlSize(.small)
            .disabled(disabled)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.bar)
    }

    /// 文案带条数，用户能一眼确认要删几个。
    private var cleanSelectedTitle: String {
        let n = viewModel.selectedItems.count
        return n > 0 ? "清理选中项（\(n)）" : "清理选中项"
    }
}

// MARK: - 会话行
//
// 标题 / 摘要 / 元信息三层。体积固定在右侧且必须完整可见 ——
// 不加 fixedSize 时它会和标题抢压缩额度，被截成「2...」。

private struct ConversationRow: View {
    @EnvironmentObject var viewModel: CleanViewModel

    let item: ConversationItem
    let isBusy: Bool

    private var selection: Binding<Bool> {
        Binding(
            get: { viewModel.conversations.first { $0.id == item.id }?.isSelected ?? item.isSelected },
            set: { viewModel.setItemSelected(item.id, selected: $0) }
        )
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Toggle("选择 \(item.title)", isOn: selection)
                .labelsHidden()
                .toggleStyle(.checkbox)
                .help(item.isSelected ? "取消选择此会话" : "选择此会话")
                .disabled(isBusy)

            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(item.category.rawValue)
                        .font(.caption2)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(.quaternary))
                    Text(item.title)
                        .font(.headline)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Text(item.formattedSize)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .fixedSize()
                }

                Text(item.snippet)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                metaLine
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
    }

    private var metaLine: some View {
        HStack(spacing: 5) {
            // 只显示末两级：前缀截断砍掉的恰恰是末段，而末段才是区分同名项目的东西
            Text(Fmt.pathTail(item.displayProjectPath))
                .font(.system(size: 10.5, design: .monospaced))
                .help("项目路径：\(item.displayProjectPath)")

            if let branch = item.gitBranch, !branch.isEmpty {
                sep
                Text(branch).lineLimit(1).help("Git 分支：\(branch)")
            }

            sep
            Text("\(item.messageCount) 轮")

            sep
            Text(Fmt.relative(item.updatedAt))

            Spacer(minLength: 8)

            Text("#\(item.shortSessionId)")
                .font(.system(size: 10.5, design: .monospaced))
                .help("会话 ID：\(item.sessionId)")
        }
        .lineLimit(1)
    }

    private var sep: some View {
        Text("·").foregroundStyle(.tertiary)
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
