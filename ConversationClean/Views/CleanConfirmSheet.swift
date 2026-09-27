import SwiftUI

// MARK: - 清理确认弹层
//
// 逐块移植原型 `#scrim > .sheet`（.sheet-h / .sheet-hero / .sheet-b / .sheet-f）
// 与 `renderEstimate(list, label)` 生成的四个内容块：
//   ① 收益位置（.eb）② 卷占用（.cap + .cap-d + .est-note）③ 释放说明（.est-note）
//   ④ 空间构成（.cr）
// 文案、计算公式、条宽下限全部照抄原型，不做再设计。
//
// 与原型的两处刻意差异 —— 都因为本 App 读的是真实磁盘而不是演示数据：
//   1. 卷容量/已用量取自主目录所在卷的真实 URL 资源值（见文件末尾 VolumeInfo），
//      不是原型写死的 VOL = {cap:994GiB, used:912GiB}；
//   2. 因此 .sh 右侧那颗「演示数据」胶囊换成真实卷名：它原本的作用是声明
//      「这组数字是假的」，本 App 的数字是真的，再挂任何「演示」字样都是误导。
//
// 版面约束：hero 留在滚动区之外（原型注释：headline 不该被滚掉），
// 滚动区装三个带顶线的 .est-sec，提示块与页脚固定在下方。

struct CleanConfirmSheet: View {
    @EnvironmentObject var viewModel: CleanViewModel

    /// 弹层可用高度（视口高 - 上下留白），由 `ModalScrim` 传入。
    /// 原型 `.sheet-b{max-height:min(58vh,520px)}` 用 vh 表达，SwiftUI 没有 vh 单位。
    let availableHeight: CGFloat

    /// 滚动区的上限：`.sheet-b` 的 `min(58vh, 520px)`。
    private var bodyMaxHeight: CGFloat { min(availableHeight * 0.58, 520) }

    // MARK: - 常量（对应原型 IDX_PER / MAIN_MAX）

    /// 原型 `IDX_PER = 34*1024`。第二层索引行（Pi 的 context-mode SQLite、
    /// VS Code 家族的 state.vscdb）不是独立文件，没有实测大小可读，按每会话 34 KB 估。
    private static let idxPer: Int64 = 34 * 1024
    /// 原型 `MAIN_MAX = 5`：空间构成最多列 5 个 Agent，多出来的并成「其余 N 个会话」。
    private static let mainMax = 5
    private static let panelWidth: CGFloat = 520

    // 卷信息整弹只读一次：@State 的初值只在弹层创建时生效，
    // 之后 body 重算不会覆盖它（磁盘占用在弹层停留的几秒里也不会有意义的变动）。
    @State private var volume: VolumeInfo? = VolumeInfo.current()

    // MARK: - 设置开关
    //
    // 走 Core 层的 `CleanPrefs`（唯一读取入口）。它与 SettingsView 的 `@AppStorage`
    // 键名一一对应、现读不缓存，所以运行中改开关后立刻生效。
    // 不要在这里自己再写一遍键名 —— 两套键名迟早会漂。

    private static var syncSnapshots: Bool { CleanPrefs.cleanFileHistorySnapshots }
    private static var dropEmptyFolders: Bool { CleanPrefs.cleanEmptyProjectFolders }

    /// 原型 `AMAP[*].idx`：这些 Agent 除了主会话文件还维护第二层索引载体，
    /// 清理时会连索引行一起删。名字取载体的末段（原型 `mid()`）。
    private static func indexLayer(for category: ConversationCategory) -> String? {
        switch category {
        case .piAgent:
            return "context-mode"                                  // ~/.pi/agent/context-mode
        case .copilotChat, .cursor, .windsurf, .trae, .antigravity:
            return "state.vscdb"                                   // workspaceStorage 里的 vscdb
        default:
            return nil
        }
    }

    // MARK: - 数据（先算好，避免 body 里反复 reduce）

    /// 目标集合以**面板打开那一刻**为准（`estimateCategory` + `cleanTarget`），
    /// 而不是读当前的 `selectedCategory` / `filteredConversations`。
    /// 面板开着的时候用户仍能切分类、点搜索，原型是按 `pending` 列表算的 ——
    /// 面板上写着的条数与「确认清除」实际删掉的必须始终是同一批。
    private var targets: [ConversationItem] { viewModel.estimateTargets(for: viewModel.cleanTarget) }

