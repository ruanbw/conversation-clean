import SwiftUI
import AppKit

// MARK: - DetailView（详情栏）
//
// 上下文切换：
//   无选中 → OverviewView（总占用 / 总会话数 / 存储分布）
//   有选中 → 会话元数据
//
// 焦点由 `viewModel.selectedConversation` 驱动，不再用 `.ccFocusConversation` 通知。
// 通知存在的理由是「列表与检视器各持一份焦点」，selection 驱动后焦点只有一份，
// 于是「conversations 变化时把快照换成最新的」那段同步代码也不需要了 ——
// 现取即可，会话被删后自动变 nil。
//
// 视觉基线 ui-a-precision.html 的 `.det` / `.det-scroll`，密度改法：
//   ① 底色从 `windowBackgroundColor` 换成 `Theme.bg` —— 三栏此前同色，
//      截图里就是三块白板拼贴。现在侧栏 sidebar / 列表 surface / 详情 bg，
//      详情栏是三栏里最"沉"的一层，正好把最亮的内容面让给列表。
//   ② 64pt 巨型图标 + 20pt 粗体标题砍成 28pt 图标 + 15pt 标题，
//      省下的竖向预算给了「体积读数」—— 设计稿的母题是体积第一层级。
//   ③ 元数据从 `Grid` 换成定宽标签列 + 发丝线分隔的行表，扫读时眼睛能竖着走。
//   ④ 4 个操作按钮全走 DrawnButtonStyle，不再是系统 Button + .controlSize(.large)。
//   ⑤ FileRow 的 hover 底色不再用 `nsColor.quaternaryLabelColor`
//      （系统色，深浅色下对比都不准），改走 Theme.accentWash。

/// 有第二层索引载体、删除时会连索引行一起删的 Agent。
/// 值为 nil 时整个「原子清理」分区不渲染。
private let idxNote: [ConversationCategory: String] = [
    .piAgent: "context-mode SQLite 索引行同步删除",
    .copilotChat: "state.vscdb 索引行同步删除",
    .cursor: "state.vscdb 索引行同步删除",
    .windsurf: "state.vscdb 索引行同步删除",
    .trae: "state.vscdb 索引行同步删除",
    .antigravity: "state.vscdb 索引行同步删除"
]

/// 这几款在「关联文件」里多列一条索引位置。
private let idxPath: [ConversationCategory: String] = [
    .piAgent: "~/.pi/agent/context-mode",
    .copilotChat: "state.vscdb",
    .cursor: "state.vscdb",
    .windsurf: "state.vscdb",
    .trae: "state.vscdb",
    .antigravity: "state.vscdb"
]

struct DetailView: View {
    @EnvironmentObject var viewModel: CleanViewModel
    @State private var copied = false

    /// 复制反馈的存活时长。1.5s 够读完「已复制」，又不至于让人等着确认。
    private let copyFeedbackDuration: UInt64 = 1_500_000_000

    var body: some View {
        Group {
            if let item = viewModel.selectedConversation {
                detail(item)
            } else {
                OverviewView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.bg)
        // 切到另一条会话时重置「已复制」文案
        .onChange(of: viewModel.selectedConversationID) { _, _ in copied = false }
    }

    private func detail(_ item: ConversationItem) -> some View {
        // 关联文件算一次，元数据表和文件表共用 —— 原来的实现两处各算一遍，
        // 靠"两边结果必然相同"维持一致。
        let paths = relatedPaths(for: item)

        return ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.ll) {
                header(item)
                    .padding(.bottom, Theme.Space.xs)
                    .hairline(.bottom)
                metadata(item, paths: paths)
                // 摘要为空时整区不显示
                if !item.snippet.isEmpty {
                    snippet(item)
                }
                if let note = idxNote[item.category] {
                    atomicNote(note)
                }
                files(paths)
                actions(item)
            }
            .padding(.horizontal, Theme.Space.xl)
            .padding(.top, Theme.Space.xl)
            .padding(.bottom, Theme.Space.huge)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - 区块标题
    //
    // 不用 `SectionLabel`：它是侧栏那套「11pt 大写 + 左右 6pt 内边距」的微标签，
    // 详情栏的分区标题在设计稿里是 12pt semibold 的 t1（`.dt`），
    // 大写化在这个栏位反而变噪声。`Theme.Typo.sectionHeadStrong` 正是那一档。

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(Theme.Typo.sectionHeadStrong)
            .foregroundStyle(Theme.t1)
    }

