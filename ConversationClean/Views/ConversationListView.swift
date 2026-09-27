import SwiftUI
import Combine

// MARK: - 排序模式
//
// 原先走系统 `Picker(.menu)`，那个控件带着系统菜单的弹出层与分隔线，
// 混在自绘的筛选栏里非常突兀。现在排序器收进列表列顶部的自绘分段控件。

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

    var symbol: String {
        switch self {
        case .date: return "clock"
        case .size: return "arrow.down.right.and.arrow.up.left"
        case .msgs: return "text.bubble"
        }
    }
}

// MARK: - 会话列表
//
// 视觉基线 ui-a-precision.html。修掉的四处：
//   ① 系统 `List` → ScrollView + LazyVStack。行完全自绘，选中态用「2pt 靛蓝竖条
//      + 极淡靛蓝底」内嵌在行里（不占布局，不会把文字推歪）。
//   ② 62pt 的会话 ID 列删掉。它用的是 `.tertiary`，肉眼几乎看不见，却占着
//      右对齐数字区里最宽的一格，把体积挤到了一边 —— 纯浪费的视觉预算。
//   ③ 体积提到 12.5pt semibold（比标题的 medium 更重）。原实现标题 13pt medium
//      比体积 12pt semibold 更重，在一个「清理 99MB 垃圾」的工具里层级是反的。
//   ④ 禁用的「清理选中项」原本是 `.tint(.red) + .disabled`，macOS 会把它渲染成
//      粉红。现在自绘，禁用态只降 opacity，不换色。

struct ConversationListView: View {
    @EnvironmentObject var viewModel: CleanViewModel

    @AppStorage("listSortMode") private var sortRaw: String = ListSortMode.size.rawValue
    @AppStorage("searchText") private var searchRaw: String = ""

    /// 搜索框焦点。绑定到本地状态而不是直接用 ⌘F 改 AppStorage：
    /// 焦点是视图状态，持久化它只会让下次开窗口凭空抢走键盘。
    @FocusState private var searchIsFocused: Bool
    /// 列表是否吃到键盘焦点，决定 ↑↓ 能否移动选中
    @FocusState private var listIsFocused: Bool

    private var sort: ListSortMode { ListSortMode(rawValue: sortRaw) ?? .date }
    private var isBusy: Bool { viewModel.isScanning || viewModel.isCleaning }
    private var rows: [ConversationItem] { sorted }
    private var allSelected: Bool { !rows.isEmpty && rows.allSatisfy { $0.isSelected } }
    private var someSelected: Bool { !allSelected && rows.contains { $0.isSelected } }

    private var searchBinding: Binding<String> {
        Binding(get: { searchRaw }, set: { searchRaw = $0; viewModel.searchText = $0 })
    }
    private var sortBinding: Binding<ListSortMode> {
        Binding(get: { sort }, set: { sortRaw = $0.rawValue })
    }

    var body: some View {
        VStack(spacing: 0) {
            filterBar
            Rectangle().fill(Theme.line).frame(height: 1)
            notice
            if rows.isEmpty {
                emptyState
            } else {
                list
            }
            batchBar
        }
        .background(Theme.surface)
        .onChange(of: viewModel.searchFocusRequest) { _, _ in
            searchIsFocused = true
        }
        // Esc 分三级退：先清搜索词，再清勾选。
        // 行选中（看详情）不参与 —— 它不是「批量操作状态」，Esc 掉它会让人
        // 突然丢失右侧详情，且没有对应的恢复手势。
        .onKeyPress(.escape) {
            if !searchRaw.trimmed.isEmpty {
                searchBinding.wrappedValue = ""
                return .handled
            }
            if !viewModel.selectedItems.isEmpty {
                viewModel.selectAll(false)
                return .handled
            }
            return .ignored
        }
        // ↑↓ 在列表内移动选中行。系统 List 自带这个行为，自绘后要自己补，
        // 否则列表只能用鼠标点 —— 那是可用性回退，不是等价替换。
        .onKeyPress(.upArrow) { moveSelection(by: -1) }
        .onKeyPress(.downArrow) { moveSelection(by: 1) }
    }

    // MARK: - 筛选栏