    private var count: Int { targets.count }
    private var mainBytes: Int64 { targets.reduce(0) { $0 + $1.sizeInBytes } }

    /// 命中的第二层索引会话数与去重后的层名（原型 idxN / idxLayer）。
    private var indexHit: (count: Int, layers: [String]) {
        guard Self.syncSnapshots else { return (0, []) }
        var n = 0
        var seen: Set<String> = []
        var layers: [String] = []
        for item in targets {
            guard let layer = Self.indexLayer(for: item.category) else { continue }
            n += 1
            if seen.insert(layer).inserted { layers.append(layer) }
        }
        return (n, layers)
    }

    private var idxBytes: Int64 { Int64(indexHit.count) * Self.idxPer }
    private var totalBytes: Int64 { mainBytes + idxBytes }

    /// 原型 `cleanableAll()`：全库主文件 + 同一口径下的索引层估算。
    private var allBytes: Int64 {
        let hits = Self.syncSnapshots
            ? viewModel.conversations.filter { Self.indexLayer(for: $0.category) != nil }.count
            : 0
        return viewModel.totalSize + Int64(hits) * Self.idxPer
    }

    /// 原型 askClean 的 label：整类清理时带上范围名；无分类或只清选中项时省略「「X」的 」。
    /// 分类取 `estimateCategory`（打开面板时的那个），不是当前的 `selectedCategory`。
    private var scopeLabel: String? {
        switch viewModel.cleanTarget {
        case .selected:
            return nil
        case .allInCurrentCategory:
            return viewModel.estimateCategory == .all ? nil : viewModel.estimateCategory.rawValue
        }
    }

    /// 按 Agent 聚合的主文件字节（索引层单独成行，不混进来）。
    private var shares: [AgentShare] {
        var bytes: [ConversationCategory: Int64] = [:]
        var counts: [ConversationCategory: Int] = [:]
        var order: [ConversationCategory] = []
        for item in targets {
            if bytes[item.category] == nil { order.append(item.category) }
            bytes[item.category, default: 0] += item.sizeInBytes
            counts[item.category, default: 0] += 1
        }
        // 降序；同字节按名称排，保证每次渲染顺序稳定
        return order
            .map { AgentShare(category: $0, bytes: bytes[$0] ?? 0, count: counts[$0] ?? 0) }
            .sorted { $0.bytes == $1.bytes ? $0.name < $1.name : $0.bytes > $1.bytes }
    }

    private var mainRows: [AgentShare] { Array(shares.prefix(Self.mainMax)) }
    private var restRows: [AgentShare] { Array(shares.dropFirst(Self.mainMax)) }
    /// 「其余 N 个会话」：N 是被折叠掉的会话条数，不是被折叠掉的 Agent 数。
    private var restCount: Int { restRows.reduce(0) { $0 + $1.count } }
    private var restBytes: Int64 { restRows.reduce(0) { $0 + $1.bytes } }

    private var indexRowTitle: String {
        let layers = indexHit.layers
        return layers.count == 1
            ? "索引行 · \(layers[0])"
            : "索引行与快照 · \(layers.count) 层"
    }

    // MARK: - 骨架

