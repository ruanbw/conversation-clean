import Foundation
import Combine
import AppKit

enum CleanTarget {
    case selected
    case allInCurrentCategory
}

struct CategoryStats: Equatable {
    var count: Int = 0
    var sizeInBytes: Int64 = 0

    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: sizeInBytes, countStyle: .file)
    }
}

@MainActor
class CleanViewModel: ObservableObject {
    /// 设置面板 4 个开关的键名常量。真正读值的地方全在 `CleanPrefs`（Core 层），
    /// 这里只是给 UI 侧一个 `CleanViewModel.Prefs.autoScanOnLaunch` 的写法入口。
    typealias Prefs = CleanPrefs

    @Published var conversations: [ConversationItem] = [] {
        didSet {
            updateCachedStats()
            updateFilteredConversations()
        }
    }
    @Published var selectedCategory: ConversationCategory = .all {
        didSet {
            updateFilteredConversations()
        }
    }
    @Published var searchText: String = "" {
        didSet {
            searchSubject.send(searchText)
        }
    }

    @Published private(set) var filteredConversations: [ConversationItem] = []
    @Published private(set) var categoryStats: [ConversationCategory: CategoryStats] = [:]
    @Published private(set) var totalSize: Int64 = 0

    @Published var isScanning: Bool = false
    @Published var isCleaning: Bool = false
    @Published var lastCleanedBytes: Int64 = 0
    /// 上一轮清理实际移除的会话条数。成功横幅要同时展示「释放了多少」和「清了几条」，
    /// 两个数字都由执行点记账，而不是由发起方预先猜测 —— 检视器里的单条删除
    /// 并不经过 requestClean*，预记账会出现条数对不上的陈旧值。
    @Published private(set) var lastCleanedCount: Int = 0
    @Published var showCleanSuccessAlert: Bool = false

    /// 扫描完成横幅（原型 `flashOk("扫描完成 · 命中 …")`）。
    /// 只在「一键扫描」后显示，启动自动扫描不显示（避免开机就弹提示）。
    @Published var showScanSuccessAlert: Bool = false
    @Published private(set) var scanSuccessCount: Int = 0
    @Published private(set) var scanSuccessBytes: Int64 = 0
    @Published var showCleanConfirmAlert: Bool = false
    @Published var cleanTarget: CleanTarget = .selected
    /// 预览面板在清单改动后是否需要重建。
    /// 面板会算「预计释放 / 卷占用 / 空间构成」，目标一变这些数字就得重算。
    /// 用 token 而不是直接算在 body 里：后者每次重绘都会新建滚动状态、把滚动位置弹回顶部。
    @Published private(set) var estimateToken: Int = 0
    /// 预览面板当前作用在哪一个分类上 —— 面板是「整类清理」的语义，
    /// 打开后用户切分类不该让面板指向的集合跟着变，所以要钉住打开时的那一刻。
    @Published private(set) var estimateCategory: ConversationCategory = .all
    /// 面板打开那一刻的待清理条数。`estimateToken` 变化时一并记账，
    /// 面板据此把「将删除 N 个会话文件」写成打开瞬间的数字。
    @Published private(set) var estimateCount: Int = 0
    @Published var agentInfos: [AgentInfo] = []
    /// 本次进程内是否已经跑过一次扫描。列表空态要靠它区分「还没扫过」
    /// 和「扫完确实没有会话」——关掉「启动时自动扫描」时列表永远停在空态。
    @Published private(set) var hasScanned: Bool = false

    /// 搜索框的焦点请求（⌘F）。
    ///
    /// 原型把这条挂在 `document` 上：
    /// `if((e.metaKey||e.ctrlKey) && e.key.toLowerCase()==="f"){ e.preventDefault();
    ///   $("#q").focus(); $("#q").select(); }`
    /// 原生这边用 `@FocusState` 驱动，所以需要把焦点态提到能被菜单命令改写的高度。
    /// 放在 ViewModel 而不是 ContentView 的 `@State`：`⌘F` 定义在 App 的
    /// `.commands` 里，那儿拿不到 ContentView 的状态。
    @Published var searchFieldFocused: Bool = false

    /// 「设置」弹层是否打开（原型 `#setScrim` 的显隐）。
    /// 同样要跨 `.commands` 与视图共享，理由同 `searchFieldFocused`。
    @Published var settingsPresented: Bool = false

    private let scanService = AgentScanService.shared
    private let searchSubject = PassthroughSubject<String, Never>()
    private var cancellables = Set<AnyCancellable>()
    private var debouncedSearchText: String = ""
    /// 启动扫描只跑一次：`WindowGroup` 每开一个新窗口都会重跑一次 `.task`，
    /// 用这个闸门让后续窗口直接返回，不把全盘扫描重复几遍。
    private var hasAttemptedLaunchScan: Bool = false

