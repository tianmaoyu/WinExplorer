import AppKit

/// 少数快捷键会被 SwiftUI 的内置派发先吃掉（实测 ⌘Z、⌘I：菜单项 keyEquivalent 命中了
/// 但我们的 action 根本收不到），所以在 sendEvent 之前拦一层，只接管这几个组合。
final class ShortcutMonitor {
    static let shared = ShortcutMonitor()

    private var monitor: Any?
    private var isBlocked: () -> Bool = { false }
    private var onUndo: () -> Void = {}
    private var onRedo: () -> Void = {}
    /// 其它需要抢在菜单之前的组合（返回 true 表示已消费）
    private var onShortcut: (NSEvent) -> Bool = { _ in false }

    private init() {}

    func install(
        isBlocked: @escaping () -> Bool,
        onUndo: @escaping () -> Void,
        onRedo: @escaping () -> Void,
        onShortcut: @escaping (NSEvent) -> Bool = { _ in false }
    ) {
        self.isBlocked = isBlocked
        self.onUndo = onUndo
        self.onRedo = onRedo
        self.onShortcut = onShortcut

        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self else { return event }
            return self.handle(event) ? nil : event
        }
    }

    private func handle(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags
        let modifiers: NSEvent.ModifierFlags = [.command, .function, .option]
        guard !flags.intersection(modifiers).isEmpty, !flags.contains(.control) else { return false }

        // 显示简介 / 搜索这类组合先接管：即使焦点在文本框里也允许（⌘F 在搜索框里 = 全选重输）
        if onShortcut(event) { return true }

        // 以下只处理 ⌘Z / ⇧⌘Z
        guard event.keyCode == 6 else { return false }
        guard !isBlocked() else { return false }

        // 正在行内重命名时让系统去撤销文字编辑
        if NSApp.keyWindow?.firstResponder is NSTextView { return false }

        if flags.contains(.shift) {
            onRedo()
        } else {
            onUndo()
        }
        return true
    }
}