    var body: some View {
        VStack(spacing: 0) {
            header
            hero
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    benefitSection
                    volumeSection
                    compositionSection
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                // 原型 .sheet-b{max-height:min(58vh,520px)}；内容不足一屏时顶对齐
                .frame(maxHeight: bodyMaxHeight, alignment: .top)
                // 原型 .sheet-b 的 padding-bottom: 18px
                .padding(.bottom, 18)
            }
            tip
            footer
        }
        .frame(width: Self.panelWidth)
        // 弹层由 `ModalScrim` 承载，不用 `.sheet`：
        // 之前是 sheet 会自动按内容开窗，这里的 fixed width + 自身高度不再需要，
        // 但垂直方向仍不能溢出视口 —— 头部/hero/页脚是固定高，滚动区是弹性，
        // 整体超过视口时先压滚动区，再让内容整体上移。
        .frame(maxHeight: availableHeight)
        .background(
            RoundedRectangle(cornerRadius: CC.R.lg, style: .continuous).fill(CC.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: CC.R.lg, style: .continuous)
                .strokeBorder(CC.border, lineWidth: 1)
        )
        // 先裁圆角再投影，否则圆角外的背景矩形会把阴影方角化
        .clipShape(RoundedRectangle(cornerRadius: CC.R.lg, style: .continuous))
        .shadow(color: CC.fg.opacity(0.18), radius: 24, y: 12)
    }

    // MARK: - ① 头部（.sheet-h）

    private var header: some View {
        VStack(alignment: .leading, spacing: 13) {
            ZStack {
                Circle().fill(CC.dangerSoft)
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 20))
                    .foregroundStyle(CC.danger)
            }
            .frame(width: 38, height: 38)

            Text("确认清除会话？")
                .font(CC.F.display)
                .foregroundStyle(CC.fg)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.init(top: 20, leading: 22, bottom: 0, trailing: 22))
    }

    // MARK: - ② 预计释放（.sheet-hero / .est-hero）
    //
    // 留在滚动区之外：原型把 headline 放在 #estHero 里而不是 #shBody 里，
    // 目的就是清理目标再多也不该把「预计释放」这行滚没。

    private var hero: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("预计释放")
                .font(CC.F.monoSm)
                .tracking(1.1)
                .foregroundStyle(CC.muted)

            heroFigure
                .padding(.top, 6)

            heroCaption
                .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.init(top: 14, leading: 22, bottom: 0, trailing: 22))
    }

    @ViewBuilder
    private var heroFigure: some View {
        let split = Self.split(Fmt.bytes(totalBytes))
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            if count == 0 {
                Text("—")
                    .font(CC.F.num(34))
                    .tracking(-1.36)
                    .foregroundStyle(CC.fg)
            } else if split.unit.isEmpty {
                // 没有可拆的单位（如 "0 B"）时整串用大号排，避免留一个空单位占位
                Text(split.value)
                    .font(CC.F.num(34))
                    .tracking(-1.36)
                    .foregroundStyle(CC.fg)
            } else {
                Text(split.value)
                    .font(CC.F.num(34))
                    .tracking(-1.36)          // .est-hero .v 的 letter-spacing: -.04em
                    .foregroundStyle(CC.fg)
                Text(split.unit)
                    .font(CC.F.num(16, .medium))
                    .foregroundStyle(CC.muted)
            }
        }
    }

    @ViewBuilder
    private var heroCaption: some View {
        if count == 0 {
            Text("当前没有可清理的会话。")
                .font(.system(size: 11.5))
                .foregroundStyle(CC.muted)
                .lineSpacing(3.4)             // 原型 line-height: 1.5
                .fixedSize(horizontal: false, vertical: true)
        } else {
            (Text("将删除")
             + (scopeLabel.map { Text("「\($0)」的 ") } ?? Text(""))
             + Text("\(count)").figureEmphasis(size: 11.5)
             + Text(" 个会话文件，覆盖 ")
             + Text("\(shares.count)").figureEmphasis(size: 11.5)
             + Text(" 个 Agent。此操作不可撤销。"))
                .font(.system(size: 11.5))
                .foregroundStyle(CC.muted)
                .lineSpacing(3.4)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - ③ 收益位置（.est-sec + .eb × 2）

    private var benefitSection: some View {
        estSection {
            sectionLabel("收益位置")
        } content: {
            VStack(spacing: 13) {
                EstBarRow(
                    label: "占全部可清理空间",
                    val: totalBytes,
                    basis: allBytes
                ) {
                    // 「全部可清理 X · 本次占 Y%」，一位小数
                    (Text("全部可清理 ")
                     + Text(Fmt.bytes(allBytes)).figureEmphasis(size: 10.5)
                     + Text(" · 本次占 ")
                     + Text(allBytes > 0
                            ? String(format: "%.1f%%", Double(totalBytes) / Double(allBytes) * 100)
                            : "0%").figureEmphasis(size: 10.5))
                        .font(.system(size: 10.5))
                        .foregroundStyle(CC.muted)
                }

                // 卷容量读不到时整行不画：宁可少一条收益，也不用假分母编出一个占比
                if let vol = volume {
                    EstBarRow(
                        label: "占卷总容量",
                        val: totalBytes,
                        basis: vol.capacity
                    ) {
                        // 卷容量口径三位小数：几百 MB 摊到 TB 级卷上，两位小数会全变成 0.00%
                        (Text("卷容量 ")
                         + Text(Fmt.bytes(vol.capacity)).figureEmphasis(size: 10.5)
                         + Text(" · 本次占 ")
                         + Text(String(format: "%.3f%%", Double(totalBytes) / Double(vol.capacity) * 100))
                            .figureEmphasis(size: 10.5))
                            .font(.system(size: 10.5))
                            .foregroundStyle(CC.muted)
                    }
                }
            }
        }
    }

    // MARK: - ④ 卷占用（.cap × 2 + .cap-d）+ ⑤ 释放说明（.est-note）

    @ViewBuilder
    private var volumeSection: some View {
        // 拿不到真实卷信息就整块不渲染：宁可少一节，也不能拿演示数字冒充真实占用
        if let vol = volume {
            estSection {
                sectionHeader("卷占用", path: vol.mountPath, badge: vol.name)
            } content: {
                VStack(alignment: .leading, spacing: 0) {
                    let usedBefore = Double(vol.used) / Double(vol.capacity)
                    let usedAfter  = Double(max(0, vol.used - totalBytes)) / Double(vol.capacity)
                    let gainPct    = Double(totalBytes) / Double(vol.capacity) * 100

                    VStack(spacing: 7) {
                        CapRow(
                            label: "清理前",
                            usedRatio: usedBefore,
                            gainPercent: nil,
                            readout: usedBefore
                        )
                        CapRow(
                            label: "清理后",
                            usedRatio: usedAfter,
                            gainPercent: gainPct,
                            readout: usedAfter,
                            isAfter: true
                        )
                    }

                    capDetail(vol, gainPct: gainPct)
                    note
                }
            }
        }
    }

    /// 原型 `.cap-d`：量级徽标 + 可用空间的实际变化。
    private func capDetail(_ vol: VolumeInfo, gainPct: Double) -> some View {
        let freeBefore = vol.free
        let freeAfter = freeBefore + totalBytes
        let level: (String, Bool) =
            gainPct < 0.5 ? ("量级微小", false) : (gainPct < 5 ? ("量级有限", false) : ("量级显著", true))
        // 可用空间的相对增幅：分母是清理前的可用空间
        let freeJump = freeBefore > 0
            ? String(format: "%.2f", Double(totalBytes) / Double(freeBefore) * 100)
            : "0.00"

        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            LevelBadge(text: level.0, isOK: level.1)
            (Text("可用空间 ")
             + Text("\(Self.fmtVol(freeBefore)) → \(Self.fmtVol(freeAfter))").figureEmphasis(size: 11.5)
             + Text("（+\(freeJump)%），相当于卷容量的 ")
             + Text(String(format: "%.3f%%", gainPct)).figureEmphasis(size: 11.5)
             + Text("。"))
                .font(.system(size: 11.5))
                .foregroundStyle(CC.muted)
                .lineSpacing(4.6)                 // 原型 line-height: 1.6
                .fixedSize(horizontal: false, vertical: true)
        }
        // 原型 .cap-d{margin-top:11px; padding-top:10px; border-top:1px}
        .padding(.top, 10)
        .ccHairline(.top)
        .padding(.top, 11)
    }

    /// 原型 `.est-note`：释放量为什么可能低于预估；若本次之外还有会话，一并交代。
    private var note: some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: "info.circle")
                .font(.system(size: 12))
                .foregroundStyle(CC.muted)
                .padding(.top, 2)
            noteText
                .font(.system(size: 10.5))
                .foregroundStyle(CC.muted)
                .lineSpacing(4.2)                 // 原型 line-height: 1.6
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 10)
    }

    private var noteText: Text {
        var text = Text("实际释放可能低于预估：APFS 稀疏文件按分配块回收，Time Machine 本地快照仍保留旧数据块，被其他进程占用的文件句柄也会延后释放。")
        let others = viewModel.conversations.count - targets.count
        if others > 0 {
            // 原型只把两个数字裹进 <b>，连接文字保持常规字重
            text = text
                + Text("本次之外另有 ")
                + Text("\(others)").figureEmphasis(size: 10.5)
                + Text(" 个会话占用 ")
                + Text(Fmt.bytes(max(allBytes - totalBytes, 0))).figureEmphasis(size: 10.5)
                + Text("，未纳入本次预估。")
        }
        return text
    }

    // MARK: - ⑥ 空间构成（.est-sec + .cr）

    private var compositionSection: some View {
        estSection {
            sectionLabel("空间构成")
        } content: {
            VStack(spacing: 8) {
                ForEach(mainRows) { row in
                    CompositionRow(name: row.name, bytes: row.bytes, basis: totalBytes)
                }
                if restCount > 0 {
                    CompositionRow(name: "其余 \(restCount) 个会话", bytes: restBytes, basis: totalBytes)
                }
                if idxBytes > 0 {
                    CompositionRow(
                        name: indexRowTitle,
                        bytes: idxBytes,
                        basis: totalBytes,
                        tag: "估算",
                        isEstimated: true
                    )
                }
            }
        }
    }

    // MARK: - ⑦ 提示块（.sheet-b .tip）

    private var tip: some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: "info.circle")
                .font(.system(size: 13))
                .foregroundStyle(CC.muted)
                .padding(.top, 2)
            tipText
                .font(.system(size: 11.5))
                .foregroundStyle(CC.muted)
                .lineSpacing(3.4)                 // 原型 line-height: 1.5
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.init(top: 9, leading: 11, bottom: 9, trailing: 11))
        .background(RoundedRectangle(cornerRadius: CC.R.sm, style: .continuous).fill(CC.fillSoft))
        // 原型 .tip{margin-top:11px} + .sheet-b{padding-bottom:18px}
        .padding(.init(top: 11, leading: 22, bottom: 18, trailing: 22))
    }

    private var tipText: Text {
        guard Self.syncSnapshots else {
            return Text("当前已关闭快照同步清理，仅删除主会话文件，索引行与快照会残留在原处。")
        }
        var text = Text("将同步删除快照、子代理数据与 SQLite 索引行")
        if Self.dropEmptyFolders {
            text = text + Text("，并移除空项目目录")
        }
        // 「34 KB」必须按 1024 进制写：Fmt.bytes 是 1000 进制，会打成 34.8 KB
        return text
            + Text("；索引层按命中的 \(indexHit.count) 个会话、每会话 \(Self.idxPer / 1024) KB 估算。")
    }

    // MARK: - ⑧ 页脚（.sheet-f）

    private var footer: some View {
        HStack(spacing: 9) {
            Spacer(minLength: 0)
            CCButton(title: "取消", kind: .ghost, help: "放弃本次清理") {
                viewModel.cancelClean()
            }
            CCButton(
                title: viewModel.isCleaning ? "正在清除…" : "确认清除 · \(Fmt.bytes(totalBytes))",
                kind: .danger,
                enabled: count > 0 && !viewModel.isCleaning,
                help: count > 0 ? "删除这 \(count) 个会话文件及其索引行" : "没有可清理的会话"
            ) {
                // 面板由 `showCleanConfirmAlert` 驱动显隐，`executeClean` 内部自行收起。
                // 之前这里是 `dismiss()`（`.sheet` 的环境动作），换成遮罩后没有 dismiss 可用。
                Task { await viewModel.executeClean() }
            }
        }
        .padding(.init(top: 13, leading: 22, bottom: 13, trailing: 22))
        .background(CC.bg.opacity(0.45))
        .ccHairline(.top)
    }

    // MARK: - 小组件

    /// 复刻 `.est-sec`：顶线 + 18pt 外间距 + 16pt 内边距 + 左右 22pt。
    private func estSection<H: View, C: View>(
        @ViewBuilder header: () -> H,
        @ViewBuilder content: () -> C
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            header()
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 12)          // .sh{margin-bottom:12px}
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.init(top: 16, leading: 22, bottom: 0, trailing: 22))
        .padding(.top, 18)
        .ccHairline(.top)
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(CC.F.monoSm)
            .tracking(1.1)                     // .sh{letter-spacing:.11em}
            .foregroundStyle(CC.muted)
    }

    /// `.sh` 完整形态：mono 小标 + 弱化色路径 + 右侧胶囊。
    private func sectionHeader(_ title: String, path: String?, badge: String?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            sectionLabel(title)
            if let path {
                Text(path)
                    .font(CC.F.monoSm)          // .sh .p{letter-spacing:0}
                    .foregroundStyle(CC.fg.opacity(0.72))
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if let badge {
                CCBadge(text: badge, tone: .neutral)
            }
        }
    }

    // MARK: - 数字与单位工具

    /// 原型 `splitB`：`Fmt.bytes` 的结果拆成数值与单位。
    private static func split(_ s: String) -> (value: String, unit: String) {
        let parts = s.split(separator: " ")
        guard let last = parts.last, parts.count > 1, last.allSatisfy({ $0.isLetter }) else {
            return (s, "")
        }
        return (parts.dropLast().joined(separator: " "), String(last))
    }

    /// 原型 `fmtVol`：GB 保留两位小数。几百 MB 在 TB 级卷上低于 `Fmt.bytes`
    /// 的分辨率（两个数会打成一样），所以这里另起一套固定格式。
    private static func fmtVol(_ bytes: Int64) -> String {
        String(format: "%.2f GB", Double(bytes) / (1024.0 * 1024 * 1024))
    }
}

