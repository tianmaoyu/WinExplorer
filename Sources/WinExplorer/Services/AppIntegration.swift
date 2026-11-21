import AppKit

/// 系统集成的统一入口：菜单栏图标 + 全局快捷键。
/// 启动时调用一次，用户改开关时再调用一次即可。
enum AppIntegration {

    /// 自检时不装菜单栏图标、不注册系统快捷键
    static var enabled = true

    static func apply() {
        guard enabled else { return }

        StatusItemController.shared.onOpen = {
            WindowOpener.shared.showMainWindow()
        }
        StatusItemController.shared.onOpenPath = { url in
            WindowOpener.shared.showMainWindow()
            WindowOpener.shared.navigate?(url)
        }
        StatusItemController.shared.setVisible(Preferences.showsMenuBarIcon)

        GlobalHotKey.shared.onTrigger = {
            WindowOpener.shared.showMainWindow()
        }
        if Preferences.enablesGlobalHotKey {
            _ = GlobalHotKey.shared.register()
        } else {
            GlobalHotKey.shared.unregister()
        }
    }
}
