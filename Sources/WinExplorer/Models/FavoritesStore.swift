import Foundation

/// 侧边栏收藏夹。存路径（不是书签）——简单、可读；目录被移动后会失效，点开时给提示。
final class FavoritesStore: ObservableObject {
    static let shared = FavoritesStore()

    @Published private(set) var items: [Place] = []

    private let defaults: UserDefaults?
    private static let storageKey = "favorites.paths"

    /// persisting = false 时只在内存里（自检用，不污染用户设置）
    init(persisting: Bool = true) {
        defaults = persisting ? .standard : nil
        load()
    }

    func contains(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        return items.contains { $0.url.standardizedFileURL.path == path }
    }

    /// 只接受真实存在的文件夹；重复加不报错，返回 false
    @discardableResult
    func add(_ url: URL) -> Bool {
        let standardized = url.standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: standardized.path, isDirectory: &isDirectory),
              isDirectory.boolValue,
              !contains(standardized) else { return false }

        let name = standardized.path == "/"
            ? BrowserModel.volumeName
            : (FileManager.default.displayName(atPath: standardized.path))
        items.append(Place(name: name, url: standardized))
        persist()
        return true
    }

    func remove(_ url: URL) {
        let path = url.standardizedFileURL.path
        let before = items.count
        items.removeAll { $0.url.standardizedFileURL.path == path }
        if items.count != before { persist() }
    }

    /// 拖拽排序
    func move(from: Int, to: Int) {
        guard items.indices.contains(from), to >= 0, to <= items.count else { return }
        let item = items.remove(at: from)
        let target = to > from ? to - 1 : to
        items.insert(item, at: min(max(target, 0), items.count))
        persist()
    }

    /// 丢掉已经不存在的位置（启动时清一次，避免侧边栏残留死条目）
    func pruneMissing() {
        let before = items.count
        items.removeAll { !FileManager.default.fileExists(atPath: $0.url.path) }
        if items.count != before { persist() }
    }

    // MARK: - 持久化

    private func load() {
        guard let paths = defaults?.stringArray(forKey: Self.storageKey) else { return }
        items = paths.compactMap { path in
            let url = URL(fileURLWithPath: path).standardizedFileURL
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            let name = url.path == "/"
                ? BrowserModel.volumeName
                : (FileManager.default.displayName(atPath: url.path))
            return Place(name: name, url: url)
        }
    }

    private func persist() {
        defaults?.set(items.map { $0.url.path }, forKey: Self.storageKey)
    }
}
