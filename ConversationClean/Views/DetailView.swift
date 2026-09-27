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

    var body: some View {
        Group {
            if let item = viewModel.selectedConversation {
                detail(item)
            } else {
                OverviewView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        // 切到另一条会话时重置「已复制」文案
        .onChange(of: viewModel.selectedConversationID) { _, _ in copied = false }
    }

    private func detail(_ item: ConversationItem) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header(item)
                Divider()
                metadata(item)
                // 摘要为空时整区不显示
                if !item.snippet.isEmpty {
                    snippet(item)
                }
                if let note = idxNote[item.category] {
                    atomicNote(note)
                }
                files(item)
                actions(item)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - 头部
    //
    // 照 DefaultAppManager 的 ExtensionDetailView：超大彩色徽章 + 大标题 +
    // 分类胶囊。原来是 18pt 小图标 + 15pt 标题，详情列这么宽根本用不满。

    private func header(_ item: ConversationItem) -> some View {
        HStack(alignment: .top, spacing: 16) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.secondary.opacity(0.13))
                Image(systemName: item.category.iconName)
                    .font(.system(size: 30, weight: .regular))
            }
            .frame(width: 72, height: 72)

            VStack(alignment: .leading, spacing: 6) {
                Text(item.title)
                    .font(.system(size: 22, weight: .bold))
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 8) {
                    Text(item.category.rawValue)
                        .font(.system(size: 11, weight: .medium))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.secondary.opacity(0.15)))
                        .foregroundStyle(.secondary)
                    Text(item.formattedSize)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
                .padding(.top, 2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - 元数据

    private func metadata(_ item: ConversationItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("元数据").font(.headline)

            Grid(alignment: .topLeading, horizontalSpacing: 12, verticalSpacing: 6) {
                kvRow("会话 ID", item.sessionId, mono: true)
                kvRow("项目路径", item.displayProjectPath, mono: true)
                kvRow("Git 分支", item.gitBranch ?? "", mono: true)
                kvRow("对话轮数", "\(item.messageCount)", mono: true)
                kvRow("最后更新", Fmt.full(item.updatedAt), mono: true)
                kvRow("存储路径", storagePath(for: item), mono: true)
            }
        }
    }

    private func kvRow(_ label: String, _ value: String, mono: Bool) -> some View {
        GridRow {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.leading)
            // 长路径要在任意字符处折行，不能只行尾省略
            Text(value.isEmpty ? "—" : value)
                .font(mono ? .system(size: 11, design: .monospaced) : .callout)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func storagePath(for item: ConversationItem) -> String {
        let raw = viewModel.agentInfos.first { $0.category == item.category }?.storagePath ?? ""
        return Fmt.abbreviateHome(raw)
    }

    // MARK: - 摘要

    private func snippet(_ item: ConversationItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("摘要").font(.headline)
            Text(item.snippet)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - 原子清理（仅 idxNote 命中的 Agent）

    private func atomicNote(_ note: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("原子清理").font(.headline)
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "info.circle")
                    .foregroundStyle(.secondary)
                Text("\(note)，不会留下幽灵会话。")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(.quaternary))
        }
    }

    // MARK: - 关联文件（点击复制路径）

    private func files(_ item: ConversationItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("关联文件").font(.headline)
            VStack(spacing: 2) {
                ForEach(relatedPaths(for: item), id: \.self) { path in
                    FileRow(path: path) { viewModel.copyToClipboard(text: path) }
                }
            }
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

    private func actions(_ item: ConversationItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("操作").font(.headline)

            Button {
                viewModel.revealInFinder(item: item)
            } label: {
                Label("在 Finder 中显示", systemImage: "folder")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .controlSize(.large)

            Button {
                viewModel.copyToClipboard(text: item.displayProjectPath)
            } label: {
                Label("复制项目路径", systemImage: "doc.on.doc")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .controlSize(.large)
            .disabled(item.displayProjectPath.isEmpty)

            Button {
                viewModel.copyToClipboard(text: item.sessionId)
                copied = true
                Task {
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    copied = false
                }
            } label: {
                Label(copied ? "已复制" : "复制会话 ID", systemImage: "number")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .controlSize(.large)

            Button(role: .destructive) {
                Task { await viewModel.deleteSingle(item: item) }
            } label: {
                Label("删除此会话", systemImage: "trash")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .controlSize(.large)
            .disabled(viewModel.isCleaning)
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
            HStack(spacing: 6) {
                Image(systemName: "folder")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text(path)
                    .font(.system(size: 10.5, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(hovering ? Color(nsColor: .quaternaryLabelColor) : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("复制路径")
    }
}
