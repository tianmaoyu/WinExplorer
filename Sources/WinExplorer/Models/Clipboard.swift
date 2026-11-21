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
