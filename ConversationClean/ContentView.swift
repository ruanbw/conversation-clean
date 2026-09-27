import SwiftUI
import AppKit

// MARK: - ContentView · 三栏工作台
//
// 结构照 DefaultAppManager 的 MainSplitView：**不是** NavigationSplitView。
// 原因就一条：红绿灯。
//
// 用系统标题栏时，红绿灯底下那块是系统画的原生标题栏，颜色不可控 —— 深色模式下
// 侧栏是深灰、标题栏是另一种灰，视觉上永远是"贴了块补丁"。`.windowStyle(.hiddenTitleBar)`
// 把那块变成我们自己的背景，深浅色自动跟着走，代价是得自己给红绿灯让出左侧 78pt。
//
// 三栏也是手搓 HStack，不是 NavigationSplitView：后者会自己往窗口上挂一条
// NSToolbar（多出 ~52pt 带子）、给侧栏套 sidebar 材质，这些都不是我们要的形态。
//
// 本文件只管窗口这一层：顶部条、三栏几何、全局动作、弹层编排。
//
// 视觉基线 ui-a-precision.html：三栏**不是**同一个 windowBackgroundColor。
// 原实现三栏同色，截图里就是三块白板拼贴；现在按表面梯分四层 ——
// 侧栏 sunken 之下、内容面 surface 最亮、详情栏 bg 居中，层级一下就出来了。

struct ContentView: View {
    @EnvironmentObject var viewModel: CleanViewModel

    /// 三栏列宽存 AppStorage：原生 App 记住列宽是基本礼貌，
    /// 每次开窗口都要重新拖一遍分隔条，用户只会当成 bug。
    @AppStorage("sidebarWidth") private var sidebarWidth: Double = 230
    @AppStorage("listWidth") private var listWidth: Double = 400

    private let sidebarMin: CGFloat = 200
    private let sidebarMax: CGFloat = 420
    private let listMin: CGFloat = 340
    private let listMax: CGFloat = 760
    /// 详情栏是唯一吃剩余宽度的栏（`maxWidth: .infinity`），
    /// 它的 minWidth 则是另两条分隔条的拖拽上限从哪里来。
    private let detailMin: CGFloat = 300

    var body: some View {
        VStack(spacing: 0) {
            topBar
            GeometryReader { geo in
                columns(available: geo.size.width)
            }
        }
        .background(Theme.bg)
        // 让内容铺到窗口最顶端 y=0，红黄绿浮在我们自己的背景上。
        // 不用 NSWindow.styleMask 插 fullSizeContentView：那个 mask 由 SwiftUI 自己持有，
        // 手动插会被回退。
        .ignoresSafeArea(edges: .top)
        .sheet(isPresented: $viewModel.showCleanConfirmAlert) {
            CleanConfirmSheet()
                .environmentObject(viewModel)
        }
    }

    /// 分隔条的可达区间必须随窗口宽度收窄。
    ///
    /// 固定 max 会拼出这种破图：窗口只有 1000pt（App 的 minWidth）时把列表拖到 760，
    /// 侧栏又停在 420，1000 - 420 - 760 = -180，剩下不够详情栏的 minWidth，
    /// 三栏互相挤到变形。所以上限用 `available - 另一栏的 min - 详情栏 min` 算。
    private func columns(available: CGFloat) -> some View {
        let sidebarCeiling = max(sidebarMin, min(sidebarMax, available - listMin - detailMin))
        // 实际生效的宽度要再夹一次，不能只靠拖拽时的 range：
        // 存值可能来自一个更宽的窗口（上次把侧栏拖到 420，现在把窗口缩回 1000），
        // 那种情况下 range 从头到尾没参与计算，不夹就会直接挤变形。
        let sidebar = min(CGFloat(sidebarWidth), sidebarCeiling)
        let listCeiling = max(listMin, min(listMax, available - sidebar - detailMin))
        let list = min(CGFloat(listWidth), listCeiling)
        return HStack(spacing: 0) {
            SidebarView()
                .frame(width: sidebar)
            ColumnResizeHandle(width: $sidebarWidth,
                               range: sidebarMin...sidebarCeiling,
                               growsWithRightwardDrag: true)
            ConversationListView()
                .frame(width: list)
            // 列表是中间栏，往右拖它变宽、详情栏变窄，所以方向取反。
            ColumnResizeHandle(width: $listWidth,
                               range: listMin...listCeiling,
                               growsWithRightwardDrag: false)
            DetailView()
                .frame(minWidth: detailMin, maxWidth: .infinity)
        }
    }