// MARK: - 构成行数据

/// 一个 Agent 在本次清理中的合计：字节用于排序与画条，条数只用于「其余 N 个会话」。
private struct AgentShare: Identifiable {
    let category: ConversationCategory
    let bytes: Int64
    let count: Int
    var name: String { category.rawValue }
    var id: String { category.rawValue }
}

// MARK: - Text 拼装辅助

extension Text {
    /// 原型 `.sheet-b b` / `.est-note b`：等宽、半粗、表格数字。
    /// 用在说明句里的数字上，让「读了几个 / 有多大」能被逐行扫读。
    fileprivate func figureEmphasis(size: CGFloat) -> Text {
        font(CC.F.num(size)).foregroundColor(CC.fg)
    }
}

// MARK: - .eb 收益条

/// 原型 `.eb`：左上标签 + 右上数值，中间隔一条 9pt 描边条，底下跟一行说明。
/// 条宽 `val/basis*100`，数值 > 0 时至少 0.5%（原型 `Math.max(w, 0.5)`）。
private struct EstBarRow<Cap: View>: View {
    let label: String
    let val: Int64
    let basis: Int64
    @ViewBuilder var caption: () -> Cap

    private var percent: Double { basis > 0 ? Double(val) / Double(basis) * 100 : 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(label)
                    .font(.system(size: 11.5))
                    .foregroundStyle(CC.muted)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(Fmt.bytes(val))
                    .font(CC.F.num(11.5))
                    .foregroundStyle(CC.fg)
                    .lineLimit(1)
            }

