import SwiftUI
import Combine

// MARK: - 聚焦广播（跨模块契约）
//
// 检视器（DetailView.swift）只 `.onReceive` 订阅、不定义该 extension，
// 因此它必须且只能在本文件里定义一次；object 必须是 ConversationItem 或 nil。
extension Notification.Name {
    static let ccFocusConversation = Notification.Name("ccFocusConversation")
}

// MARK: - 排序方式
//
// `filteredConversations` 本身无序，排序完全在列表模块本地完成，不污染数据层。
private enum ListSortMode: String, CaseIterable, Hashable {
    case date, size, msgs

    var label: String {
        switch self {
        case .date: return "最近更新"
        case .size: return "占用空间"
        case .msgs: return "对话轮数"
        }
    }
}

// MARK: - 列表容器
//
// 原型 `.toolbar` / `.content-head` / `.sbar` / `.banner` / `.list` / `.empty` /
// `.batchbar` 的整体移植。纵向顺序与原型 DOM 一一对应。
struct ConversationListView: View {
    @EnvironmentObject var viewModel: CleanViewModel

    @State private var sort: ListSortMode = .date
    @State private var focusedID: UUID?

    private var isBusy: Bool { viewModel.isScanning || viewModel.isCleaning }
    private var rows: [ConversationItem] { sorted }
    private var hasQuery: Bool { !viewModel.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        VStack(spacing: 0) {
            progressStrip
            successBanner
            contentHead
            contentArea
            batchBar
        }
        .background(CC.surface)
        .animation(CC.Mv.base, value: viewModel.selectedItems.count)
        .animation(CC.Mv.base, value: isBusy)
        .animation(CC.Mv.base, value: viewModel.showCleanSuccessAlert)
        .animation(CC.Mv.base, value: viewModel.filteredConversations.isEmpty)
        .onReceive(NotificationCenter.default.publisher(for: .ccFocusConversation)) { note in
            // 检视器侧的关闭 / 跳转同样通过该通知回传，这里只同步状态、不再回发，避免回环
            if let item = note.object as? ConversationItem {
                if focusedID != item.id { focusedID = item.id }
            } else if focusedID != nil {
                focusedID = nil
            }
        }
        .onChange(of: viewModel.conversations.count) { _, _ in
            // 会话被清理后聚焦项可能已不存在，需要向检视器广播一次取消
            if let focusedID, !viewModel.conversations.contains(where: { $0.id == focusedID }) {
                setFocus(nil)
            }
        }
        .onChange(of: viewModel.selectedCategory) { _, _ in
            // 换分类等于换整份列表，旧焦点失效（对齐原型 setCat 清空 focusId）
            if focusedID != nil { setFocus(nil) }
        }
    }

    // MARK: 工具条（`.toolbar`）

    // MARK: 进度条 / 成功横幅（`.sbar` / `.banner.ok`）

    @ViewBuilder
    private var progressStrip: some View {
        if isBusy {
            CCProgressLine(label: viewModel.isScanning ? "正在扫描本机会话…" : "正在清理选中项…")
                .transition(.opacity.combined(with: .move(edge: .top)))
        }
    }

    @ViewBuilder
    private var successBanner: some View {
        if viewModel.showCleanSuccessAlert && viewModel.lastCleanedBytes > 0 {
            CCRichBanner(tone: .ok) {
                Text("已释放 ")
                + Text(Fmt.bytes(viewModel.lastCleanedBytes))
                    .font(CC.F.num(12, .semibold))
                    .foregroundStyle(CC.ok)
                + Text("（")
                + Text("\(viewModel.lastCleanedCount)")
                    .font(CC.F.num(12, .semibold))
                    .foregroundStyle(CC.ok)
                + Text(" 个会话）本地磁盘存储空间")
            } trailing: {
                CCButton(title: "知道了", kind: .ghost, compact: true, help: "关闭提示") {
                    withAnimation(CC.Mv.base) { viewModel.showCleanSuccessAlert = false }
                }
            }
            .transition(.opacity.combined(with: .move(edge: .top)))
        }
    }

    // MARK: 内容头（`.content-head`）

