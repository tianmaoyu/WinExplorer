import AppKit
import SwiftUI

/// 窗口根视图：当前标签的浏览器。标签栏在窗口工具栏中央（adr/0006）。
/// 单独拆一层是为了让「切换标签」能换掉 BrowserView 观察的 model。
struct RootView: View {
    @ObservedObject var tabs: TabsModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        BrowserView(model: tabs.active, tabs: tabs)
        .onAppear {
            // 菜单栏图标 / 全局快捷键要能把窗口叫回来（包括窗口已被关掉的情况）
            WindowOpener.shared.open = { openWindow(id: "main") }
            WindowOpener.shared.navigate = { url in
                tabs.active.navigate(to: url)
            }
        }
    }
}
