import SwiftUI

/// 窗口根视图：标签栏 + 当前标签的浏览器。
/// 单独拆一层是为了让「切换标签」能换掉 BrowserView 观察的 model。
struct RootView: View {
    @ObservedObject var tabs: TabsModel

    var body: some View {
        VStack(spacing: 0) {
            if tabs.count > 1 {
                TabBarView(tabs: tabs)
            }
            BrowserView(model: tabs.active, tabs: tabs)
        }
    }
}
