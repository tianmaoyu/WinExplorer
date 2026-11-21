import AppKit
import SwiftUI

/// 验收用：`WINEXPLORER_TAB_COMPARE=/path.png` 时开一个对比窗口 ——
/// 白卡片与 Win11 梯形切角两种标签样式并排渲染，截图后退出。
///
/// 为什么单独开窗口：`cacheDisplay` 抓 `NSThemeFrame`（含工具栏 chrome）
/// 在窗口不在前台时会漏画 layer 宿主内容，得到空壳图；对比视图是纯
/// SwiftUI 内容，抓取可靠。
enum TabStyleCompare {
    private static var didRun = false

    static func runIfNeeded() -> Bool {
        guard let path = ProcessInfo.processInfo.environment["WINEXPLORER_TAB_COMPARE"] else {
            return false
        }
        guard !didRun else { return true }
        didRun = true
        let content = NSHostingView(rootView: TabStyleCompareView())
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: content.fittingSize.width,
                                height: content.fittingSize.height),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.title = "Tab Style Compare"
        window.contentView = content
        window.center()
        window.makeKeyAndOrderFront(nil)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            let bounds = content.bounds
            if let rep = content.bitmapImageRepForCachingDisplay(in: bounds) {
                content.cacheDisplay(in: bounds, to: rep)
                if let data = rep.representation(using: .png, properties: [:]) {
                    try? data.write(to: URL(fileURLWithPath: path))
                    FileHandle.standardError.write(Data("compare snapshot: \(path)\n".utf8))
                }
            }
            exit(0)
        }
        return true
    }
}

/// 两种标签样式并排：左=白卡片（圆角矩形），右=梯形切角（Win11 profile）。
struct TabStyleCompareView: View {
    var body: some View {
        HStack(alignment: .top, spacing: 20) {
            column(style: .card, title: "白卡片 card（当前默认）")
            column(style: .trapezoid, title: "梯形切角 trapezoid（Win11）")
        }
        .padding(20)
        .frame(width: 720)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func column(style: TabCardStyle, title: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            HStack(spacing: 6) {
                chip(style: style, title: "logs", active: true)
                chip(style: style, title: "文档", active: false)
                chip(style: style, title: "code", active: false)
                plus
            }
            .padding(.horizontal, 12)
            // 只设高度即可生效：chip 填满条带高度（底部贴齐），宽度/形状自适应
            .frame(height: 52)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .underPageBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .frame(maxWidth: .infinity)
    }

    private func chip(style: TabCardStyle, title: String, active: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "folder")
                .resizable()
                .frame(width: 15, height: 15)
                .opacity(active ? 1 : 0.75)

            Text(title)
                .font(.system(size: 13, weight: active ? .medium : .regular))
                .lineLimit(1)
                .foregroundStyle(active ? Color.primary : Color.secondary)

            // 未激活标签的 × 悬停才显示；对比图里直接隐藏
            Image(systemName: "xmark")
                .font(.system(size: 9, weight: .bold))
                .frame(width: 16, height: 16)
                .foregroundStyle(.secondary)
                .opacity(active ? 1 : 0)
        }
        .padding(.horizontal, TabCardShape.horizontalPadding(for: style))
        // 高度占满条带（高度由容器给定），底部贴齐
        .frame(maxHeight: .infinity)
        .background {
            TabCardShape(style: style)
                .fill(active ? Color(nsColor: .textBackgroundColor) : Color.clear)
        }
        .overlay {
            TabCardShape(style: style)
                .stroke(active ? Color.primary.opacity(0.10) : Color.clear, lineWidth: 1)
        }
        .compositingGroup()
        .shadow(color: .black.opacity(active ? 0.16 : 0), radius: 2, y: 1)
    }

    private var plus: some View {
        Image(systemName: "plus")
            .font(.system(size: 12, weight: .semibold))
            .frame(width: 24, height: 22)
            .foregroundStyle(.secondary)
    }
}
