import AppKit
import Quartz

/// 空格键快速预览（Quick Look）。
///
/// QLPreviewPanel 通过响应链找"控制器"：面板显示时会向 responder chain 询问
/// `acceptsPreviewPanelControl:`，所以 KeyCaptureView 里实现了那三个方法，
/// 由这里统一提供 dataSource / delegate。
final class QuickLookController: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    static let shared = QuickLookController()

    private(set) var urls: [URL] = []
    private(set) var index: Int = 0

    /// 在面板里用 ↑↓ 切换时，同步列表里的选中项
    var onFocus: ((URL) -> Void)?

    private override init() {
        super.init()
    }

    var isVisible: Bool {
        QLPreviewPanel.sharedPreviewPanelExists() && QLPreviewPanel.shared().isVisible
    }

    /// 准备预览列表并返回起始下标（自检直接调这个，不碰面板）
    @discardableResult
    func prepare(urls: [URL], startAt url: URL?) -> Int {
        let cleaned = urls.map { $0.standardizedFileURL }
        guard !cleaned.isEmpty else {
            self.urls = []
            index = 0
            return 0
        }
        self.urls = cleaned
        let targetPath = url?.standardizedFileURL.path
        index = targetPath.flatMap { path in
            cleaned.firstIndex { $0.path == path }
        } ?? 0
        return index
    }

    /// 空格：显示或关闭。多选时以整个选区为预览列表。
    func toggle(urls: [URL], startAt url: URL?) {
        if isVisible {
            close()
            return
        }
        prepare(urls: urls, startAt: url)
        guard !self.urls.isEmpty, let panel = QLPreviewPanel.shared() else { return }
        panel.currentPreviewItemIndex = index
        panel.makeKeyAndOrderFront(nil)
        panel.reloadData()
    }

    func close() {
        guard QLPreviewPanel.sharedPreviewPanelExists(), QLPreviewPanel.shared().isVisible else { return }
        QLPreviewPanel.shared().orderOut(nil)
    }

    /// ↑↓ 在预览列表里切换
    @discardableResult
    func step(_ delta: Int) -> URL? {
        guard urls.count > 1 else { return nil }
        index = (index + delta + urls.count) % urls.count
        if QLPreviewPanel.sharedPreviewPanelExists() {
            let panel = QLPreviewPanel.shared()
            panel?.currentPreviewItemIndex = index
            panel?.reloadData()
        }
        let url = urls[index]
        onFocus?(url)
        return url
    }

    // MARK: - QLPreviewPanelDataSource

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        urls.count
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        guard urls.indices.contains(index) else { return nil }
        return urls[index] as NSURL
    }

    // MARK: - QLPreviewPanelDelegate

    /// 面板拿到键盘事件时：空格 / Esc 关闭，↑↓ 换一个预览
    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        guard event.type == .keyDown else { return false }
        switch event.keyCode {
        case 49, 53: // Space / Esc
            close()
            return true
        case 125: // ↓
            step(1)
            return true
        case 126: // ↑
            step(-1)
            return true
        default:
            return false
        }
    }

    func previewPanelWillClose(_ panel: QLPreviewPanel!) {
        // 面板关闭后把键盘焦点还给文件列表，方向键才能继续用
        DispatchQueue.main.async {
            FocusKeeper.shared.reclaim(force: true)
        }
    }
}