    // MARK: - 头部
    //
    // 64pt 徽章 + 20pt 粗体标题占了近 100pt 竖向，只为显示一个 app 图标。
    // 现在图标 28pt、标题 15pt，省下的空间给右侧的体积读数 ——
    // 这是一个"清理占空间的数据"的工具，体积就该是这一栏的第一视觉层级。

    private func header(_ item: ConversationItem) -> some View {
        HStack(alignment: .top, spacing: Theme.Space.l) {
            AgentIconView(category: item.category, size: 28)

            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                Text(item.title)
                    .font(Theme.Typo.cardTitle)
                    .foregroundStyle(Theme.t1)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: Theme.Space.s) {
                    chip(item.category.rawValue)
                    // 轮数与日期走 tabular-nums，与下面的体积读数同口径
                    Text("\(item.messageCount) 轮")
                        .font(Theme.Typo.num(11))
                        .foregroundStyle(Theme.t2)
                    Text("·")
                        .font(Theme.Typo.rowSub)
                        .foregroundStyle(Theme.t3)
                    Text(Fmt.relative(item.updatedAt))
                        .font(Theme.Typo.rowSub)
                        .foregroundStyle(Theme.t3)
                }
                .padding(.top, 1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            sizeReadout(item)
        }
    }

    /// 体积读数：数值与单位分排两种字号，照设计稿体检卡的做法
    /// （`52.3` 用 20pt semibold、`MB` 用 10.5pt），拼成一个字符串就分不出层级了。
    private func sizeReadout(_ item: ConversationItem) -> some View {
        let parts = Fmt.splitValue(item.sizeInBytes)
        return VStack(alignment: .trailing, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(parts.0)
                    .font(Theme.Typo.num(21, .semibold))
                    .foregroundStyle(Theme.t1)
                Text(parts.1)
                    .font(Theme.Typo.num(10, .semibold))
                    .foregroundStyle(Theme.t3)
            }
            Text("占用空间")
                .font(Theme.Typo.rowSub)
                .foregroundStyle(Theme.t3)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("占用空间 \(item.formattedSize)")
    }

