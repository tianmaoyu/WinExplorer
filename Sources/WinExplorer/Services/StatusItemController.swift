import AppKit

/// 让 AppKit 侧（菜单栏图标、全局快捷键）能把主窗口叫回来。
/// SwiftUI 的 `openWindow` 只能在视图里取到，所以由 RootView 注册到这里。
final class WindowOpener {
    static let shared = WindowOpener()

    var open: (() -> Void)?
    /// 状态栏菜单里点开某个位置
    var navigate: ((URL) -> Void)?

    private init() {}

    /// 有窗口就前置，没有就请 SwiftUI 重新开一个
    func showMainWindow() {
        NSApp.activate(ignoringOtherApps: true)

        if let window = NSApp.windows.first(where: {
            $0.canBecomeMain && !($0 is NSPanel) && $0.contentView != nil
        }) {
            window.makeKeyAndOrderFront(nil)
            return
        }
        open?()
    }
}

/// 菜单栏常驻图标
final class StatusItemController: NSObject {
    static let shared = StatusItemController()

    /// 点「打开」/ 全局快捷键
    var onOpen: (() -> Void)?
    /// 打开某个固定位置（个人文件夹、下载…）
    var onOpenPath: ((URL) -> Void)?

    private var item: NSStatusItem?

    var isVisible: Bool { item != nil }

    private override init() {
        super.init()
    }

    func setVisible(_ visible: Bool) {
        if visible {
            install()
        } else {
            remove()
        }
    }

    private func install() {
        guard item == nil else { return }

        let status = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = status.button {
            let image = NSImage(systemSymbolName: "folder", accessibilityDescription: "WinExplorer")
            image?.isTemplate = true
            button.image = image
            button.toolTip = L("WinExplorer（⌥⌘E 唤起）", "WinExplorer (⌥⌘E to show)")
        }

        let menu = NSMenu()

        let open = NSMenuItem(
            title: L("打开 WinExplorer", "Open WinExplorer"),
            action: #selector(handleOpen),
            keyEquivalent: ""
        )
        open.target = self
        menu.addItem(open)

        let hint = NSMenuItem(
            title: L("全局快捷键：⌥⌘E", "Global shortcut: ⌥⌘E"),
            action: nil,
            keyEquivalent: ""
        )
        hint.isEnabled = false
        menu.addItem(hint)

        menu.addItem(.separator())

        addPlaceItem(to: menu, title: L("个人文件夹", "Home"),
                     url: FileManager.default.homeDirectoryForCurrentUser)
        if let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first {
            addPlaceItem(to: menu, title: L("下载", "Downloads"), url: downloads)
        }
        addPlaceItem(to: menu, title: L("桌面", "Desktop"),
                     url: FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first)

        menu.addItem(.separator())

        let quit = NSMenuItem(
            title: L("退出 WinExplorer", "Quit WinExplorer"),
            action: #selector(handleQuit),
            keyEquivalent: "q"
        )
        quit.target = self
        menu.addItem(quit)

        status.menu = menu
        item = status
    }

    private func addPlaceItem(to menu: NSMenu, title: String, url: URL?) {
        guard let url else { return }
        let entry = NSMenuItem(title: title, action: #selector(handlePlace(_:)), keyEquivalent: "")
        entry.target = self
        entry.representedObject = url
        menu.addItem(entry)
    }

    private func remove() {
        guard let item else { return }
        NSStatusBar.system.removeStatusItem(item)
        self.item = nil
    }

    @objc private func handleOpen() {
        onOpen?()
    }

    @objc private func handlePlace(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        onOpenPath?(url)
    }

    @objc private func handleQuit() {
        NSApp.terminate(nil)
    }
}
