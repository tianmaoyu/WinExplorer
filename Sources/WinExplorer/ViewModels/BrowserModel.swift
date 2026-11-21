import AppKit
import Combine
import Foundation

/// 浏览器的全部状态与动作。
/// 所有方法都在主线程调用（SwiftUI 的按钮/菜单回调），文件读取对单个目录来说是毫秒级的。
final class BrowserModel: ObservableObject {

    @Published private(set) var currentURL: URL
    @Published private(set) var items: [FileItem] = []
    @Published var selection: URL?
    @Published var errorMessage: String?
    @Published var flash: String?

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
    var selectedItem: FileItem? { items.first { $0.url == selection } }
    var hasSelection: Bool { selection != nil }

    /// 窗口标题：当前文件夹名（根目录显示卷名）
    var titleText: String {
        currentURL.path == "/" ? Self.volumeName : currentURL.lastPathComponent
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

    private func load(directory url: URL, recordHistory: Bool) {
        do {
            let loaded = try FileSystemService.contents(of: url)
            if recordHistory, url != currentURL {
                backStack.append(currentURL)
                forwardStack.removeAll()
            }
            currentURL = url
            allItems = loaded
            selection = nil
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

        if let selection, !items.contains(where: { $0.url == selection }) {
            self.selection = nil
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

    // MARK: - 打开 / 操作

    func open(_ item: FileItem) {
        if item.isFolderLike {
            load(directory: item.url, recordHistory: true)
        } else {
            NSWorkspace.shared.open(item.url)
        }
    }

    func openSelection() {
        guard let item = selectedItem else { return }
        open(item)
    }

    func revealInFinder(_ item: FileItem) {
        NSWorkspace.shared.activateFileViewerSelecting([item.url])
    }

    func copyPath(_ item: FileItem) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(item.url.path, forType: .string)
        showFlash("已复制路径")
    }

    /// 新建文件夹，重名时自动加序号（Windows 的"新建文件夹 (2)"习惯）
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
            selection = target.standardizedFileURL
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