    /// 靛蓝淡底 + 靛蓝淡边的小胶囊。原来的 `Color.secondary.opacity(0.15)` + Capsule
    /// 是一坨中性灰，在这一栏里没有任何指向性。
    private func chip(_ text: String) -> some View {
        Text(text)
            .font(Theme.Typo.rowSub)
            .foregroundStyle(Theme.accent)
            .padding(.horizontal, Theme.Space.s)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous)
                    .fill(Theme.accentSoft)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous)
                    .strokeBorder(Theme.accentEdge, lineWidth: 1)
            )
    }

    // MARK: - 元数据
    //
    // 从 `Grid` 换掉。Grid 的两列宽度跟着内容走，长路径会把值列推出去，
    // 标签列也随之变宽，扫读时标签基线是斜的 —— 竖着扫就散了。
    // 现在标签列钉死 60pt 右对齐（行内最长标签「最后更新」够放），
    // 行间加 1px 发丝线，标签列与值列各自成一条竖向节奏。

    private func metadata(_ item: ConversationItem, paths: [String]) -> some View {
        let rows = metaRows(item, paths: paths)
        return VStack(alignment: .leading, spacing: Theme.Space.s) {
            sectionTitle("元数据")
            VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                    metaRow(row, isFirst: index == 0)
                }
            }
            .cardSurface()
        }
    }

    private func metaRows(_ item: ConversationItem, paths: [String]) -> [MetaRow] {
        [
            MetaRow(id: "size", label: "占用空间", value: item.formattedSize, kind: .num),
            MetaRow(id: "msgs", label: "对话轮数", value: "\(item.messageCount)", kind: .num),
            MetaRow(id: "files", label: "关联文件", value: "\(paths.count)", kind: .num),
            MetaRow(id: "updated", label: "最后更新", value: Fmt.full(item.updatedAt), kind: .plain),
            MetaRow(id: "branch", label: "Git 分支", value: item.gitBranch ?? "", kind: .mono),
            MetaRow(id: "project", label: "项目路径", value: item.displayProjectPath, kind: .mono),
            MetaRow(id: "store", label: "存储路径", value: storagePath(for: item), kind: .mono),
            MetaRow(id: "session", label: "会话 ID", value: item.sessionId, kind: .mono)
        ]
    }

    private func metaRow(_ row: MetaRow, isFirst: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.m) {
            Text(row.label)
                .font(Theme.Typo.rowSub)
                .foregroundStyle(Theme.t3)
                .frame(width: 58, alignment: .trailing)

            Text(row.value.isEmpty ? "—" : row.value)
                .font(row.font)
                .foregroundStyle(row.value.isEmpty ? Theme.t3 : Theme.t1)
                .textSelection(.enabled)
                // 长路径在任意字符处折行，不能只行尾省略
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, Theme.Space.l)
        .padding(.vertical, 6)
        // 不用 Divider()：它的默认色跟着系统材质走，在 Theme.bg 上深浅色都对不准
        .overlay(alignment: .top) {
            if !isFirst {
                Rectangle().fill(Theme.line).frame(height: 1)
            }
        }
    }

    private func storagePath(for item: ConversationItem) -> String {
        let raw = viewModel.agentInfos.first { $0.category == item.category }?.storagePath ?? ""
        return Fmt.abbreviateHome(raw)
    }

    // MARK: - 摘要

    private func snippet(_ item: ConversationItem) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            sectionTitle("摘要")
            Text(item.snippet)
                .font(Theme.Typo.navItem)
                .foregroundStyle(Theme.t2)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Theme.Space.l)
                .cardSurface()
        }
    }

    // MARK: - 原子清理（仅 idxNote 命中的 Agent）

    private func atomicNote(_ note: String) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            sectionTitle("原子清理")
            HStack(alignment: .top, spacing: Theme.Space.s) {
                Image(systemName: "info.circle")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                Text("\(note)，不会留下幽灵会话。")
                    .font(Theme.Typo.rowSub)
                    .foregroundStyle(Theme.t2)
                    .lineSpacing(1.5)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(Theme.Space.l)
            // 靛蓝淡底 = 这一栏唯一的彩色块，和上面两张白卡拉开层次
            .tintedSurface()
        }
    }

    // MARK: - 关联文件（点击复制路径）

    private func files(_ paths: [String]) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            sectionTitle("关联文件")
            VStack(spacing: 0) {
                ForEach(Array(paths.enumerated()), id: \.element) { index, path in
                    FileRow(path: path) { viewModel.copyToClipboard(text: path) }
                        .overlay(alignment: .top) {
                            if index > 0 {
                                Rectangle().fill(Theme.line).frame(height: 1)
                            }
                        }
                }
            }
            // 先裁圆角再上卡面：hover 底色才不会从卡片的圆角外溢出去
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
            .cardSurface()
        }
    }

    /// 优先用扫描器给出的真实 `associatedPaths`；拿不到时按
    /// `<project>/.session` → `<agent.storagePath>/<sessionId>.jsonl` → 索引位置 拼。
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

    // MARK: - 操作
    //
    // 2×2 网格。原来是 4 个 `.controlSize(.large)` 的系统按钮竖着排，
    // 既高又和自绘部分割裂（系统灰底 + 系统圆角 + 系统字号）。
    // 现在四个全走 DrawnButtonStyle：三个次要动作 ghost，删除 danger 实心红 ——
    // 不可逆的动作在视觉上必须自己跳出来，不该和"复制路径"平级。

    private func actions(_ item: ConversationItem) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            sectionTitle("操作")
            VStack(spacing: Theme.Space.m) {
                HStack(spacing: Theme.Space.m) {
                    actionButton("在 Finder 中显示", "folder", .ghost, enabled: true) {
                        viewModel.revealInFinder(item: item)
                    }
                    actionButton("复制项目路径", "doc.on.doc", .ghost,
                                 enabled: !item.displayProjectPath.isEmpty) {
                        viewModel.copyToClipboard(text: item.displayProjectPath)
                    }
                }
                HStack(spacing: Theme.Space.m) {
                    actionButton(copied ? "已复制" : "复制会话 ID",
                                 copied ? "checkmark" : "number",
                                 .ghost, enabled: true) {
                        viewModel.copyToClipboard(text: item.sessionId)
                        copied = true
                        Task {
                            try? await Task.sleep(nanoseconds: copyFeedbackDuration)
                            copied = false
                        }
                    }
                    actionButton("删除此会话", "trash", .danger,
                                 enabled: !viewModel.isCleaning) {
                        Task { await viewModel.deleteSingle(item: item) }
                    }
                }
            }
        }
    }

    private func actionButton(_ title: String, _ symbol: String,
                              _ variant: DrawnButtonVariant,
                              enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: Theme.Space.xs) {
                Image(systemName: symbol)
                    .font(.system(size: 10, weight: .medium))
                Text(title)
                    .font(Theme.Typo.rowTitle)
                    .lineLimit(1)
                    .minimumScaleFactor(0.9)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(DrawnButtonStyle(
            variant: variant,
            horizontalPadding: Theme.Space.m,
            enabled: enabled))
        .disabled(!enabled)
    }
}

