import AppKit
import Combine
import Foundation

/// 键盘导航后需要把某一行滚进视口（用 token 保证同一个 URL/目标 连续触发也能生效）
struct ScrollRequest: Equatable {
    enum Target: Equatable {
        case item(URL)
        /// 列表底部留白（滚到底：scroll:end 钩子与截图验收用）
        case trailingBlank
    }

    let target: Target
    let token: UUID

    init(_ url: URL) {
        target = .item(url)
        token = UUID()
    }

    init(trailingBlank: Bool = true) {
        target = .trailingBlank
        token = UUID()
    }

    /// 项滚动请求的 URL（其它目标为 nil），旧调用/断言可继续用
    var url: URL? {
        if case .item(let url) = target { return url }
        return nil
    }
}

/// 浏览器的全部状态与动作。
/// 所有方法都在主线程调用（SwiftUI 的按钮/菜单/键盘回调），单目录读取是毫秒级的。
final class BrowserModel: ObservableObject {

    /// 标签身份（TabsModel / SwiftUI ForEach 用）
    let tabID = UUID()

    @Published private(set) var currentURL: URL
    @Published private(set) var items: [FileItem] = []
    @Published private(set) var errorMessage: String?
    /// 目录正在后台读取（状态栏显示小转圈，避免"点了没反应"的错觉）
    @Published private(set) var isLoadingDirectory = false
    /// 目录监听触发的自动刷新正在进行（同一时刻只允许一次）
    private var isRefreshing = false

    // MARK: - 树形展开（adr/0019）

    /// 已展开的文件夹。折叠时会把它的所有后代一起移出，
    /// 否则重新展开这个文件夹时，里面的子节点会「记着」上次是展开的。
    @Published private(set) var expandedPaths: Set<String> = []
    /// 展开过的文件夹里有什么（key: 标准化路径）。
    /// 读过的空目录也会写进来（空数组），用来区分「没读过」和「读了但没有」。
    private var treeChildren: [String: [FileItem]] = [:]
    /// 正在后台读取的文件夹（行上显示小转圈）
    @Published private(set) var loadingTreePaths: Set<String> = []
    /// 扁平化后的可见行：`LazyVStack` 直接渲染这个
    @Published private(set) var treeRows: [TreeRow] = []
    @Published var flash: String?

    /// 多选集合
    @Published private(set) var selection: Set<URL> = []
    /// 键盘导航的当前项（也是"主选中项"）
    @Published private(set) var focusedURL: URL?
    /// Shift 连选的锚点
    private var anchorURL: URL?
    /// 视图消费后触发滚动定位
    @Published var scrollRequest: ScrollRequest?

    /// 正在行内重命名的项
    @Published private(set) var renamingURL: URL?
    /// 等待用户确认的"彻底删除"目标
    @Published private(set) var pendingPermanentDelete: [FileItem]?
    /// 待确认的「移到废纸篓」：文件夹会连子项一起进废纸篓，先把数量说清楚（adr/0019）
    @Published private(set) var pendingTrash: [FileItem]?

    /// 批量重命名编辑态（nil 表示面板关闭）
    @Published var batchRename: BatchRenameState?
    /// 压缩 / 解压这类"拿不到细粒度进度"的任务（nil 表示空闲）
    @Published private(set) var archiveBusy: TransferProgress?
    private var archiveTask: ArchiveTask?
    private var clipboardCancellable: AnyCancellable?

    /// 应用内文件剪贴板（复制 / 剪切）。
    /// 底层是全局共享的 ClipboardStore：⌘C 在标签 A / 窗口 A，切到标签 B 直接 ⌘V
    /// （Windows 剪贴板本来就是全局的，adr/0006）。订阅广播保证
    /// 「剪切中变淡」在所有标签和窗口同步刷新。
    var clipboard: FileClipboard? {
        get { ClipboardStore.shared.item }
        set { ClipboardStore.shared.set(newValue) }
    }
    /// 正在进行的复制 / 跨卷移动（nil 表示空闲）
    @Published private(set) var transfer: TransferProgress?
    private var transferCancellation: TransferCancellation?
    /// 拖拽悬停中的文件夹行（用于高亮落点）
    @Published var dropTargetURL: URL?

    /// 地址栏是否处于编辑态
    @Published private(set) var isEditingPath = false
    /// 地址栏编辑中的文本
    @Published var pathDraft: String = ""
    /// 地址栏编辑的错误提示（路径不存在等）
    @Published private(set) var pathError: String?

