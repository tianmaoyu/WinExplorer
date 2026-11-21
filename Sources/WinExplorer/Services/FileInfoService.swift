import Foundation

/// 属性面板里的一行
struct InfoField: Identifiable, Equatable {
    let id: String
    let label: String
    var value: String
}

/// 属性面板的完整状态（单个 / 多选）
struct InfoSheetState: Identifiable, Equatable {
    let id = UUID()
    let iconURL: URL
    var title: String
    var kind: String
    var fields: [InfoField]
    /// 文件夹还在统计时显示的提示
    var note: String?

    mutating func set(_ fieldID: String, to value: String) {
        guard let index = fields.firstIndex(where: { $0.id == fieldID }) else { return }
        fields[index].value = value
    }
}

/// 属性面板的数据来源：读取资源值 + 递归统计文件夹大小。
enum FileInfoService {

    struct FolderStats: Equatable {
        var bytes: Int64 = 0
        var allocated: Int64 = 0
        var fileCount = 0
        var folderCount = 0

        var isEmpty: Bool { fileCount == 0 && folderCount == 0 }
    }

    static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        return formatter
    }()

    static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = L10n.isEnglish ? "MMM d, yyyy HH:mm:ss" : "yyyy年M月d日 HH:mm:ss"
        return formatter
    }()

    static func byteText(_ bytes: Int64) -> String {
        if bytes < 1024 { return L("\(bytes) 字节", "\(bytes) bytes") }
        return byteFormatter.string(fromByteCount: bytes)
    }

    // MARK: - 单个项目

    /// 同步生成基础信息；文件夹的大小/包含项先占位，稍后由 folderStats 回填。
    static func state(for item: FileItem) -> InfoSheetState {
        let url = item.url
        let values = try? url.resourceValues(forKeys: [
            .fileSizeKey,
            .totalFileSizeKey,
            .totalFileAllocatedSizeKey,
            .fileAllocatedSizeKey,
            .creationDateKey,
            .contentModificationDateKey,
            .isDirectoryKey,
            .isPackageKey,
            .isSymbolicLinkKey
        ])
        let attributes = (try? FileManager.default.attributesOfItem(atPath: url.path)) ?? [:]

        var fields: [InfoField] = []
        fields.append(InfoField(id: "kind", label: L("类型", "Kind"), value: item.kind))

        if item.isDirectory {
            fields.append(InfoField(id: "size", label: L("大小", "Size"), value: L("计算中…", "Calculating…")))
            fields.append(InfoField(id: "items", label: L("包含", "Contains"), value: L("计算中…", "Calculating…")))
        } else {
            let logical = Int64(values?.fileSize ?? Int(item.size ?? 0))
            let allocated = Int64(values?.totalFileAllocatedSize ?? values?.fileAllocatedSize ?? Int(logical))
            fields.append(InfoField(id: "size", label: L("大小", "Size"), value: byteText(logical)))
            fields.append(InfoField(id: "allocated", label: L("占用空间", "Space Used"), value: byteText(allocated)))
            if !url.pathExtension.isEmpty {
                fields.append(InfoField(id: "ext", label: L("扩展名", "Extension"), value: ".\(url.pathExtension.lowercased())"))
            }
        }

        fields.append(InfoField(
            id: "location",
            label: L("位置", "Where"),
            value: url.deletingLastPathComponent().path
        ))

        if let created = values?.creationDate ?? (attributes[.creationDate] as? Date) {
            fields.append(InfoField(id: "created", label: L("创建时间", "Created"), value: dateFormatter.string(from: created)))
        }
        if let modified = values?.contentModificationDate ?? (attributes[.modificationDate] as? Date) {
            fields.append(InfoField(id: "modified", label: L("修改时间", "Modified"), value: dateFormatter.string(from: modified)))
        }

        fields.append(InfoField(
            id: "permissions",
            label: L("权限", "Permissions"),
            value: permissionText(attributes: attributes, isDirectory: item.isDirectory)
        ))
        if let owner = attributes[.ownerAccountName] as? String {
            fields.append(InfoField(id: "owner", label: L("所有者", "Owner"), value: owner))
        }
        if values?.isSymbolicLink == true,
           let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: url.path) {
            fields.append(InfoField(id: "link", label: L("链接到", "Symlink To"), value: destination))
        }

        return InfoSheetState(
            iconURL: url,
            title: item.name,
            kind: item.isDirectory ? L("文件夹", "Folder") : item.kind,
            fields: fields,
            note: item.isDirectory ? L("正在统计文件夹大小…", "Calculating folder size…") : nil
        )
    }

    /// 把一个项目的统计结果写回状态
    static func apply(_ stats: FolderStats, to state: inout InfoSheetState) {
        state.set("size", to: byteText(stats.bytes))
        state.set("allocated", to: byteText(stats.allocated))
        state.set(
            "items",
            to: L("\(stats.fileCount) 个文件，\(stats.folderCount) 个文件夹", "\(stats.fileCount) file(s), \(stats.folderCount) folder(s)")
        )
        state.note = nil
    }

    // MARK: - 多选

    static func state(for items: [FileItem]) -> InfoSheetState {
        let folders = items.filter(\.isDirectory).count
        let files = items.count - folders
        let knownBytes = items.reduce(Int64(0)) { $0 + ($1.isDirectory ? 0 : ($1.size ?? 0)) }

        var fields: [InfoField] = [
            InfoField(id: "count", label: L("已选", "Selected"), value: L("\(items.count) 项（\(files) 个文件，\(folders) 个文件夹）", "\(items.count) items (\(files) files, \(folders) folders)")),
            InfoField(id: "size", label: L("大小", "Size"), value: folders > 0 ? L("计算中…", "Calculating…") : byteText(knownBytes))
        ]

        // 同一个目录下才显示位置，跨目录时说明来源不同
        let parents = Set(items.map { $0.url.deletingLastPathComponent().standardizedFileURL.path })
        if parents.count == 1, let parent = parents.first {
            fields.append(InfoField(id: "location", label: L("位置", "Where"), value: parent))
        } else {
            fields.append(InfoField(id: "location", label: L("位置", "Where"),
                                   value: L("来自 \(parents.count) 个不同文件夹",
                                            "From \(parents.count) different folders")))
        }

        let names = items.prefix(3).map(\.name).joined(separator: "、")
        let suffix = items.count > 3 ? L(" 等 \(items.count) 项", " and \(items.count) items") : ""
        fields.append(InfoField(id: "names", label: L("项目", "Items"), value: names + suffix))

        return InfoSheetState(
            iconURL: items.first?.url ?? URL(fileURLWithPath: "/"),
            title: L("\(items.count) 个项目", "\(items.count) items"),
            kind: L("多选", "Multiple Selection"),
            fields: fields,
            note: folders > 0 ? L("正在统计文件夹大小…", "Calculating folder sizes…") : nil
        )
    }

    // MARK: - 递归统计

    /// 递归统计目录大小（包内部也统计，和 Finder 的口径一致）。
    /// 用 `totalFileSize` 得到逻辑大小，`totalFileAllocatedSize` 得到真实占用。
    static func folderStats(_ url: URL) -> FolderStats {
        var stats = FolderStats()
        let keys: [URLResourceKey] = [
            .isDirectoryKey,
            .fileSizeKey,
            .totalFileSizeKey,
            .fileAllocatedSizeKey,
            .totalFileAllocatedSizeKey,
            .isSymbolicLinkKey
        ]
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: keys,
            options: [],
            errorHandler: { _, _ in true }
        ) else {
            return stats
        }

        for case let child as URL in enumerator {
            guard let values = try? child.resourceValues(forKeys: Set(keys)) else { continue }
            if values.isSymbolicLink == true { continue }
            if values.isDirectory == true {
                stats.folderCount += 1
                // 包（.app）内部继续统计，大小才算得准
                continue
            }
            stats.fileCount += 1
            stats.bytes += Int64(values.totalFileSize ?? values.fileSize ?? 0)
            stats.allocated += Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
        }
        return stats
    }

    // MARK: - 权限

    /// 把 posix 权限位渲染成 `drwxr-xr-x` 这样的字符串
    static func permissionText(attributes: [FileAttributeKey: Any], isDirectory: Bool) -> String {
        let raw = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0
        var text = isDirectory ? "d" : "-"
        let bits: [(Int, String)] = [
            (0o400, "r"), (0o200, "w"), (0o100, "x"),
            (0o040, "r"), (0o020, "w"), (0o010, "x"),
            (0o004, "r"), (0o002, "w"), (0o001, "x")
        ]
        for (mask, symbol) in bits {
            text += (raw & mask) != 0 ? symbol : "-"
        }
        text += "（\(String(raw, radix: 8))）"
        return text
    }
}