// MARK: - 元数据行模型

/// 一行元数据。`kind` 决定值的排版：路径 / ID 走等宽，数字走 tabular-nums，
/// 其余走正文。
private struct MetaRow: Identifiable {
    enum Kind {
        case mono, num, plain
    }

    let id: String
    let label: String
    let value: String
    let kind: Kind

    var font: Font {
        switch kind {
        case .mono:  return Theme.Typo.mono(11)
        case .num:   return Theme.Typo.num(12, .medium)
        case .plain: return Theme.Typo.rowTitle
        }
    }
}

// MARK: - 关联文件行

private struct FileRow: View {
    let path: String
    let onCopy: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: onCopy) {
            HStack(spacing: Theme.Space.s) {
                Image(systemName: isPlainFile ? "doc" : "folder")
                    .font(Theme.Typo.tiny)
                    .foregroundStyle(hovering ? Theme.accent : Theme.t3)
                    .frame(width: 12)
                Text(path)
                    .font(Theme.Typo.mono(11))
                    .foregroundStyle(hovering ? Theme.accent : Theme.t1)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: Theme.Space.xs)
                // hover 才出现的复制提示：常驻一个图标是在跟标题抢注意力
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(Theme.accent)
                    .opacity(hovering ? 1 : 0)
            }
            .padding(.horizontal, Theme.Space.l)
            .frame(height: Theme.Size.rowCompact)
            .background {
                RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous)
                    .fill(hovering ? Theme.accentWash : .clear)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("复制路径：\(path)")
        .animation(.easeOut(duration: 0.10), value: hovering)
    }

    /// 索引载体（`state.vscdb`）没有目录层级，用文件夹图标是错的。
    private var isPlainFile: Bool { !path.contains("/") }
}