            bar.padding(.top, 6)

            // 原型 .eb{row-gap:6px} 而 .c{margin-top:-1px}，净间距 5pt
            caption().padding(.top, 5)
        }
    }

    private var bar: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2, style: .continuous).fill(CC.surface)
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(CC.fg)
                    .frame(width: fillWidth(in: geo.size.width))
            }
        }
        .frame(height: 9)
        .overlay(
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .strokeBorder(CC.border, lineWidth: 1)
        )
        .accessibilityHidden(true)
    }

    private func fillWidth(in width: CGFloat) -> CGFloat {
        guard val > 0 else { return 0 }
        // 1px 描边画在内侧，填充只能落在剩下的内宽里
        let inner = max(0, width - 2)
        return max(1.5, inner * CGFloat(max(percent, 0.5) / 100))
    }
}

// MARK: - .cap 卷容量双条

/// 原型 `.cap`：36pt 标签 + 真比例条 + 右对齐读数。
/// `gainPercent` 只有「清理后」那条有值，画成一小段深色，表示本次释放的那一刀。
private struct CapRow: View {
    let label: String
    let usedRatio: Double
    let gainPercent: Double?
    let readout: Double
    var isAfter: Bool = false

    var body: some View {
        HStack(spacing: 9) {
            Text(label)
                .font(.system(size: 11, weight: isAfter ? .semibold : .regular))
                .foregroundStyle(isAfter ? CC.fg : CC.muted)
                .lineLimit(1)
                .frame(width: 36, alignment: .leading)

            GeometryReader { geo in
                let inner = max(0, geo.size.width - 2)   // 让开 1px 描边
                HStack(spacing: 0) {
                    Rectangle()
                        .fill(CC.fg.opacity(isAfter ? 0.21 : 0.27))
                        .frame(width: inner * CGFloat(min(1, max(0, usedRatio))), height: 15)
                    if let gainPercent {
                        Rectangle()
                            .fill(CC.fg)
                            // 原型 min-width:1.5px + Math.max(gPct, 0.16)
                            .frame(width: max(1.5, inner * CGFloat(max(gainPercent, 0.16) / 100)), height: 15)
                    }
                }
                .frame(width: geo.size.width, height: 15, alignment: .leading)
            }
            .frame(height: 15)
            .background(
                RoundedRectangle(cornerRadius: 3, style: .continuous).fill(CC.surface)
            )
            .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .strokeBorder(CC.border, lineWidth: 1)
            )
            .accessibilityHidden(true)

            // 原型 .cap .rv{b{fg 600}}：百分号数字加重，「 已用」保持 muted 常规字重
            (Text(String(format: "%.3f%%", readout * 100)).figureEmphasis(size: 10.5)
             + Text(" 已用").font(CC.F.num(10.5, .regular)).foregroundColor(CC.muted))
                .lineLimit(1)
                .frame(width: 96, alignment: .trailing)
        }
    }
}