    private var filterBar: some View {
        VStack(spacing: Theme.Space.m) {
            DrawnSearchField(text: searchBinding,
                             placeholder: "搜索标题、摘要、项目路径或会话 ID")
                .focused($searchIsFocused)

            HStack(spacing: Theme.Space.m) {
                DrawnSegmented(selection: sortBinding, items: ListSortMode.allCases.map {
                    DrawnSegmented.Item($0, $0.label)
                })

                Spacer(minLength: Theme.Space.s)

                Text("共 \(rows.count) 项")
                    .font(Theme.Typo.rowSub)
                    .foregroundStyle(Theme.t3)

                Button {
                    Task { await viewModel.scanConversations() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 10.5, weight: .semibold))
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(DrawnButtonStyle(variant: .flat, horizontalPadding: 0))
                .disabled(isBusy)
                .help("重新扫描")
            }
        }
        .padding(.horizontal, Theme.Space.l)
        .padding(.vertical, Theme.Space.ms)
        .background(Theme.surface)
    }

    // MARK: - 列表

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(rows) { item in
                        ConversationRow(item: item, isBusy: isBusy) {
                            viewModel.selectedConversationID = item.id
                        } onToggle: {
                            viewModel.setItemSelected(item.id, selected: !item.isSelected)
                        }
                        .id(item.id)
                        .contextMenu { rowMenu(item) }
                    }
                }
                .padding(.vertical, Theme.Space.xs)
            }
            .focusable()
            .focused($listIsFocused)
            .onChange(of: viewModel.selectedConversationID) { _, id in
                guard let id else { return }
                withAnimation(.easeOut(duration: 0.14)) { proxy.scrollTo(id, anchor: .center) }
            }
        }
    }

    private var sorted: [ConversationItem] {
        switch sort {
        case .date: return viewModel.filteredConversations.sorted { $0.updatedAt > $1.updatedAt }
        case .size: return viewModel.filteredConversations.sorted { $0.sizeInBytes > $1.sizeInBytes }
        case .msgs: return viewModel.filteredConversations.sorted { $0.messageCount > $1.messageCount }
        }
    }

    /// ↑↓ 移动选中。列表空、或已经在首/尾时返回 .ignored，
    /// 让事件继续冒泡（否则会吃掉窗口级的导航键）。
    private func moveSelection(by delta: Int) -> KeyPress.Result {
        guard !rows.isEmpty else { return .ignored }
        let current = viewModel.selectedConversationID
        guard let idx = current.flatMap({ id in rows.firstIndex { $0.id == id } }) else {
            // 没有任何选中时，↓ 进第一条、↑ 进最后一条
            viewModel.selectedConversationID = delta > 0 ? rows[0].id : rows[rows.count - 1].id
            return .handled
        }
        let next = idx + delta
        guard next >= 0, next < rows.count else { return .ignored }
        viewModel.selectedConversationID = rows[next].id
        return .handled
    }

    // 右键菜单由系统 Menu 渲染，菜单项外观应跟随系统，不做自绘替换。
    // selfdraw-exempt: begin
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
    // selfdraw-exempt: end

    // MARK: - 通知条

    @ViewBuilder
    private var notice: some View {
        if viewModel.showCleanSuccessAlert {
            DrawnNotice(
                icon: "checkmark.circle.fill",
                text: "清理完成 · 删除 \(viewModel.lastCleanedCount) 个会话，释放 "
                    + Fmt.bytes(viewModel.lastCleanedBytes)
                    + " 磁盘空间，剩余 \(viewModel.conversations.count) 个会话。",
                dismissTitle: "知道了"
            ) { viewModel.showCleanSuccessAlert = false }
            .padding(.horizontal, Theme.Space.l)
            .padding(.top, Theme.Space.m)
        } else if viewModel.showScanSuccessAlert {
            DrawnNotice(
                icon: "checkmark.circle.fill",
                text: "扫描完成 · 命中 \(viewModel.scanSuccessCount) 个会话，合计 "
                    + Fmt.bytes(viewModel.scanSuccessBytes) + "。",
                dismissTitle: "知道了"
            ) { viewModel.showScanSuccessAlert = false }
            .padding(.horizontal, Theme.Space.l)
            .padding(.top, Theme.Space.m)
        }
    }

    // MARK: - 空态

    @ViewBuilder
    private var emptyState: some View {
        if viewModel.isScanning {
            DrawnEmptyState(
                symbol: "arrow.triangle.2.circlepath",
                title: "正在扫描本机会话…",
                message: "正在查找本机各 Agent 的会话缓存，请稍候。"
            )
        } else if !viewModel.hasScanned {
            DrawnEmptyState(
                symbol: "magnifyingglass",
                title: "还没有扫描过会话",
                message: "已关闭「启动时自动扫描」。点下方按钮手动扫描本机各 Agent 的会话缓存。",
                actionTitle: "重新扫描"
            ) { Task { await viewModel.scanConversations() } }
        } else if hasQuery {
            DrawnEmptyState(
                symbol: "magnifyingglass",
                title: "没有匹配「\(searchRaw.trimmed)」的会话",
                message: "换个关键词，或清空搜索词看全部 \(viewModel.conversations.count) 个会话。",
                actionTitle: "清除搜索词"
            ) { searchBinding.wrappedValue = "" }
        } else {
            DrawnEmptyState(
                symbol: viewModel.selectedCategory.iconName,
                title: "暂无 \(viewModel.selectedCategory.rawValue) 会话记录",
                message: "未在本地检测到该 Agent 的历史会话文件，或所有会话均已被清理。"
            )
        }
    }

    private var hasQuery: Bool { !searchRaw.trimmed.isEmpty }

    // MARK: - 批量条

    private var batchBar: some View {
        let disabled = viewModel.selectedItems.isEmpty || isBusy
        return HStack(spacing: Theme.Space.m) {
            (Text("已选 ")
                + Text("\(viewModel.selectedItems.count)").bold()
                + Text(" 项 · ")
                + Text(Fmt.bytes(viewModel.selectedSize)).bold())
                .font(Theme.Typo.rowSub)
                .foregroundStyle(Theme.t2)
                .lineLimit(1)
                .truncationMode(.tail)
                // 空间不够时先牺牲这段文字（优先级 -1）。
                //
                // 注意方向：上一版写的是 `layoutPriority(1)`，注释说「先压这段
                // 文字」而代码说「最后才压它」—— 优先级越高越晚被压缩，两者刚好
                // 相反，结果是按钮被挤扁而文字纹丝不动。保住按钮的可点区域，
                // 就得让文字先让路，所以是 -1；下面的按钮组再抬到 1。
                .layoutPriority(-1)

            Button(allSelected ? "取消全选" : "全选当前") { viewModel.selectAll(!allSelected) }
                .buttonStyle(DrawnButtonStyle(variant: .flat,
                                              horizontalPadding: 6,
                                              // enabled 必须传进 style：光写 .disabled()
                                              // 只断交互，style 里的 enabled 仍为 true，
                                              // 文字会保持正常深色 —— 看着能点却点不动。
                                              enabled: !rows.isEmpty,
                                              compact: true))
                .disabled(rows.isEmpty)

            Spacer(minLength: Theme.Space.xs)

            // 列表列最窄只有 340pt，这一排塞不下四个带文字的按钮。
            // 次要动作改纯图标（tooltip 兜底），主操作保留文字。
            //
            // 「取消选择」整个去掉：Esc 已经能清，且它与「全选当前 / 取消全选」重复。
            Button {
                for item in viewModel.selectedItems { viewModel.revealInFinder(item: item) }
            } label: {
                Image(systemName: "folder")
                    .font(Theme.Typo.num(10.5, .medium))
                    .frame(width: 24, height: 22)
            }
            .buttonStyle(DrawnButtonStyle(variant: .flat, horizontalPadding: 0,
                                          enabled: !disabled, compact: true))
            .disabled(disabled)
            .help("在 Finder 中显示选中的会话")

            Button { viewModel.requestCleanSelected() } label: {
                HStack(spacing: 4) {
                    Image(systemName: "trash")
                        .font(Theme.Typo.num(10, .semibold))
                    Text(cleanSelectedTitle)
                        .font(Theme.Typo.rowSub.weight(.medium))
                }
            }
            .buttonStyle(DrawnButtonStyle(variant: .danger,
                                          horizontalPadding: Theme.Space.s,
                                          enabled: !disabled, compact: true))
            .disabled(disabled)
            .help("删除选中的会话及其索引行")
        }
        // 按钮组整体抬高优先级：窄栏（340pt）下先压文字，按钮保持完整可点区域
        .layoutPriority(1)
        .padding(.horizontal, Theme.Space.l)
        .frame(height: Theme.Size.bar)
        .background(Theme.bg)
        // 同 topBar：裸 Rectangle 会填满 44pt 高的整条批量条，把「已选 N 项」
        // 和两个按钮全部盖掉。Theme.line 与 Theme.bg 同色，看上去就是「底部什么都没有」。
        .hairline(.top)
    }

    private var cleanSelectedTitle: String {
        let n = viewModel.selectedItems.count
        return n > 0 ? "清理选中项（\(n)）" : "清理选中项"
    }
}