    /// 当前目录的搜索词（实时过滤，不递归子目录）
    @Published var searchText: String = "" {
        didSet {
            guard searchText != oldValue else { return }
            // 每敲一个字符都全量过滤 + 排序会明显卡手（排序用 localizedStandardCompare，
            // 很贵）。输入停 0.18s 后才真正过滤；回车/失焦等路径仍即时生效。
            guard Self.debouncesSearch else {
                applySortAndFilter()
                return
            }
            searchDebounce?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.applySortAndFilter() }
            searchDebounce = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: work)
        }
    }
    private var searchDebounce: DispatchWorkItem?
    /// 视图消费后把焦点放进搜索框（⌘F 每次都是新的 token，连按会重新全选）
    @Published private(set) var searchFocusRequest: UUID?

    /// 属性面板的内容（nil 表示关闭）
    @Published private(set) var info: InfoSheetState?

    /// 等待用户授权才能继续的那一项 / 那个目录（nil 表示没有）
    @Published private(set) var accessRequest: AccessRequest?

    /// 关于面板
    @Published var showsAbout = false

    func showAbout() {
        showsAbout = true
    }

    func closeAbout() {
        showsAbout = false
    }

    /// 视图模式
    @Published var viewMode: ViewMode = Preferences.viewMode {
        didSet {
            guard viewMode != oldValue else { return }
            Preferences.viewMode = viewMode
        }
    }

    /// 详细信息视图的列宽
    @Published private(set) var columnWidths: ColumnWidths = Preferences.columnWidths

    /// 图标视图当前能放下几列（由视图回写，键盘导航要用）
    @Published var gridColumnCount: Int = 4

    /// 自检时关掉，避免动到用户的系统剪贴板
    static var syncsSystemPasteboard = true
    /// 自检时同步执行复制/移动，便于断言（生产路径始终异步）
    static var runsTransfersSynchronously = false
    /// 自检时不算属性面板的文件夹大小（避免在临时目录里递归等待）
    static var computesFolderSizeSynchronously = false
    /// 自检时关掉目录监听（用例会自己造/删文件，自动刷新会干扰断言）
    static var watchesFileSystem = true
    /// 搜索是否防抖（自检里关掉，设完 searchText 立刻能断言过滤结果）
    static var debouncesSearch = true
    /// 目录读取是否同步（自检里打开，navigate 完立刻能断言；生产路径始终后台读）
    static var loadsDirectorySynchronously = false

    // MARK: - 撤销栈

    private var undoStack: [UndoEntry] = []
    private var redoStack: [UndoEntry] = []
    private static let undoLimit = 50

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }
    var undoTitle: String? { undoStack.last?.title }
    var redoTitle: String? { redoStack.last?.title }

    func registerUndo(_ entry: UndoEntry) {
        undoStack.append(entry)
        if undoStack.count > Self.undoLimit { undoStack.removeFirst() }
        redoStack.removeAll()
    }

    func undo() {
        guard let entry = undoStack.popLast() else {
            showFlash("Nothing to undo")
            return
        }
        entry.undo()
        redoStack.append(entry)
        reload()
        showFlash(L("已撤销：\(entry.title)", "Undone: \(entry.title)"))
    }

    func redo() {
        guard let entry = redoStack.popLast() else {
            showFlash("Nothing to redo")
            return
        }
        entry.redo()
        undoStack.append(entry)
        reload()
        showFlash(L("已重做：\(entry.title)", "Redone: \(entry.title)"))
    }

    /// 为一批移动/复制生成撤销项：移动就搬回去，复制就把副本删掉
    private func transferUndo(_ requests: [TransferRequest], targetName: String) -> UndoEntry {
        let copyCount = requests.filter { $0.mode == .copy }.count
        let verb: String
        if copyCount == requests.count {
            verb = L("复制", "copy")
        } else if copyCount == 0 {
            verb = L("移动", "move")
        } else {
            verb = L("移动/复制", "move/copy")
        }
        let title = L("\(verb) \(requests.count) 项到「\(targetName)」", "\(verb) \(requests.count) item(s) to “\(targetName)”")

        return UndoEntry(
            title: title,
            undo: { [weak self] in
                guard let self else { return }
                let fm = FileManager.default
                var reverted = 0
                for request in requests.reversed() {
                    switch request.mode {
                    case .move:
                        if fm.fileExists(atPath: request.destination.path),
                           !fm.fileExists(atPath: request.source.path) {
                            do {
                                try fm.moveItem(at: request.destination, to: request.source)
                                reverted += 1
                            } catch {
                                self.errorMessage = L("撤销移动失败：\(error.localizedDescription)", "Couldn’t undo the move: \(error.localizedDescription)")
                            }
                        }
                    case .copy:
                        if fm.fileExists(atPath: request.destination.path) {
                            do {
                                try fm.removeItem(at: request.destination)
                                reverted += 1
                            } catch {
                                self.errorMessage = L("撤销复制失败：\(error.localizedDescription)", "Couldn’t undo the copy: \(error.localizedDescription)")
                            }
                        }
                    }
                }
                if reverted == 0 { self.errorMessage = L("撤销失败：这些项目已经不在原位置了", "Undo failed: those items are no longer in their original location") }
            },
            redo: { [weak self] in
                guard let self else { return }
                let fm = FileManager.default
                for request in requests {
                    switch request.mode {
                    case .move:
                        if fm.fileExists(atPath: request.source.path),
                           !fm.fileExists(atPath: request.destination.path) {
                            do {
                                try fm.moveItem(at: request.source, to: request.destination)
                            } catch {
                                self.errorMessage = L("重做移动失败：\(error.localizedDescription)", "Couldn’t redo the move: \(error.localizedDescription)")
                            }
                        }
                    case .copy:
                        if !fm.fileExists(atPath: request.destination.path) {
                            do {
                                try fm.copyItem(at: request.source, to: request.destination)
                            } catch {
                                self.errorMessage = L("重做复制失败：\(error.localizedDescription)", "Couldn’t redo the copy: \(error.localizedDescription)")
                            }
                        }
                    }
                }
            }
        )
    }

    @Published var sortColumn: SortColumn = Preferences.sortColumn {
        didSet {
            Preferences.sortColumn = sortColumn
            applySortAndFilter()
        }
    }
    @Published var sortAscending: Bool = Preferences.sortAscending {
        didSet {
            Preferences.sortAscending = sortAscending
            applySortAndFilter()
        }
    }
    @Published var showHidden: Bool = Preferences.showHidden {
        didSet {
            Preferences.showHidden = showHidden
            applySortAndFilter()
        }
    }

    /// 是否在列表里显示文件夹大小（异步统计，默认关闭）
    @Published var showsFolderSizes: Bool = Preferences.showsFolderSizes {
        didSet {
            guard showsFolderSizes != oldValue else { return }
            Preferences.showsFolderSizes = showsFolderSizes
            refreshFolderSizes()
        }
    }

    /// 已经算出来的文件夹大小（path → 大小）。
    /// 实现在 FolderSizeCoordinator 里，这里只做转发，视图读到的还是 `model.folderSizes`
    var folderSizes: [String: FolderSizeService.Size] { folderSizeCoordinator.sizes }
    private let folderSizeCoordinator = FolderSizeCoordinator()
    private var folderSizeCancellable: AnyCancellable?

    @Published private(set) var backStack: [URL] = []
    @Published private(set) var forwardStack: [URL] = []

    private var allItems: [FileItem] = []
    private var flashWorkItem: DispatchWorkItem?
    private var cachedPasteboardChangeCount = -1
    private var cachedPasteboardURLs: [URL] = []
    /// 上次真正问系统剪贴板的时间。
    /// 右键菜单是**逐行预先构建**的（SwiftUI 的 contextMenu 会立即求值），
    /// 一帧内可能问几百次 `pasteboard.changeCount` —— 那是 XPC，会把主线程拖死。
    /// 所以这里限速：250ms 内只问一次，其余读缓存（adr/0016）。
    private var lastPasteboardProbe = Date.distantPast
    /// 剪贴板里是否有可粘贴的文件（canPaste 只读这个）
    private var pasteboardHasFiles = false

    /// 目录监听（外部新增/删除文件时自动刷新）
    private let directoryWatcher = DirectoryWatcher()
    /// 上一次读到的目录快照（用来判断内容是否真的变了，避免无意义刷新）
    private var directorySignature: [String] = []
    /// 正在显示属性的目标（异步统计文件夹大小要用）
    private var infoTargets: [FileItem] = []
    /// 属性面板的代次：用户关掉或换目标后，旧的统计结果直接丢弃
    private var infoGeneration = 0

    /// 根卷的名字，比如 "Macintosh HD"
    static let volumeName: String = {
        let root = URL(fileURLWithPath: "/")
        let values = try? root.resourceValues(forKeys: [.volumeLocalizedNameKey])
        return values?.volumeLocalizedName ?? "Macintosh HD"
    }()

    init(startAt url: URL? = nil) {
        // 开发钩子：WINEXPLORER_START=/某个/目录 可直接打开指定目录，便于截图验收
        let envStart = ProcessInfo.processInfo.environment["WINEXPLORER_START"]
            .map { URL(fileURLWithPath: $0) }

        // 上次浏览的目录（和资源管理器一样，重开回到原处），目录不在就回个人文件夹
        let remembered: URL? = Preferences.lastDirectoryPath.flatMap { path in
            var isDirectory: ObjCBool = false
            let candidate = URL(fileURLWithPath: path)
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
                  isDirectory.boolValue else { return nil }
            return candidate
        }

        let requested = url ?? envStart ?? remembered ?? FileManager.default.homeDirectoryForCurrentUser
        let start = requested.standardizedFileURL
        currentURL = start
        load(directory: start, recordHistory: false)

        // 外部程序在这个目录里新建/删除/改名时自动刷新
        directoryWatcher.onChange = { [weak self] in
            self?.handleDirectoryChange()
        }

        // 全局剪贴板变化 → 本模型也发 objectWillChange，
        // 让「剪切中变淡」在所有标签 / 窗口里同步刷新
        clipboardCancellable = ClipboardStore.shared.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }

        // 文件夹大小统计搬到了 FolderSizeCoordinator：它的变化也要让视图重绘
        folderSizeCancellable = folderSizeCoordinator.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    // MARK: - 导航状态

    var canGoBack: Bool { !backStack.isEmpty }
    var canGoForward: Bool { !forwardStack.isEmpty }
    var canGoUp: Bool { currentURL.path != "/" }
    var hasSelection: Bool { !selection.isEmpty }

    /// 剪切中的项，行里会画成半透明（Windows 的"待移动"观感）
    var cutURLs: Set<URL> { clipboard?.cutURLs ?? [] }

    /// 有剪贴板内容或系统剪贴板里有文件，才能粘贴
    var canPaste: Bool {
        if clipboard != nil { return true }
        probePasteboardIfNeeded()
        return pasteboardHasFiles
    }

    /// 限速探测系统剪贴板。菜单逐行构建时绝大多数调用会在这里直接返回。
    private func probePasteboardIfNeeded() {
        let now = Date()
        guard now.timeIntervalSince(lastPasteboardProbe) >= 0.25 else { return }
        lastPasteboardProbe = now
        pasteboardHasFiles = !systemPasteboardFileURLs().isEmpty
    }

    /// 有复制/移动任务在跑
    var isTransferring: Bool { transfer != nil }

    /// 有复制/移动/压缩/解压任务在跑（这些操作都会改磁盘，彼此不能并发）
    var isBusy: Bool { transfer != nil || archiveBusy != nil }

    /// 可以压缩：选了东西且没有别的任务在跑
    var canCompress: Bool { hasSelection && !isBusy }

    /// 可以解压：选区里至少有一个 zip
    var canExtract: Bool {
        hasSelection && !isBusy && selectedItems.contains { ArchiveService.isArchive($0.url) }
    }

    /// 批量重命名的预览结果（面板关闭时为 nil）
    var batchRenamePlan: BatchRenamePlan? {
        batchRename.map { BatchRenamePlan.make($0) }
    }

    /// 该行是否是当前拖拽落点。
    /// 不能直接用 URL 相等：枚举出来的 URL 可能带尾斜杠，/tmp 也会被标准化成 /private/tmp。
    func isDropTarget(_ url: URL) -> Bool {
        guard let target = dropTargetURL else { return false }
        return target.standardizedFileURL.path == url.standardizedFileURL.path
    }

    /// 拖动时实际要带的 URL：拖的是选中项就整批带走，按列表顺序
    var dragURLs: [URL] {
        items.filter { selection.contains($0.url) }.map(\.url)
    }

    /// 焦点在文本框里（正在行内重命名）。
    /// 此时 ⌘C/⌘X/⌘V/⌘A 必须作用于文字，不能拿来操作文件。
    var textEditor: NSTextView? {
        NSApp.keyWindow?.firstResponder as? NSTextView
    }

    /// 窗口标题：当前文件夹名（根目录显示卷名）
    var titleText: String {
        currentURL.path == "/" ? Self.volumeName : currentURL.lastPathComponent
    }

    var selectedItems: [FileItem] {
        items.filter { selection.contains($0.url) }
    }

    var selectedTotalSize: Int64 {
        selectedItems.reduce(Int64(0)) { partial, item in
            item.isDirectory ? partial : partial + (item.size ?? 0)
        }
    }

    /// 一行的「大小」列文字：文件直接给大小，文件夹按需异步统计
    func sizeText(for item: FileItem) -> String {
        // 未授权项读不到内容，别把统计出来的 0 当成"空文件夹"
        guard item.isAccessible else { return "—" }
        guard item.isDirectory else { return item.sizeText }
        guard showsFolderSizes else { return "—" }
        guard let size = folderSizes[item.url.standardizedFileURL.path] else { return "…" }
        // 受保护位置没去枚举，别把 0 显示成「空文件夹」
        guard !size.skipped else { return "—" }
        let text = FileItem.byteText(size.bytes)
        return size.truncated ? "≥ " + text : text
    }

    /// 文件夹大小的统计进度（0…1，没有在算时返回 nil），状态栏用
    var folderSizeProgress: (done: Int, total: Int)? {
        guard showsFolderSizes else { return nil }
        let folders = items.filter { $0.isDirectory && $0.isAccessible }
        guard !folders.isEmpty else { return nil }
        let done = folders.filter { folderSizes[$0.url.standardizedFileURL.path] != nil }.count
        guard done < folders.count else { return nil }
        return (done, folders.count)
    }

    var crumbs: [Crumb] {
        var result: [Crumb] = []
        let root = URL(fileURLWithPath: "/")
        result.append(Crumb(url: root, title: Self.volumeName))

        var accumulated = root
        for component in currentURL.pathComponents.dropFirst() {
            accumulated.appendPathComponent(component)
            result.append(Crumb(url: accumulated, title: component))
        }
        return result
    }

    // MARK: - 导航动作

    func navigate(to url: URL) {
        load(directory: url.standardizedFileURL, recordHistory: true)
    }

    func goBack() {
        guard let previous = backStack.popLast() else { return }
        forwardStack.append(currentURL)
        load(directory: previous, recordHistory: false)
    }

    func goForward() {
        guard let next = forwardStack.popLast() else { return }
        backStack.append(currentURL)
        load(directory: next, recordHistory: false)
    }

    func goUp() {
        guard canGoUp else { return }
        navigate(to: currentURL.deletingLastPathComponent())
    }

    func goHome() {
        navigate(to: FileManager.default.homeDirectoryForCurrentUser)
    }

    func reload() {
        load(directory: currentURL, recordHistory: false)
    }

    func dismissError() {
        errorMessage = nil
    }

    // MARK: - 搜索

    var searchQuery: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var isSearching: Bool { !searchQuery.isEmpty }

    /// ⌘F：把焦点放进搜索框并全选已有内容
    func beginSearch() {
        // 聚焦搜索框 = 放弃地址栏编辑（两个输入状态互斥，adr/0005）
        cancelPathEditing()
        searchFocusRequest = UUID()
    }

    func clearSearch() {
        searchText = ""
    }

    // MARK: - 地址栏

    func beginPathEditing() {
        guard !isEditingPath else { return }
        pathError = nil
        pathDraft = currentURL.path
        isEditingPath = true
    }

    func cancelPathEditing() {
        guard isEditingPath else { return }
        isEditingPath = false
        pathError = nil
    }

    /// 返回 false 表示这次输入不被接受（路径不存在），输入框会留在编辑态
    @discardableResult
    func commitPathEditing(_ raw: String) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            cancelPathEditing()
            return true
        }

        let expanded = (trimmed as NSString).expandingTildeInPath
        let candidate = URL(fileURLWithPath: expanded).standardizedFileURL

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory) else {
            pathError = L("找不到「\(trimmed)」", "Can’t find “\(trimmed)”")
            return false
        }

        isEditingPath = false
        pathError = nil

        if isDirectory.boolValue {
            navigate(to: candidate)
        } else {
            // 输入的是文件：跳到它所在目录并选中它（和资源管理器一致）
            navigate(to: candidate.deletingLastPathComponent())
            focus(url: candidate)
        }
        return true
    }

    /// Tab 补全：按前缀在当前目录里找，多个匹配时取公共前缀
    func completePath(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }

        let expanded = (trimmed as NSString).expandingTildeInPath
        let directoryPath: String
        let prefix: String

        if expanded.hasSuffix("/") {
            directoryPath = String(expanded.dropLast())
            prefix = ""
        } else {
            directoryPath = (expanded as NSString).deletingLastPathComponent
            prefix = (expanded as NSString).lastPathComponent
        }

        let directory = directoryPath.isEmpty ? "/" : directoryPath
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: directory) else {
            return nil
        }

        let matches = entries
            .filter { $0.lowercased().hasPrefix(prefix.lowercased()) }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        guard let first = matches.first else { return nil }

        var common = first
        for other in matches.dropFirst() {
            common = Self.commonPrefix(common, other)
            if common.isEmpty { break }
        }
        guard !common.isEmpty else { return nil }

        var completed = (directory as NSString).appendingPathComponent(common)
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: completed, isDirectory: &isDirectory), isDirectory.boolValue {
            completed += "/"
        }
        return completed
    }

    private static func commonPrefix(_ lhs: String, _ rhs: String) -> String {
        var result = ""
        for (left, right) in zip(lhs, rhs) {
            guard left == right else { break }
            result.append(left)
        }
        return result
    }

    /// 目录读取的代次：连点不同目录时，先发出的那次结果回来会被丢弃（adr/0013）
    private var loadGeneration = 0
    /// 读取超时看门狗：超时先自动重试一次，再超时就明确报错，绝不静默空列表（adr/0014）
    private var loadWatchdog: DispatchWorkItem?
    private var loadAttempts = 0

    private func load(directory url: URL, recordHistory: Bool) {
        let standardized = url.standardizedFileURL
        let directoryChanged = standardized.path != currentURL.standardizedFileURL.path

        loadGeneration += 1
        let generation = loadGeneration
        isLoadingDirectory = true
        RunLog.shared.log(.load, "开始 gen=\(generation) \(standardized.path) sync=\(Self.loadsDirectorySynchronously)")

        // 自检：同步读，保持「构造完 / navigate 完立刻断言」的写法
        if Self.loadsDirectorySynchronously {
            let result = Result { try FileSystemService.contents(of: standardized) }
            applyLoad(result, url: standardized, recordHistory: recordHistory,
                      directoryChanged: directoryChanged, generation: generation)
            return
        }

        // 目录读取放到后台：网络卷断线、几万项目录都不该冻住窗口
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let started = Date()
            let result = Result { try FileSystemService.contents(of: standardized) }
            let elapsed = Date().timeIntervalSince(started)
            // 后台读得慢也要留痕：网络卷/大目录的症状会先出现在这里
            if elapsed > 0.5 {
                RunLog.shared.log(.load, "后台读取耗时 \(Int(elapsed * 1000))ms \(standardized.path)")
            }
            if case .failure(let error) = result {
                RunLog.shared.log(.load, "读取失败 \(standardized.path) err=\(error.localizedDescription)")
            }
            DispatchQueue.main.async {
                self?.applyLoad(result, url: standardized, recordHistory: recordHistory,
                                directoryChanged: directoryChanged, generation: generation)
            }
        }
        startLoadWatchdog(generation: generation, url: standardized)
    }

    /// 读取迟迟不回来时：先自动重试一次，仍然超时就明确报错。
    /// 没有这道兜底的话，一次卡住的读取会让列表永远停在空 + 转圈。
    private func startLoadWatchdog(generation: Int, url: URL) {
        loadWatchdog?.cancel()
        guard !Self.loadsDirectorySynchronously else { return }

        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isLoadingDirectory, generation == self.loadGeneration else { return }
            self.loadAttempts += 1
            if self.loadAttempts <= 1 {
                RunLog.shared.log(.load, "看门狗超时，自动重试一次 gen=\(generation) \(url.path)")
                self.load(directory: url, recordHistory: false)
            } else {
                RunLog.shared.log(.load, "看门狗判定超时 gen=\(generation) \(url.path)")
                self.loadAttempts = 0
                self.isLoadingDirectory = false
                self.errorMessage = L(
                    "读取「\(url.lastPathComponent)」超时，请重试",
                    "Timed out reading “\(url.lastPathComponent)” — try again"
                )
            }
        }
        loadWatchdog = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: work)
    }

    /// 读取结果回到主线程后的落地：代次不符说明用户已经切走了，整包丢弃
    private func applyLoad(
        _ result: Result<[FileItem], Error>,
        url: URL,
        recordHistory: Bool,
        directoryChanged: Bool,
        generation: Int
    ) {
        guard generation == loadGeneration else {
            RunLog.shared.log(.load, "丢弃过期结果 gen=\(generation)/\(loadGeneration) \(url.path)")
            return
        }
        isLoadingDirectory = false
        loadWatchdog?.cancel()
        loadWatchdog = nil
        loadAttempts = 0

        switch result {
        case .success(let loaded):
            RunLog.shared.log(.load, "应用 gen=\(generation)/\(loadGeneration) \(url.path) items=\(loaded.count)")
            if recordHistory, url != currentURL {
                backStack.append(currentURL)
                forwardStack.removeAll()
            }
            currentURL = url
            allItems = loaded
            invalidateSortCache()
            directorySignature = Self.signature(of: loaded)
            // 换目录时搜索词不再适用（搜索只针对当前文件夹）
            if directoryChanged { searchText = "" }
            clearSelection()
            renamingURL = nil
            pendingPermanentDelete = nil
            batchRename = nil
            dropTargetURL = nil
            accessRequest = nil
            errorMessage = nil
            isEditingPath = false
            pathError = nil
            closeInfo()
            Preferences.lastDirectoryPath = url.path
            // 树形：换目录整棵树重来；同目录刷新则保留「哪些文件夹展开着」但重读内容
            invalidateTreeCache(keepingExpansion: !directoryChanged)
            applySortAndFilter()
            reloadExpandedSubtrees()
            refreshFolderSizes()
            watchDirectory(url)
            // 预热「打开方式」候选：右键时只读缓存，不会卡住菜单（adr/0016）
            prefetchOpenWithForVisibleItems()
            // 压缩/解压完成后要选中新产物：那时列表可能还没读完，读完后补一次
            applyPendingReveal()
        case .failure(let error):
            // 权限问题不弹系统横幅式的错误条，改成窗口内的授权浮层：
            // 用户需要的是「怎么授权」，不是一行 error.localizedDescription
            if PermissionService.isPermissionDenied(error) {
                errorMessage = nil
                requestAccess(forDirectory: url, reason: error.localizedDescription)
            } else {
                errorMessage = L("无法打开「\(url.lastPathComponent)」：\(error.localizedDescription)", "Can’t open “\(url.lastPathComponent)”: \(error.localizedDescription)")
            }
        }
    }

    /// 排序结果缓存：过滤（隐藏项 / 搜索词）不改变相对顺序，所以
    /// 「先排序再过滤」和「先过滤再排序」结果完全一致。缓存全量排序结果后，
    /// 敲搜索词只需要两趟线性过滤，不再每次重排（排序比较器很贵）。
    private var sortedCache: (key: String, items: [FileItem])?

    /// allItems 变了就得丢缓存（换目录 / 外部刷新 / 权限状态更新）
    private func invalidateSortCache() {
        sortedCache = nil
    }

    private func applySortAndFilter() {
        let key = "\(sortColumn.rawValue)|\(sortAscending)"
        let base: [FileItem]
        if let cached = sortedCache, cached.key == key {
            base = cached.items
        } else {
            base = FileSystemService.sort(allItems, by: sortColumn, ascending: sortAscending)
            sortedCache = (key, base)
        }

        var visible = base
        if !showHidden {
            visible = visible.filter { !$0.isHidden }
        }
        let query = searchQuery
        if !query.isEmpty {
            visible = visible.filter { $0.name.localizedStandardContains(query) }
        }
        items = visible

        let visibleURLs = Set(items.map(\.url))
        selection = selection.intersection(visibleURLs)
        if let focused = focusedURL, !visibleURLs.contains(focused) {
            focusedURL = nil
        }
        if let anchor = anchorURL, !visibleURLs.contains(anchor) {
            anchorURL = nil
        }
        rebuildTreeRows()
    }

    // MARK: - 树形展开（adr/0019）

    /// 搜索时退化成扁平列表：搜索本来就只针对当前层，
    /// 树形展开会让「搜索到底搜不搜子层」变得含糊，这里不引入歧义。
    private var usesTreeLayout: Bool { searchQuery.isEmpty }

    /// 展开 / 折叠一个文件夹
    func toggleExpanded(_ url: URL) {
        // 一律用标准化后的 **路径字符串** 当键：URL 的相等性会被
        // /tmp 与 /private/tmp、末尾斜杠这类差异破坏，而 path 是确定的
        let key = Self.treeKey(url)
        if expandedPaths.contains(key) {
            // 连同所有后代一起收起：否则下次展开时子节点会「记着」自己是展开的
            let prefix = key + "/"
            expandedPaths = expandedPaths.filter { $0 != key && !$0.hasPrefix(prefix) }
        } else {
            expandedPaths.insert(key)
            ensureChildrenLoaded(url)
        }
        RunLog.shared.log(.user, "树形展开变更 count=\(expandedPaths.count) rows=\(treeRows.count) \(key)")
        rebuildTreeRows()
    }

    /// 某个文件夹是否展开
    func isExpanded(_ url: URL) -> Bool {
        expandedPaths.contains(Self.treeKey(url))
    }

    /// 子项是否正在读取（视图上显示小转圈）
    func isTreeLoading(_ url: URL) -> Bool {
        loadingTreePaths.contains(Self.treeKey(url))
    }

    private static func treeKey(_ url: URL) -> String {
        url.standardizedFileURL.path
    }

    /// 读某个文件夹的子项（已有缓存就直接用）
    private func ensureChildrenLoaded(_ url: URL) {
        let key = Self.treeKey(url)
        guard treeChildren[key] == nil, !loadingTreePaths.contains(key) else { return }
        loadingTreePaths.insert(key)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { try FileSystemService.contents(of: url) }
            DispatchQueue.main.async {
                guard let self else { return }
                self.loadingTreePaths.remove(key)
                switch result {
                case .success(let children):
                    self.treeChildren[key] = children
                case .failure(let error):
                    RunLog.shared.log(.load, "展开目录失败 \(url.path) err=\(error.localizedDescription)")
                    // 记为「读过但没有」：免得每次重建都再发起一次必然失败的读取
                    self.treeChildren[key] = []
                }
                if self.expandedPaths.contains(key) {
                    self.rebuildTreeRows()
                    // 刚新建/移动进来的项可能就在这一层，读完顺手选中它
                    if self.pendingRevealURL != nil { self.applyPendingReveal() }
                }
            }
        }
    }

    /// 扁平化：当前层的可见项按顺序排开，展开的文件夹后面紧跟着它的子项
    private func rebuildTreeRows() {
        guard usesTreeLayout else {
            treeRows = items.map { TreeRow(item: $0, depth: 0, isExpanded: false) }
            return
        }
        var rows: [TreeRow] = []
        appendRows(from: items, depth: 0, into: &rows)
        treeRows = rows
        if ProcessInfo.processInfo.environment["WINEXPLORER_TREE_DEBUG"] == "1" {
            let dump = rows.prefix(20).map { "\(String(repeating: "  ", count: $0.depth))\($0.item.name)" }
            print("[Tree] rows=\(rows.count): " + dump.joined(separator: " | "))
        }

    }

    private func appendRows(from source: [FileItem], depth: Int, into rows: inout [TreeRow]) {
        // 深度兜底：符号链接指回祖先时不会把栈打爆
        guard depth < 24 else { return }
        for item in source {
            let key = Self.treeKey(item.url)
            let expanded = expandedPaths.contains(key)
            rows.append(TreeRow(item: item, depth: depth, isExpanded: expanded))
            guard expanded, item.isDirectory,
                  let children = treeChildren[key],
                  !children.isEmpty else { continue }
            appendRows(from: displayable(children), depth: depth + 1, into: &rows)
        }
    }

    /// 子层沿用当前目录那套过滤与排序（隐藏项 / 搜索词 / 排序方式）
    private func displayable(_ source: [FileItem]) -> [FileItem] {
        var visible = source
        if !showHidden { visible = visible.filter { !$0.isHidden } }
        let query = searchQuery
        if !query.isEmpty { visible = visible.filter { $0.name.localizedStandardContains(query) } }
        guard !visible.isEmpty else { return visible }
        return FileSystemService.sort(visible, by: sortColumn, ascending: sortAscending)
    }

    /// 文件系统改动后让子树缓存失效。
    /// - `keepingExpansion == true`：保留哪些文件夹是展开的，把内容重读一遍（同目录刷新）
    /// - `keepingExpansion == false`：连展开状态一起清掉（换了目录）
    private func invalidateTreeCache(keepingExpansion: Bool) {
        treeChildren.removeAll()
        guard keepingExpansion else {
            expandedPaths.removeAll()
            return
        }
        // 被删掉的文件夹不能继续留在展开集合里：否则每次刷新都会去读一个
        // 已经不存在的路径，而且「折叠父级」时还会留下幽灵节点
        let fm = FileManager.default
        expandedPaths = expandedPaths.filter { fm.fileExists(atPath: $0) }
    }

    /// 把已展开的目录重新读一遍（刷新后子树内容可能变了）
    private func reloadExpandedSubtrees() {
        for path in expandedPaths { ensureChildrenLoaded(URL(fileURLWithPath: path)) }
    }

    /// 一次文件系统改动（新建 / 移动）后的收尾：
    /// 改在**当前目录**里就重读并选中；改在**子文件夹**里就把它展开、重读、
    /// 等子项回来后自动选中（`pendingRevealURL` 那条线）。
    private func finishMutation(in directory: URL, revealing target: URL? = nil) {
        let root = currentURL.standardizedFileURL
        if directory.standardizedFileURL.path == root.path {
            reload()
            if let target { focus(url: target, scroll: false) }
            return
        }
        expandedPaths.insert(Self.treeKey(directory))
        treeChildren[Self.treeKey(directory)] = nil
        if let target { pendingRevealURL = target.standardizedFileURL }
        ensureChildrenLoaded(directory)
        rebuildTreeRows()
    }

    /// 把从当前目录到 `url` 的所有祖先都展开，并让它们重读内容。
    /// 用于「新建在子文件夹里」「移动到子文件夹」之后把结果露出来。
    func revealAncestors(of url: URL) {
        let root = currentURL.standardizedFileURL
        let target = url.standardizedFileURL.deletingLastPathComponent()
        guard target.path != root.path, target.path.hasPrefix(root.path + "/") else { return }

        // 从直接父目录一路往上，收集到当前目录为止
        var chain: [URL] = []
        var cursor = target
        while cursor.path != root.path, cursor.path.hasPrefix(root.path) {
            chain.append(cursor)
            let parent = cursor.deletingLastPathComponent()
            if parent.path == cursor.path { break }
            cursor = parent
        }
        guard !chain.isEmpty else { return }
        for dir in chain { expandedPaths.insert(Self.treeKey(dir)) }
        // 这些目录的内容需要重读（刚写进去的东西不在旧缓存里）
        for dir in chain { treeChildren[Self.treeKey(dir)] = nil }
        for dir in chain { ensureChildrenLoaded(dir) }
        rebuildTreeRows()
    }

    /// 全部收起（切到列表 / 图标视图时用，那时不展示层级）
    func collapseAllTreeNodes() {
        guard !expandedPaths.isEmpty else { return }
        expandedPaths.removeAll()
        treeChildren.removeAll()
        rebuildTreeRows()
    }

    // MARK: - 文件夹大小

    /// 重排统计任务：缓存直接命中，没算过的丢给后台队列（最多一次 200 个目录）
    private func refreshFolderSizes() {
        let folders = items.filter { $0.isDirectory && $0.isAccessible }.map(\.url)
        folderSizeCoordinator.refresh(
            folders: folders,
            enabled: showsFolderSizes,
            synchronously: Self.computesFolderSizeSynchronously
        )
    }

    // MARK: - 目录监听

    private static func signature(of items: [FileItem]) -> [String] {
        items.map {
            // 带上 access：权限被改掉时也要触发列表刷新（否则会一直显示旧的锁状态）
            "\($0.url.path)|\($0.size ?? -1)|\($0.modified?.timeIntervalSince1970 ?? 0)|\($0.isDirectory)|\($0.access.rawValue)"
        }
        .sorted()
    }

    private func watchDirectory(_ url: URL) {
        guard Self.watchesFileSystem else { return }
        directoryWatcher.watch(url)
        RunLog.shared.log(.watch, "监听 \(url.path) fd=\(RunLog.resources().fd)")
    }

    private func handleDirectoryChange() {
        // 用户正在编辑或确认时不打断：这些操作结束时会各自 reload
        guard renamingURL == nil,
              pendingPermanentDelete == nil,
              batchRename == nil,
              info == nil,
              accessRequest == nil,
              !isEditingPath,
              transfer == nil,
              archiveBusy == nil else { return }
        refreshFromDisk()
    }

    /// 外部变更后重新读目录：保留选择与焦点，只有内容真的变了才更新（避免无谓刷新）
    /// 目录监听触发的自动刷新：同样放到后台读（adr/0016）。
    ///
    /// 这里以前是主线程同步读。下载目录、编译产物目录会持续触发 vnode 事件，
    /// 每次都在主线程读几百项 —— 叠加右键菜单里的 LaunchServices 查询，
    /// 主线程被反复排队，表现出来就是「菜单不弹、刷新后一片空白」。
    func refreshFromDisk() {
        // 正在刷就跳过：vnode 已经在 0.25s 防抖里合并过一次，
        // 这里再挡一层，避免事件密集时排出一长串后台读
        guard !isRefreshing else {
            RunLog.shared.note(.watch, "已在刷新，跳过本次触发")
            return
        }
        // 自检：同步读，保持「改完文件立刻断言」的写法（与 load 的开关共用语义）
        if Self.loadsDirectorySynchronously {
            let result = Result { try FileSystemService.contents(of: currentURL) }
            applyRefresh(result, url: currentURL, generation: loadGeneration)
            return
        }

        isRefreshing = true

        let url = currentURL
        let generation = loadGeneration
        RunLog.shared.note(.watch, "自动刷新开始 gen=\(generation) \(url.path)")

        DispatchQueue.global(qos: .utility).async { [weak self] in
            let started = Date()
            let result = Result { try FileSystemService.contents(of: url) }
            let elapsed = Date().timeIntervalSince(started)
            DispatchQueue.main.async {
                guard let self else { return }
                self.isRefreshing = false
                RunLog.shared.log(.watch, "自动刷新完成 \(Int(elapsed * 1000))ms gen=\(generation) \(url.path)")
                self.applyRefresh(result, url: url, generation: generation)
            }
        }
    }

    private func applyRefresh(_ result: Result<[FileItem], Error>, url: URL, generation: Int) {
        // 期间用户切走了目录 / 又发生了新的一次加载：这次刷新结果作废
        guard generation == loadGeneration,
              url.standardizedFileURL == currentURL.standardizedFileURL else {
            RunLog.shared.note(.watch, "自动刷新结果作废 gen=\(generation)/\(loadGeneration)")
            return
        }

        do {
            let loaded = try result.get()
            let signature = Self.signature(of: loaded)
            guard signature != directorySignature else { return }
            directorySignature = signature
            allItems = loaded
            invalidateSortCache()
            invalidateTreeCache(keepingExpansion: true)
            applySortAndFilter()
            reloadExpandedSubtrees()
            refreshFolderSizes()
            prefetchOpenWithForVisibleItems()
        } catch {
            RunLog.shared.log(.watch, "自动刷新读取失败 \(url.path) err=\(error.localizedDescription)")
            if PermissionService.isPermissionDenied(error) {
                // 当前目录被收走了：已加载的行一律按未授权显示，再给一次授权入口
                allItems = allItems.map {
                    var copy = $0
                    copy.access = .denied
                    return copy
                }
                invalidateSortCache()
                applySortAndFilter()
                if accessRequest == nil {
                    requestAccess(forDirectory: currentURL, reason: error.localizedDescription)
                }
            } else if errorMessage == nil {
                errorMessage = L("「\(currentURL.lastPathComponent)」已不可访问：\(error.localizedDescription)", "“\(currentURL.lastPathComponent)” is no longer accessible: \(error.localizedDescription)")
            }
            directoryWatcher.stop()
        }
    }

    func toggleSort(_ column: SortColumn) {
        if sortColumn == column {
            sortAscending.toggle()
        } else {
            sortColumn = column
            sortAscending = true
        }
    }

    // MARK: - 选择

    private func index(of url: URL) -> Int? {
        items.firstIndex { $0.url == url }
    }

    /// 单击：按修饰键决定单选 / ⌘ 加选 / Shift 连选
    func handleClick(on item: FileItem, modifiers: NSEvent.ModifierFlags) {
        // 用户把注意力转回列表：地址栏编辑态是独占输入状态，必须让位（adr/0005）
        cancelPathEditing()
        let shift = modifiers.contains(.shift)
        let command = modifiers.contains(.command)

        if shift, let anchor = anchorURL, let from = index(of: anchor), let to = index(of: item.url) {
            let lower = min(from, to)
            let upper = max(from, to)
            selection = Set(items[lower...upper].map(\.url))
            focusedURL = item.url
            return
        }

        if command {
            if selection.contains(item.url) {
                selection.remove(item.url)
                if focusedURL == item.url {
                    focusedURL = selection.first
                }
            } else {
                selection.insert(item.url)
                focusedURL = item.url
                anchorURL = item.url
            }
            return
        }

        selection = [item.url]
        focusedURL = item.url
        anchorURL = item.url
    }

    func selectAll() {
        guard !items.isEmpty else { return }
        selection = Set(items.map(\.url))
        focusedURL = items.first?.url
        anchorURL = items.first?.url
    }

    /// 只选中这一项（右键菜单等操作前调用）
    func selectOnly(_ item: FileItem) {
        selection = [item.url]
        focusedURL = item.url
        anchorURL = item.url
    }

    func clearSelection() {
        selection.removeAll()
        focusedURL = nil
        anchorURL = nil
    }

    /// 把焦点移到指定 URL（不作为公开 UI 入口，供键盘与测试使用）
    /// 注意：枚举出来的目录 URL 可能带尾斜杠，这里按标准化路径匹配，不能直接比 URL。
    func focus(url: URL, scroll: Bool = true) {
        let targetPath = url.standardizedFileURL.path
        // 树形展开后，目标可能在某个子层里，所以先在可见行里找
        let pool = usesTreeLayout ? treeRows.map(\.item) : items
        guard let match = pool.first(where: { $0.url.standardizedFileURL.path == targetPath }) else {
            return
        }
        selection = [match.url]
        focusedURL = match.url
        anchorURL = match.url
        if scroll { scrollRequest = ScrollRequest(match.url) }
    }

    /// 键盘 ↑↓ / PgUp / PgDn
    func moveFocus(by delta: Int) {
        guard !items.isEmpty else { return }
        let current = focusedURL.flatMap(index(of:)) ?? (delta > 0 ? -1 : items.count)
        let next = min(max(current + delta, 0), items.count - 1)
        focus(url: items[next].url)
    }

    /// Home / End
    func focusEdge(first: Bool) {
        guard let target = first ? items.first : items.last else { return }
        focus(url: target.url)
    }

    /// ↑↓：图标视图里按「行」跳，其它视图按「项」跳
    func moveFocusVertically(by rows: Int) {
        moveFocus(by: viewMode == .icons ? rows * max(gridColumnCount, 1) : rows)
    }

    // MARK: - 列宽与视图

    func width(for column: ResizableColumn) -> CGFloat {
        switch column {
        case .size: return columnWidths.size
        case .date: return columnWidths.date
        case .kind: return columnWidths.kind
        }
    }

    func resizeColumn(_ column: ResizableColumn, to width: CGFloat) {
        var widths = columnWidths
        switch column {
        case .size:
            widths.size = clamp(width, ColumnWidths.sizeRange)
        case .date:
            widths.date = clamp(width, ColumnWidths.dateRange)
        case .kind:
            widths.kind = clamp(width, ColumnWidths.kindRange)
        }
        guard widths != columnWidths else { return }
        columnWidths = widths
        Preferences.columnWidths = widths
    }

    /// 双击列边界：按当前目录里最宽的内容把这一列调成刚好
    func autoFitColumn(_ column: ResizableColumn) {        let font: NSFont = column == .size
            ? NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
            : NSFont.systemFont(ofSize: 12)

        let texts: [String]
        switch column {
        case .size: texts = items.map(\.sizeText)
        case .date: texts = items.map(\.modifiedText)
        case .kind: texts = items.map(\.kind)
        }

        let widest = texts.reduce(CGFloat(0)) { partial, text in
            max(partial, (text as NSString).size(withAttributes: [.font: font]).width)
        }
        // 左对齐的列（日期 / 类型）内容还带一段左内缩，自适应时要把这段算进去，
        // 否则双击「按内容自适应」会把列压得刚好装不下文字
        let textInset: CGFloat = column == .size ? 0 : FileListLayout.columnTextInset
        resizeColumn(column, to: ceil(widest) + 26 + textInset)
    }

    /// 一次把三列都调成刚好
    func autoFitAllColumns() {
        for column in ResizableColumn.allCases {
            autoFitColumn(column)
        }
    }

    private func clamp(_ value: CGFloat, _ range: ClosedRange<CGFloat>) -> CGFloat {
        min(max(value, range.lowerBound), range.upperBound)
    }

    // MARK: - 访问授权

    /// 有未授权项就弹授权浮层并返回 true —— 调用方直接 return，不做半截操作。
    /// 这是唯一的拦截点：列目录、画行、算大小都不会走到这里。
    private func blockedByUnauthorized(_ items: [FileItem]) -> Bool {
        let denied = items.filter { $0.access.isDenied }
        guard !denied.isEmpty else { return false }
        requestAccess(forItems: denied)
        return true
    }

    /// 用户主动打开 / 操作某个未授权项时，只针对该项提示
    func requestAccess(forItems items: [FileItem]) {
        guard let first = items.first else { return }
        accessRequest = AccessRequest(
            target: first.url,
            items: items,
            reason: nil,
            needsSystemSettings: PermissionService.needsSystemSettings(first.url)
        )
    }

    /// 进入一个打不开的目录时提示（items 为空表示"整目录被拒"）
    func requestAccess(forDirectory url: URL, reason: String?) {
        accessRequest = AccessRequest(
            target: url,
            items: [],
            reason: reason,
            needsSystemSettings: PermissionService.needsSystemSettings(url)
        )
    }

    func cancelAccessRequest() {
        accessRequest = nil
    }

    /// 「选择此项目以授权」：拉起一次系统面板，回来只重新探测，不做别的事
    func authorizeBlockedTarget() {
        guard let request = accessRequest else { return }
        // 先收起浮层，否则面板会被挡住
        accessRequest = nil

        guard let picked = PermissionService.pickInPanel(target: request.target) else { return }

        guard PermissionService.isReadable(picked) else {
            // 重新选过还是不给读：说明不是"没授权"而是文件本身的权限位 / 只读卷
            accessRequest = AccessRequest(
                target: request.target,
                items: request.items,
                reason: L(
                    "系统仍然拒绝读取「\(picked.lastPathComponent)」。这通常是文件自身的权限位或所在卷只读，需要在 Finder 的「显示简介 → 共享与权限」里改。",
                    "macOS still refuses to read “\(picked.lastPathComponent)”. This is usually the file’s own permission bits or a read-only volume — change it in Finder’s Get Info → Sharing & Permissions."
                ),
                needsSystemSettings: request.needsSystemSettings
            )
            return
        }

        if request.items.isEmpty {
            // 原本是"进不去这个目录"，现在能进了就直接进去
            load(directory: request.target.standardizedFileURL, recordHistory: true)
        } else {
            // 单个项目：刷新一遍让锁与淡化消失，不替用户执行原本的操作
            refreshFromDisk()
        }
        showFlash(L("已获得「\(picked.lastPathComponent)」的访问权限", "Access granted for “\(picked.lastPathComponent)”"))
    }

    /// 面板里的「打开系统设置」
    func openPrivacySettings() {
        if !PermissionService.openPrivacySettings() {
            showFlash(L("没能打开系统设置，可在「隐私与安全性 → 文件与文件夹」里手动添加", "Couldn’t open System Settings — add it manually under Privacy & Security → Files and Folders"))
        }
    }

    /// 面板里的「在 Finder 中显示」（改权限位要去 Finder 的显示简介）
    func revealBlockedTarget() {
        guard let target = accessRequest?.target else { return }
        NSWorkspace.shared.activateFileViewerSelecting([target])
    }

    // MARK: - 打开 / 操作

    func open(_ item: FileItem) {
        guard !item.access.isDenied else {
            requestAccess(forItems: [item])
            return
        }
        if item.isFolderLike {
            load(directory: item.url, recordHistory: true)
        } else {
            NSWorkspace.shared.open(item.url)
        }
    }

    func openSelection() {
        let targets = selectedItems
        guard !targets.isEmpty else { return }
        if blockedByUnauthorized(targets) { return }

        if targets.count == 1 {
            open(targets[0])
            return
        }

        // 多选时和 Windows 一样逐个打开文件；文件夹只提示、不切换窗口
        var opened = 0
        for item in targets where !item.isFolderLike {
            if NSWorkspace.shared.open(item.url) { opened += 1 }
        }
        let folders = targets.filter(\.isFolderLike).count
        var message = L("已打开 \(opened) 个文件", "Opened \(opened) file(s)")
        if folders > 0 { message += L("，跳过 \(folders) 个文件夹", ", skipped \(folders) folder(s)") }
        showFlash(message)
    }

    // MARK: - 打开方式（adr/0010）

    /// 候选应用缓存（按类型）。右键菜单构建时**只读缓存**，绝不现场查 LaunchServices
    /// —— `urlsForApplications` 是同步查询，系统 LS 数据库繁忙时会阻塞几秒，
    /// 表现就是「右键菜单点了不出来」（adr/0016）。
    private var openWithCache: [String: [OpenWithService.App]] = [:]
    /// 默认应用的缓存。用枚举区分「没查过」和「查过但没有默认应用」
    private enum CachedDefaultApp { case none, app(OpenWithService.App) }
    private var defaultAppCache: [String: CachedDefaultApp] = [:]
    /// 正在后台查询的类型（避免重复发起）
    private var openWithPending: Set<String> = []

    /// 缓存键：文件夹和文件分开（两者的候选应用不同）
    private func openWithKey(for item: FileItem) -> String {
        item.isFolderLike ? ":dir" : item.url.pathExtension.lowercased()
    }

    /// 「打开方式」子菜单要列出的应用：**只读缓存**，未命中返回空并触发后台预热
    func openWithCandidates(for item: FileItem) -> [OpenWithService.App] {
        let key = openWithKey(for: item)
        if let cached = openWithCache[key] { return cached }
        prefetchOpenWith(for: item)
        return []
    }

    /// 自检用：清掉「打开方式」缓存，验证首次菜单构建不会阻塞
    func resetOpenWithCacheForTesting() {
        openWithCache.removeAll()
        defaultAppCache.removeAll()
        openWithPending.removeAll()
    }

    /// 候选应用是否还在后台查询（菜单里据此显示「正在读取…」而不是「没有应用」）
    func isOpenWithLoading(for item: FileItem) -> Bool {
        openWithPending.contains(openWithKey(for: item))
    }

    /// 当前默认打开方式（双击会用谁）：同样只读缓存
    func defaultOpenWithApp(for item: FileItem) -> OpenWithService.App? {
        let key = openWithKey(for: item)
        if let cached = defaultAppCache[key] {
            if case .app(let app) = cached { return app }
            return nil
        }
        prefetchOpenWith(for: item)
        return nil
    }

    /// 后台查 LaunchServices，查完回主线程写缓存并通知菜单重绘
    private func prefetchOpenWith(for item: FileItem) {
        let key = openWithKey(for: item)
        guard openWithCache[key] == nil, !openWithPending.contains(key) else { return }
        openWithPending.insert(key)
        let url = item.url

        DispatchQueue.global(qos: .utility).async { [weak self] in
            let apps = RunLog.shared.timed(.menu, "LS 候选应用 key=\(key)", threshold: 0.2) {
                OpenWithService.applications(for: url)
            }
            let defaultApp = RunLog.shared.timed(.menu, "LS 默认应用 key=\(key)", threshold: 0.2) {
                OpenWithService.defaultApplication(for: url)
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.openWithPending.remove(key)
                self.openWithCache[key] = apps
                self.defaultAppCache[key] = defaultApp.map(CachedDefaultApp.app) ?? .none
                // 让菜单在下次展开时拿到候选（不主动弹菜单，这只是数据变化）
                self.objectWillChange.send()
            }
        }
    }

    /// 目录加载完后，预热可见项的「打开方式」（最多 6 种类型），
    /// 这样第一次右键基本都能直接命中缓存
    private func prefetchOpenWithForVisibleItems() {
        var keys = Set<String>()
        for item in items.prefix(200) {
            let key = openWithKey(for: item)
            guard !keys.contains(key) else { continue }
            keys.insert(key)
            if keys.count > 6 { break }
            prefetchOpenWith(for: item)
        }
    }

    /// 用指定应用**一次性**打开：多选时打开全部选中项，不改系统默认应用
    func open(_ item: FileItem, withApp app: OpenWithService.App) {
        let targets = targetItemsForOpenWith(item)
        guard !targets.isEmpty else { return }
        if blockedByUnauthorized(targets) { return }

        OpenWithService.open(targets.map(\.url), with: app) { [weak self] failure in
            guard let self else { return }
            if let failure {
                self.errorMessage = OpenWithService.message(for: failure)
            } else {
                self.showFlash(L("已用「\(app.name)」打开", "Opened with \(app.name)"))
            }
        }
    }

    /// 选一个应用来一次性打开（面板取消 = 什么都不做，不报错）
    func openWithPicker(_ item: FileItem) {
        guard let app = OpenWithService.pickApplication() else { return }
        open(item, withApp: app)
    }

    /// 选一个应用并设为该类文件的默认打开方式
    func setDefaultOpenWithApp(_ item: FileItem) {
        guard let app = OpenWithService.pickApplication() else { return }
        if let failure = OpenWithService.setDefault(app, for: item.url) {
            errorMessage = OpenWithService.message(for: failure)
        } else {
            showFlash(L("「\(item.url.pathExtension)」文件默认用「\(app.name)」打开",
                        "“\(item.url.pathExtension)” files now open with \(app.name)"))
        }
    }

    /// 打开方式的作用对象：该项在选中集合里就作用于整个选择，否则只作用于它自己
    private func targetItemsForOpenWith(_ item: FileItem) -> [FileItem] {
        if selection.contains(item.url), selectedItems.count > 1 {
            return selectedItems
        }
        return [item]
    }

    func revealInFinder(_ item: FileItem) {
        NSWorkspace.shared.activateFileViewerSelecting([item.url])
    }

    func copyPath(_ item: FileItem) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(item.url.path, forType: .string)
        showFlash(L("已复制路径", "Path copied"))
    }

    /// 复制选中项路径（多选时每行一条）
    func copySelectedPaths() {
        let paths = selectedItems.map(\.url.path)
        guard !paths.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(paths.joined(separator: "\n"), forType: .string)
        showFlash(paths.count == 1 ? L("已复制路径", "Path copied") : L("已复制 \(paths.count) 条路径", "Copied \(paths.count) paths"))
    }

    func copyCurrentDirectoryPath() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(currentURL.path, forType: .string)
        showFlash(L("已复制当前文件夹路径", "Folder path copied"))
    }

    func revealCurrentDirectory() {
        NSWorkspace.shared.activateFileViewerSelecting([currentURL])
    }

    // MARK: - 快速预览

    /// 空格：系统 Quick Look 预览选中项（多选时以整个选区为预览列表）
    func toggleQuickLook() {
        let targets = selectedItems
        guard !targets.isEmpty else {
            showFlash(L("请先选中要预览的项目", "Select what you want to preview"))
            return
        }
        // 预览要真读文件，未授权项先提示授权，避免系统预览面板弹出一片空白
        if blockedByUnauthorized(targets) { return }
        QuickLookController.shared.onFocus = { [weak self] url in
            self?.focus(url: url)
        }
        QuickLookController.shared.toggle(
            urls: targets.map(\.url),
            startAt: focusedURL ?? targets.first?.url
        )
    }

    // MARK: - 收藏夹

    func addCurrentDirectoryToFavorites() {
        if FavoritesStore.shared.add(currentURL) {
            showFlash(L("已把「\(titleText)」加入收藏夹", "Added “\(titleText)” to Favorites"))
        } else {
            showFlash(L("「\(titleText)」已在收藏夹里", "“\(titleText)” is already in Favorites"))
        }
    }

    func addToFavorites(_ item: FileItem) {
        guard item.isFolderLike else {
            showFlash(L("只能收藏文件夹", "Only folders can be added to Favorites"))
            return
        }
        if FavoritesStore.shared.add(item.url) {
            showFlash(L("已收藏「\(item.name)」", "Saved “\(item.name)” to Favorites"))
        } else {
            showFlash(L("「\(item.name)」已在收藏夹里", "“\(item.name)” is already in Favorites"))
        }
    }

    var isCurrentDirectoryFavorite: Bool {
        FavoritesStore.shared.contains(currentURL)
    }

    // MARK: - 属性面板

    /// ⌘I / 右键「显示简介」
    func showInfo() {
        let targets = selectedItems
        guard !targets.isEmpty else {
            showFlash(L("请先选中要查看属性的项目", "Select what you want info about"))
            return
        }

        infoGeneration += 1
        let token = infoGeneration
        infoTargets = targets

        let state = targets.count == 1
            ? FileInfoService.state(for: targets[0])
            : FileInfoService.state(for: targets)
        info = state

        let folders = targets.filter(\.isDirectory).map(\.url)
        guard !folders.isEmpty else { return }

        let compute: () -> [String: FileInfoService.FolderStats] = {
            var result: [String: FileInfoService.FolderStats] = [:]
            for url in folders {
                result[url.standardizedFileURL.path] = FileInfoService.folderStats(url)
            }
            return result
        }

        let apply: ([String: FileInfoService.FolderStats]) -> Void = { [weak self] stats in
            guard let self else { return }
            self.applyFolderStats(stats, token: token)
        }

        // 自检模式同步算，生产路径丢到后台，避免大文件夹卡住界面
        if Self.computesFolderSizeSynchronously {
            apply(compute())
        } else {
            DispatchQueue.global(qos: .userInitiated).async {
                let stats = compute()
                DispatchQueue.main.async { apply(stats) }
            }
        }
    }

    private func applyFolderStats(_ stats: [String: FileInfoService.FolderStats], token: Int) {
        guard token == infoGeneration, var state = info else { return }

        if infoTargets.count == 1, let item = infoTargets.first {
            let key = item.url.standardizedFileURL.path
            FileInfoService.apply(stats[key] ?? FileInfoService.FolderStats(), to: &state)
        } else {
            var bytes = infoTargets
                .filter { !$0.isDirectory }
                .reduce(Int64(0)) { $0 + ($1.size ?? 0) }
            var skipped = false
            for item in infoTargets where item.isDirectory {
                let entry = stats[item.url.standardizedFileURL.path]
                if entry?.skipped == true {
                    skipped = true
                } else {
                    bytes += entry?.bytes ?? 0
                }
            }
            state.set("size", to: (skipped ? "≥ " : "") + FileInfoService.byteText(bytes))
            state.note = skipped
                ? L(
                    "有文件夹受 macOS 隐私保护，未计入大小",
                    "Some folders are protected by macOS and were not counted"
                )
                : nil
        }
        info = state
    }

    func closeInfo() {
        guard info != nil || !infoTargets.isEmpty else { return }
        infoGeneration += 1
        info = nil
        infoTargets = []
    }

    /// 属性面板里点「在 Finder 中显示」
    func revealInfoTarget() {
        if infoTargets.count == 1, let item = infoTargets.first {
            revealInFinder(item)
        } else if !infoTargets.isEmpty {
            NSWorkspace.shared.activateFileViewerSelecting(infoTargets.map(\.url))
        }
    }

    /// 属性面板 / 删除确认 / 批量重命名 / 关于 打开时，方向键/快捷键不应继续操作后台列表
    var hasModalOverlay: Bool {
        info != nil || pendingPermanentDelete != nil || batchRename != nil || showsAbout
            || accessRequest != nil
    }

    // MARK: - 剪贴板

    /// 复制：内容同时写进系统剪贴板，所以可以直接粘到 Finder 或其它 App
    func copySelection() {
        let targets = selectedItems.map(\.url)
        guard !targets.isEmpty else {
            showFlash(L("请先选中要复制的内容", "Select what you want to copy"))
            return
        }
        if blockedByUnauthorized(selectedItems) { return }
        clipboard = FileClipboard(urls: targets, mode: .copy, sourceDirectory: currentURL)
        writeSystemPasteboard(targets)
        showFlash(targets.count == 1
                  ? L("已复制「\(targets[0].lastPathComponent)」，⌘V 粘贴", "Copied “\(targets[0].lastPathComponent)” — ⌘V to paste")
                  : L("已复制 \(targets.count) 项，⌘V 粘贴", "Copied \(targets.count) item(s) — ⌘V to paste"))
    }

    /// 剪切：只做标记，真正移动发生在粘贴时（和 Windows 一致，可以反悔）
    func cutSelection() {
        let targets = selectedItems.map(\.url)
        guard !targets.isEmpty else {
            showFlash(L("请先选中要剪切的内容", "Select what you want to cut"))
            return
        }
        if blockedByUnauthorized(selectedItems) { return }
        clipboard = FileClipboard(urls: targets, mode: .cut, sourceDirectory: currentURL)
        writeSystemPasteboard(targets)
        showFlash(targets.count == 1
                  ? L("已剪切「\(targets[0].lastPathComponent)」，⌘V 粘贴", "Cut “\(targets[0].lastPathComponent)” — ⌘V to paste")
                  : L("已剪切 \(targets.count) 项，⌘V 粘贴", "Cut \(targets.count) item(s) — ⌘V to paste"))
    }

    func paste(into destination: URL? = nil) {
        guard transfer == nil else {
            showFlash(L("上一项操作还没结束", "The previous operation is still running"))
            return
        }

        let targetDir = (destination ?? currentURL).standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: targetDir.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            errorMessage = L("「\(targetDir.lastPathComponent)」不是文件夹，无法粘贴到里面", "“\(targetDir.lastPathComponent)” is not a folder — can’t paste into it")
            return
        }

        let mode: ClipboardMode
        let rawSources: [URL]
        if let clipboard {
            mode = clipboard.mode
            rawSources = clipboard.urls
        } else {
            // 应用内剪贴板为空时，尝试用系统剪贴板里的文件（比如刚从 Finder 复制的）
            mode = .copy
            rawSources = systemPasteboardFileURLs()
        }

        let fm = FileManager.default
        let sources = rawSources
            .map { $0.standardizedFileURL }
            .filter { fm.fileExists(atPath: $0.path) }
        guard !sources.isEmpty else {
            showFlash(clipboard == nil ? "没有可粘贴的内容" : L("剪贴板里的内容已经不在了", "The clipboard contents are gone"))
            return
        }

        // 防呆：不能把文件夹粘进它自己或它的子目录
        let targetPath = targetDir.path
        for source in sources {
            if targetPath == source.path || targetPath.hasPrefix(source.path + "/") {
                errorMessage = L("不能把「\(source.lastPathComponent)」粘贴到它自己里面", "Can’t paste “\(source.lastPathComponent)” into itself")
                return
            }
        }

        var requests: [TransferRequest] = []
        var skipped: [String] = []
        var conflicts: [String] = []

        for source in sources {
            let sameDirectory = source.deletingLastPathComponent().standardizedFileURL.path == targetPath
            if sameDirectory, mode == .cut {
                // 原地剪切粘贴 = 什么都不用做
                skipped.append(source.lastPathComponent)
                continue
            }

            let direct = targetDir.appendingPathComponent(source.lastPathComponent)
            switch mode {
            case .copy:
                requests.append(TransferRequest(
                    source: source,
                    destination: TransferService.uniqueDestination(for: source, in: targetDir),
                    mode: .copy
                ))
            case .cut:
                if fm.fileExists(atPath: direct.path) {
                    conflicts.append(source.lastPathComponent)
                } else {
                    requests.append(TransferRequest(source: source, destination: direct, mode: .move))
                }
            }
        }

        // 移动时目标已有同名项：整批拒绝，绝不覆盖
        if !conflicts.isEmpty {
            errorMessage = L("「\(targetDir.lastPathComponent)」里已存在同名项目：", "“\(targetDir.lastPathComponent)” already contains: ")
                + conflicts.prefix(3).joined(separator: "、")
                + (conflicts.count > 3 ? L(" 等", " and more") : "")
                + L("，未执行粘贴", ", paste skipped")
            return
        }

        guard !requests.isEmpty else {
            if !skipped.isEmpty {
                showFlash(L("「\(skipped[0])」已经在当前文件夹里", "“\(skipped[0])” is already in this folder"))
            }
            return
        }

        execute(requests: requests, targetDir: targetDir, clearsClipboard: mode == .cut)
    }

    /// 「移动到…」：选一个目标文件夹，把选中项移过去（adr/0019）
    func chooseMoveDestination() {
        let targets = selectedItems
        guard !targets.isEmpty else { return }
        if blockedByUnauthorized(targets) { return }

        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = L("移动到这里", "Move Here")
        panel.message = L("选择要把 \(targets.count) 个项目移动到的文件夹",
                          "Choose a folder to move \(targets.count) item(s) into")
        panel.directoryURL = currentURL
        guard panel.runModal() == .OK, let destination = panel.url?.standardizedFileURL else { return }
        moveItems(targets.map(\.url), to: destination)
    }

    /// 把一批项移动到指定目录。复用拖放的传输通道（强制移动），
    /// 目标非法（比如移进它自己）时由 `drop` 里的校验拦下。
    func moveItems(_ urls: [URL], to destination: URL) {
        guard !urls.isEmpty else { return }
        let dest = destination.standardizedFileURL
        let sameParent = urls.allSatisfy {
            $0.deletingLastPathComponent().standardizedFileURL.path == dest.path
        }
        guard !sameParent else {
            showFlash(L("它们已经在这个文件夹里了", "They’re already in this folder"))
            return
        }
        drop(urls: urls, into: dest, modifiers: [.command])
    }

    /// 拖放：把一批 URL 放进 target 目录。
    /// 规则和 Windows 一致：⌥ 强制复制、⌘ 强制移动，否则同卷移动、跨卷复制。
    func drop(urls: [URL], into targetDir: URL, modifiers: NSEvent.ModifierFlags) {
        guard transfer == nil else {
            showFlash(L("上一项操作还没结束", "The previous operation is still running"))
            return
        }

        let fm = FileManager.default
        let target = targetDir.standardizedFileURL
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: target.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            showFlash(L("「\(target.lastPathComponent)」不是文件夹", "“\(target.lastPathComponent)” is not a folder"))
            return
        }

        let sources = urls.map { $0.standardizedFileURL }.filter { fm.fileExists(atPath: $0.path) }
        guard !sources.isEmpty else { return }

        if let message = invalidTargetMessage(sources: sources, target: target, verb: L("移动", "move")) {
            errorMessage = message
            return
        }

        let forceCopy = modifiers.contains(.option)
        let forceMove = modifiers.contains(.command)

        var requests: [TransferRequest] = []
        var skipped: [String] = []
        var conflicts: [String] = []

        for source in sources {
            let sameDirectory = source.deletingLastPathComponent().standardizedFileURL.path == target.path
            let wantsCopy = forceCopy || (!forceMove && !TransferService.sameVolume(source, target))

            if sameDirectory, !wantsCopy {
                // 拖回原处且不是复制，等于没动
                skipped.append(source.lastPathComponent)
                continue
            }

            if wantsCopy {
                requests.append(TransferRequest(
                    source: source,
                    destination: TransferService.uniqueDestination(for: source, in: target),
                    mode: .copy
                ))
            } else {
                let direct = target.appendingPathComponent(source.lastPathComponent)
                if fm.fileExists(atPath: direct.path) {
                    conflicts.append(source.lastPathComponent)
                } else {
                    requests.append(TransferRequest(source: source, destination: direct, mode: .move))
                }
            }
        }

        if !conflicts.isEmpty {
            errorMessage = L("「\(target.lastPathComponent)」里已存在同名项目：", "“\(target.lastPathComponent)” already contains: ")
                + conflicts.prefix(3).joined(separator: "、")
                + (conflicts.count > 3 ? L(" 等", " and more") : "")
                + L("，未执行拖放", ", drop skipped")
            return
        }

        guard !requests.isEmpty else {
            if !skipped.isEmpty {
                showFlash(L("「\(skipped[0])」已经在这个文件夹里", "“\(skipped[0])” is already in this folder"))
            }
            return
        }

        execute(requests: requests, targetDir: target, clearsClipboard: false)
    }

    // MARK: - 传输执行

    /// 统一的传输执行器：同卷移动瞬时完成，其余走后台进度；完成后登记撤销。
    private func execute(requests: [TransferRequest], targetDir: URL, clearsClipboard: Bool) {
        let fm = FileManager.default
        let targetName = targetDir.lastPathComponent
        let canMoveInstantly = requests.allSatisfy {
            $0.mode == .move && TransferService.sameVolume($0.source, $0.destination)
        }

        if canMoveInstantly {
            var done: [TransferRequest] = []
            var failures: [String] = []
            for request in requests {
                do {
                    try fm.moveItem(at: request.source, to: request.destination)
                    done.append(request)
                } catch {
                    failures.append("\(request.source.lastPathComponent)：\(error.localizedDescription)")
                }
            }
            if clearsClipboard { clipboard = nil }
            if !done.isEmpty { registerUndo(transferUndo(done, targetName: targetName)) }
            reload()
            select(urls: done.map(\.destination))
            if failures.isEmpty {
                showFlash(L("已移动 \(done.count) 项到「\(targetName)」", "Moved \(done.count) item(s) to “\(targetName)”"))
            } else {
                errorMessage = L("部分项目移动失败：\n", "Some items couldn’t be moved:\n") + failures.joined(separator: "\n")
            }
            return
        }

        // 复制或跨卷移动：后台跑，带进度与取消
        let cancellation = TransferCancellation()
        transferCancellation = cancellation
        let isCopyOnly = requests.allSatisfy { $0.mode == .copy }
        let title = isCopyOnly ? L("正在复制", "Copying") : L("正在移动", "Moving")
        let total = requests.reduce(0) { $0 + TransferService.countFiles($1.source) }
        transfer = TransferProgress(title: title, completed: 0, total: max(total, 1), currentName: "")

        func apply(_ result: TransferService.Result) {
            transferCancellation = nil
            transfer = nil
            if clearsClipboard, !result.cancelled { clipboard = nil }

            // 只为真正完成的项登记撤销
            let finishedPaths = Set((result.moved + result.copied).map { $0.standardizedFileURL.path })
            let finished = requests.filter { finishedPaths.contains($0.destination.standardizedFileURL.path) }
            if !finished.isEmpty { registerUndo(transferUndo(finished, targetName: targetName)) }

            reload()
            select(urls: result.moved + result.copied)

            if !result.failures.isEmpty {
                errorMessage = L("部分项目处理失败：\n", "Some items couldn’t be processed:\n") + result.failures.joined(separator: "\n")
            } else if result.cancelled {
                let done = result.moved.count + result.copied.count
                showFlash(L("已取消，其中 \(done) 项已完成", "Cancelled — \(done) item(s) already done"))
            } else {
                let done = result.moved.count + result.copied.count
                showFlash(L("已\(isCopyOnly ? "复制" : "移动") \(done) 项到「\(targetName)」", "Copied/moved \(done) item(s) to “\(targetName)”"))
            }
        }

        // 自检模式同步执行，方便断言（生产路径始终走后台队列）
        if Self.runsTransfersSynchronously {
            let result = TransferService.perform(
                requests: requests,
                title: title,
                progress: { _ in },
                isCancelled: { false }
            )
            apply(result)
            return
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = TransferService.perform(
                requests: requests,
                title: title,
                // perform 已经把进度切到主线程了，这里不能再包一层 async，
                // 否则最后一条进度可能晚于 apply() 到达，把已清空的卡片又画出来
                progress: { snapshot in
                    self?.transfer = snapshot
                },
                isCancelled: { cancellation.isCancelled }
            )

            DispatchQueue.main.async {
                apply(result)
            }
        }
    }

    /// 目标必须在来源之外（不能把文件夹放进它自己的子树）
    private func invalidTargetMessage(sources: [URL], target: URL, verb: String) -> String? {
        let targetPath = target.path
        for source in sources where targetPath == source.path || targetPath.hasPrefix(source.path + "/") {
            return L("不能把「\(source.lastPathComponent)」\(verb)到它自己里面", "Can’t \(verb) “\(source.lastPathComponent)” into itself")
        }
        return nil
    }

    func cancelTransfer() {
        guard transferCancellation != nil else { return }
        transferCancellation?.cancel()
        showFlash(L("正在取消…", "Cancelling…"))
    }

    /// 选中一批 URL（粘贴完成后高亮新生成的项目）
    func select(urls: [URL]) {
        let paths = Set(urls.map { $0.standardizedFileURL.path })
        guard !paths.isEmpty else { return }
        let matched = items.filter { paths.contains($0.url.standardizedFileURL.path) }
        guard !matched.isEmpty else { return }
        selection = Set(matched.map(\.url))
        focusedURL = matched.first?.url
        anchorURL = matched.first?.url
        if let first = matched.first { scrollRequest = ScrollRequest(first.url) }
    }

    // MARK: - 系统剪贴板桥接

    private func writeSystemPasteboard(_ urls: [URL]) {
        guard Self.syncsSystemPasteboard else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects(urls as [NSURL])
    }

    /// 读系统剪贴板里的文件 URL（按 changeCount 缓存，避免每次渲染都解归档）
    func systemPasteboardFileURLs() -> [URL] {
        guard Self.syncsSystemPasteboard else { return [] }
        let pasteboard = NSPasteboard.general
        if pasteboard.changeCount != cachedPasteboardChangeCount {
            cachedPasteboardChangeCount = pasteboard.changeCount
            let objects = pasteboard.readObjects(
                forClasses: [NSURL.self],
                options: [.urlReadingFileURLsOnly: true]
            ) as? [URL] ?? []
            cachedPasteboardURLs = objects.filter(\.isFileURL)
            pasteboardHasFiles = !cachedPasteboardURLs.isEmpty
        }
        return cachedPasteboardURLs
    }

    // MARK: - 重命名

    func beginRename() {
        // 多选时按 F2 走批量重命名（Windows 11 的行为），单选走行内编辑
        if selection.count > 1 {
            beginBatchRename()
            return
        }
        guard let item = selectedItems.first else {
            showFlash(L("请先选中一个项目再重命名", "Select one item to rename"))
            return
        }
        renamingURL = item.url
        errorMessage = nil
    }

    /// 右键菜单入口：先选中该项再进入编辑
    func beginRename(item: FileItem) {
        selectOnly(item)
        beginRename()
    }

    func cancelRename() {
        renamingURL = nil
    }

    /// 返回是否提交成功；失败时保持编辑状态，让用户改名字
    @discardableResult
    func commitRename(_ newName: String) -> Bool {
        guard let source = renamingURL else { return false }

        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            errorMessage = L("名称不能为空", "The name can’t be empty")
            return false
        }
        if trimmed.contains("/") || trimmed.contains(":") {
            errorMessage = L("名称不能包含「/」或「:」", "The name can’t contain “/” or “:”")
            return false
        }
        if trimmed == source.lastPathComponent {
            renamingURL = nil
            return true
        }

        let target = source.deletingLastPathComponent().appendingPathComponent(trimmed)
        if FileManager.default.fileExists(atPath: target.path) {
            errorMessage = L("「\(trimmed)」已存在，请换一个名字", "“\(trimmed)” already exists — pick another name")
            return false
        }

        do {
            try FileManager.default.moveItem(at: source, to: target)
            renamingURL = nil
            registerUndo(UndoEntry(
                title: L("重命名为「\(trimmed)」", "Rename to “\(trimmed)”"),
                undo: { [weak self] in self?.moveItemReportingFailure(from: target, to: source) },
                redo: { [weak self] in self?.moveItemReportingFailure(from: source, to: target) }
            ))
            reload()
            focus(url: target, scroll: false)
            showFlash(L("已重命名为「\(trimmed)」", "Renamed to “\(trimmed)”"))
            return true
        } catch {
            errorMessage = L("重命名失败：\(error.localizedDescription)", "Rename failed: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - 批量重命名

    /// 多选后 F2 / 菜单 / 右键进入
    func beginBatchRename() {
        let targets = selectedItems
        guard targets.count > 1 else {
            showFlash(L("请先选中多个项目", "Select more than one item"))
            return
        }
        renamingURL = nil
        errorMessage = nil

        let seed = targets.first { $0.url == focusedURL } ?? targets[0]
        batchRename = BatchRenameState(items: targets, baseName: BatchRenameState.stem(of: seed))
    }

    func cancelBatchRename() {
        batchRename = nil
    }

    /// 面板里每次改字段都走这里，保证预览是实时的
    func updateBatchRename(_ mutate: (inout BatchRenameState) -> Void) {
        guard var state = batchRename else { return }
        mutate(&state)
        batchRename = state
    }

    func applyBatchRename() {
        guard let state = batchRename else { return }
        let plan = BatchRenamePlan.make(state)

        if !plan.problems.isEmpty {
            errorMessage = plan.problems.joined(separator: "；")
            return
        }
        guard plan.isApplicable else {
            if plan.changes.isEmpty { showFlash(L("名称没有变化", "The name didn’t change")) }
            return
        }

        let moves = plan.changes
        let failures = Self.applyRenames(moves)
        batchRename = nil

        guard failures.isEmpty else {
            reload()
            errorMessage = L("批量重命名未完成：\n", "Batch rename didn’t finish:\n") + failures.joined(separator: "\n")
            return
        }

        let backward = moves.map { (from: $0.to, to: $0.from) }
        registerUndo(UndoEntry(
            title: L("批量重命名 \(moves.count) 项", "Batch rename \(moves.count) item(s)"),
            undo: { [weak self] in
                let result = Self.applyRenames(backward)
                if !result.isEmpty {
                    self?.errorMessage = L("撤销批量重命名失败：\n", "Couldn’t undo the batch rename:\n") + result.joined(separator: "\n")
                }
            },
            redo: { [weak self] in
                let result = Self.applyRenames(moves)
                if !result.isEmpty {
                    self?.errorMessage = L("重做批量重命名失败：\n", "Couldn’t redo the batch rename:\n") + result.joined(separator: "\n")
                }
            }
        ))

        reload()
        select(urls: moves.map { $0.to })
        showFlash(L("已重命名 \(moves.count) 项", "Renamed \(moves.count) item(s)"))
    }

    /// 两阶段改名：先全部挪到临时名，再挪到目标名。
    /// 这样 A→B 与 B→A 互换、以及只改大小写（大小写不敏感磁盘）都不会互相踩。
    /// 任何一步失败都回滚已完成的动作。
    @discardableResult
    private static func applyRenames(_ moves: [(from: URL, to: URL)]) -> [String] {
        guard !moves.isEmpty else { return [] }
        let fm = FileManager.default
        var staged: [(temp: URL, to: URL, from: URL)] = []
        var finished: [(to: URL, from: URL)] = []
        var failures: [String] = []

        func rollback() {
            for entry in finished.reversed() where fm.fileExists(atPath: entry.to.path) {
                try? fm.moveItem(at: entry.to, to: entry.from)
            }
            for entry in staged.reversed() where fm.fileExists(atPath: entry.temp.path) {
                try? fm.moveItem(at: entry.temp, to: entry.from)
            }
        }

        for move in moves {
            let temp = move.from.deletingLastPathComponent()
                .appendingPathComponent(".winexplorer-rename-\(UUID().uuidString)")
            do {
                try fm.moveItem(at: move.from, to: temp)
                staged.append((temp, move.to, move.from))
            } catch {
                failures.append("\(move.from.lastPathComponent)：\(error.localizedDescription)")
                rollback()
                return failures
            }
        }

        for entry in staged {
            do {
                try fm.moveItem(at: entry.temp, to: entry.to)
                finished.append((entry.to, entry.from))
            } catch {
                failures.append("\(entry.from.lastPathComponent)：\(error.localizedDescription)")
                rollback()
                return failures
            }
        }
        return failures
    }

    // MARK: - 压缩 / 解压

    /// 把选中项压缩成 zip，落在当前文件夹
    func compressSelection() {
        guard !isBusy else {
            showFlash(L("上一项操作还没结束", "The previous operation is still running"))
            return
        }
        let targets = selectedItems.map(\.url)
        guard !targets.isEmpty else {
            showFlash(L("请先选中要压缩的项目", "Select what you want to compress"))
            return
        }
        if blockedByUnauthorized(selectedItems) { return }
        let destination = ArchiveService.compressDestination(for: targets, in: currentURL)
        runArchive(
            title: L("正在压缩 \(destination.lastPathComponent)", "Compressing \(destination.lastPathComponent)"),
            result: destination,
            success: L("已压缩为「\(destination.lastPathComponent)」", "Compressed to “\(destination.lastPathComponent)”")
        ) { task in
            try ArchiveService.compress(items: targets, to: destination, task: task)
        }
    }

    /// 解压选中的 zip。
    /// - toOwnFolder = true：每个压缩包解到同名的新文件夹（绝不覆盖已有文件）
    /// - toOwnFolder = false：解到当前文件夹；先查顶层同名项，有冲突直接拒绝
    func extractSelection(toOwnFolder: Bool = true) {
        guard !isBusy else {
            showFlash(L("上一项操作还没结束", "The previous operation is still running"))
            return
        }
        let archives = selectedItems.filter { ArchiveService.isArchive($0.url) }
        guard !archives.isEmpty else {
            showFlash(L("请先选中 zip 压缩包", "Select a ZIP archive"))
            return
        }
        if blockedByUnauthorized(archives) { return }

        if toOwnFolder {
            let destinations = archives.map {
                ArchiveService.extractDestination(for: $0.url, in: currentURL)
            }
            let count = archives.count
            runArchive(
                title: count == 1 ? L("正在解压 \(archives[0].name)", "Extracting \(archives[0].name)") : L("正在解压 \(count) 个压缩包", "Extracting \(count) archives"),
                result: destinations.last,
                success: count == 1
                    ? L("已解压到「\(destinations[0].lastPathComponent)」", "Extracted to “\(destinations[0].lastPathComponent)”")
                    : L("已解压 \(count) 个压缩包", "Extracted \(count) archives")
            ) { task in
                var failures: [String] = []
                for (index, archive) in archives.enumerated() {
                    do {
                        try ArchiveService.extract(archive: archive.url, to: destinations[index], task: task)
                    } catch {
                        if task.isCancelled { throw ArchiveService.Failure.cancelled }
                        failures.append("\(archive.name)：\(error.localizedDescription)")
                    }
                }
                if !failures.isEmpty {
                    throw ArchiveService.Failure.invalid(failures.joined(separator: "\n"))
                }
            }
            return
        }

        guard archives.count == 1 else {
            showFlash(L("「解压到当前文件夹」一次只能处理一个压缩包", "“Extract Here” handles one archive at a time"))
            return
        }
        let archive = archives[0].url
        let targetDirectory = currentURL
        runArchive(
            title: L("正在解压 \(archive.lastPathComponent)", "Extracting \(archive.lastPathComponent)"),
            result: nil,
            success: L("已解压到当前文件夹", "Extracted into this folder")
        ) { task in
            try ArchiveService.extract(archive: archive, to: targetDirectory, task: task)
        }
    }

    /// 压缩 / 解压统一执行器：后台跑系统子进程，底部显示忙碌卡片，可取消
    private func runArchive(
        title: String,
        result: URL?,
        success: String,
        work: @escaping (ArchiveTask) throws -> Void
    ) {
        let task = ArchiveTask()
        archiveTask = task
        archiveBusy = TransferProgress(
            title: title,
            completed: 0,
            total: 1,
            currentName: "",
            indeterminate: true
        )
        errorMessage = nil

        func finish(_ failure: String?) {
            archiveTask = nil
            archiveBusy = nil
            reload()
            if let failure {
                if failure == ArchiveService.Failure.cancelled.errorDescription {
                    showFlash(L("已取消", "Cancelled"))
                } else {
                    errorMessage = failure
                }
            } else {
                if let result { revealNewItem(result) }
                showFlash(success)
            }
        }

        // 自检模式同步执行，方便断言（生产路径始终走后台队列）
        if Self.runsTransfersSynchronously {
            do {
                try work(task)
                finish(nil)
            } catch {
                finish(error.localizedDescription)
            }
            return
        }

        DispatchQueue.global(qos: .userInitiated).async {
            var failure: String?
            do {
                try work(task)
            } catch {
                failure = error.localizedDescription
            }
            DispatchQueue.main.async { finish(failure) }
        }
    }

    /// 操作完成后把新生成的项选中并滚进视口（不在当前目录就只刷新）
    /// 压缩 / 解压完成要选中的产物。目录是异步读的，读完前列表里还没有它，
    /// 所以先记下来，读完后由 applyPendingReveal() 补上
    private var pendingRevealURL: URL?

    private func revealNewItem(_ url: URL) {
        pendingRevealURL = url.standardizedFileURL
        applyPendingReveal()
    }

    private func applyPendingReveal() {
        guard let target = pendingRevealURL else { return }
        let path = target.path
        let pool = usesTreeLayout ? treeRows.map(\.item) : items
        guard let match = pool.first(where: { $0.url.standardizedFileURL.path == path }) else { return }
        pendingRevealURL = nil
        selection = [match.url]
        focusedURL = match.url
        anchorURL = match.url
        scrollRequest = ScrollRequest(match.url)
    }

    func cancelArchive() {
        guard archiveTask != nil else { return }
        archiveTask?.cancel()
        showFlash(L("正在取消…", "Cancelling…"))
    }

    // MARK: - 删除

    /// 移到废纸篓（可恢复）
    /// 菜单入口：先登记，等确认框（列出级联影响）再真正执行
    func requestTrash() {
        let targets = selectedItems
        guard !targets.isEmpty else { return }
        if blockedByUnauthorized(targets) { return }
        pendingTrash = targets
    }

    func cancelTrash() {
        pendingTrash = nil
    }

    func confirmTrash() {
        guard let targets = pendingTrash else { return }
        pendingTrash = nil
        moveSelectionToTrash(targets)
    }

    /// 直接执行（撤销、自检用）
    func moveSelectionToTrash() {
        moveSelectionToTrash(selectedItems)
    }

    private func moveSelectionToTrash(_ targets: [FileItem]) {
        guard !targets.isEmpty else { return }
        if blockedByUnauthorized(targets) { return }

        var failures: [String] = []
        var trashed: [(original: URL, inTrash: URL)] = []
        for item in targets {
            var resulting: NSURL?
            do {
                try FileManager.default.trashItem(at: item.url, resultingItemURL: &resulting)
                if let resulting = resulting as URL? {
                    trashed.append((item.url, resulting))
                }
            } catch {
                failures.append("\(item.name)：\(error.localizedDescription)")
            }
        }

        if !trashed.isEmpty {
            registerUndo(UndoEntry(
                title: L("移到废纸篓 \(trashed.count) 项", "Move \(trashed.count) item(s) to the Trash"),
                undo: { [weak self] in
                    guard let self else { return }
                    let fm = FileManager.default
                    for pair in trashed.reversed() where fm.fileExists(atPath: pair.inTrash.path) {
                        guard !fm.fileExists(atPath: pair.original.path) else {
                            self.errorMessage = L("原位置已有同名项目，无法还原「\(pair.original.lastPathComponent)」", "An item with the same name is already in the original location; can’t restore “\(pair.original.lastPathComponent)”")
                            continue
                        }
                        do {
                            try fm.moveItem(at: pair.inTrash, to: pair.original)
                        } catch {
                            self.errorMessage = L("从废纸篓还原失败：\(error.localizedDescription)", "Couldn’t restore from the Trash: \(error.localizedDescription)")
                        }
                    }
                },
                redo: { [weak self] in
                    guard let self else { return }
                    for pair in trashed where FileManager.default.fileExists(atPath: pair.original.path) {
                        do {
                            try FileManager.default.trashItem(at: pair.original, resultingItemURL: nil)
                        } catch {
                            self.errorMessage = L("再次移到废纸篓失败：\(error.localizedDescription)", "Couldn’t move it to the Trash again: \(error.localizedDescription)")
                        }
                    }
                }
            ))
        }

        reload()
        if failures.isEmpty {
            showFlash(targets.count == 1 ? L("已移到废纸篓", "Moved to the Trash") : L("已把 \(targets.count) 项移到废纸篓", "Moved \(targets.count) item(s) to the Trash"))
        } else {
            errorMessage = L("部分项目无法移到废纸篓：\n", "Some items couldn’t be moved to the Trash:\n") + failures.joined(separator: "\n")
        }
    }

    /// 移动单个文件并报告失败（撤销/重做共用）
    private func moveItemReportingFailure(from: URL, to: URL) {
        do {
            try FileManager.default.moveItem(at: from, to: to)
        } catch {
            errorMessage = L("操作失败：\(error.localizedDescription)", "Operation failed: \(error.localizedDescription)")
        }
    }

    /// 彻底删除需要二次确认，这里只登记目标
    func requestPermanentDelete() {
        let targets = selectedItems
        guard !targets.isEmpty else { return }
        if blockedByUnauthorized(targets) { return }
        pendingPermanentDelete = targets
    }

    func cancelPermanentDelete() {
        pendingPermanentDelete = nil
    }

    /// 用户确认后执行，不进废纸篓，不可撤销
    func confirmPermanentDelete() {
        guard let targets = pendingPermanentDelete else { return }
        pendingPermanentDelete = nil

        var removed = 0
        var failures: [String] = []

        for item in targets {
            // 安全兜底：绝不删除当前目录本身或其祖先
            let path = item.url.standardizedFileURL.path
            let current = currentURL.standardizedFileURL.path
            if path == current || current.hasPrefix(path + "/") {
                failures.append(L("\(item.name)：不能删除当前所在目录", "\(item.name): can’t delete the folder you’re in"))
                continue
            }
            do {
                try FileManager.default.removeItem(at: item.url)
                removed += 1
            } catch {
                failures.append("\(item.name)：\(error.localizedDescription)")
            }
        }

        reload()
        if failures.isEmpty {
            showFlash(L("已彻底删除 \(removed) 项", "Deleted \(removed) item(s) permanently"))
        } else {
            errorMessage = L("部分项目删除失败：\n", "Some items couldn’t be deleted:\n") + failures.joined(separator: "\n")
        }
    }

    /// 新建文件夹，重名时自动加序号（Windows 的"新建文件夹 2"习惯）
    /// 新建文件夹。
    /// `directory` 只在「右键某个文件夹 → 在此文件夹中新建」时传入；
    /// 快捷键和工具栏按钮一律建在当前目录 —— 否则连续新建会一层层嵌套下去。
    func createFolder(in directory: URL? = nil) {
        let fm = FileManager.default
        let base = (directory ?? currentURL).standardizedFileURL
        var name = L("新建文件夹", "New Folder")
        var index = 2
        var target = base.appendingPathComponent(name)

        while fm.fileExists(atPath: target.path) {
            name = "\(L("新建文件夹", "New Folder")) \(index)"
            target = base.appendingPathComponent(name)
            index += 1
        }

        do {
            try fm.createDirectory(at: target, withIntermediateDirectories: false)
            registerUndo(UndoEntry(
                title: L("新建「\(name)」", "Create “\(name)”"),
                undo: { [weak self] in
                    guard let self else { return }
                    // 只撤销空文件夹，绝不连带删掉用户后来放进去的东西
                    let contents = (try? FileManager.default.contentsOfDirectory(atPath: target.path)) ?? []
                    if contents.isEmpty {
                        try? FileManager.default.removeItem(at: target)
                    } else {
                        self.errorMessage = L("「\(name)」里已经有内容了，没有撤销", "“\(name)” already had contents, so it can’t be undone")
                    }
                },
                redo: { [weak self] in
                    do {
                        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
                        self?.focus(url: target.standardizedFileURL, scroll: false)
                    } catch {
                        self?.errorMessage = L("重做新建失败：\(error.localizedDescription)", "Couldn’t redo creating the folder: \(error.localizedDescription)")
                    }
                }
            ))
            finishMutation(in: base, revealing: target)
            showFlash(L("已新建「\(name)」", "Created “\(name)”"))
        } catch {
            errorMessage = L("新建文件夹失败：\(error.localizedDescription)", "Couldn’t create the folder: \(error.localizedDescription)")
        }
    }

    // MARK: - 新建文件（右键 → 新建）

    /// 在当前目录创建一个新文件，重名自动编号，创建完直接进行内重命名。
    /// 文本类初始为空；RTF 由 AppKit 生成；Office 三件套写入内嵌的最小空白包。
    func createFile(_ kind: NewFileKind, in destination: URL? = nil) {
        let fm = FileManager.default
        let directory = (destination ?? currentURL).standardizedFileURL
        let base = kind.defaultBaseName
        var name = "\(base).\(kind.fileExtension)"
        var index = 2
        var target = directory.appendingPathComponent(name)
        while fm.fileExists(atPath: target.path) {
            name = "\(base) \(index).\(kind.fileExtension)"
            target = directory.appendingPathComponent(name)
            index += 1
        }

        guard let content = DocumentTemplates.content(for: kind) else {
            errorMessage = L(
                "新建文件失败：没有「\(kind.displayName)」的模板",
                "Couldn’t create the file: no template for \(kind.displayName)"
            )
            return
        }

        do {
            try content.write(to: target, options: .atomic)
            let createdSize = content.count
            registerUndo(UndoEntry(
                title: L("新建「\(name)」", "Create “\(name)”"),
                undo: { [weak self] in
                    // 文件被编辑过（大小变了）就不撤，绝不丢用户写进去的内容
                    let current = (try? fm.attributesOfItem(atPath: target.path))?[.size] as? Int ?? 0
                    if current == createdSize {
                        try? fm.removeItem(at: target)
                    } else {
                        self?.errorMessage = L(
                            "「\(name)」已经被编辑过，没有撤销",
                            "“\(name)” has been edited, so it can’t be undone"
                        )
                    }
                },
                redo: { [weak self] in
                    do {
                        try content.write(to: target, options: .atomic)
                        self?.focus(url: target.standardizedFileURL, scroll: false)
                    } catch {
                        self?.errorMessage = L(
                            "重做新建失败：\(error.localizedDescription)",
                            "Couldn’t redo creating the file: \(error.localizedDescription)"
                        )
                    }
                }
            ))
            finishMutation(in: directory, revealing: target)
            showFlash(L("已新建「\(name)」", "Created “\(name)”"))
            // 和 Windows 一致：新建完立刻改名字（只对当前目录里能立刻定位到的项）
            if let item = treeRows.first(where: {
                $0.item.url.standardizedFileURL == target.standardizedFileURL
            })?.item {
                beginRename(item: item)
            }
        } catch {
            errorMessage = L(
                "新建文件失败：\(error.localizedDescription)",
                "Couldn’t create the file: \(error.localizedDescription)"
            )
        }
    }

    // MARK: - 在终端中打开

    /// 把文件夹交给终端应用开新窗口。`directory` 为 nil 时用当前目录。
    func openInTerminal(_ directory: URL?, app: TerminalService.App) {
        let target = directory ?? currentURL
        let didStart = TerminalService.open(target, app: app)
        if didStart {
            showFlash(L("已在 \(app.name) 中打开", "Opened in \(app.name)"))
        }
    }

    func showFlash(_ message: String) {
        flash = message
        flashWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.flash = nil
        }
        flashWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8, execute: item)
    }
}
