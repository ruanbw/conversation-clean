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

    /// 请求打开检视器面板（原型 `if(!P.panel){ P.panel=true; }`）。
    /// 由 ContentView 注入，点击行时自动展开第三栏。
    var onRequestInspector: (() -> Void)? = nil

    /// 排序方式，持久化（原型 `P.sort` 存 `localStorage`，默认 `date`）。
    @AppStorage("listSortMode") private var sortRaw: String = ListSortMode.date.rawValue
    @State private var focusedID: UUID?

    /// 非法值（`UserDefaults` 里是旧版本留下的）回落默认，不让它传播成空列表。
    private var sort: ListSortMode {
        ListSortMode(rawValue: sortRaw) ?? .date
    }

    /// 提到外面避免类型检查超时：`CCSegmented` 的泛型 + `map` 写在 body 里
    /// 会把整个 `contentHead` 表达式树的推断成本拉爆。
    private var sortOptions: [CCSegmented<ListSortMode>.Option] {
        ListSortMode.allCases.map { CCSegmented<ListSortMode>.Option(value: $0, label: $0.label) }
    }

    /// 写回 `@AppStorage` 用的绑定。
    private var sortBinding: Binding<ListSortMode> {
        Binding(
            get: { sort },
            set: { sortRaw = $0.rawValue }
        )
    }

    private var isBusy: Bool { viewModel.isScanning || viewModel.isCleaning }
    private var rows: [ConversationItem] { sorted }
    private var hasQuery: Bool { !viewModel.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        VStack(spacing: 0) {
            // 纵向顺序严格照抄原型 DOM（docs/prototype.html 559-607）：
            //   .content-head → .sbar → .banner.ok → .list / .empty → .batchbar
            // 之前把进度条和横幅提到了 contentHead 之前，于是「全部会话」这一行
            // 会被两条带子顶下去、且位置随忙碌状态上下跳 —— 标题行在 macOS 上
            // 是窗口里的固定锚点，不该动。
            contentHead
            progressStrip
            successBanner
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
            CCProgressLine()
                .transition(.opacity)
        }
    }



    @ViewBuilder
    private var successBanner: some View {
        if viewModel.showCleanSuccessAlert {
            // 原型 `.banner.ok`：accent-soft 背景 + 16px 图标 + 24pt 高按钮
            CCRichBanner(tone: .ok) {
                Text("清理完成 · 删除 ")
                + Text("\(viewModel.lastCleanedCount)")
                    .font(CC.F.num(12, .semibold))
                    .foregroundStyle(CC.ok)
                + Text(" 个会话，释放 ")
                + Text(Fmt.bytes(viewModel.lastCleanedBytes))
                    .font(CC.F.num(12, .semibold))
                    .foregroundStyle(CC.ok)
                + Text(" 磁盘空间，剩余 ")
                + Text("\(viewModel.conversations.count)")
                    .font(CC.F.num(12, .semibold))
                    .foregroundStyle(CC.ok)
                + Text(" 个会话。")
            } trailing: {
                CCButton(title: "知道了", kind: .ghost, height: 24, help: "关闭提示") {
                    withAnimation(CC.Mv.base) { viewModel.showCleanSuccessAlert = false }
                }
            }
            .transition(.opacity)
        } else if viewModel.showScanSuccessAlert {
            // 原型 `flashOk("扫描完成 · 命中 N 个会话，合计 X。")`
            CCRichBanner(tone: .ok) {
                Text("扫描完成 · 命中 ")
                + Text("\(viewModel.scanSuccessCount)")
                    .font(CC.F.num(12, .semibold))
                    .foregroundStyle(CC.ok)
                + Text(" 个会话，合计 ")
                + Text(Fmt.bytes(viewModel.scanSuccessBytes))
                    .font(CC.F.num(12, .semibold))
                    .foregroundStyle(CC.ok)
                + Text("。")
            } trailing: {
                CCButton(title: "知道了", kind: .ghost, height: 24, help: "关闭提示") {
                    withAnimation(CC.Mv.base) { viewModel.showScanSuccessAlert = false }
                }
            }
            .transition(.opacity)
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
                options: sortOptions,
                selection: sortBinding
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
                        onToggleSelect: { viewModel.setItemSelected(item.id, selected: !item.isSelected) },
                        onDelete: { requestDelete(item) }
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
                path: path,
                pathLabel: "存储路径："
            ) {
                rescanButton
            }
        } else if viewModel.conversations.isEmpty {
            CCEmptyState(
                systemImage: viewModel.selectedCategory.iconName,
                title: "暂无 \(viewModel.selectedCategory.rawValue) 会话记录",
                message: "未在本地检测到任何 Agent 历史会话文件，或所有会话均已被清理。",
                path: viewModel.selectedCategory == .all ? nil : path,
                pathLabel: "存储路径："
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
                path: path,
                pathLabel: "存储路径："
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

            // 原型 renderBatch()：文案带条数，「清理选中项（3）」。
            // 没有条数时按钮看着像个泛泛的操作，加了之后用户能一眼确认要删几个。
            CCButton(
                title: cleanSelectedTitle,
                systemImage: "trash",
                kind: .danger,
                enabled: !disabled,
                help: "删除选中的会话及其关联缓存"
            ) {
                requestCleanSelected()
            }
        }
        .padding(.init(top: 11, leading: 20, bottom: 11, trailing: 20))
        // 原型 `.batchbar{background:color-mix(in oklch,var(--bg) 45%,var(--surface))}`
        .background(CC.bg.opacity(0.45))
        .ccHairline(.top)
    }

    /// 原型：`"清理选中项"+(sel.length? "（"+sel.length+"）":"")`
    private var cleanSelectedTitle: String {
        let n = viewModel.selectedItems.count
        return n > 0 ? "清理选中项（\(n)）" : "清理选中项"
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
    /// 点击行时如果检视器未打开，自动展开（原型 `if(!P.panel){ P.panel=true; }`）。
    private func toggleFocus(_ item: ConversationItem) {
        let shouldOpenInspector = focusedID != item.id
        setFocus(focusedID == item.id ? nil : item)
        if shouldOpenInspector {
            onRequestInspector?()
        }
    }

    private func requestCleanSelected() {
        viewModel.requestCleanSelected()
    }

    /// 行内删除 / 右键删除。保持原来的直接删除，不改行为。
    private func deleteRow(_ item: ConversationItem) async {
        await viewModel.deleteSingle(item: item)
        if focusedID == item.id { setFocus(nil) }
    }

    private func requestDelete(_ item: ConversationItem) {
        Task { await deleteRow(item) }
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
    let onToggleSelect: () -> Void
    let onDelete: () -> Void

    @State private var hovering = false
    @State private var cbHovering = false
    /// 原型 `list.addEventListener("keydown")`：行是 `tabindex="0"` 的可聚焦元素，
    /// Space 切换勾选、Enter 聚焦并展开检视器。没有这个状态行就收不到键盘事件。
    @FocusState private var keyboardFocused: Bool

    private var isSelected: Bool { item.isSelected }
    private var showActions: Bool { hovering || isFocused || keyboardFocused }

    var body: some View {
        // 修饰符链分三段挂：背景/无障碍/焦点/键盘/菜单。
        // 一次全挂上去时表达式树过大，编译器推不出类型。
        rowLayout
            .background { rowBackground }
            .contentShape(RoundedRectangle(cornerRadius: CC.R.md, style: .continuous))
            .overlay { focusBorder }
            .onHover { hovering = $0 }
            .animation(CC.Mv.quick, value: hovering)
            .animation(CC.Mv.quick, value: isSelected)
            .animation(CC.Mv.quick, value: isFocused)
            .accessibilityElement(children: .contain)
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(item.title)
            .accessibilityValue(item.formattedSize)
            .accessibilityHint("空格选择，回车查看详情")
        .rowInteraction(
            keyboardFocused: $keyboardFocused,
            onToggleSelect: onToggleSelect,
            onConfirm: onFocus
        )
        .contextMenu { rowMenu }
    }

    /// 状态底色 + 整行点击热区（在背景层，见 `rowHitArea` 的注释）。
    private var rowBackground: some View {
        ZStack {
            RoundedRectangle(cornerRadius: CC.R.md, style: .continuous)
                .fill(isFocused || isSelected ? CC.fillSoft : (hovering ? CC.fillHair : .clear))
            rowHitArea
        }
    }

    /// 聚焦描边。原型 `.row.focus{border-color:fg 34%}`。
    private var focusBorder: some View {
        RoundedRectangle(cornerRadius: CC.R.md, style: .continuous)
            .strokeBorder(isFocused ? CC.fg.opacity(0.34) : .clear, lineWidth: 1)
    }

    /// 行的内容骨架，与修饰符链分开。
    ///
    /// 拆开是**编译需要**：修饰符链（背景 / overlay / 焦点 / 两个 onKeyPress /
    /// 无障碍 / contextMenu）挂在同一个 HStack 之后时，整条表达式树大到 Swift
    /// 编译器在合理时间内推不出类型，报 "unable to type-check this expression"。
    /// 骨架单独成一个属性后，两边各自都小得能推完。
    private var rowLayout: some View {
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
    }

    /// 原型 `openCtx()` 的四项，顺序照抄。
    /// 每项执行前先 `onFocus()`：原型是在 `contextmenu` 事件里就把焦点设上，
    /// 而 `.contextMenu` 没有「即将弹出」的回调，只能退到执行时同步。
    @ViewBuilder
    private var rowMenu: some View {
        Button("在 Finder 中显示", systemImage: "folder") {
            onFocus()
            viewModel.revealInFinder(item: item)
        }
        Button("复制项目路径", systemImage: "doc.on.doc") {
            onFocus()
            viewModel.copyToClipboard(text: item.displayProjectPath)
        }
        Button("复制会话 ID", systemImage: "number") {
            onFocus()
            viewModel.copyToClipboard(text: item.sessionId)
        }
        Divider()
        Button("删除此会话", systemImage: "trash", role: .destructive) {
            onFocus()
            onDelete()
        }
    }

    // MARK: 行内零件

    /// `.tag`：mono 小字 + 1px 描边的分类标签，排在标题之前。
    private var tag: some View {
        CCBadge(text: item.category.rawValue, tone: .neutral, mono: true, outlined: true, cornerRadius: CC.R.xs)
            .lineLimit(1)
            .fixedSize()
            .help("所属分类：\(item.category.rawValue)")
    }

    /// 标题可点击聚焦。
    ///
    /// 必须用真正的 Button，而不是 `.onTapGesture` + `.help()`：
    /// macOS 上 `.help()` 会额外叠一层 tooltip 展示层，若它盖在 tap 手势之上，
    /// 点击会被这层吃掉（实测点击标题无反应、而同一行的复选框点击正常）。
    /// Button 自带鼠标命中与键盘 / 切换控制可达性。
    private var titleText: some View {
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

    /// 铺满整行的点击热区。
    ///
    /// 原型 `.row` 的 list click 处理器里，只要不落在 `[data-act]`（复选框 / 删除）
    /// 上就聚焦该行并展开检视器 —— 摘要行、元信息行、行尾空白都算。实现之前只有
    /// 标题可点，右侧大片区域点了没反应。
    ///
    /// **必须挂在 `.background` 而不是 `.overlay`**：这层是透明矩形，
    /// 放在内容之上会把子 Button（复选框、删除）的鼠标命中一起吃掉，
    /// 而原型明确要求这两个按钮优先于行的聚焦行为。放到底下则相反 ——
    /// 内容先命中，没命中内容的地方才落到热区。
    private var rowHitArea: some View {
        Color.clear
            .contentShape(Rectangle())
            .onTapGesture(perform: onFocus)
    }

    /// `.r-l3`：每项都是「11pt 图标 + 文字」，项间用更淡的「·」分隔。
    private var metaLine: some View {
        HStack(spacing: 7) {
            // 1. 项目路径 —— 只显示末两级（`Fmt.pathTail`），前缀 `…/`。
            // 原型 `shortPath()` 就是这个口径；CSS 再叠一层 `direction:rtl` 只是溢出兜底。
            // 之前显示整条路径再从尾部截断，砍掉的恰是末两级 ——
            // 而末两级才是区分同名项目的唯一信息。
            metaIcon("folder")
            Text(Fmt.pathTail(item.displayProjectPath))
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

// MARK: - 行交互（键盘）

/// 原型 `list.addEventListener("keydown")` 的两条分支 + `tabindex="0"`。
///
/// 单独抽成 `ViewModifier` 有两个原因：
///   1. **编译需要** —— 焦点 + 两个 `onKeyPress` 挂在行主体上时，表达式树大到
///      Swift 编译器推不出类型（"unable to type-check this expression"）。
///   2. 这几条是**键盘焦点态的唯一消费者**，装进修饰符后 `@FocusState` 的读写
///      范围跟着修饰符走，不用担心行视图里其它代码误读。
private struct RowInteractionModifier: ViewModifier {
    @FocusState.Binding var keyboardFocused: Bool
    let onToggleSelect: () -> Void
    let onConfirm: () -> Void

    func body(content: Content) -> some View {
        content
            // `.focusEffectDisabled()`：原型用 `.row.focus` 自己画一圈 34% fg 描边
            // 表示键盘焦点，系统焦点环会叠在上面变成双圈。
            .focusable()
            .focusEffectDisabled()
            .focused($keyboardFocused)
            .onKeyPress(.space) {
                onToggleSelect()
                return .handled
            }
            // `.return` 而不是 `.enter`：`KeyEquivalent` 里没有 `enter` 这个静态成员，
            // 回车键的名字就是 `.return`。
            .onKeyPress(.return) {
                onConfirm()
                return .handled
            }
    }
}

private extension View {
    func rowInteraction(
        keyboardFocused: FocusState<Bool>.Binding,
        onToggleSelect: @escaping () -> Void,
        onConfirm: @escaping () -> Void
    ) -> some View {
        modifier(RowInteractionModifier(
            keyboardFocused: keyboardFocused,
            onToggleSelect: onToggleSelect,
            onConfirm: onConfirm
        ))
    }
}

// MARK: - 小工具

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