    private var contentHead: some View {
        HStack(alignment: .bottom, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                // `.ch-title`：20pt 线性图标 + display 标题，图标不是圆形徽章
                HStack(spacing: 8) {
                    Image(systemName: viewModel.selectedCategory.iconName)
                        .font(.system(size: 20, weight: .regular))
                        .foregroundStyle(CC.fg)
                        .frame(width: 20, height: 20)
                    Text(viewModel.selectedCategory.rawValue)
                        .font(CC.F.display)
                        .foregroundStyle(CC.fg)
                        .lineLimit(1)
                }
                headSubtitle
                    .font(CC.F.label)
                    .foregroundStyle(CC.muted)
                    .lineLimit(1)
            }
            .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 8)

            CCSegmented<ListSortMode>(
                options: ListSortMode.allCases.map { CCSegmented<ListSortMode>.Option(value: $0, label: $0.label) },
                selection: $sort
            )
            .help("排序方式")

            CCButton(
                title: allSelected ? "取消全选" : "全选当前",
                kind: .outline,
                compact: true,
                enabled: !rows.isEmpty,
                help: allSelected ? "取消选中当前列表中的全部会话" : "选中当前列表中的全部会话"
            ) {
                withAnimation(CC.Mv.base) { viewModel.selectAll(!allSelected) }
            }
        }
        .padding(.init(top: 16, leading: 20, bottom: 13, trailing: 20))
        .background(CC.surface)
        .ccHairline(.bottom)
    }

    /// `.ch-sub` 的两个分支：有搜索词报「匹配 / 全部」，无搜索词报「条数 + 体积」。
    /// 每个数字都用等宽 semibold + fg（原型 `.ch-sub b`）。
    private var headSubtitle: Text {
        let count = rows.count
        let bytes = rows.reduce(Int64(0)) { $0 + $1.sizeInBytes }
        let selected = viewModel.selectedItems.count
        let selectedBytes = Fmt.bytes(viewModel.selectedSize)
        let total = viewModel.categoryStats[viewModel.selectedCategory]?.count ?? 0

        if hasQuery {
            return Text("在 ")
                + Text(viewModel.selectedCategory.rawValue)
                + Text(" 中匹配 ")
                + num(count)
                + Text(" 条 · 全部 ")
                + num(total)
                + Text(" 条 · 已选中 ")
                + num(selected)
                + Text(" 项（")
                + num(selectedBytes)
                + Text("）")
        } else {
            return Text("共 ")
                + num(count)
                + Text(" 个会话项，占用 ")
                + num(Fmt.bytes(bytes))
                + Text(" · 已选中 ")
                + num(selected)
                + Text(" 项（")
                + num(selectedBytes)
                + Text("）")
        }
    }

    private func num(_ s: String) -> Text {
        Text(s).font(CC.F.num(11.5, .semibold)).foregroundStyle(CC.fg)
    }

    private func num(_ i: Int) -> Text { num("\(i)") }

    private var allSelected: Bool {
        !rows.isEmpty && rows.allSatisfy { $0.isSelected }
    }

    // MARK: 列表 / 空态（`.list` / `.empty`）

    @ViewBuilder
    private var contentArea: some View {
        if rows.isEmpty {
            emptyState.transition(.opacity)
        } else {
            listArea.transition(.opacity)
        }
    }

    private var listArea: some View {
        ScrollView(.vertical) {
            LazyVStack(spacing: 2) {
                ForEach(rows) { item in
                    RowCell(
                        item: item,
                        isFocused: focusedID == item.id,
                        isBusy: isBusy,
                        onFocus: { toggleFocus(item) },
                        onDelete: { Task { await deleteRow(item) } }
                    )
                }
            }
            .padding(.init(top: 6, leading: 12, bottom: 16, trailing: 12))
        }
    }

    /// 本地排序：三种键各自降序，条目量级有限，`.sorted` 足够。
    private var sorted: [ConversationItem] {
        switch sort {
        case .date: return viewModel.filteredConversations.sorted { $0.updatedAt > $1.updatedAt }
        case .size: return viewModel.filteredConversations.sorted { $0.sizeInBytes > $1.sizeInBytes }
        case .msgs: return viewModel.filteredConversations.sorted { $0.messageCount > $1.messageCount }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        let path = currentStoragePath
        if viewModel.isScanning {
            CCEmptyState(
                systemImage: "arrow.triangle.2.circlepath",
                title: "正在扫描本机会话…",
                message: "正在查找本机各 Agent 的会话缓存，请稍候。"
            )
        } else if !viewModel.hasScanned {
            // 「启动时自动扫描」关掉时的落点：列表从未被填充过，
            // 文案要告诉用户是还没扫，而不是扫完空空如也。
            CCEmptyState(
                systemImage: "magnifyingglass",
                title: "还没有扫描过会话",
                message: "已关闭「启动时自动扫描」。点下方按钮手动扫描本机各 Agent 的会话缓存。",
                path: path
            ) {
                rescanButton
            }
        } else if viewModel.conversations.isEmpty {
            CCEmptyState(
                systemImage: viewModel.selectedCategory.iconName,
                title: "暂无 \(viewModel.selectedCategory.rawValue) 会话记录",
                message: "未在本地检测到任何 Agent 历史会话文件，或所有会话均已被清理。",
                path: path
            ) {
                rescanButton
            }
        } else if hasQuery {
            CCEmptyState(
                systemImage: viewModel.selectedCategory.iconName,
                title: "没有匹配的会话",
                message: "当前分类下没有标题、摘要、项目路径或会话 ID 包含「\(viewModel.searchText.trimmed)」的记录。"
            ) {
                rescanButton
            }
        } else {
            CCEmptyState(
                systemImage: viewModel.selectedCategory.iconName,
                title: "暂无 \(viewModel.selectedCategory.rawValue) 会话记录",
                message: "未在下面的存储路径中检测到该 Agent 的会话文件。",
                path: path
            ) {
                rescanButton
            }
        }
    }

    private var rescanButton: some View {
        CCButton(title: "重新扫描", systemImage: "arrow.clockwise", kind: .outline, help: "重新扫描本机会话缓存") {
            Task { await viewModel.scanConversations() }
        }
    }

    private var currentStoragePath: String? {
        guard viewModel.selectedCategory != .all else { return nil }
        return viewModel.agentInfos.first { $0.category == viewModel.selectedCategory }?.storagePath
    }

    // MARK: 批量条（`.batchbar`）
    //
    // 原型里它是常驻底栏：0 选中时三个按钮只是禁用灰态，文案照样显示 0。

    private var batchBar: some View {
        let disabled = viewModel.selectedItems.isEmpty || isBusy
        return HStack(spacing: 12) {
            batchLabel
                .font(CC.F.label)
                .foregroundStyle(CC.muted)

            Spacer(minLength: 8)

            CCButton(
                title: "取消选择",
                kind: .ghost,
                compact: true,
                enabled: !disabled,
                help: "取消选中全部会话"
            ) {
                withAnimation(CC.Mv.base) { viewModel.selectAll(false) }
            }

            CCButton(
                title: "在 Finder 中显示",
                systemImage: "folder",
                // 原型 `.batchbar` 里这个按钮是 `btn-ghost btn-sm`（透明底、无边框）
                kind: .ghost,
                compact: true,
                enabled: !disabled,
                help: "在 Finder 中逐个定位选中的会话"
            ) {
                // NSWorkspace 一次只能定位一个文件，逐个调用由系统堆叠为连续的多窗口定位
                for item in viewModel.selectedItems { viewModel.revealInFinder(item: item) }
            }

            CCButton(
                title: "清理选中项",
                systemImage: "trash",
                kind: .danger,
                enabled: !disabled,
                help: "删除选中的会话及其关联缓存"
            ) {
                requestCleanSelected()
            }
        }
        .padding(.init(top: 11, leading: 20, bottom: 11, trailing: 20))
        .background(CC.bg)
        .ccHairline(.top)
    }

    /// 原型 `.batchbar .b-n`。
    private var batchLabel: Text {
        Text("已选中 ")
        + Text("\(viewModel.selectedItems.count)")
            .font(CC.F.num(13, .semibold))
            .foregroundStyle(CC.fg)
        + Text(" 项 · ")
        + Text(Fmt.bytes(viewModel.selectedSize))
            .font(CC.F.num(13, .semibold))
            .foregroundStyle(CC.fg)
    }

    // MARK: 动作

    private func setFocus(_ item: ConversationItem?) {
        focusedID = item?.id
        NotificationCenter.default.post(name: .ccFocusConversation, object: item)
    }

    /// 再点一次已聚焦的行即取消聚焦：检视器不回传状态，取消聚焦的入口必须在本模块内。
    private func toggleFocus(_ item: ConversationItem) {
        setFocus(focusedID == item.id ? nil : item)
    }

    private func requestCleanSelected() {
        viewModel.requestCleanSelected()
    }

    private func deleteRow(_ item: ConversationItem) async {
        await viewModel.deleteSingle(item: item)
        if focusedID == item.id { setFocus(nil) }
    }
}

