import Foundation

/// 剪贴板的两种模式，对应 Windows 的「复制」与「剪切」
enum ClipboardMode {
    case copy
    case cut

    var verb: String {
        switch self {
        case .copy: return L("复制", "Copy")
        case .cut: return L("剪切", "Cut")
        }
    }
}

/// 应用内的文件剪贴板。
/// 之所以不只用系统剪贴板：剪切需要保留"这是移动"的语义，系统剪贴板表达不了。
struct FileClipboard {
    let urls: [URL]
    let mode: ClipboardMode
    /// 剪切时的来源目录，用于粘贴后判断是否需要刷新
    let sourceDirectory: URL

    var cutURLs: Set<URL> {
        mode == .cut ? Set(urls) : []
    }
}

/// 应用级共享剪贴板。
///
/// Windows 的剪贴板本来就是全局的：⌘C 在一个文件夹窗口，切到另一个窗口直接 ⌘V。
/// 标签页 / 独立窗口（adr/0006、0007）之间传文件走同一条路 —— 每个 BrowserModel
/// 的 `clipboard` 属性都转发到这里；变化通过订阅广播回每个模型，
/// 「剪切中变淡」在所有标签和窗口里同步刷新。
final class ClipboardStore: ObservableObject {
    static let shared = ClipboardStore()

    @Published private(set) var item: FileClipboard?

    private init() {}

    func set(_ clipboard: FileClipboard?) {
        item = clipboard
    }
}