// MARK: - .cr 构成行

/// 原型 `.cr`：名称(+ tag) + 8pt 细条 + 字节 + 百分比。
/// `isEstimated` 时条用 135° 斜纹 —— 斜纹是「这段不是实测」的唯一记号。
private struct CompositionRow: View {
    let name: String
    let bytes: Int64
    let basis: Int64
    var tag: String? = nil
    var isEstimated: Bool = false

    private var percent: Double { basis > 0 ? Double(bytes) / Double(basis) * 100 : 0 }
    private var fraction: Double { min(1, max(0, percent / 100)) }

    var body: some View {
        HStack(spacing: 9) {
            HStack(spacing: 6) {
                Text(name)
                    .font(.system(size: 11.5))
                    .foregroundStyle(isEstimated ? CC.muted : CC.fg)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: 190, alignment: .leading)   // .cr .cn{max-width:190px}
                if let tag {
                    CCBadge(text: tag, tone: .neutral)
                }
            }

            bar

            Text(Fmt.bytes(bytes))
                .font(CC.F.num(10.5, .regular))
                .foregroundStyle(CC.muted)
                .lineLimit(1)
                .frame(width: 58, alignment: .trailing)

            Text(String(format: "%.1f%%", percent))
                .font(CC.F.num(10.5, .regular))
                .foregroundStyle(CC.muted)
                .lineLimit(1)
                .frame(width: 42, alignment: .trailing)
        }
        .accessibilityElement(children: .combine)
    }

    private var bar: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2, style: .continuous).fill(CC.fillSoft)
                if isEstimated {
                    HatchedFill()
                        .frame(width: max(1.5, geo.size.width * fraction), height: 8)
                } else {
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(CC.fg)
                        .frame(width: max(1.5, geo.size.width * fraction))
                }
            }
        }
        .frame(height: 8)
        .clipShape(RoundedRectangle(cornerRadius: 2, style: .continuous))
        .accessibilityHidden(true)
    }
}

