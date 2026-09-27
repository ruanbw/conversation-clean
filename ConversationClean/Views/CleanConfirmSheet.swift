import SwiftUI
import AppKit

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
//
// 配色这一版的处理（全部走 Theme 动态色，深浅色等价）：
//   · 收益条 / 卷容量条：原来是 `Color.primary` 黑灰填充，深色模式下变成白条、
//     且看着像禁用态。现在是靛蓝渐变（accentHi→accent），「本次释放」那一刀用
//     语义绿 success —— 绿色在这里是「拿回多少」的唯一记号。
//   · 空间构成色块：原来是 `Color.primary.opacity()` 灰阶，与 OverviewView 里
//     修掉的是同一个病（深色变白条、相邻段分不出）。换成 Theme.distColor
//     靛蓝色阶（同一 hue 250° 的明度阶梯），并补上设计稿里的
//     「堆叠总览条 + 横条列表」两件套 —— 只有横条没有堆叠条时，
//     读者要在心里自己做加法才知道谁大谁小。
//   · 全部 `Divider()` 换成 Theme.line 发丝线：系统 Divider 在深色下是另一层灰。

struct CleanConfirmSheet: View {
    @EnvironmentObject var viewModel: CleanViewModel

    /// 滚动区的上限。原型的 `min(58vh, 520px)` 用 vh 表达，
    /// `.sheet` 场景下 SwiftUI 没有 vh —— 固定取 520。
    private let bodyMaxHeight: CGFloat = 520

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

    /// 空间构成的完整分段表。堆叠总览条与横条列表读同一份 —— 两处各算一次
    /// 迟早会漂，漂了就变成「条上说的」和「块上画的」不是一回事。
    ///
    /// `colorIndex` 顺位分配：相邻段在 Theme.distColor 上必差一阶明度，
    /// 深浅色下都分得开（色阶只有 8 级，段数上限 7，超了自然夹到末阶）。
    private var segments: [CompSegment] {
        var out: [CompSegment] = mainRows.enumerated().map { index, row in
            CompSegment(name: row.name, bytes: row.bytes, colorIndex: index)
        }
        if restCount > 0 {
            out.append(CompSegment(name: "其余 \(restCount) 个会话",
                                   bytes: restBytes, colorIndex: out.count))
        }
        if idxBytes > 0 {
            out.append(CompSegment(name: indexRowTitle, bytes: idxBytes,
                                   colorIndex: out.count, tag: "估算", isEstimated: true))
        }
        return out
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
        .background(Theme.bg)
    }

    // MARK: - ① 头部（.sheet-h）

    private var header: some View {
        HStack(spacing: Theme.Space.l) {
            ZStack {
                Circle().fill(Theme.dangerSoft)
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(Theme.danger)
            }
            .frame(width: 34, height: 34)

            Text("确认清除会话？")
                .font(Theme.Typo.cardTitle)
                .foregroundStyle(Theme.t1)

            Spacer(minLength: 0)
        }
        .padding(.init(top: 16, leading: 22, bottom: 0, trailing: 22))
    }

    // MARK: - ② 预计释放（.sheet-hero / .est-hero）
    //
    // 留在滚动区之外：原型把 headline 放在 #estHero 里而不是 #shBody 里，
    // 目的就是清理目标再多也不该把「预计释放」这行滚没。
    //
    // 版式按设计稿的 `.big` 卡片：白底 + 1px 发丝边 + 8pt 圆角。
    // 数字用 Theme.Typo.num(26)（tabular-nums，**不是** monospaced 设计字体）：
    // 原型那条 `.system(.largeTitle, design: .monospaced)` 34pt 半粗，
    // 等宽字形又宽又重，视觉重量压过了它下面真正的信息（会话数 / Agent 数）。

    private var hero: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("预计释放")
                .font(Theme.Typo.sectionHead)
                .tracking(0.4)
                .foregroundStyle(Theme.t3)

            heroFigure
                .padding(.top, 6)

