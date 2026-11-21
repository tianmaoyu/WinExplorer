import AppKit
import Combine
import Foundation

/// 键盘导航后需要把某一行滚进视口（用 token 保证同一个 URL 连续触发也能生效）
struct ScrollRequest: Equatable {
    let url: URL
    let token: UUID

    init(_ url: URL) {
        self.url = url
        self.token = UUID()
    }
}

/// 浏览器的全部状态与动作。
/// 所有方法都在主线程调用（SwiftUI 的按钮/菜单/键盘回调），单目录读取是毫秒级的。
final class BrowserModel: ObservableObject {

    @Published private(set) var currentURL: URL
    @Published private(set) var items: [FileItem] = []
    @Published private(set) var errorMessage: String?
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

    /// 应用内文件剪贴板（复制 / 剪切）
    @Published private(set) var clipboard: FileClipboard?
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
            applySortAndFilter()
        }
    }
    /// 视图消费后把焦点放进搜索框（⌘F 每次都是新的 token，连按会重新全选）
    @Published private(set) var searchFocusRequest: UUID?

    /// 属性面板的内容（nil 表示关闭）
    @Published private(set) var info: InfoSheetState?

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
            showFlash("没有可撤销的操作")
            return
        }
        entry.undo()
        redoStack.append(entry)
        reload()
        showFlash("已撤销：\(entry.title)")
    }

    func redo() {
        guard let entry = redoStack.popLast() else {
            showFlash("没有可重做的操作")
            return
        }
        entry.redo()
        undoStack.append(entry)
        reload()
        showFlash("已重做：\(entry.title)")
    }

    /// 为一批移动/复制生成撤销项：移动就搬回去，复制就把副本删掉
    private func transferUndo(_ requests: [TransferRequest], targetName: String) -> UndoEntry {
        let copyCount = requests.filter { $0.mode == .copy }.count
        let verb: String
        if copyCount == requests.count {
            verb = "复制"
        } else if copyCount == 0 {
            verb = "移动"
        } else {
            verb = "移动/复制"
        }
        let title = "\(verb) \(requests.count) 项到「\(targetName)」"

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
                                self.errorMessage = "撤销移动失败：\(error.localizedDescription)"
                            }
                        }
                    case .copy:
                        if fm.fileExists(atPath: request.destination.path) {
                            do {
                                try fm.removeItem(at: request.destination)
                                reverted += 1
                            } catch {
                                self.errorMessage = "撤销复制失败：\(error.localizedDescription)"
                            }
                        }
                    }
                }
                if reverted == 0 { self.errorMessage = "撤销失败：这些项目已经不在原位置了" }
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
                                self.errorMessage = "重做移动失败：\(error.localizedDescription)"
                            }
                        }
                    case .copy:
                        if !fm.fileExists(atPath: request.destination.path) {
                            do {
                                try fm.copyItem(at: request.source, to: request.destination)
                            } catch {
                                self.errorMessage = "重做复制失败：\(error.localizedDescription)"
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

    @Published private(set) var backStack: [URL] = []
    @Published private(set) var forwardStack: [URL] = []

    private var allItems: [FileItem] = []
    private var flashWorkItem: DispatchWorkItem?
    private var cachedPasteboardChangeCount = -1
    private var cachedPasteboardURLs: [URL] = []

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
        return !systemPasteboardFileURLs().isEmpty
    }

    /// 有复制/移动任务在跑
    var isTransferring: Bool { transfer != nil }

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
            pathError = "找不到「\(trimmed)」"
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

    private func load(directory url: URL, recordHistory: Bool) {
        let standardized = url.standardizedFileURL
        let directoryChanged = standardized.path != currentURL.standardizedFileURL.path
        do {
            let loaded = try FileSystemService.contents(of: standardized)
            if recordHistory, standardized != currentURL {
                backStack.append(currentURL)
                forwardStack.removeAll()
            }
            currentURL = standardized
            allItems = loaded
            directorySignature = Self.signature(of: loaded)
            // 换目录时搜索词不再适用（搜索只针对当前文件夹）
            if directoryChanged { searchText = "" }
            clearSelection()
            renamingURL = nil
            pendingPermanentDelete = nil
            dropTargetURL = nil
            errorMessage = nil
            isEditingPath = false
            pathError = nil
            closeInfo()
            Preferences.lastDirectoryPath = standardized.path
            applySortAndFilter()
            watchDirectory(standardized)
        } catch {
            errorMessage = "无法打开「\(url.lastPathComponent)」：\(error.localizedDescription)"
        }
    }

    private func applySortAndFilter() {
        var visible = allItems
        if !showHidden {
            visible = visible.filter { !$0.isHidden }
        }
        let query = searchQuery
        if !query.isEmpty {
            visible = visible.filter { $0.name.localizedStandardContains(query) }
        }
        items = FileSystemService.sort(visible, by: sortColumn, ascending: sortAscending)

        let visibleURLs = Set(items.map(\.url))
        selection = selection.intersection(visibleURLs)
        if let focused = focusedURL, !visibleURLs.contains(focused) {
            focusedURL = nil
        }
        if let anchor = anchorURL, !visibleURLs.contains(anchor) {
            anchorURL = nil
        }
    }

    // MARK: - 目录监听

    private static func signature(of items: [FileItem]) -> [String] {
        items.map {
            "\($0.url.path)|\($0.size ?? -1)|\($0.modified?.timeIntervalSince1970 ?? 0)|\($0.isDirectory)"
        }
        .sorted()
    }

    private func watchDirectory(_ url: URL) {
        guard Self.watchesFileSystem else { return }
        directoryWatcher.watch(url)
    }

    private func handleDirectoryChange() {
        // 用户正在编辑或确认时不打断：这些操作结束时会各自 reload
        guard renamingURL == nil,
              pendingPermanentDelete == nil,
              info == nil,
              !isEditingPath,
              transfer == nil else { return }
        refreshFromDisk()
    }

    /// 外部变更后重新读目录：保留选择与焦点，只有内容真的变了才更新（避免无谓刷新）
    func refreshFromDisk() {
        do {
            let loaded = try FileSystemService.contents(of: currentURL)
            let signature = Self.signature(of: loaded)
            guard signature != directorySignature else { return }
            directorySignature = signature
            allItems = loaded
            applySortAndFilter()
        } catch {
            if errorMessage == nil {
                errorMessage = "「\(currentURL.lastPathComponent)」已不可访问：\(error.localizedDescription)"
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
        guard let match = items.first(where: { $0.url.standardizedFileURL.path == targetPath }) else {
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
        resizeColumn(column, to: ceil(widest) + 26)
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

    // MARK: - 打开 / 操作

    func open(_ item: FileItem) {
        if item.isFolderLike {
            load(directory: item.url, recordHistory: true)
        } else {
            NSWorkspace.shared.open(item.url)
        }
    }

    func openSelection() {
        let targets = selectedItems
        guard !targets.isEmpty else { return }

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
        var message = "已打开 \(opened) 个文件"
        if folders > 0 { message += "，跳过 \(folders) 个文件夹" }
        showFlash(message)
    }

    func revealInFinder(_ item: FileItem) {
        NSWorkspace.shared.activateFileViewerSelecting([item.url])
    }

    func copyPath(_ item: FileItem) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(item.url.path, forType: .string)
        showFlash("已复制路径")
    }

    /// 复制选中项路径（多选时每行一条）
    func copySelectedPaths() {
        let paths = selectedItems.map(\.url.path)
        guard !paths.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(paths.joined(separator: "\n"), forType: .string)
        showFlash(paths.count == 1 ? "已复制路径" : "已复制 \(paths.count) 条路径")
    }

    func copyCurrentDirectoryPath() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(currentURL.path, forType: .string)
        showFlash("已复制当前文件夹路径")
    }

    func revealCurrentDirectory() {
        NSWorkspace.shared.activateFileViewerSelecting([currentURL])
    }

    // MARK: - 属性面板

    /// ⌘I / 右键「显示简介」
    func showInfo() {
        let targets = selectedItems
        guard !targets.isEmpty else {
            showFlash("请先选中要查看属性的项目")
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
            for item in infoTargets where item.isDirectory {
                bytes += stats[item.url.standardizedFileURL.path]?.bytes ?? 0
            }
            state.set("size", to: FileInfoService.byteText(bytes))
            state.note = nil
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

    /// 属性面板打开时，方向键/快捷键不应继续操作后台列表
    var hasModalOverlay: Bool {
        info != nil || pendingPermanentDelete != nil
    }

    // MARK: - 剪贴板

    /// 复制：内容同时写进系统剪贴板，所以可以直接粘到 Finder 或其它 App
    func copySelection() {
        let targets = selectedItems.map(\.url)
        guard !targets.isEmpty else {
            showFlash("请先选中要复制的内容")
            return
        }
        clipboard = FileClipboard(urls: targets, mode: .copy, sourceDirectory: currentURL)
        writeSystemPasteboard(targets)
        showFlash(targets.count == 1
                  ? "已复制「\(targets[0].lastPathComponent)」，⌘V 粘贴"
                  : "已复制 \(targets.count) 项，⌘V 粘贴")
    }

    /// 剪切：只做标记，真正移动发生在粘贴时（和 Windows 一致，可以反悔）
    func cutSelection() {
        let targets = selectedItems.map(\.url)
        guard !targets.isEmpty else {
            showFlash("请先选中要剪切的内容")
            return
        }
        clipboard = FileClipboard(urls: targets, mode: .cut, sourceDirectory: currentURL)
        writeSystemPasteboard(targets)
        showFlash(targets.count == 1
                  ? "已剪切「\(targets[0].lastPathComponent)」，⌘V 粘贴"
                  : "已剪切 \(targets.count) 项，⌘V 粘贴")
    }

    func paste(into destination: URL? = nil) {
        guard transfer == nil else {
            showFlash("上一项操作还没结束")
            return
        }

        let targetDir = (destination ?? currentURL).standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: targetDir.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            errorMessage = "「\(targetDir.lastPathComponent)」不是文件夹，无法粘贴到里面"
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
            showFlash(clipboard == nil ? "没有可粘贴的内容" : "剪贴板里的内容已经不在了")
            return
        }

        // 防呆：不能把文件夹粘进它自己或它的子目录
        let targetPath = targetDir.path
        for source in sources {
            if targetPath == source.path || targetPath.hasPrefix(source.path + "/") {
                errorMessage = "不能把「\(source.lastPathComponent)」粘贴到它自己里面"
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
            errorMessage = "「\(targetDir.lastPathComponent)」里已存在同名项目："
                + conflicts.prefix(3).joined(separator: "、")
                + (conflicts.count > 3 ? " 等" : "")
                + "，未执行粘贴"
            return
        }

        guard !requests.isEmpty else {
            if !skipped.isEmpty {
                showFlash("「\(skipped[0])」已经在当前文件夹里")
            }
            return
        }

        execute(requests: requests, targetDir: targetDir, clearsClipboard: mode == .cut)
    }

    /// 拖放：把一批 URL 放进 target 目录。
    /// 规则和 Windows 一致：⌥ 强制复制、⌘ 强制移动，否则同卷移动、跨卷复制。
    func drop(urls: [URL], into targetDir: URL, modifiers: NSEvent.ModifierFlags) {
        guard transfer == nil else {
            showFlash("上一项操作还没结束")
            return
        }

        let fm = FileManager.default
        let target = targetDir.standardizedFileURL
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: target.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            showFlash("「\(target.lastPathComponent)」不是文件夹")
            return
        }

        let sources = urls.map { $0.standardizedFileURL }.filter { fm.fileExists(atPath: $0.path) }
        guard !sources.isEmpty else { return }

        if let message = invalidTargetMessage(sources: sources, target: target, verb: "移动") {
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
            errorMessage = "「\(target.lastPathComponent)」里已存在同名项目："
                + conflicts.prefix(3).joined(separator: "、")
                + (conflicts.count > 3 ? " 等" : "")
                + "，未执行拖放"
            return
        }

        guard !requests.isEmpty else {
            if !skipped.isEmpty {
                showFlash("「\(skipped[0])」已经在这个文件夹里")
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
                showFlash("已移动 \(done.count) 项到「\(targetName)」")
            } else {
                errorMessage = "部分项目移动失败：\n" + failures.joined(separator: "\n")
            }
            return
        }

        // 复制或跨卷移动：后台跑，带进度与取消
        let cancellation = TransferCancellation()
        transferCancellation = cancellation
        let isCopyOnly = requests.allSatisfy { $0.mode == .copy }
        let title = isCopyOnly ? "正在复制" : "正在移动"
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
                errorMessage = "部分项目处理失败：\n" + result.failures.joined(separator: "\n")
            } else if result.cancelled {
                let done = result.moved.count + result.copied.count
                showFlash("已取消，其中 \(done) 项已完成")
            } else {
                let done = result.moved.count + result.copied.count
                showFlash("已\(isCopyOnly ? "复制" : "移动") \(done) 项到「\(targetName)」")
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
            return "不能把「\(source.lastPathComponent)」\(verb)到它自己里面"
        }
        return nil
    }

    func cancelTransfer() {
        guard transferCancellation != nil else { return }
        transferCancellation?.cancel()
        showFlash("正在取消…")
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
        }
        return cachedPasteboardURLs
    }

    // MARK: - 重命名

    func beginRename() {
        guard selection.count == 1, let item = selectedItems.first else {
            showFlash("请先选中一个项目再重命名")
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
            errorMessage = "名称不能为空"
            return false
        }
        if trimmed.contains("/") || trimmed.contains(":") {
            errorMessage = "名称不能包含「/」或「:」"
            return false
        }
        if trimmed == source.lastPathComponent {
            renamingURL = nil
            return true
        }

        let target = source.deletingLastPathComponent().appendingPathComponent(trimmed)
        if FileManager.default.fileExists(atPath: target.path) {
            errorMessage = "「\(trimmed)」已存在，请换一个名字"
            return false
        }

        do {
            try FileManager.default.moveItem(at: source, to: target)
            renamingURL = nil
            registerUndo(UndoEntry(
                title: "重命名为「\(trimmed)」",
                undo: { [weak self] in self?.moveItemReportingFailure(from: target, to: source) },
                redo: { [weak self] in self?.moveItemReportingFailure(from: source, to: target) }
            ))
            reload()
            focus(url: target, scroll: false)
            showFlash("已重命名为「\(trimmed)」")
            return true
        } catch {
            errorMessage = "重命名失败：\(error.localizedDescription)"
            return false
        }
    }

    // MARK: - 删除

    /// 移到废纸篓（可恢复）
    func moveSelectionToTrash() {
        let targets = selectedItems
        guard !targets.isEmpty else { return }

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
                title: "移到废纸篓 \(trashed.count) 项",
                undo: { [weak self] in
                    guard let self else { return }
                    let fm = FileManager.default
                    for pair in trashed.reversed() where fm.fileExists(atPath: pair.inTrash.path) {
                        guard !fm.fileExists(atPath: pair.original.path) else {
                            self.errorMessage = "原位置已有同名项目，无法还原「\(pair.original.lastPathComponent)」"
                            continue
                        }
                        do {
                            try fm.moveItem(at: pair.inTrash, to: pair.original)
                        } catch {
                            self.errorMessage = "从废纸篓还原失败：\(error.localizedDescription)"
                        }
                    }
                },
                redo: { [weak self] in
                    guard let self else { return }
                    for pair in trashed where FileManager.default.fileExists(atPath: pair.original.path) {
                        do {
                            try FileManager.default.trashItem(at: pair.original, resultingItemURL: nil)
                        } catch {
                            self.errorMessage = "再次移到废纸篓失败：\(error.localizedDescription)"
                        }
                    }
                }
            ))
        }

        reload()
        if failures.isEmpty {
            showFlash(targets.count == 1 ? "已移到废纸篓" : "已把 \(targets.count) 项移到废纸篓")
        } else {
            errorMessage = "部分项目无法移到废纸篓：\n" + failures.joined(separator: "\n")
        }
    }

    /// 移动单个文件并报告失败（撤销/重做共用）
    private func moveItemReportingFailure(from: URL, to: URL) {
        do {
            try FileManager.default.moveItem(at: from, to: to)
        } catch {
            errorMessage = "操作失败：\(error.localizedDescription)"
        }
    }

    /// 彻底删除需要二次确认，这里只登记目标
    func requestPermanentDelete() {
        let targets = selectedItems
        guard !targets.isEmpty else { return }
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
                failures.append("\(item.name)：不能删除当前所在目录")
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
            showFlash("已彻底删除 \(removed) 项")
        } else {
            errorMessage = "部分项目删除失败：\n" + failures.joined(separator: "\n")
        }
    }

    /// 新建文件夹，重名时自动加序号（Windows 的"新建文件夹 2"习惯）
    func createFolder() {
        let fm = FileManager.default
        var name = "新建文件夹"
        var index = 2
        var target = currentURL.appendingPathComponent(name)

        while fm.fileExists(atPath: target.path) {
            name = "新建文件夹 \(index)"
            target = currentURL.appendingPathComponent(name)
            index += 1
        }

        do {
            try fm.createDirectory(at: target, withIntermediateDirectories: false)
            registerUndo(UndoEntry(
                title: "新建「\(name)」",
                undo: { [weak self] in
                    guard let self else { return }
                    // 只撤销空文件夹，绝不连带删掉用户后来放进去的东西
                    let contents = (try? FileManager.default.contentsOfDirectory(atPath: target.path)) ?? []
                    if contents.isEmpty {
                        try? FileManager.default.removeItem(at: target)
                    } else {
                        self.errorMessage = "「\(name)」里已经有内容了，没有撤销"
                    }
                },
                redo: { [weak self] in
                    do {
                        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
                        self?.focus(url: target.standardizedFileURL, scroll: false)
                    } catch {
                        self?.errorMessage = "重做新建失败：\(error.localizedDescription)"
                    }
                }
            ))
            reload()
            focus(url: target.standardizedFileURL, scroll: false)
            showFlash("已新建「\(name)」")
        } catch {
            errorMessage = "新建文件夹失败：\(error.localizedDescription)"
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