// MARK: - 斜纹填充

/// 原型 `.cr.est .cb i` 的 `repeating-linear-gradient(135deg, fg 0 2px, transparent 2px 4px)`
/// —— 135°、2pt 实 2pt 空、整体 55% 不透明度。Canvas 画的斜纹只在 8pt 高的条里出现，
/// 不值得为它引一个渐变资源。
private struct HatchedFill: View {
    var body: some View {
        Canvas { ctx, size in
            var x = -size.height
            while x < size.width {
                var stripe = Path()
                stripe.move(to: CGPoint(x: x, y: size.height))
                stripe.addLine(to: CGPoint(x: x + size.height, y: 0))
                stripe.addLine(to: CGPoint(x: x + size.height + 2, y: 0))
                stripe.addLine(to: CGPoint(x: x + 2, y: size.height))
                stripe.closeSubpath()
                ctx.fill(stripe, with: .color(CC.fg))
                x += 4
            }
        }
        .opacity(0.55)
    }
}

// MARK: - .lvl 量级徽标

/// 原型 `.lvl`：mono 9.5 胶囊，warn / ok 两态。
/// `CCBadge` 的 tone 只有 neutral / accent / danger / warn，缺 ok 态（原型是绿系），
/// 而 warn / ok 的底色透明度也不同（15% / 14%），所以这里自绘一个只服务量级徽标的小胶囊，
/// 不去动共享组件的 tone 枚举。
private struct LevelBadge: View {
    let text: String
    let isOK: Bool