            heroCaption
                .padding(.top, Theme.Space.m)
        }
        .padding(Theme.Space.ll)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
        .padding(.init(top: Theme.Space.l, leading: 22, bottom: 0, trailing: 22))
    }

    @ViewBuilder
    private var heroFigure: some View {
        let split = Self.split(Fmt.bytes(totalBytes))
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            if count == 0 {
                Text("—")
                    .font(Theme.Typo.num(26, .semibold))
                    .foregroundStyle(Theme.t3)
            } else if split.unit.isEmpty {
                // 没有可拆的单位（如 "0 B"）时整串用大号排，避免留一个空单位占位
                Text(split.value)
                    .font(Theme.Typo.num(26, .semibold))
                    .foregroundStyle(Theme.t1)
            } else {
                Text(split.value)
                    .font(Theme.Typo.num(26, .semibold))     // .est-hero .v 的 letter-spacing: -.04em
                    .tracking(-0.8)
                    .foregroundStyle(Theme.t1)
                Text(split.unit)
                    .font(Theme.Typo.num(13, .medium))
                    .foregroundStyle(Theme.t2)
            }
        }
    }

    @ViewBuilder
    private var heroCaption: some View {
        if count == 0 {
            Text("当前没有可清理的会话。")
                .font(Theme.Typo.rowSub)
                .foregroundStyle(Theme.t2)
                .lineSpacing(3.2)             // 原型 line-height: 1.5
                .fixedSize(horizontal: false, vertical: true)
        } else {
            (Text("将删除")
             + (scopeLabel.map { Text("「\($0)」的 ") } ?? Text(""))
             + Text("\(count)").figureEmphasis(.callout)
             + Text(" 个会话文件，覆盖 ")
             + Text("\(shares.count)").figureEmphasis(.callout)
             + Text(" 个 Agent。此操作不可撤销。"))
                .font(Theme.Typo.rowSub)
                .foregroundStyle(Theme.t2)
                .lineSpacing(3.2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - ③ 收益位置（.est-sec + .eb × 2）

    private var benefitSection: some View {
        estSection {
            sectionLabel("收益位置")
        } content: {
            VStack(spacing: Theme.Space.l) {
                EstBarRow(
                    label: "占全部可清理空间",
                    val: totalBytes,
                    basis: allBytes
                ) {
                    // 「全部可清理 X · 本次占 Y%」，一位小数
                    (Text("全部可清理 ")
                     + Text(Fmt.bytes(allBytes)).figureEmphasis(.caption)
                     + Text(" · 本次占 ")
                     + Text(allBytes > 0
                            ? String(format: "%.1f%%", Double(totalBytes) / Double(allBytes) * 100)
                            : "0%").figureEmphasis(.caption))
                        .font(Theme.Typo.rowSub)
                        .foregroundStyle(Theme.t3)
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
                         + Text(Fmt.bytes(vol.capacity)).figureEmphasis(.caption)
                         + Text(" · 本次占 ")
                         + Text(String(format: "%.3f%%", Double(totalBytes) / Double(vol.capacity) * 100))
                            .figureEmphasis(.caption))
                            .font(Theme.Typo.rowSub)
                            .foregroundStyle(Theme.t3)
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

        // 原来这里是 `return HStack { ... }.padding(.top, 10)` 后面跟一句独立的
        // `Divider().padding(.top, 11)`：函数已经 return，那句的结果没人接，
        // 分隔线被静默丢弃（编译器会报 "result of call to 'padding' is unused"）。
        // 「卷占用」与下面「释放说明」之间因此少了一根线。用 VStack 把两者收进同一个返回值。
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Space.m) {
                LevelBadge(text: level.0, isOK: level.1)
                (Text("可用空间 ")
                 + Text("\(Self.fmtVol(freeBefore)) → \(Self.fmtVol(freeAfter))").figureEmphasis(.callout)
                 + Text("（+\(freeJump)%），相当于卷容量的 ")
                 + Text(String(format: "%.3f%%", gainPct)).figureEmphasis(.callout)
                 + Text("。"))
                    .font(Theme.Typo.rowSub)
                    .foregroundStyle(Theme.t2)
                    .lineSpacing(4.0)                 // 原型 line-height: 1.6
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, Theme.Space.ms)

            Rectangle()
                .fill(Theme.line)
                .frame(height: 1)
                .padding(.top, 11)
        }
    }

    /// 原型 `.est-note`：释放量为什么可能低于预估；若本次之外还有会话，一并交代。
    /// 底色用 `Theme.sunken` 而不是强调色 —— 这一块是免责说明，靛蓝会被读成
    /// 「重点提示」；真正需要被看见的提示是页脚那块 `tip`（靛蓝淡底）。
    private var note: some View {
        HStack(alignment: .top, spacing: Theme.Space.s) {
            Image(systemName: "info.circle")
                .font(Theme.Typo.sectionHead)
                .foregroundStyle(Theme.t3)
                .padding(.top, 2)
            noteText
                .font(Theme.Typo.rowSub)
                .foregroundStyle(Theme.t3)
                .lineSpacing(3.6)                 // 原型 line-height: 1.6
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.Space.ms)
        .background {
            RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                .fill(Theme.sunken)
        }
        .padding(.top, Theme.Space.ms)
    }

    private var noteText: Text {
        var text = Text("实际释放可能低于预估：APFS 稀疏文件按分配块回收，Time Machine 本地快照仍保留旧数据块，被其他进程占用的文件句柄也会延后释放。")
        let others = viewModel.conversations.count - targets.count
        if others > 0 {
            // 原型只把两个数字裹进 <b>，连接文字保持常规字重
            text = text
                + Text("本次之外另有 ")
                + Text("\(others)").figureEmphasis(.caption)
                + Text(" 个会话占用 ")
                + Text(Fmt.bytes(max(allBytes - totalBytes, 0))).figureEmphasis(.caption)
                + Text("，未纳入本次预估。")
        }
        return text
    }

    // MARK: - ⑥ 空间构成（.est-sec + .stack + .cr）

    private var compositionSection: some View {
        estSection {
            sectionLabel("空间构成")
        } content: {
            VStack(alignment: .leading, spacing: 0) {
                // 设计稿 `.stack`：8pt 堆叠总览条。先看整体谁大，再看下面逐段的量 ——
                // 只有横条没有它，读者得在心里自己做加法。
                if totalBytes > 0 {
                    CompositionStack(segments: segments, basis: totalBytes)
                    Text(stackCaption)
                        .font(Theme.Typo.rowSub)
                        .foregroundStyle(Theme.t3)
                        .padding(.top, Theme.Space.s)
                        .padding(.bottom, Theme.Space.s)
                }

                VStack(spacing: 0) {
                    ForEach(Array(segments.enumerated()), id: \.offset) { _, seg in
                        CompositionRow(segment: seg, basis: totalBytes)
                    }
                }
            }
        }
    }

    /// 堆叠条下面那行注脚：把「谁最大」直接写成文字，省掉读者在段与段之间换算。
    private var stackCaption: String {
        guard let top = segments.max(by: { $0.bytes < $1.bytes }), top.bytes > 0 else {
            return "本次没有可清理的空间。"
        }
        let pct = totalBytes > 0
            ? Double(top.bytes) / Double(totalBytes) * 100
            : 0
        return "\(top.name) 占 \(String(format: "%.1f%%", pct)) · 共 \(segments.count) 段"
    }

    // MARK: - ⑦ 提示块（.sheet-b .tip）

    /// 设计稿 `.note`：靛蓝 5% 底 + 靛蓝 12% 边 + 靛蓝图标。
    private var tip: some View {
        HStack(alignment: .top, spacing: Theme.Space.s) {
            Image(systemName: "info.circle")
                .font(Theme.Typo.body12)
                .foregroundStyle(Theme.accent)
                .padding(.top, 2)
            tipText
                .font(Theme.Typo.rowSub)
                .foregroundStyle(Theme.t2)
                .lineSpacing(3.4)                 // 原型 line-height: 1.5
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.init(top: 9, leading: 11, bottom: 9, trailing: 11))
        .tintedSurface()
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
        HStack(spacing: Theme.Space.m) {
            Spacer(minLength: 0)
            Button("取消") { viewModel.cancelClean() }
                .buttonStyle(DrawnButtonStyle(variant: .ghost))
                .keyboardShortcut(.cancelAction)

            Button(action: { Task { await viewModel.executeClean() } }) {
                Text(viewModel.isCleaning ? "正在清除…" : "确认清除 · \(Fmt.bytes(totalBytes))")
                    .font(Theme.Typo.navItem.weight(.medium))
            }
            .buttonStyle(DrawnButtonStyle(
                variant: .danger,
                horizontalPadding: Theme.Space.xl,
                enabled: count > 0 && !viewModel.isCleaning))
            .keyboardShortcut(.defaultAction)
            .disabled(count == 0 || viewModel.isCleaning)
            .help(count > 0 ? "删除这 \(count) 个会话文件及其索引行" : "没有可清理的会话")
        }
        .padding(.init(top: Theme.Space.l, leading: 22, bottom: Theme.Space.l, trailing: 22))
        .background(Theme.bg)
        .hairline(.top, color: Theme.line)
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
                .padding(.bottom, Theme.Space.l)          // .sh{margin-bottom:12px}
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.init(top: 16, leading: 22, bottom: 0, trailing: 22))
        .padding(.top, 18)
        // 顶线走 Theme.line，不用 Divider：系统 Divider 的默认色在深色下是另一层灰，
        // 与 Theme.surface 卡片的边界对不上。
        .hairline(.top, color: Theme.line)
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(Theme.Typo.sectionHead.weight(.medium))
            .tracking(0.4)                     // .sh{letter-spacing:.11em}
            .foregroundStyle(Theme.t3)
    }

    /// `.sh` 完整形态：小标 + 弱化色路径 + 右侧胶囊。
    private func sectionHeader(_ title: String, path: String?, badge: String?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.m) {
            sectionLabel(title)
            if let path {
                Text(path)
                    .font(Theme.Typo.mono(10.5))          // .sh .p{letter-spacing:0}
                    .foregroundStyle(Theme.t2)
                    .lineLimit(1)
            }
            Spacer(minLength: Theme.Space.xs)
            if let badge {
                Text(badge)
                    .font(Theme.Typo.mono(10))
                    .foregroundStyle(Theme.t2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background {
                        RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous)
                            .fill(Theme.sunken)
                    }
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

/// 空间构成的一段（Agent / 其余合并 / 索引行）。堆叠条与横条列表共用。
private struct CompSegment: Identifiable {
    let name: String
    let bytes: Int64
    /// Theme.distColor 的阶位，顺位分配保证相邻段必然差一阶明度
    let colorIndex: Int
    var tag: String? = nil
    var isEstimated: Bool = false

    var color: Color { Theme.distColor(colorIndex) }
    var id: String { name + (tag ?? "") }
}

// MARK: - Text 拼装辅助

extension Text {
    /// 原型 `.sheet-b b` / `.est-note b`：半粗、**表格数字**。
    /// 用在说明句里的数字上，让「读了几个 / 有多大」能被逐行扫读。
    /// 用 tabular-nums 而不是全等宽设计字体：后者在这个尺寸下字形太宽，
    /// 一句话里塞两三个数字会把句子撑散。
    fileprivate func figureEmphasis(_ base: Font) -> Text {
        font(base.monospacedDigit().weight(.semibold)).foregroundColor(Theme.t1)
    }
}

// MARK: - .eb 收益条

/// 原型 `.eb`：左上标签 + 右上数值，中间隔一条 9pt 描边条，底下跟一行说明。
/// 条宽 `val/basis*100`，数值 > 0 时至少 0.5%（原型 `Math.max(w, 0.5)`）。
///
/// 配色：靛蓝渐变填充 + 靛蓝 11% 轨道。原来是 `Color.primary` 黑灰 —— 深色模式
/// 下变白条，浅色模式下像禁用态，两种模式都不是「这是一条有多满」的读法。
private struct EstBarRow<Cap: View>: View {
    let label: String
    let val: Int64
    let basis: Int64
    @ViewBuilder var caption: () -> Cap

    private var percent: Double { basis > 0 ? Double(val) / Double(basis) * 100 : 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Space.l) {
                Text(label)
                    .font(Theme.Typo.navItem)
                    .foregroundStyle(Theme.t2)
                    .lineLimit(1)
                Spacer(minLength: Theme.Space.m)
                Text(Fmt.bytes(val))
                    .font(Theme.Typo.num(12.5, .semibold))
                    .foregroundStyle(Theme.t1)
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
                RoundedRectangle(cornerRadius: Theme.Radius.chipSmall, style: .continuous)
                    .fill(Theme.accent.opacity(0.11))
                RoundedRectangle(cornerRadius: Theme.Radius.chipSmall, style: .continuous)
                    .fill(LinearGradient(colors: [Theme.accentHi, Theme.accent],
                                         startPoint: .leading, endPoint: .trailing))
                    .frame(width: fillWidth(in: geo.size.width))
            }
        }
        .frame(height: 9)
        .accessibilityHidden(true)
    }

    private func fillWidth(in width: CGFloat) -> CGFloat {
        guard val > 0 else { return 0 }
        return max(1.5, width * CGFloat(max(percent, 0.5) / 100))
    }
}

// MARK: - .cap 卷容量双条

/// 原型 `.cap`：36pt 标签 + 真比例条 + 右对齐读数。
/// `gainPercent` 只有「清理后」那条有值，画成一小段**语义绿** —— 这一刀
/// 就是「能拿回多少」，全弹唯一该用语义色标出来的地方。
/// 原来是 `Color.primary` / `Color.primary.opacity(0.27)` 两级灰：
/// 深色下变白条，浅色下像两条被禁用的控件。
private struct CapRow: View {
    let label: String
    let usedRatio: Double
    let gainPercent: Double?
    let readout: Double
    var isAfter: Bool = false

    var body: some View {
        HStack(spacing: Theme.Space.m) {
            Text(label)
                .font(Theme.Typo.rowTitle)
                .foregroundStyle(isAfter ? Theme.t1 : Theme.t2)
                .lineLimit(1)
                .frame(width: 36, alignment: .leading)

            GeometryReader { geo in
                HStack(spacing: 0) {
                    LinearGradient(colors: [Theme.accentHi, Theme.accent],
                                   startPoint: .leading, endPoint: .trailing)
                        .frame(width: geo.size.width * CGFloat(min(1, max(0, usedRatio))), height: 14)
                    if let gainPercent {
                        Rectangle()
                            .fill(Theme.success)
                            // 原型 min-width:1.5px + Math.max(gPct, 0.16)
                            .frame(width: max(1.5, geo.size.width * CGFloat(max(gainPercent, 0.16) / 100)),
                                   height: 14)
                    }
                }
                .frame(width: geo.size.width, height: 14, alignment: .leading)
            }
            .frame(height: 14)
            .background {
                RoundedRectangle(cornerRadius: Theme.Radius.micro, style: .continuous).fill(Theme.sunken)
            }
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.micro, style: .continuous))
            .accessibilityHidden(true)

            // 原型 .cap .rv{b{fg 600}}：百分号数字加重，「 已用」保持 muted 常规字重
            (Text(String(format: "%.3f%%", readout * 100)).figureEmphasis(.caption)
             + Text(" 已用").font(Theme.Typo.mono(10)).foregroundColor(Theme.t3))
                .lineLimit(1)
                .frame(width: 96, alignment: .trailing)
        }
    }
}

