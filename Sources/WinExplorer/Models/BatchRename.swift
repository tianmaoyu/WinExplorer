import Foundation

/// 批量重命名的两种方式：
/// - 序号命名：Windows 11 里多选后按 F2 的效果（`照片 1.jpg`、`照片 2.jpg`），额外支持补零与分隔符
/// - 查找替换：在文件名（默认只对主文件名）里做替换，支持区分大小写
enum BatchRenameMode: String, CaseIterable, Identifiable {
    case sequence
    case replace

    var id: String { rawValue }

    var title: String {
        switch self {
        case .sequence: return L("序号命名", "Numbering")
        case .replace: return L("查找替换", "Find & Replace")
        }
    }
}

/// 批量重命名的编辑态。纯数据，方便自检直接构造。
struct BatchRenameState {
    /// 按列表顺序排列，序号也按这个顺序编号
    var items: [FileItem]
    var mode: BatchRenameMode = .sequence
    /// 序号命名的基名
    var baseName: String = ""
    var startIndex: Int = 1
    /// 序号位数，0 = 不补零
    var digits: Int = 0
    /// 基名与序号之间的连接符
    var separator: String = " "
    var findText: String = ""
    var replaceText: String = ""
    var caseSensitive: Bool = false
    /// 保留原扩展名（文件夹没有扩展名，天然不受影响）
    var keepExtension: Bool = true

    var directory: URL {
        items.first?.url.deletingLastPathComponent() ?? URL(fileURLWithPath: "/")
    }

    /// 主文件名（不含扩展名）
    static func stem(of item: FileItem) -> String {
        let name = item.url.lastPathComponent
        guard !item.isDirectory else { return name }
        let nsName = name as NSString
        guard !nsName.pathExtension.isEmpty else { return name }
        let base = nsName.deletingPathExtension
        return base.isEmpty ? name : base
    }

    /// 带点号的扩展名（文件夹与无扩展名文件返回空串）
    static func extensionPart(of item: FileItem) -> String {
        guard !item.isDirectory else { return "" }
        let ext = (item.url.lastPathComponent as NSString).pathExtension
        return ext.isEmpty ? "" : "." + ext
    }
}

/// 一次批量重命名的预览结果。所有冲突都在这里算出来，应用前一行都不会动。
struct BatchRenamePlan {

    struct Row: Identifiable {
        let id: URL
        let originalName: String
        let newName: String
        /// 非空表示这一项有问题，整批不允许执行
        let problem: String?

        var isChanged: Bool { originalName != newName }
    }

    let rows: [Row]
    /// 真正要落地的改名动作（按列表顺序）
    let changes: [(from: URL, to: URL)]
    /// 整批级别的问题（基名为空、查找内容为空等）
    let problems: [String]

    var isApplicable: Bool {
        problems.isEmpty && !changes.isEmpty && rows.allSatisfy { $0.problem == nil }
    }

    var changedCount: Int { changes.count }

    /// 预览是逐项计算出来的，冲突判断用「目录列表 + 大小写不敏感」一次性比对，
    /// 避免每敲一个字都去 stat 磁盘。
    static func make(_ state: BatchRenameState) -> BatchRenamePlan {
        let fm = FileManager.default
        var existing: Set<String> = []
        if let names = try? fm.contentsOfDirectory(atPath: state.directory.path) {
            existing = Set(names.map { $0.lowercased() })
        }
        var problems: [String] = []
        if state.mode == .sequence, state.baseName.trimmingCharacters(in: .whitespaces).isEmpty {
            problems.append(L("请填写基名", "Enter a base name"))
        }
        if state.mode == .replace, state.findText.isEmpty {
            problems.append(L("请填写要查找的内容", "Enter text to find"))
        }

        // 第一遍：只算新名字
        var computed: [(item: FileItem, original: String, newName: String)] = []
        for (offset, item) in state.items.enumerated() {
            let original = item.url.lastPathComponent
            let ext = state.keepExtension ? BatchRenameState.extensionPart(of: item) : ""

            var newName: String
            switch state.mode {
            case .sequence:
                let index = state.startIndex + offset
                let number = state.digits > 0
                    ? String(format: "%0\(state.digits)d", index)
                    : String(index)
                let prefix = state.baseName.isEmpty ? "" : state.baseName + state.separator
                newName = prefix + number + ext
            case .replace:
                var body = original
                if !ext.isEmpty, original.lowercased().hasSuffix(ext.lowercased()) {
                    body = String(original.dropLast(ext.count))
                }
                var options: String.CompareOptions = []
                if !state.caseSensitive { options.insert(.caseInsensitive) }
                body = body.replacingOccurrences(
                    of: state.findText,
                    with: state.replaceText,
                    options: options
                )
                newName = body + ext
            }
            computed.append((item, original, newName))
        }

        // 这些名字会被腾出来（改名项的原名），互换名字、只改大小写都靠它判断
        let freedNames = Set(
            computed.filter { $0.newName != $0.original }.map { $0.original.lowercased() }
        )

        // 第二遍：查非法、查重复、查与磁盘上「不参与本次改名」的项目重名
        var rows: [Row] = []
        var seen: Set<String> = []

        for entry in computed {
            var problem: String?
            let trimmed = entry.newName.trimmingCharacters(in: .whitespacesAndNewlines)

            if trimmed.isEmpty {
                problem = L("名称为空", "Name is empty")
            } else if entry.newName.contains("/") || entry.newName.contains(":") {
                problem = L("不能包含「/」或「:」", "Cannot contain “/” or “:”")
            } else if entry.newName != entry.original {
                let key = entry.newName.lowercased()
                if seen.contains(key) {
                    problem = L("与本次另一项重名", "Duplicate name in this batch")
                } else if existing.contains(key), !freedNames.contains(key) {
                    problem = L("已存在同名项目", "A file with this name already exists")
                }
            }
            if entry.newName != entry.original, problem == nil {
                seen.insert(entry.newName.lowercased())
            }

            rows.append(Row(
                id: entry.item.url,
                originalName: entry.original,
                newName: entry.newName,
                problem: problem
            ))
        }

        let changes = rows.compactMap { row -> (from: URL, to: URL)? in
            guard row.isChanged, row.problem == nil else { return nil }
            return (row.id, row.id.deletingLastPathComponent().appendingPathComponent(row.newName))
        }

        return BatchRenamePlan(rows: rows, changes: changes, problems: problems)
    }
}
