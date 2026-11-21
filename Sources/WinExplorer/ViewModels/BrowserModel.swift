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

    /// 自检时关掉，避免动到用户的系统剪贴板
    static var syncsSystemPasteboard = true
    /// 自检时同步执行复制/移动，便于断言（生产路径始终异步）
    static var runsTransfersSynchronously = false

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
    private var cachedPasteboardChangeCount = -1
    private var cachedPasteboardURLs: [URL] = []

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

    /// 剪切中的项，行里会画成半透明（Windows 的"待移动"观感）
    var cutURLs: Set<URL> { clipboard?.cutURLs ?? [] }

    /// 有剪贴板内容或系统剪贴板里有文件，才能粘贴
    var canPaste: Bool {
        if clipboard != nil { return true }
        return !systemPasteboardFileURLs().isEmpty
    }

    /// 有复制/移动任务在跑
    var isTransferring: Bool { transfer != nil }

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

    func copyCurrentDirectoryPath() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(currentURL.path, forType: .string)
        showFlash("已复制当前文件夹路径")
    }

    func revealCurrentDirectory() {
        NSWorkspace.shared.activateFileViewerSelecting([currentURL])
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

        let canMoveInstantly = requests.allSatisfy {
            $0.mode == .move && TransferService.sameVolume($0.source, $0.destination)
        }

        if canMoveInstantly {
            var failures: [String] = []
            for request in requests {
                do {
                    try fm.moveItem(at: request.source, to: request.destination)
                } catch {
                    failures.append("\(request.source.lastPathComponent)：\(error.localizedDescription)")
                }
            }
            if mode == .cut { clipboard = nil }
            reload()
            select(urls: requests.map(\.destination))
            if failures.isEmpty {
                showFlash("已移动 \(requests.count) 项到「\(targetDir.lastPathComponent)」")
            } else {
                errorMessage = "部分项目移动失败：\n" + failures.joined(separator: "\n")
            }
            return
        }

        // 复制或跨卷移动：后台跑，带进度与取消
        let cancellation = TransferCancellation()
        transferCancellation = cancellation
        let title = mode == .copy ? "正在复制" : "正在移动"
        let total = requests.reduce(0) { $0 + TransferService.countFiles($1.source) }
        transfer = TransferProgress(title: title, completed: 0, total: max(total, 1), currentName: "")

        let isCut = mode == .cut
        let targetName = targetDir.lastPathComponent

        func apply(_ result: TransferService.Result) {
            transferCancellation = nil
            transfer = nil
            if isCut, !result.cancelled { clipboard = nil }

            reload()
            select(urls: result.moved + result.copied)

            if !result.failures.isEmpty {
                errorMessage = "部分项目处理失败：\n" + result.failures.joined(separator: "\n")
            } else if result.cancelled {
                let done = result.moved.count + result.copied.count
                showFlash("已取消，其中 \(done) 项已完成")
            } else {
                let done = result.moved.count + result.copied.count
                showFlash("已\(isCut ? "移动" : "复制") \(done) 项到「\(targetName)」")
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