// MARK: - .stack 空间构成堆叠总览条

/// 设计稿 `.stack`：8pt 高、4pt 圆角、段间 2pt 缝。
/// 段色取 `Theme.distColor`（靛蓝明度阶梯）—— 同一 hue，所以堆起来是一族颜色
/// 而不是彩虹；相邻段必差一阶明度，深浅色下都分得开。
private struct CompositionStack: View {
    let segments: [CompSegment]
    let basis: Int64

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 2) {
                ForEach(segments) { seg in
                    if width(of: seg, in: geo.size.width) >= 1 {
                        RoundedRectangle(cornerRadius: Theme.Radius.fine, style: .continuous)
                            .fill(seg.color)
                            .frame(width: width(of: seg, in: geo.size.width))
                            // 估算段打斜纹：斜纹是「这段不是实测」的唯一记号
                            .overlay {
                                if seg.isEstimated {
                                    HatchedFill(color: Theme.bg)
                                }
                            }
                    }
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .leading)
        }
        .frame(height: 8)
        .clipShape(Capsule())
        .background(Capsule().fill(Theme.sunken))
        .accessibilityHidden(true)
    }

    private func width(of seg: CompSegment, in total: CGFloat) -> CGFloat {
        guard seg.bytes > 0, basis > 0 else { return 0 }
        return total * CGFloat(Double(seg.bytes) / Double(basis))
    }
}