    init() {
        setupSearchDebounce()
        updateCachedStats()
        // 这里原本还有一句无条件的 `Task { await scanConversations() }`：
        // 启动扫描改由 `scanOnLaunchIfEnabled()` 统一发起，否则「启动时自动扫描」
        // 关掉后这道暗门仍会把列表填上，开关形同虚设。
    }

    private func setupSearchDebounce() {
        searchSubject
            .debounce(for: .milliseconds(120), scheduler: RunLoop.main)
            .removeDuplicates()
            .sink { [weak self] debouncedQuery in
                guard let self = self else { return }
                self.debouncedSearchText = debouncedQuery.trimmingCharacters(in: .whitespacesAndNewlines)
                self.updateFilteredConversations()
            }
            .store(in: &cancellables)
    }

    var selectedItems: [ConversationItem] {
        conversations.filter { $0.isSelected }
    }

    var selectedSize: Int64 {
        selectedItems.reduce(0) { $0 + $1.sizeInBytes }
    }

    var currentCategorySize: Int64 {
        filteredConversations.reduce(0) { $0 + $1.sizeInBytes }
    }

    func selectAll(_ select: Bool) {
        let currentFilteredIds = Set(filteredConversations.map { $0.id })
        for index in conversations.indices {
            if currentFilteredIds.contains(conversations[index].id) {
                conversations[index].isSelected = select
            }
        }
        updateFilteredConversations()
    }

    func setItemSelected(_ id: UUID, selected: Bool) {
        if let idx = conversations.firstIndex(where: { $0.id == id }) {
            conversations[idx].isSelected = selected
        }
    }

    func scanConversations() async {
        guard !isScanning else { return }
        isScanning = true
        let scanned = await scanService.scanAll()
        conversations = scanned
        agentInfos = scanService.getAgentInfos(from: scanned)
        isScanning = false
        hasScanned = true
        // 原型 `flashOk("扫描完成 · 命中 N 个会话，合计 X。")`
        scanSuccessCount = scanned.count
        scanSuccessBytes = scanned.reduce(0) { $0 + $1.sizeInBytes }
        showScanSuccessAlert = true
        reconcileSelectedCategory()
    }

    /// 扫描完成后校正 `selectedCategory`。
    ///
    /// 分类是从 `localStorage` 恢复的（原型 `P.cat`），而可见分类取决于**本机装了什么**。
    /// 上一台机器上装过 Cursor、这台没装时，恢复出来的 `.cursor` 会在侧栏里根本不存在，
    /// 列表却按它过滤 —— 结果是「选了个看不见的分类，右边空空如也」。
    /// 所以扫完必须校一次：未安装的分类回落 `.all`。
    private func reconcileSelectedCategory() {
        guard selectedCategory != .all else { return }
        let installed = Set(agentInfos.filter(\.isInstalled).map(\.category))
        guard !installed.contains(selectedCategory) else { return }
        selectedCategory = .all
    }

    // MARK: - 设置开关的生效点

    /// 「启动时自动扫描」当前值。只在启动那一刻读一次，运行中改它不重新扫描。
    var scansOnLaunch: Bool { CleanPrefs.autoScanOnLaunch }

    /// 启动扫描的唯一入口。由 `ConversationCleanApp` 的 `.task` 调用。
    func scanOnLaunchIfEnabled() async {
        // 幂等：后续新开的窗口也会重跑 `.task`，谁先到谁扫，后到的直接退出。
        guard !hasAttemptedLaunchScan else { return }
        hasAttemptedLaunchScan = true

        guard scansOnLaunch else { return }
        await scanConversations()
    }

    /// 「回收空项目目录」关掉时，删除会话会在磁盘上留下空的 project / 目录。
    /// 侧栏那句说明文字（原型 `.ov-note`）要跟着变，由它直接取。
    var emptyFolderPolicyText: String {
        CleanPrefs.cleanEmptyProjectFolders
            ? "删除会话后会一并回收空目录与子代理目录。"
            : "空目录将保留在磁盘上，可在设置中开启回收。"
    }

    /// 「同时清理文件历史快照」关掉时，删除会话只删正文，文件改动快照保留。
    /// 侧栏 `pathNote` 说的就是这件事，一并提供。
    var snapshotPolicyText: String {
        CleanPrefs.cleanFileHistorySnapshots
            ? "清理时同步删除快照与子代理数据。"
            : "清理时保留文件改动快照，只删会话文件。"
    }

    /// 请求清理选中项。`confirmBeforeClean` 关掉时一步到底，不弹面板。
    func requestCleanSelected() {
        guard !selectedItems.isEmpty else { return }
        presentCleanConfirm(target: .selected)
    }

    /// 请求清理当前列表全部（「清除全部」/「清除本分类」）。
    func requestCleanAll() {
        guard !filteredConversations.isEmpty else { return }
        presentCleanConfirm(target: .allInCurrentCategory)
    }

