import SwiftUI
import Combine

// MARK: - 分类色
//
// 刻意**不**给 15 款 Agent 各配一色：一列排下来就是花的，读不出信息。
// DefaultAppManager 的「导航模式」一组图标也全是同一个 accentColor，
// 只有「格式分类」那 10 个语义类才上色。这里取同样克制的做法 ——
// 徽章统一中性底 + 前景字，只靠首字母区分。


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
// 版式照 DefaultAppManager 的 ExtensionListView：
//   列表列顶部 = 搜索框 + 筛选器 + 「共 N 项」+ 刷新
//   行       = 彩色徽章 + 标题 + 等宽灰字副标题 + 右侧数值
//   详情列   = 会话元数据（见 DetailView）

struct ConversationListView: View {
    @EnvironmentObject var viewModel: CleanViewModel

    @AppStorage("listSortMode") private var sortRaw: String = ListSortMode.size.rawValue
    @AppStorage("searchText") private var searchRaw: String = ""

    private var sort: ListSortMode { ListSortMode(rawValue: sortRaw) ?? .date }
    private var isBusy: Bool { viewModel.isScanning || viewModel.isCleaning }
    private var rows: [ConversationItem] { sorted }
    private var allSelected: Bool { !rows.isEmpty && rows.allSatisfy { $0.isSelected } }

    private var searchBinding: Binding<String> {
        Binding(get: { searchRaw }, set: { searchRaw = $0; viewModel.searchText = $0 })
    }

