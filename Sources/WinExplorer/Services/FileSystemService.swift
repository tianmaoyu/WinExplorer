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
        .localizedNameKey
    ]

    static func contents(of directory: URL) throws -> [FileItem] {
        let urls = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: resourceKeys,
            options: []
        )
        return urls.compactMap { makeItem(for: $0) }
    }

    static func makeItem(for url: URL) -> FileItem? {
        guard let values = try? url.resourceValues(forKeys: Set(resourceKeys)) else {
            return nil
        }

        let isDirectory = values.isDirectory ?? false
        let isPackage = values.isPackage ?? false
        let name = values.localizedName ?? url.lastPathComponent

        return FileItem(
            url: url,
            name: name,
            isDirectory: isDirectory,
            isPackage: isPackage,
            isHidden: values.isHidden ?? name.hasPrefix("."),
            size: isDirectory ? nil : Int64(values.fileSize ?? 0),
            modified: values.contentModificationDate,
            kind: kindDescription(url: url, isDirectory: isDirectory, isPackage: isPackage)
        )
    }

    private static func kindDescription(url: URL, isDirectory: Bool, isPackage: Bool) -> String {
        if isPackage {
            return url.pathExtension.lowercased() == "app" ? "应用程序" : "包"
        }
        if isDirectory { return "文件夹" }

        let ext = url.pathExtension
        guard !ext.isEmpty, let type = UTType(filenameExtension: ext) else { return "文件" }
        return type.localizedDescription ?? "文件"
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
