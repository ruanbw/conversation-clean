import SwiftUI
import Combine

// MARK: - Inspector panel（原型 `.inspector`）
//
// 右侧详情面板，逐字对应原型 `renderInspector()`（docs/prototype.html 约 891 行）：
// 头部 `.insp-h` / `.insp-sub` → 元数据 `.kv` → 摘要 → 原子清理 `.insp-note`
// → 关联文件 `.flist` → 操作 `.insp-acts`。
// 焦点由列表模块通过 `.ccFocusConversation` 通知推入，面板自身不持有列表选择状态，
// 因此两边的刷新节奏互不干扰。

/// 原型 AGENTS 表的 `idxNote` 字段：只有这几个 Agent 有索引需要同步删行，
/// 其余没有 —— 值为 nil 时整个「原子清理」分区不渲染。
private let idxNote: [ConversationCategory: String] = [
    .piAgent: "context-mode SQLite 索引行同步删除",
    .copilotChat: "state.vscdb 索引行同步删除",
    .cursor: "state.vscdb 索引行同步删除",
    .windsurf: "state.vscdb 索引行同步删除",
    .trae: "state.vscdb 索引行同步删除",
    .antigravity: "state.vscdb 索引行同步删除"
]

/// 原型 AGENTS 表的 `idx` 字段：有索引的 Agent 会在「关联文件」里多列一条索引位置。
private let idxPath: [ConversationCategory: String] = [
    .piAgent: "~/.pi/agent/context-mode",
    .copilotChat: "state.vscdb",
    .cursor: "state.vscdb",
    .windsurf: "state.vscdb",
    .trae: "state.vscdb",
    .antigravity: "state.vscdb"
]

struct InspectorPanel: View {

    @EnvironmentObject var viewModel: CleanViewModel

    /// 当前聚焦的会话快照；nil = 空态。
    @State private var focused: ConversationItem?
    /// 复制会话 ID 后的短暂文案反馈。
    @State private var copied = false