// MARK: - 会话行
//
// 原型 `.row`（grid 20px + 1fr / gap 11）+ `.cbx` + `.r-l1/.r-snip/.r-l3` + `.r-acts`。
// 不用 `List`：macOS 的 List 行高与背景无法与原型对齐。
private struct RowCell: View {
    @EnvironmentObject var viewModel: CleanViewModel

    let item: ConversationItem
    let isFocused: Bool
    let isBusy: Bool
    let onFocus: () -> Void
    let onDelete: () -> Void

    @State private var hovering = false
    @State private var cbHovering = false

    private var isSelected: Bool { item.isSelected }
    private var showActions: Bool { hovering || isFocused }

    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            checkbox
                .frame(width: 20, height: 16, alignment: .leading)

            VStack(alignment: .leading, spacing: 0) {
                // 第 1 行：分类 tag + 标题 + 右侧体积
                HStack(spacing: 8) {
                    tag
                    titleText
                    Spacer(minLength: 8)
                    Text(item.formattedSize)
                        .font(CC.F.num(11, .medium))
                        .foregroundStyle(CC.muted)
                        .lineLimit(1)
                        // 体积是右对齐的固定量，必须永远完整可见；
                        // 不加 fixedSize 时它会和标题抢压缩额度，被截成「2...」
                        .fixedSize()
                }

                // 第 2 行：摘要
                Text(item.snippet)
                    .font(CC.F.label)
                    .foregroundStyle(CC.muted)
                    .lineLimit(1)
                    .padding(.top, 3)

                // 第 3 行：项目路径 · 分支 · 轮数 · 时间 · 会话 ID · 悬浮动作
                metaLine
                    .font(CC.F.caption)
                    .foregroundStyle(CC.muted)
                    .padding(.top, 5)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.init(top: 11, leading: 10, bottom: 11, trailing: 8))
        .background(
            RoundedRectangle(cornerRadius: CC.R.md, style: .continuous)
                .fill(isFocused || isSelected ? CC.fillSoft : (hovering ? CC.fillHair : .clear))
        )
        .overlay(
            RoundedRectangle(cornerRadius: CC.R.md, style: .continuous)
                .strokeBorder(isFocused ? CC.fg.opacity(0.34) : .clear, lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: CC.R.md, style: .continuous))
        .onHover { hovering = $0 }
        .animation(CC.Mv.quick, value: hovering)
        .animation(CC.Mv.quick, value: isSelected)
        .animation(CC.Mv.quick, value: isFocused)
        // 用 .contain 而不是 .combine：.combine 会把行内子元素合并成一个整体，
        // 连带把复选框 Button 的独立可达性也吃掉，VoiceOver 用户就再也听不到
        // “选择/取消选择 <会话名>” 这一步。改为 .contain 后行本身是容器、
        // 复选框与标题各自可聚焦。
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isButton)
    }

    // MARK: 行内零件

    /// `.tag`：mono 小字 + 1px 描边的分类标签，排在标题之前。
    private var tag: some View {
        CCBadge(text: item.category.rawValue, tone: .neutral, mono: true, outlined: true, cornerRadius: CC.R.xs)
            .lineLimit(1)
            .fixedSize()
            .help("所属分类：\(item.category.rawValue)")
    }

    /// 聚焦手势只挂在标题上：挂整行会吞掉复选框的点击。
    private var titleText: some View {
        // 必须用真正的 Button，而不是 `.onTapGesture` + `.help()`：
        // macOS 上 `.help()` 会额外叠一层 tooltip 展示层，若它盖在 tap 手势之上，
        // 点击会被这层吃掉（实测点击标题无反应、而同一行的复选框点击正常）。
        // Button 自带鼠标命中与键盘 / 切换控制可达性。
        Button(action: onFocus) {
            Text(item.title)
                .font(.system(size: 13.5, weight: .semibold))
                .foregroundStyle(CC.fg)
                .lineLimit(1)
                .layoutPriority(1)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(item.title)
    }

    /// `.r-l3`：每项都是「11pt 图标 + 文字」，项间用更淡的「·」分隔。
    private var metaLine: some View {
        HStack(spacing: 7) {
            // 1. 项目路径（原型用 RTL 截断，SwiftUI 用尾部截断近似）
            metaIcon("folder")
            Text(item.displayProjectPath)
                .font(CC.F.mono)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: 200, alignment: .leading)
                .help("项目路径：\(item.displayProjectPath)")

            // 2. Git 分支：为空时整项省略，连同它前面的分隔符
            if let branch = item.gitBranch, !branch.isEmpty {
                separator
                metaIcon("arrow.triangle.branch")
                Text(branch)
                    .lineLimit(1)
                    .help("Git 分支：\(branch)")
            }

            // 3. 对话轮数
            separator
            metaIcon("bubble.left")
            Text("\(item.messageCount) 轮对话")
                .lineLimit(1)
                .help("对话轮数：\(item.messageCount)")

            // 4. 更新时间
            separator
            metaIcon("clock")
            Text(Fmt.relative(item.updatedAt))
                .lineLimit(1)
                .help("最近更新：\(Fmt.relative(item.updatedAt))")

            Spacer(minLength: 8)

            // 5. 会话 ID
            Text("#\(item.shortSessionId)")
                .font(CC.F.mono)
                .lineLimit(1)
                .help("会话 ID：\(item.sessionId)")

            // 6. 悬浮动作区
            actions
        }
    }

    private var separator: some View {
        Text("·")
            .font(CC.F.caption)
            .foregroundStyle(CC.muted.opacity(0.55))
    }

    private func metaIcon(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 11))
            .foregroundStyle(CC.muted.opacity(0.85))
            .frame(width: 11, height: 11)
    }

    /// 自绘复选框：原型 `.cbx` 的 16×16 / r4 / 1.5px 描边。
    private var checkbox: some View {
        Button {
            selection.wrappedValue.toggle()
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: CC.R.xs, style: .continuous)
                    .fill(isSelected ? CC.fg : (cbHovering ? CC.fillHair : .clear))
                RoundedRectangle(cornerRadius: CC.R.xs, style: .continuous)
                    .strokeBorder(cbBorder, lineWidth: 1.5)
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(CC.surface)
                    .opacity(isSelected ? 1 : 0)
            }
            .frame(width: 16, height: 16)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.top, 2)
        .onHover { cbHovering = $0 }
        .animation(CC.Mv.quick, value: isSelected)
        .animation(CC.Mv.quick, value: cbHovering)
        .help(isSelected ? "取消选择此会话" : "选择此会话")
        .accessibilityLabel(isSelected ? "取消选择 \(item.title)" : "选择 \(item.title)")
    }

    /// 以数据层为准读取当前勾选态，避免行值过期导致反复切换。
    private var selection: Binding<Bool> {
        Binding(
            get: { viewModel.conversations.first { $0.id == item.id }?.isSelected ?? item.isSelected },
            set: { viewModel.setItemSelected(item.id, selected: $0) }
        )
    }

    private var cbBorder: Color {
        isSelected ? CC.fg : (cbHovering ? CC.fg : CC.fg.opacity(0.34))
    }

    /// 悬浮动作区：默认透明，hover 或聚焦时出现（原型 `.r-acts`，只有一个删除按钮）。
    private var actions: some View {
        CCIconButton(
            systemImage: "trash",
            tint: CC.danger,
            enabled: !isBusy,
            size: 22,
            help: "删除此会话"
        ) {
            onDelete()
        }
        .padding(.leading, 1)   // `.r-acts{margin-left:8}` 里的 2px 内部 gap + 视觉补偿
        .opacity(showActions ? 1 : 0)
        .animation(CC.Mv.quick, value: showActions)
        .accessibilityHidden(true)
    }
}

// MARK: - 小工具

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