// MARK: - .cr 构成行

/// 原型 `.cr`，按设计稿 `.distrow` 排：8pt 色块 + 名字(+ tag) + 5pt 细条 +
/// 百分比 + 大小。条用该段自己的 `Theme.distColor`，与堆叠条同色 —— 两处对得上，
/// 读者才能在条与块之间来回跳。
private struct CompositionRow: View {
    let segment: CompSegment
    let basis: Int64

    private var percent: Double { basis > 0 ? Double(segment.bytes) / Double(basis) * 100 : 0 }
    private var fraction: Double { min(1, max(0, percent / 100)) }

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            // 8pt 色块：与堆叠条同色，深色下不会变成白块
            RoundedRectangle(cornerRadius: Theme.Radius.chipSmall, style: .continuous)
                .fill(segment.color)
                .frame(width: 8, height: 8)

            HStack(spacing: Theme.Space.s) {
                Text(segment.name)
                    .font(Theme.Typo.navItem)
                    .foregroundStyle(segment.isEstimated ? Theme.t2 : Theme.t1)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: 168, alignment: .leading)   // .cr .cn{max-width:190px}
                if let tag = segment.tag {
                    Text(tag)
                        .font(Theme.Typo.mono(9))
                        .foregroundStyle(Theme.t3)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background {
                            RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous)
                                .fill(Theme.sunken)
                        }
                }
            }

            bar

            Text(percentText)
                .font(Theme.Typo.num(11, .medium))
                .foregroundStyle(Theme.t2)
                .lineLimit(1)
                .frame(width: 38, alignment: .trailing)

            Text(Fmt.bytes(segment.bytes))
                .font(Theme.Typo.num(11, .medium))
                .foregroundStyle(Theme.t3)
                .lineLimit(1)
                .frame(width: 56, alignment: .trailing)
        }
        .frame(height: 22)
        .accessibilityElement(children: .combine)
    }

    /// 0.4% 四舍五入成 0% 会读成「占 0 字节」，与右边的体积自相矛盾。
    private var percentText: String {
        if percent > 0, percent < 0.5 { return "<1%" }
        return String(format: "%.1f%%", percent)
    }

    private var bar: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.accent.opacity(0.11))
                if segment.isEstimated {
                    HatchedFill(color: segment.color)
                        .clipShape(Capsule())
                        .frame(width: max(1.5, geo.size.width * fraction), height: 5)
                } else {
                    Capsule()
                        .fill(LinearGradient(colors: [Theme.accentHi, Theme.accent],
                                             startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(1.5, geo.size.width * fraction))
                }
            }
            .frame(height: 5)
        }
        .frame(height: 5)
        .accessibilityHidden(true)
    }
}