    var body: some View {
        Text(text)
            .font(CC.F.monoSm)
            .tracking(0.2)                        // .lvl{letter-spacing:.02em}
            .foregroundStyle(isOK ? CC.ok : CC.warn)
            .padding(.horizontal, 7)
            .padding(.vertical, 1.5)
            .background(
                Capsule().fill((isOK ? CC.ok : CC.warn).opacity(isOK ? 0.14 : 0.15))
            )
            .fixedSize()
            .accessibilityHidden(true)
    }
}

// MARK: - 真实卷信息

/// 宿主卷的容量与已用量。
///
/// 放在 UI 层而不是 ViewModel 里，是因为本次只允许改这一个文件（ViewModel / Core
/// 归 wire-prefs agent），而且这个值只有一个消费者 —— 弹层的「卷占用」两节。
/// 原型里的 `VOL = {cap:994GiB, used:912GiB}` 是写死的演示数字，这里必须读真值，
/// 否则「清理后 91.750% 已用」会拿一条不存在的卷去承诺用户。
private struct VolumeInfo {
    let name: String          // 卷名，如 "Macintosh HD"
    let mountPath: String?    // 真实挂载点，如 "/"、"/System/Volumes/Data"
    let capacity: Int64
    let used: Int64

    var free: Int64 { max(0, capacity - used) }

    /// 读主目录所在卷。拿不到就返回 nil，调用方整块不渲染。
    static func current() -> VolumeInfo? {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        guard let v = try? home.resourceValues(forKeys: [
            .volumeNameKey,
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityKey,
            .volumeIdentifierKey
        ]) else { return nil }

        // 可用量优先用 ImportantUsage：它与 Finder「可用空间」同口径，
        // 且已经扣掉了 purgeable 的那部分；拿不到再退回普通的 volumeAvailableCapacity。
        let capacity = Int64(v.volumeTotalCapacity ?? 0)
        let available = v.volumeAvailableCapacityForImportantUsage
            ?? v.volumeAvailableCapacity.map(Int64.init)
            ?? 0
        guard capacity > 0, available > 0, available <= capacity else { return nil }

        let used = capacity - available
        guard used > 0 else { return nil }

        // 挂载点：URLResourceValues 没有暴露 volumeURL，只能拿卷标识去
        // mountedVolumeURLs 里反查（系统卷与 Data 卷同属一个 APFS 容器时
        // 会命中系统根卷，这正是容量该报的那个卷）。
        let identifier = v.volumeIdentifier as? NSObject
        let mounts: [URL] = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: [.volumeIdentifierKey], options: []
        ) ?? []
        let mountPath = identifier.flatMap { id in
            mounts.first { url in
                ((try? url.resourceValues(forKeys: [.volumeIdentifierKey]))?.volumeIdentifier as? NSObject) == id
            }?.path
        }

        let name = v.volumeName
            ?? v.volumeLocalizedName
            ?? mountPath
            ?? "本机磁盘"
        return VolumeInfo(name: name, mountPath: mountPath, capacity: capacity, used: used)
    }
}
