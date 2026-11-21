import AppKit
import SwiftUI

@main
struct WinExplorerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    /// 菜单命令作用于聚焦窗口的标签组；每个窗口有自己独立的 TabsModel（adr/0007）
    @FocusedObject private var focusedTabs: TabsModel?

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
            WindowRootView()
                .frame(minWidth: 840, minHeight: 500)
        }
        .defaultSize(width: 1060, height: 680)
        .commands {
            ExplorerCommands(tabs: focusedTabs)
        }
    }
}

/// 一个窗口一份 TabsModel —— 多窗口彼此完全独立：
/// 各自的标签组、目录、历史、选中，窗口间拖拽传文件由 macOS 原生支持（adr/0007）。
private struct WindowRootView: View {
    @StateObject private var tabs = TabsModel()

    var body: some View {
        RootView(tabs: tabs)
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
