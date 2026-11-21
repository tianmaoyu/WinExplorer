import AppKit
import SwiftUI

@main
struct WinExplorerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var tabs = TabsModel()

    init() {
        // 截图验收用：WINEXPLORER_APPEARANCE=dark|light 强制外观，默认跟随系统
        if let forced = ProcessInfo.processInfo.environment["WINEXPLORER_APPEARANCE"] {
            NSApplication.shared.appearance = NSAppearance(named: forced == "dark" ? .darkAqua : .aqua)
        }
        if ProcessInfo.processInfo.environment["WINEXPLORER_SELFTEST"] == "1" {
            SelfTest.runAll()
        }
    }

    var body: some Scene {
        Window("WinExplorer", id: "main") {
            RootView(tabs: tabs)
                .frame(minWidth: 840, minHeight: 500)
        }
        .defaultSize(width: 1060, height: 680)
        .windowToolbarStyle(.unified)
        .commands {
            ExplorerCommands(tabs: tabs)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        AppIntegration.apply()
    }

    /// 开启菜单栏常驻时，关窗不退出，靠菜单栏图标或 ⌥⌘E 叫回来
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !Preferences.showsMenuBarIcon
    }

    /// 点 Dock 图标（窗口已关）时把窗口叫回来
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { WindowOpener.shared.showMainWindow() }
        return true
    }
}
