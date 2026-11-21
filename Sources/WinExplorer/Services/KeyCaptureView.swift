import AppKit
import SwiftUI

/// 持有当前窗口的"键盘响应视图"，点击后可以把它重新设为第一响应者，
/// 避免 SwiftUI 抢走焦点后方向键失效。
final class FocusKeeper {
    static let shared = FocusKeeper()

    private weak var view: NSView?

    private init() {}

    func register(_ view: NSView) {
        self.view = view
    }

    func reclaim(force: Bool = false) {
        guard let view, let window = view.window else { return }
        // 正在文本框里编辑时不要抢焦点（否则打字会中断）；
        // force = true 用于点击列表时主动结束编辑、触发失焦提交。
        if !force, window.firstResponder is NSTextView { return }
        if window.firstResponder !== view {
            window.makeFirstResponder(view)
        }
    }
}

/// 一个零尺寸、专门收键盘事件的 NSView。
/// 放在 SwiftUI 视图的 overlay 里，保证方向键/回车/空格总能到我们手里。
struct KeyCaptureView: NSViewRepresentable {
    let onKey: (NSEvent) -> Bool

    func makeNSView(context: Context) -> KeyView {
        let view = KeyView()
        view.onKey = onKey
        return view
    }

    func updateNSView(_ nsView: KeyView, context: Context) {
        nsView.onKey = onKey
    }

    final class KeyView: NSView {
        var onKey: ((NSEvent) -> Bool)?
        private var keyObserver: NSObjectProtocol?

        override var acceptsFirstResponder: Bool { true }
        override var canBecomeKeyView: Bool { true }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()

            if let keyObserver {
                NotificationCenter.default.removeObserver(keyObserver)
                self.keyObserver = nil
            }

            guard let window else { return }

            FocusKeeper.shared.register(self)
            DispatchQueue.main.async { FocusKeeper.shared.reclaim() }

            keyObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didBecomeKeyNotification,
                object: window,
                queue: .main
            ) { _ in
                DispatchQueue.main.async { FocusKeeper.shared.reclaim() }
            }
        }

        override func keyDown(with event: NSEvent) {
            if onKey?(event) == true { return }
            super.keyDown(with: event)
        }

        deinit {
            if let keyObserver {
                NotificationCenter.default.removeObserver(keyObserver)
            }
        }
    }
}
