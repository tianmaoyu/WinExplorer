import Foundation
import UniformTypeIdentifiers

/// 目录读取 + 排序。纯函数式，方便以后替换成异步/增量加载。
enum FileSystemService {

    static let resourceKeys: [URLResourceKey] = [
        .isDirectoryKey,
        .isPackageKey,
        .isHiddenKey,
        .isSymbolicLinkKey,
        .fileSizeKey,
        .contentModificationDateKey,
        .localizedNameKey,
        // 和上面几个 key 同一次 stat 拿到，不额外付出系统调用；
        // 有它才能在列表里区分「能读」和「不给读」，而不去真的打开文件试探
        .isReadableKey
    ]

    /// 预构造：`resourceValues(forKeys:)` 每次调用都传 `Set(resourceKeys)` 会在
    /// 每个 item 上多分配一个 Set（万级目录里是白白的开销）
    private static let resourceKeySet = Set(resourceKeys)

    /// 文件类型描述缓存：`UTType(filenameExtension:)` 会查 LaunchServices，
    /// 同一目录里几百个 .swift/.png 没必要各查一次
    private static let kindCache: NSCache<NSString, NSString> = {
        let cache = NSCache<NSString, NSString>()
        cache.countLimit = 256
        return cache
    }()

    static func contents(of directory: URL) throws -> [FileItem] {
        let urls = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: resourceKeys,
            options: []
        )
        var result: [FileItem] = []
        result.reserveCapacity(urls.count)
        for url in urls {
            if let item = makeItem(for: url) { result.append(item) }
        }
        return result
    }

    /// 造一行列表项。**永不返回 nil**：属性读不出来时降级成「未授权」占位项。
    ///
    /// 这里曾经返回 nil，`contents` 用 compactMap 过滤 —— 一旦某项的
    /// `resourceValues` 抛错（TCC 未授权、目录权限不足、网络卷瞬间掉线），
    /// 那一项就被静默丢掉；赶上整层都读不出来，文件夹就"看起来是空的"，
    /// 用户既没有错误提示也没法授权。降级成占位项后：能看到「有这么个东西 + 锁」，
    /// 点它会走已有的授权流程。
    static func makeItem(for url: URL) -> FileItem? {
        guard let values = try? url.resourceValues(forKeys: resourceKeySet) else {
            return degradedItem(for: url)
        }

        let isDirectory = values.isDirectory ?? false
        let isPackage = values.isPackage ?? false
        let name = values.localizedName ?? url.lastPathComponent
        // nil 说明系统没给出结论，按可读处理：宁可不加锁，也不要误把一个正常文件变淡
        let access: AccessState = values.isReadable == false ? .denied : .granted

        return FileItem(
            url: url,
            name: name,
            isDirectory: isDirectory,
            isPackage: isPackage,
            isHidden: values.isHidden ?? name.hasPrefix("."),
            size: isDirectory ? nil : Int64(values.fileSize ?? 0),
            modified: values.contentModificationDate,
            kind: kindDescription(url: url, isDirectory: isDirectory, isPackage: isPackage),
            access: access
        )
    }

    /// 属性读不出来时的降级项：名称取路径最后一段，类型未知，标记为未授权。
    /// 目录与否能 stat 就用 stat，stat 也失败就按文件画（比"消失"诚实）。
    private static func degradedItem(for url: URL) -> FileItem {
        var isDirectory: ObjCBool = false
        let statted = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        let name = url.lastPathComponent
        return FileItem(
            url: url,
            name: name.isEmpty ? url.path : name,
            isDirectory: statted && isDirectory.boolValue,
            isPackage: false,
            isHidden: name.hasPrefix("."),
            size: nil,
            modified: nil,
            kind: L("无法读取", "Unreadable"),
            access: .denied
        )
    }

    private static func kindDescription(url: URL, isDirectory: Bool, isPackage: Bool) -> String {
        if isPackage {
            return url.pathExtension.lowercased() == "app"
                ? L("应用程序", "Application")
                : L("包", "Package")
        }
        if isDirectory { return L("文件夹", "Folder") }

        let ext = url.pathExtension
        guard !ext.isEmpty else { return L("文件", "File") }

        // 按扩展名缓存：同一目录里几百个同类型文件只查一次 LaunchServices
        let key = ext.lowercased() as NSString
        if let cached = kindCache.object(forKey: key) { return cached as String }

        let description = UTType(filenameExtension: ext)?.localizedDescription ?? L("文件", "File")
        kindCache.setObject(description as NSString, forKey: key)
        return description
    }

    /// 排序规则：文件夹永远在前（和 Windows 资源管理器一致），再按列比较。
    static func sort(_ items: [FileItem], by column: SortColumn, ascending: Bool) -> [FileItem] {
        items.sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory {
                return lhs.isDirectory
            }

            let result: ComparisonResult
            switch column {
            case .name:
                result = lhs.name.localizedStandardCompare(rhs.name)
            case .modified:
                result = compare(lhs.modified ?? .distantPast, rhs.modified ?? .distantPast)
            case .size:
                result = compare(lhs.size ?? -1, rhs.size ?? -1)
            case .kind:
                result = lhs.kind.localizedStandardCompare(rhs.kind)
            }

            if result == .orderedSame {
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
            return ascending ? result == .orderedAscending : result == .orderedDescending
        }
    }

    private static func compare<T: Comparable>(_ lhs: T, _ rhs: T) -> ComparisonResult {
        if lhs < rhs { return .orderedAscending }
        if lhs > rhs { return .orderedDescending }
        return .orderedSame
    }
}