    /// ScrollView 顶部锚点，用于切换会话时把面板滚回顶部。
    private static let topAnchor = "ccInspectorTop"

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Color.clear.frame(height: 0).id(Self.topAnchor)
                    content
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.init(top: 16, leading: 18, bottom: 20, trailing: 18))
            }
            .background(CC.panel)
            .ccHairline(.leading)
            .onChange(of: focused?.id) { _, _ in
                copied = false
                withAnimation(CC.Mv.base) { proxy.scrollTo(Self.topAnchor, anchor: .top) }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .ccFocusConversation)) { note in
            focused = note.object as? ConversationItem
        }
        .onChange(of: viewModel.selectedCategory) {
            // 换分类等于换整份列表，旧焦点失效（对齐原型 setCat 清空 focusId）
            focused = nil
        }
        .onChange(of: viewModel.conversations) {
            // 重新扫描后用最新快照替换，避免面板显示过期标题 / 体积；被删掉的项自动清空
            let list = viewModel.conversations
            guard let id = focused?.id else { return }
            focused = list.first { $0.id == id }
        }
    }

    // MARK: - 内容

    @ViewBuilder private var content: some View {
        if let item = focused {
            VStack(alignment: .leading, spacing: 0) {
                header(item)
                metadata(item).inspectorSectionGap()
                // 摘要为空时整区不显示，对应原型「摘要」段落无内容
                if !item.snippet.isEmpty {
                    snippet(item).inspectorSectionGap()
                }
                if let note = idxNote[item.category] {
                    atomicNote(note).inspectorSectionGap()
                }
                files(item).inspectorSectionGap()
                actions(item).inspectorSectionGap()
            }
            // 关闭按钮：原型 CSS 留了 `.inspector .close{position:absolute}` 这条规则，
            // 但 renderInspector() 没渲染对应元素。实际使用里「收起面板」是高频动作，
            // 只靠工具栏的「检视器」开关太远，这里按那条 CSS 的意图补回来。
            .overlay(alignment: .topTrailing) {
                CCIconButton(
                    systemImage: "xmark",
                    size: 22,
                    help: "关闭详情"
                ) {
                    focused = nil
                }
                .offset(x: 6, y: -4)
            }
        } else {
            // 原型空态只是一行 `.ov-note` 说明文字，没有图标也没有大标题
            Text("选择一条会话以查看完整元数据、关联文件与索引同步说明。")
                .font(CC.F.caption)
                .foregroundStyle(CC.muted)
                .lineSpacing(2.75)          // .ov-note line-height:1.45
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 8)      // 内联样式 padding:8px 0
        }
    }

    // MARK: - 头部（`.insp-h` + `.insp-sub`）

    private func header(_ item: ConversationItem) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 9) {
                // `.insp-h .gi` 是 19px 的裸图标（不是圆形徽章），上移 2px 对齐标题首行
                Image(systemName: item.category.iconName)
                    .font(.system(size: 19))
                    .foregroundStyle(CC.fg)
                    .frame(width: 19, height: 19)
                    .padding(.top, 2)
                Text(item.title)
                    .font(CC.F.title)
                    .tracking(-0.18)        // 原型 letter-spacing:-.012em @15px
                    .foregroundStyle(CC.fg)
                    .lineSpacing(2.25)      // 原型 line-height:1.35
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.bottom, 3)            // .insp-h margin-bottom:3px

            HStack(spacing: 7) {
                CCBadge(text: item.category.rawValue, mono: true, outlined: true, cornerRadius: CC.R.xs)
                // 注意是体积不是时间：列表第 3 行才用相对时间，检视器头部只给体积
                Text(item.formattedSize)
                    .font(CC.F.num(11, .regular))
                    .foregroundStyle(CC.muted)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.top, 7)                // .insp-sub margin:7px 0 0
        }
    }

    // MARK: - 元数据（`.kv`）

    private func metadata(_ item: ConversationItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            CCSectionHeader("元数据")
            // 原型 grid-template-columns:76px 1fr; gap:7px 10px
            Grid(alignment: .topLeading, horizontalSpacing: 10, verticalSpacing: 7) {
                kvRow("会话 ID", item.sessionId, font: CC.F.mono)
                kvRow("项目路径", item.displayProjectPath, font: CC.F.mono)
                kvRow("Git 分支", item.gitBranch ?? "", font: CC.F.mono)
                kvRow("对话轮数", "\(item.messageCount)", font: CC.F.num(12, .regular))
                kvRow("最后更新", Fmt.full(item.updatedAt), font: CC.F.num(12, .regular))
                kvRow("存储路径", storagePath(for: item), font: CC.F.mono)
            }
        }
    }

    /// 标签列固定 76pt；值为空回落 `—`。
    private func kvRow(_ label: String, _ value: String, font: Font) -> some View {
        GridRow {
            Text(label)
                .font(CC.F.caption)
                .foregroundStyle(CC.muted)
                .frame(width: 76, alignment: .leading)
            // `.kv dd{word-break:break-all}`：长路径要在任意字符处折行，不能只行尾省略
            Text(value.isEmpty ? "—" : value)
                .font(font)
                .foregroundStyle(CC.fg)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func storagePath(for item: ConversationItem) -> String {
        let raw = viewModel.agentInfos.first { $0.category == item.category }?.storagePath ?? ""
        return Fmt.abbreviateHome(raw)
    }


    // MARK: - 摘要（原型是纯文本段落，不是卡片）

    private func snippet(_ item: ConversationItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            CCSectionHeader("摘要")
            Text(item.snippet)
                .font(CC.F.label)
                .foregroundStyle(CC.muted)
                .lineSpacing(3.6)              // 原型 line-height:1.6 @12px
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - 原子清理（`.insp-note`，仅 idxNote 命中的 Agent 才出现）

    private func atomicNote(_ note: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            CCSectionHeader("原子清理")
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "info.circle")
                    .font(.system(size: 14))
                    .foregroundStyle(CC.muted)
                    .padding(.top, 2)
                Text("\(note)，不会留下幽灵会话。")
                    .font(.system(size: 11.5))
                    .foregroundStyle(CC.fg)
                    .lineSpacing(2.25)         // 原型 line-height:1.5
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.init(top: 9, leading: 10, bottom: 9, trailing: 10))
            .background(RoundedRectangle(cornerRadius: CC.R.sm, style: .continuous).fill(CC.fillSoft))
        }
    }

    // MARK: - 关联文件（`.flist` / `.fitem`；点击是**复制路径**，不是 Finder 定位）

    private func files(_ item: ConversationItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            CCSectionHeader("关联文件")
            VStack(spacing: 2) {                 // .flist gap:2px
                ForEach(relatedPaths(for: item), id: \.self) { path in
                    FileRow(path: path) {
                        viewModel.copyToClipboard(text: path)
                    }
                }
            }
        }
    }

    /// 优先用扫描器给出的真实 `associatedPaths`；拿不到时按原型 `files` 的规则拼：
    /// `<project>/.session` → `<agent.storagePath>/<sessionId>.jsonl` → 索引位置。
    private func relatedPaths(for item: ConversationItem) -> [String] {
        if !item.associatedPaths.isEmpty {
            return item.associatedPaths.map(Fmt.abbreviateHome)
        }
        var out: [String] = []
        if let proj = item.projectPath, !proj.isEmpty {
            out.append(Fmt.abbreviateHome(proj) + "/.session")
        }
        let agentPath = storagePath(for: item)
        if !agentPath.isEmpty {
            out.append(agentPath + "/" + item.sessionId + ".jsonl")
        }
        if let idx = idxPath[item.category] { out.append(idx) }
        return out
    }

    // MARK: - 操作（`.insp-acts`，4 个全宽左对齐按钮）

    private func actions(_ item: ConversationItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            CCSectionHeader("操作")
            VStack(spacing: 5) {                 // .insp-acts gap:5px
                actRow {
                    CCButton(
                        title: "在 Finder 中显示",
                        systemImage: "folder",
                        height: 30,              // 原型 .insp-acts .btn{height:30px}
                        help: "在访达中定位该会话的文件位置"
                    ) {
                        viewModel.revealInFinder(item: item)
                    }
                }

                actRow {
                    CCButton(
                        title: "复制项目路径",
                        systemImage: "doc.on.doc",
                        height: 30,
                        enabled: !item.displayProjectPath.isEmpty,
                        help: "复制项目路径到剪贴板"
                    ) {
                        viewModel.copyToClipboard(text: item.displayProjectPath)
                    }
                }

                actRow {
                    CCButton(
                        title: copied ? "已复制" : "复制会话 ID",
                        systemImage: "doc.on.doc",
                        height: 30,
                        help: "复制会话 ID 到剪贴板"
                    ) {
                        viewModel.copyToClipboard(text: item.sessionId)
                        copied = true
                        // 1.5s 后回落文案；期间切走面板也会被 onChange 重置
                        Task {
                            try? await Task.sleep(nanoseconds: 1_500_000_000)
                            copied = false
                        }
                    }
                    .animation(CC.Mv.quick, value: copied)
                }

                actRow {
                    CCButton(
                        title: "删除此会话",
                        systemImage: "trash",
                        kind: .dangerOutline,
                        height: 30,
                        enabled: !viewModel.isCleaning,
                        help: "删除该会话及其关联快照"
                    ) {
                        Task {
                            await viewModel.deleteSingle(item: item)
                            focused = nil
                        }
                    }
                }
            }
        }
    }

    /// 原型 `.insp-acts .btn{justify-content:flex-start}`：按钮自身不撑满，
    /// 尾部 Spacer 把整行顶到左边。
    private func actRow<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 0) {
            content()
            Spacer(minLength: 0)
        }
    }
}

// MARK: - 关联文件行（`.fitem`）

private struct FileRow: View {
    let path: String
    let onCopy: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: onCopy) {
            HStack(spacing: 7) {
                Image(systemName: "folder")
                    .font(.system(size: 12))
                    .foregroundStyle(CC.muted.opacity(0.8))
                Text(path)
                    .font(CC.F.mono)
                    .foregroundStyle(hovering ? CC.fg : CC.muted)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .padding(.init(top: 6, leading: 7, bottom: 6, trailing: 7))
            .background(
                RoundedRectangle(cornerRadius: CC.R.sm, style: .continuous)
                    .fill(hovering ? CC.fillHair : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("复制路径")
    }
}

private extension View {
    /// 原型 `.insp-sec{margin-top:18px; padding-top:14px; border-top:1px solid var(--border)}`
    /// 是**一条规则作用于每个分区**，所以头部之后的第一个分区（元数据）也带这条发丝线。
    func inspectorSectionGap() -> some View {
        padding(.top, 18)
            .ccHairline(.top)
            .padding(.top, 14)
    }
}
