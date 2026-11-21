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
    /// 可否读取。`.denied` 的项在列表里变淡带锁，且不会为它触发任何系统弹窗
    var access: AccessState = .granted

    var id: URL { url }

    /// 可以"进入"的文件夹（排除 .app 等包）
    var isFolderLike: Bool { isDirectory && !isPackage }

    var isAccessible: Bool { access == .granted }
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
        return Self.byteText(size)
    }

    static func byteText(_ size: Int64) -> String {
        if size < 1024 { return "\(size) B" }
        return sizeFormatter.string(fromByteCount: size)
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
        case .name: return L("名称", "Name")
        case .modified: return L("修改日期", "Date Modified")
        case .size: return L("大小", "Size")
        case .kind: return L("类型", "Kind")
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
    /// 本机卷 = true；SMB / AFP 这类网络位置 = false
    var isLocal: Bool = true
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

        add(L("个人文件夹", "Home"), fm.homeDirectoryForCurrentUser)
        // iCloud 云盘：目录存在才显示（没登录 iCloud 的机器上没有）
        add(L("iCloud 云盘", "iCloud Drive"), fm.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs"))
        add(L("桌面", "Desktop"), fm.urls(for: .desktopDirectory, in: .userDomainMask).first)
        add(L("文稿", "Documents"), fm.urls(for: .documentDirectory, in: .userDomainMask).first)
        add(L("下载", "Downloads"), fm.urls(for: .downloadsDirectory, in: .userDomainMask).first)
        add(L("应用程序", "Applications"), URL(fileURLWithPath: "/Applications"))
        return list
    }

    /// 本机卷（含根卷）。网络卷单独走 `networkVolumes`，侧边栏分两段显示。
    static var volumes: [Place] {
        allMountedVolumes().filter(\.isLocal)
    }

    /// 网络位置（SMB / AFP / WebDAV 等已挂载的远程卷）
    static var networkVolumes: [Place] {
        allMountedVolumes().filter { !$0.isLocal }
    }

    /// 已挂载且可浏览的卷，根卷排最前
    private static func allMountedVolumes() -> [Place] {
        var list = [Place(name: BrowserModel.volumeName, url: URL(fileURLWithPath: "/"), isLocal: true)]
        let keys: [URLResourceKey] = [
            .volumeNameKey,
            .volumeLocalizedNameKey,
            .volumeIsLocalKey,
            .volumeIsBrowsableKey
        ]
        guard let urls = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: keys,
            options: [.skipHiddenVolumes]
        ) else {
            return list
        }

        for url in urls where url.path != "/" {
            let values = try? url.resourceValues(forKeys: Set(keys))
            guard values?.volumeIsBrowsable != false else { continue }
            list.append(Place(
                name: values?.volumeLocalizedName ?? values?.volumeName ?? url.lastPathComponent,
                url: url,
                isLocal: values?.volumeIsLocal ?? true
            ))
        }
        return list
    }
}