    // MARK: - 顶部条
    //
    // 左侧 78pt 让给红绿灯（三个 12pt 圆点 + 两个 8pt gap + 16pt 外边距），
    // 之后是产品名与总量，右侧是全局动作。
    //
    // 与旧版的差别：按钮不再是 `.foregroundStyle(.secondary)` 的裸 SF Symbol 加
    // `accentColor.opacity(0.14)` 自绘淡蓝底（那套看着像网页），改成走
    // DrawnButtonStyle —— 主操作是靛蓝渐变实心，次要操作是 hover 才显底。

    private var topBar: some View {
        HStack(spacing: Theme.Space.s) {
            Text("ConversationClean")
                .font(Theme.Typo.brand)
                .foregroundStyle(Theme.t1)
            Text("会话清理")
                .font(Theme.Typo.navItem)
                .foregroundStyle(Theme.t3)

            Rectangle()
                .fill(Theme.lineStrong)
                .frame(width: 1, height: 12)
                .padding(.horizontal, 2)
            Text(Fmt.bytes(viewModel.totalSize))
                .font(Theme.Typo.num(12, .semibold))
                .foregroundStyle(Theme.t1)
            Text("· \(viewModel.conversations.count) 个会话")
                .font(Theme.Typo.rowSub)
                .foregroundStyle(Theme.t3)

            Spacer(minLength: Theme.Space.l)

            // 危险动作图标：用 dangerQuiet（红前景、无底色）。顶栏只有 26pt 高，
            // 实心红底会扎眼，但灰色又会让「删全部」看起来和「设置」一样重。
            Button(action: { viewModel.requestCleanAll() }) {
                Image(systemName: "trash")
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: Theme.Size.buttonIcon, height: Theme.Size.button)
            }
            .buttonStyle(DrawnButtonStyle(variant: .dangerQuiet, horizontalPadding: 0))
            .disabled(viewModel.filteredConversations.isEmpty || isBusy)
            .keyboardShortcut(.delete, modifiers: .command)
            .help("清除当前列表中的全部会话")

            Button {
                Task { await viewModel.scanConversations() }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: viewModel.isScanning
                          ? "arrow.triangle.2.circlepath" : "arrow.clockwise")
                        .font(.system(size: 11, weight: .semibold))
                    Text(viewModel.isScanning ? "正在扫描…" : "一键扫描")
                        .font(Theme.Typo.navItem.weight(.medium))
                }
            }
            .buttonStyle(DrawnButtonStyle(variant: .primary, enabled: !isBusy))
            .disabled(isBusy)
            .keyboardShortcut("r", modifiers: .command)
            .help("扫描本机全部 Agent 的会话缓存")

            Button {
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: Theme.Size.buttonIcon, height: Theme.Size.button)
            }
            .buttonStyle(DrawnButtonStyle(variant: .flat, horizontalPadding: 0))
            .help("设置")
        }
        .padding(.leading, Theme.Size.trafficLightInset)
        .padding(.trailing, Theme.Space.l)
        .frame(height: Theme.Size.topBar)
        .background(Theme.bg)
        .hairline(.bottom)
    }

    private var isBusy: Bool { viewModel.isScanning || viewModel.isCleaning }
}

// MARK: - 栏间分隔条
//
// 原生三栏都能拖分隔条改列宽并记住。上一版把侧栏钉死 230pt、详情栏吃掉全部
// 剩余宽度，想给列表更多空间只能去拖窗口边框 —— 那不叫可用性。
//
// 两处细节决定它好不好用：
//   ① 命中区 11pt，视觉线只有 1pt。线画多宽就只能拖多宽的话，那条线根本点不中。
//   ② 拖动量从**按下那一刻**的宽度起算（`anchorWidth`），不是逐帧累加 translation。
//      累加的话掉一帧就把误差一并放大，鼠标一松手列宽会跳一下。

private struct ColumnResizeHandle: View {
    @Binding var width: Double
    let range: ClosedRange<CGFloat>
    /// true = 往右拖变宽（左侧栏），false = 往左拖变宽（中间列表）。
    let growsWithRightwardDrag: Bool

    @State private var anchorWidth: Double?
    @State private var hovering = false

    var body: some View {
        Color.clear
            .frame(width: 11)
            .background(hovering ? Color.primary.opacity(0.05) : .clear)
            .overlay(alignment: .center) {
                Rectangle()
                    .fill(Theme.line)
                    .frame(width: 1)
            }
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        let base = anchorWidth ?? width
                        if anchorWidth == nil { anchorWidth = width }
                        let delta = growsWithRightwardDrag
                            ? value.translation.width
                            : -value.translation.width
                        let next = base + delta
                        width = Double(min(max(CGFloat(next), range.lowerBound), range.upperBound))
                    }
                    .onEnded { _ in anchorWidth = nil }
            )
            .help("拖动调整列宽")
    }
}