    var body: some View {
        VStack(spacing: 0) {
            filterBar
            Divider()
            banner
            if rows.isEmpty {
                emptyState
            } else {
                list
            }
            batchBar
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - 列表列顶部筛选栏

    private var filterBar: some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("搜索标题、摘要、项目路径或会话 ID", text: searchBinding)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                if !searchRaw.isEmpty {
                    Button { searchBinding.wrappedValue = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
            )

            HStack(spacing: 8) {
                Picker("", selection: sortBinding) {
                    ForEach(ListSortMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .font(.system(size: 11))
                .frame(width: 110)

                Spacer()

                Text("共 \(rows.count) 项")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)

                Button {
                    Task { await viewModel.scanConversations() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .disabled(isBusy)
                .help("重新扫描")
            }
        }
        .padding(10)
        .background(Color(nsColor: .windowBackgroundColor))
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
            notice(icon: "checkmark.circle.fill",
                   text: "清理完成 · 删除 \(viewModel.lastCleanedCount) 个会话，释放 "
                       + Fmt.bytes(viewModel.lastCleanedBytes)
                       + " 磁盘空间，剩余 \(viewModel.conversations.count) 个会话。",
                   tint: .green) { viewModel.showCleanSuccessAlert = false }
        } else if viewModel.showScanSuccessAlert {
            notice(icon: "checkmark.circle.fill",
                   text: "扫描完成 · 命中 \(viewModel.scanSuccessCount) 个会话，合计 "
                       + Fmt.bytes(viewModel.scanSuccessBytes) + "。",
                   tint: .green) { viewModel.showScanSuccessAlert = false }
        }
    }

    private func notice(icon: String, text: String, tint: Color,
                        dismiss: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).foregroundStyle(tint)
            Text(text).font(.callout)
            Spacer(minLength: 8)
            Button("知道了", action: dismiss).controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(tint.opacity(0.12))
    }

    // MARK: - 空态

    @ViewBuilder
    private var emptyState: some View {
        if viewModel.isScanning {
            ContentUnavailableView("正在扫描本机会话…", systemImage: "arrow.triangle.2.circlepath",
                                   description: Text("正在查找本机各 Agent 的会话缓存，请稍候。"))
        } else if !viewModel.hasScanned {
            ContentUnavailableView {
                Label("还没有扫描过会话", systemImage: "magnifyingglass")
            } description: {
                Text("已关闭「启动时自动扫描」。点下方按钮手动扫描本机各 Agent 的会话缓存。")
            } actions: {
                Button { Task { await viewModel.scanConversations() } } label: {
                    Label("重新扫描", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderedProminent)
            }
        } else if hasQuery {
            ContentUnavailableView.search(text: searchRaw.trimmed)
        } else {
            ContentUnavailableView(
                "暂无 \(viewModel.selectedCategory.rawValue) 会话记录",
                systemImage: viewModel.selectedCategory.iconName,
                description: Text("未在本地检测到该 Agent 的历史会话文件，或所有会话均已被清理。")
            )
        }
    }

    private var hasQuery: Bool { !searchRaw.trimmed.isEmpty }

    // MARK: - 批量条

    private var batchBar: some View {
        let disabled = viewModel.selectedItems.isEmpty || isBusy
        return HStack(spacing: 10) {
            (Text("已选中 ")
                + Text("\(viewModel.selectedItems.count)").bold()
                + Text(" 项 · ")
                + Text(Fmt.bytes(viewModel.selectedSize)).bold())
                .font(.callout)
                .foregroundStyle(.secondary)

            Button(allSelected ? "取消全选" : "全选当前") { viewModel.selectAll(!allSelected) }
                .controlSize(.small)
                .disabled(rows.isEmpty)

            Spacer(minLength: 8)

            Button { viewModel.selectAll(false) } label: { Label("取消选择", systemImage: "xmark") }
                .controlSize(.small).disabled(disabled)

            Button {
                for item in viewModel.selectedItems { viewModel.revealInFinder(item: item) }
            } label: { Label("在 Finder 中显示", systemImage: "folder") }
                .controlSize(.small).disabled(disabled)

            Button { viewModel.requestCleanSelected() } label: {
                Label(cleanSelectedTitle, systemImage: "trash")
            }
            .buttonStyle(.borderedProminent).tint(.red)
            .controlSize(.small).disabled(disabled)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private var cleanSelectedTitle: String {
        let n = viewModel.selectedItems.count
        return n > 0 ? "清理选中项（\(n)）" : "清理选中项"
    }
}

// MARK: - 会话行
//
// 照 DefaultAppManager 的 ExtensionRowView：左侧彩色徽章 + 标题 + 等宽灰字副标题
// + 右侧数值。摘要与标题重复时不重复渲染 —— 之前每行都把同一句话显示两遍。

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

    /// 标题与摘要常常是同一句话（scanner 用首个 user prompt 同时当标题和摘要），
    /// 原样渲染两遍会让每行看起来都是重复噪音。
    private var subtitle: String {
        let s = item.snippet.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty || s == item.title { return Fmt.pathTail(item.displayProjectPath) }
        return s
    }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Toggle("选择 \(item.title)", isOn: selection)
                .labelsHidden()
                .toggleStyle(.checkbox)
                .help(item.isSelected ? "取消选择此会话" : "选择此会话")
                .disabled(isBusy)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                // 副标题给「这条属于哪、什么时候的」，而不是重复标题。
                // 标题常常就是首条 user prompt 的原文，再显示一遍只会让每行
                // 看起来都是重复噪音；而删除决策需要的是位置与时间。
                HStack(spacing: 5) {
                    Text(item.category.rawValue)
                        .foregroundStyle(.secondary)
                    if !path.isEmpty {
                        Text("·").foregroundStyle(.tertiary)
                        Text(path).foregroundStyle(.secondary)
                    }
                    Text("·").foregroundStyle(.tertiary)
                    Text(Fmt.relative(item.updatedAt)).foregroundStyle(.secondary)
                }
                .font(.system(size: 10.5))
                .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // 体积是这行的主数字：清理工具里「多大」比「叫什么」重要
            Text(item.formattedSize)
                .font(.system(size: 12.5, weight: .semibold, design: .monospaced))
                .foregroundStyle(item.sizeInBytes > 0 ? Color.primary : Color.secondary)
                .frame(width: 68, alignment: .trailing)
                .lineLimit(1)

            Text("#\(item.shortSessionId)")
                .font(.system(size: 9.5, design: .monospaced))
                .foregroundStyle(.tertiary)
                .frame(width: 62, alignment: .trailing)
                .lineLimit(1)
        }
        .padding(.vertical, 3)
        // 0 KB 的条目删了不省空间，不该和有体积的抢注意力
        .opacity(item.sizeInBytes > 0 ? 1 : 0.55)
        .accessibilityElement(children: .contain)
    }

    private var path: String { Fmt.pathTail(item.displayProjectPath) }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