    private func presentCleanConfirm(target: CleanTarget) {
        cleanTarget = target
        // 钉住打开时的分类：面板是「整类清理」语义，期间切分类不该改它的目标集合。
        estimateCategory = selectedCategory
        estimateCount = estimateTargets(for: target).count
        estimateToken &+= 1
        guard CleanPrefs.confirmBeforeClean else {
            Task { await executeClean() }
            return
        }
        showCleanConfirmAlert = true
    }

    /// 目标集合的条数。面板、确认前记账、执行三处共用，避免各自 reduce。
    func estimateTargets(for target: CleanTarget) -> [ConversationItem] {
        switch target {
        case .selected:             return selectedItems
        case .allInCurrentCategory: return filteredConversations
        }
    }

    /// 取消清理（原型 `#shCancel` 与点遮罩/Esc 两条路径共用）。
    /// 只收起面板，不碰任何数据。
    func cancelClean() {
        showCleanConfirmAlert = false
    }

    func executeClean() async {
        guard !isCleaning else { return }
        isCleaning = true
        showScanSuccessAlert = false  // 两个横幅互斥

        let itemsToDelete = estimateTargets(for: cleanTarget)

        guard !itemsToDelete.isEmpty else {
            isCleaning = false
            showCleanConfirmAlert = false
            return
        }

        let freedBytes = await scanService.delete(items: itemsToDelete)
        let idsToDelete = Set(itemsToDelete.map { $0.id })
        conversations.removeAll { idsToDelete.contains($0.id) }
        agentInfos = scanService.getAgentInfos(from: conversations)

        lastCleanedBytes = freedBytes > 0 ? freedBytes : itemsToDelete.reduce(0) { $0 + $1.sizeInBytes }
        lastCleanedCount = itemsToDelete.count
        isCleaning = false
        // 面板由遮罩层显隐驱动，`executeClean` 必须自己收起它。
        // 之前靠 `.sheet` 的自动 dismiss，面板只是「恰好」跟着数据变化关掉了。
        showCleanConfirmAlert = false
        showCleanSuccessAlert = true
    }

    func deleteSingle(item: ConversationItem) async {
        let freedBytes = await scanService.delete(items: [item])
        conversations.removeAll { $0.id == item.id }
        agentInfos = scanService.getAgentInfos(from: conversations)
        lastCleanedBytes = freedBytes > 0 ? freedBytes : item.sizeInBytes
        lastCleanedCount = 1
        isCleaning = false
        showScanSuccessAlert = false
        showCleanSuccessAlert = true
    }

    /// `deleteSingle` 已被 `requestCleanSingle` + `executeClean` 取代：
    /// 原型里单条删除也要过确认面板，直接删的路径没有入口。
    /// 保留为薄封装，供不需要二次确认的内部调用点使用。

    func revealInFinder(item: ConversationItem) {
        if let firstPath = item.associatedPaths.first, FileManager.default.fileExists(atPath: firstPath) {
            NSWorkspace.shared.selectFile(firstPath, inFileViewerRootedAtPath: "")
        } else if let projectPath = item.projectPath, FileManager.default.fileExists(atPath: projectPath) {
            NSWorkspace.shared.selectFile(projectPath, inFileViewerRootedAtPath: "")
        }
    }

    func copyToClipboard(text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    // MARK: - State Caching & Filtering Optimization

    private func updateCachedStats() {
        var stats: [ConversationCategory: CategoryStats] = [:]
        for cat in ConversationCategory.allCases {
            stats[cat] = CategoryStats()
        }

        var total: Int64 = 0
        for item in conversations {
            total += item.sizeInBytes
            stats[item.category, default: CategoryStats()].count += 1
            stats[item.category, default: CategoryStats()].sizeInBytes += item.sizeInBytes
            stats[.all, default: CategoryStats()].count += 1
            stats[.all, default: CategoryStats()].sizeInBytes += item.sizeInBytes
        }

        self.categoryStats = stats
        self.totalSize = total
    }

    private func updateFilteredConversations() {
        let query = debouncedSearchText.isEmpty ? searchText.trimmingCharacters(in: .whitespacesAndNewlines) : debouncedSearchText
        let targetCategory = selectedCategory

        if query.isEmpty {
            if targetCategory == .all {
                filteredConversations = conversations
            } else {
                filteredConversations = conversations.filter { $0.category == targetCategory }
            }
        } else {
            filteredConversations = conversations.filter { item in
                let matchesCategory = (targetCategory == .all || item.category == targetCategory)
                guard matchesCategory else { return false }
                return item.title.localizedCaseInsensitiveContains(query) ||
                    item.snippet.localizedCaseInsensitiveContains(query) ||
                    (item.projectPath?.localizedCaseInsensitiveContains(query) ?? false) ||
                    item.sessionId.localizedCaseInsensitiveContains(query)
            }
        }
    }
}