// MARK: - 斜纹填充

/// 原型 `.cr.est .cb i` 的 `repeating-linear-gradient(135deg, fg 0 2px, transparent 2px 4px)`
/// —— 135°、2pt 实 2pt 空。Canvas 画的斜纹只在 5-8pt 高的条里出现，
/// 不值得为它引一个渐变资源。
/// 颜色由调用方给：估算段用它自己的 distColor（条上）或面板底色（堆叠条上），
/// 两种用法都靠斜纹本身透出下层来表现「空」。
private struct HatchedFill: View {
    let color: Color

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
                ctx.fill(stripe, with: .color(color))
                x += 4
            }
        }
    }
}

// MARK: - .lvl 量级徽标

/// 原型 `.lvl`：小胶囊，ok / warn 两态。
/// 绿走 Theme.success，橙走系统语义橙 `NSColor.systemOrange`（动态色，
/// 深色下自动降级，不硬编码字面量）。原来直接用 `Color.green` / `Color.orange`。
private struct LevelBadge: View {
    let text: String
    let isOK: Bool

    private static let warn = Color(nsColor: .systemOrange)

    private var tint: Color { isOK ? Theme.success : Self.warn }

    var body: some View {
        Text(text)
            .font(Theme.Typo.mono(9.5, .medium))    // .lvl{letter-spacing:.02em}
            .tracking(0.2)
            .foregroundStyle(tint)
            .padding(.horizontal, 7)
            .padding(.vertical, 1.5)
            .background {
                Capsule().fill(tint.opacity(isOK ? 0.14 : 0.15))
            }
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
