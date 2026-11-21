import CoreGraphics
import Foundation

/// 三种视图模式，对应资源管理器的「详细信息 / 列表 / 大图标」
enum ViewMode: String, CaseIterable, Identifiable {
    case details
    case list
    case icons

    var id: String { rawValue }

    var title: String {
        switch self {
        case .details: return L("详细信息", "Details")
        case .list: return L("列表", "List")
        case .icons: return L("图标", "Icons")
        }
    }

    var symbolName: String {
        switch self {
        case .details: return "list.bullet.rectangle"
        case .list: return "list.bullet"
        case .icons: return "square.grid.2x2"
        }
    }
}

/// 详细信息视图里三列的可调宽度（名称列自适应剩余空间）
struct ColumnWidths: Equatable {
    var size: CGFloat
    var date: CGFloat
    var kind: CGFloat

    static let standard = ColumnWidths(size: 90, date: 150, kind: 120)

    static let sizeRange: ClosedRange<CGFloat> = 48...240
    static let dateRange: ClosedRange<CGFloat> = 90...320
    static let kindRange: ClosedRange<CGFloat> = 56...280
}

/// 可拖动的列边界（边界右侧的那一列会跟着变宽/变窄）
enum ResizableColumn: String, CaseIterable {
    case size
    case date
    case kind
}

/// 轻量偏好存储。自检时会被关掉，避免污染用户真实设置。
enum Preferences {
    static var enabled = true

    private static let store = UserDefaults.standard

    static var viewMode: ViewMode {
        get {
            guard enabled, let raw = store.string(forKey: "viewMode") else { return .details }
            return ViewMode(rawValue: raw) ?? .details
        }
        set {
            guard enabled else { return }
            store.set(newValue.rawValue, forKey: "viewMode")
        }
    }

    static var columnWidths: ColumnWidths {
        get {
            guard enabled else { return .standard }
            func width(_ key: String, _ fallback: CGFloat) -> CGFloat {
                guard let value = store.object(forKey: key) as? Double else { return fallback }
                return CGFloat(value)
            }
            return ColumnWidths(
                size: width("column.size", ColumnWidths.standard.size),
                date: width("column.date", ColumnWidths.standard.date),
                kind: width("column.kind", ColumnWidths.standard.kind)
            )
        }
        set {
            guard enabled else { return }
            store.set(Double(newValue.size), forKey: "column.size")
            store.set(Double(newValue.date), forKey: "column.date")
            store.set(Double(newValue.kind), forKey: "column.kind")
        }
    }

    static var sortColumn: SortColumn {
        get {
            guard enabled, let raw = store.string(forKey: "sortColumn") else { return .name }
            return SortColumn(rawValue: raw) ?? .name
        }
        set {
            guard enabled else { return }
            store.set(newValue.rawValue, forKey: "sortColumn")
        }
    }

    static var sortAscending: Bool {
        get {
            guard enabled, store.object(forKey: "sortAscending") != nil else { return true }
            return store.bool(forKey: "sortAscending")
        }
        set {
            guard enabled else { return }
            store.set(newValue, forKey: "sortAscending")
        }
    }

    static var showHidden: Bool {
        get {
            guard enabled, store.object(forKey: "showHidden") != nil else { return false }
            return store.bool(forKey: "showHidden")
        }
        set {
            guard enabled else { return }
            store.set(newValue, forKey: "showHidden")
        }
    }

    static var lastDirectoryPath: String? {
        get {
            guard enabled else { return nil }
            return store.string(forKey: "lastDirectory")
        }
        set {
            guard enabled else { return }
            store.set(newValue, forKey: "lastDirectory")
        }
    }

    /// 在列表里显示文件夹大小（默认关闭，和 Finder / 资源管理器一致：需要显式开启）
    static var showsFolderSizes: Bool {
        get {
            guard enabled, store.object(forKey: "showsFolderSizes") != nil else { return false }
            return store.bool(forKey: "showsFolderSizes")
        }
        set {
            guard enabled else { return }
            store.set(newValue, forKey: "showsFolderSizes")
        }
    }

    /// 菜单栏常驻图标
    static var showsMenuBarIcon: Bool {
        get {
            guard enabled, store.object(forKey: "showsMenuBarIcon") != nil else { return true }
            return store.bool(forKey: "showsMenuBarIcon")
        }
        set {
            guard enabled else { return }
            store.set(newValue, forKey: "showsMenuBarIcon")
        }
    }

    /// 全局快捷键 ⌥⌘E
    static var enablesGlobalHotKey: Bool {
        get {
            guard enabled, store.object(forKey: "enablesGlobalHotKey") != nil else { return true }
            return store.bool(forKey: "enablesGlobalHotKey")
        }
        set {
            guard enabled else { return }
            store.set(newValue, forKey: "enablesGlobalHotKey")
        }
    }
}
