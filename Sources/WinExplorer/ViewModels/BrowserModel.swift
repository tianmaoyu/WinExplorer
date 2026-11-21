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

    @Published var sortColumn: SortColumn = .name {
        didSet { applySortAndFilter() }
    }
    @Published var sortAscending: Bool = true {
        didSet { applySortAndFilter() }
    }
    @Published var showHidden: Bool = false {
        didSet { applySortAndFilter() }
    }

    @Published private(set) var backStack: [URL] = []
    @Published private(set) var forwardStack: [URL] = []

    private var allItems: [FileItem] = []
    private var flashWorkItem: DispatchWorkItem?

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
        let requested = url ?? envStart ?? FileManager.default.homeDirectoryForCurrentUser
        let start = requested.standardizedFileURL
        currentURL = start
        load(directory: start, recordHistory: false)
    }

    // MARK: - 导航状态

    var canGoBack: Bool { !backStack.isEmpty }
    var canGoForward: Bool { !forwardStack.isEmpty }
    var canGoUp: Bool { currentURL.path != "/" }
    var hasSelection: Bool { !selection.isEmpty }

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

    private func load(directory url: URL, recordHistory: Bool) {
        do {
            let loaded = try FileSystemService.contents(of: url)
            if recordHistory, url != currentURL {
                backStack.append(currentURL)
                forwardStack.removeAll()
            }
            currentURL = url
            allItems = loaded
            clearSelection()
            renamingURL = nil
            pendingPermanentDelete = nil
            errorMessage = nil
            applySortAndFilter()
        } catch {
            errorMessage = "无法打开「\(url.lastPathComponent)」：\(error.localizedDescription)"
        }
    }

    private func applySortAndFilter() {
        var visible = allItems
        if !showHidden {
            visible = visible.filter { !$0.isHidden }
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
        for item in targets {
            do {
                try FileManager.default.trashItem(at: item.url, resultingItemURL: nil)
            } catch {
                failures.append("\(item.name)：\(error.localizedDescription)")
            }
        }

        reload()
        if failures.isEmpty {
            showFlash(targets.count == 1 ? "已移到废纸篓" : "已把 \(targets.count) 项移到废纸篓")
        } else {
            errorMessage = "部分项目无法移到废纸篓：\n" + failures.joined(separator: "\n")
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
