import Foundation

/// 列表中的一行（文件或文件夹）。
struct FileItem: Identifiable, Hashable {
    let url: URL
    let name: String
    let isDirectory: Bool
    /// .app / .bundle 之类的包：在 Windows 眼里像"单个程序"，双击应直接打开而不是进入
    let isPackage: Bool
    let isHidden: Bool
    let size: Int64?
    let modified: Date?
    let kind: String

    var id: URL { url }

    /// 可以"进入"的文件夹（排除 .app 等包）
    var isFolderLike: Bool { isDirectory && !isPackage }
}

extension FileItem {
    private static let sizeFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        return formatter
    }()

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy/M/d HH:mm"
        return formatter
    }()

    var sizeText: String {
        guard !isDirectory, let size else { return "—" }
        if size < 1024 { return "\(size) B" }
        return Self.sizeFormatter.string(fromByteCount: size)
    }

    var modifiedText: String {
        guard let modified else { return "—" }
        return Self.dateFormatter.string(from: modified)
    }
}

/// 可排序的列
enum SortColumn: String, CaseIterable, Identifiable {
    case name
    case modified
    case size
    case kind

    var id: String { rawValue }

    var title: String {
        switch self {
        case .name: return "名称"
        case .modified: return "修改日期"
        case .size: return "大小"
        case .kind: return "类型"
        }
    }
}

/// 面包屑路径的一段
struct Crumb: Identifiable {
    let url: URL
    let title: String
    var id: URL { url }
}

/// 侧边栏的一个位置
struct Place: Identifiable, Hashable {
    let name: String
    let url: URL
    var id: URL { url }

    static var quickPlaces: [Place] {
        let fm = FileManager.default
        var list: [Place] = []

        func add(_ name: String, _ url: URL?) {
            guard let url else { return }
            let standardized = url.standardizedFileURL
            guard fm.fileExists(atPath: standardized.path) else { return }
            guard !list.contains(where: { $0.url == standardized }) else { return }
            list.append(Place(name: name, url: standardized))
        }

        add("个人文件夹", fm.homeDirectoryForCurrentUser)
        add("桌面", fm.urls(for: .desktopDirectory, in: .userDomainMask).first)
        add("文稿", fm.urls(for: .documentDirectory, in: .userDomainMask).first)
        add("下载", fm.urls(for: .downloadsDirectory, in: .userDomainMask).first)
        add("应用程序", URL(fileURLWithPath: "/Applications"))
        return list
    }

    static var volumes: [Place] {
        var list = [Place(name: BrowserModel.volumeName, url: URL(fileURLWithPath: "/"))]
        let keys: [URLResourceKey] = [.volumeNameKey, .volumeIsLocalKey]
        if let urls = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: keys,
            options: [.skipHiddenVolumes]
        ) {
            for url in urls where url.path != "/" {
                let values = try? url.resourceValues(forKeys: Set(keys))
                guard values?.volumeIsLocal == true else { continue }
                list.append(Place(name: values?.volumeName ?? url.lastPathComponent, url: url))
            }
        }
        return list
    }
}