// MARK: - 会话行
//
// 全自绘。行高 32pt（一屏 24 行 vs 旧版 19 行）。
// 副标题给「这条属于哪、什么时候的」，而不是重复标题 ——
// 标题常常就是首条 user prompt 的原文，再显示一遍只会让每行看起来都是重复噪音。
// 而删除决策需要的是位置与时间。

private struct ConversationRow: View {
    @EnvironmentObject var viewModel: CleanViewModel

    let item: ConversationItem
    let isBusy: Bool
    let onSelect: () -> Void
    let onToggle: () -> Void

    @State private var hovering = false

    private var isFocusedRow: Bool { viewModel.selectedConversationID == item.id }

    /// 该行是否处于「批量操作」语境：有勾选、或是半选行。
    /// 半选时用靛蓝半填充方块 + 横杠，与全选的勾号区分开。
    private var isMixedRow: Bool {
        !item.isSelected && someSiblingSelected
    }
    private var someSiblingSelected: Bool {
        // 整批操作过后，同栏存在已选项时把未选项标成半选，提示「这是一批操作的一部分」
        viewModel.selectedItems.isEmpty == false
    }

    var body: some View {
        HStack(spacing: Theme.Space.m) {
            DrawnCheckbox(isOn: .constant(item.isSelected),
                          enabled: !isBusy,
                          isMixed: isMixedRow,
                          help: item.isSelected ? "取消选择此会话" : "选择此会话")
                .onTapGesture { guard !isBusy else { return }; onToggle() }

            AgentIconView(category: item.category, size: 16)

            VStack(alignment: .leading, spacing: 0) {
                Text(item.title)
                    .font(isFocusedRow ? Theme.Typo.rowTitleActive : Theme.Typo.rowTitle)
                    .foregroundStyle(Theme.t1)
                    .lineLimit(1)
                    .truncationMode(.tail)
                subtitleLine
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // 占比迷你条：数字归体积，形状归占比，两者不抢同一格的注意力
            ShareBar(percent: sharePercent, width: 38, height: 5)

            // 体积是这行的主数字：清理工具里「多大」比「叫什么」重要。
            // 层级修正见文件头注释。
            Text(item.formattedSize)
                .font(Theme.Typo.sizeNum)
                .foregroundStyle(item.sizeInBytes > 0 ? Theme.t1 : Theme.t3)
                .frame(width: 52, alignment: .trailing)
                .lineLimit(1)
        }
        .padding(.horizontal, Theme.Space.l)
        .padding(.leading, Theme.Space.ms)
        .frame(height: Theme.Size.row)
        .background(background)
        // 2pt 靛蓝竖条：选中标记内嵌在行里，不占布局，文字不会因为它被推歪
        .overlay(alignment: .leading) {
            if isFocusedRow {
                Rectangle().fill(Theme.accent).frame(width: 2)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onHover { hovering = $0 }
        .opacity(item.sizeInBytes > 0 ? 1 : 0.55)   // 0 KB 的条目删了不省空间
        .accessibilityElement(children: .contain)
    }

    private var subtitleLine: some View {
        HStack(spacing: 4) {
            if !path.isEmpty {
                Text(path).foregroundStyle(Theme.t3)
                Text("·").foregroundStyle(Theme.t3.opacity(0.6))
            }
            Text(Fmt.relative(item.updatedAt)).foregroundStyle(Theme.t3)
            if let branch = item.gitBranch, !branch.isEmpty {
                Text("·").foregroundStyle(Theme.t3.opacity(0.6))
                Text(branch).foregroundStyle(Theme.t3)
            }
        }
        .font(Theme.Typo.rowSub)
        .lineLimit(1)
        .truncationMode(.tail)
    }

    private var background: Color {
        if isFocusedRow { return Theme.accentWash }
        return hovering ? Theme.sunken : .clear
    }

    private var sharePercent: Double {
        let total = viewModel.totalSize
        guard total > 0 else { return 0 }
        return Double(item.sizeInBytes) / Double(total) * 100
    }

    private var path: String { Fmt.pathTail(item.displayProjectPath) }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
