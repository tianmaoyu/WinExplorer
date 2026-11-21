import AppKit
import SwiftUI

@main
struct WinExplorerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = BrowserModel()

    init() {
        if ProcessInfo.processInfo.environment["WINEXPLORER_SELFTEST"] == "1" {
            SelfTest.runAll()
        }
    }

    var body: some Scene {
        Window("WinExplorer", id: "main") {
            BrowserView(model: model)
                .frame(minWidth: 840, minHeight: 500)
        }
        .defaultSize(width: 1060, height: 680)
        .windowToolbarStyle(.unified)
        .commands {
            ExplorerCommands(model: model)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        SnapshotSupport.scheduleIfNeeded()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
