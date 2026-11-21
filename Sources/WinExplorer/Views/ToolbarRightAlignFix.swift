import AppKit
import SwiftUI

/// 把工具栏右侧按钮组顶到窗口最右边。
///
/// 为什么需要它：SwiftUI 的工具栏 item 永远按「理想尺寸」布局 ——
/// `Spacer` / `.frame(maxWidth: .infinity)` 在 NSToolbar 宿主里都撑不开，
/// 且 `.primaryAction` 分组并不会自动获得弹性空白，于是按钮组紧贴在
/// 前一个 item（标签栏）后面，看起来「挤在中间」（adr/0008）。
///
/// 真正负责右对齐的是 AppKit 的 `NSToolbarItem.Identifier.flexibleSpace`：
/// 它占住所有剩余宽度，把后面的 item 推到最右。SwiftUI 没有暴露这个
/// 标识，所以在窗口出现 / 尺寸变化时，直接在 NSToolbar 里补一个。
struct ToolbarRightAlignFix: NSViewRepresentable {
    func makeNSView(context: Context) -> InstallerView { InstallerView() }

    func updateNSView(_ nsView: InstallerView, context: Context) {}

    final class InstallerView: NSView {
        private weak var observedWindow: NSWindow?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            if observedWindow !== window {
                NotificationCenter.default.removeObserver(self, name: nil, object: observedWindow)
                observedWindow = window
                for name in [NSWindow.didResizeNotification, NSWindow.didUpdateNotification,
                             NSWindow.didBecomeKeyNotification] {
                    NotificationCenter.default.addObserver(
                        self, selector: #selector(install), name: name, object: window)
                }
            }
            // 工具栏是窗口出现后由 SwiftUI 异步填充的，等两拍再插
            DispatchQueue.main.async { self.install() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { self.install() }
        }

        deinit { NotificationCenter.default.removeObserver(self) }

        @objc private func install() {
            guard let toolbar = window?.toolbar else { return }

            let ids = toolbar.items.map(\.itemIdentifier)
            let spaces = ids.filter { $0 == .flexibleSpace }.count
            if spaces > 1 {
                // 插入是异步生效的，可能重复插过：只留一个
                for _ in 1..<spaces {
                    if let extra = toolbar.items.lastIndex(where: { $0.itemIdentifier == .flexibleSpace }) {
                        toolbar.removeItem(at: extra)
                    }
                }
            }
            guard spaces == 0 else { return }

            // SwiftUI 把每个 item 单独暴露：分隔符之后第一个是标签栏，再往后是视图按钮组。
            // 弹性空白要插在「标签栏之后、按钮组之前」，按钮组才会整体被顶到最右。
            guard let separator = ids.firstIndex(where: { $0.rawValue.contains("splitViewSeparator") })
            else { return }
            let index = min(separator + 2, toolbar.items.count)
            toolbar.insertItem(withItemIdentifier: .flexibleSpace, at: index)
            dumpLayout()
        }

        /// 自检用：WINEXPLORER_TOOLBAR_DEBUG=1 时打印每个 item 的实际横坐标，确认按钮组贴右
        private func dumpLayout() {
            guard ProcessInfo.processInfo.environment["WINEXPLORER_TOOLBAR_DEBUG"] == "1" else { return }
            guard let window, let root = window.contentView?.superview else { return }
            guard let toolbarView = Self.findToolbarView(in: root) else {
                print("[Toolbar] NSToolbarView 未找到")
                return
            }
            let frames = toolbarView.subviews
                .filter { String(describing: type(of: $0)).contains("ItemViewer") }
                .map(\.frame)
                .sorted { $0.minX < $1.minX }
            print("[Toolbar] window=\(Int(window.frame.width)) items=\(frames.map { "\(Int($0.minX))+\(Int($0.width))" })")
        }

        private static func findToolbarView(in view: NSView) -> NSView? {
            if String(describing: type(of: view)) == "NSToolbarView" { return view }
            for sub in view.subviews {
                if let found = findToolbarView(in: sub) { return found }
            }
            return nil
        }
    }
}
