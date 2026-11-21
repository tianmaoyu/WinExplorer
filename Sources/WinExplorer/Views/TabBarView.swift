import AppKit
import SwiftUI

/// 窗口顶部的标签栏（Windows 11 资源管理器那种）。只有一个标签时整条隐藏。
struct TabBarView: View {
    @ObservedObject var tabs: TabsModel
    static let height: CGFloat = 32

    @State private var draggingID: UUID?

    var body: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(Array(tabs.tabs.enumerated()), id: \.element.id) { index, tab in
                        chip(tab: tab, index: index)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
            }

            Button {
                tabs.newTab()
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 22, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help(L("新建标签页（⌘T）", "New Tab (⌘T)"))
            .padding(.trailing, 8)
        }
        .frame(height: Self.height)
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(alignment: .bottom) {
            Divider()
        }
    }

    private func chip(tab: BrowserModel, index: Int) -> some View {
        // 注意：标签栏只观察 TabsModel，单个标签的目录变化（titleText/图标）
        // 必须由 TabChip 自己观察，否则标题会停在旧目录名上。
        TabChip(
            tab: tab,
            index: index,
            isActive: index == tabs.activeIndex,
            showsClose: tabs.count > 1,
            onSelect: {
                tabs.select(index)
                DispatchQueue.main.async { FocusKeeper.shared.reclaim(force: true) }
            },
            onClose: { tabs.closeTab(at: index) }
        )
        .onDrag {
            draggingID = tab.id
            return NSItemProvider(object: tab.id.uuidString as NSString)
        }
        .onDrop(of: [.text], delegate: TabDropDelegate(targetID: tab.id, tabs: tabs, draggingID: $draggingID))
    }
}

/// 单个标签。单独成视图是为了让它观察自己那个 BrowserModel。
private struct TabChip: View {
    @ObservedObject var tab: BrowserModel
    let index: Int
    let isActive: Bool
    let showsClose: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    @State private var hovered = false

    var body: some View {
        HStack(spacing: 6) {
            Image(nsImage: IconProvider.shared.icon(for: tab.currentURL))
                .resizable()
                .frame(width: 13, height: 13)
                .opacity(isActive ? 1 : 0.75)

            Text(tab.titleText)
                .font(.system(size: 11.5, weight: isActive ? .medium : .regular))
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(isActive ? Color.primary : Color.secondary)
                .frame(maxWidth: 168, alignment: .leading)

            if showsClose {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .frame(width: 14, height: 14)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help(L("关闭标签页（⌘W）", "Close Tab (⌘W)"))
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background {
            RoundedRectangle(cornerRadius: 6)
                .fill(background)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .stroke(isActive ? Color.accentColor.opacity(0.35) : Color.clear, lineWidth: 1)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onHover { hovered = $0 }
        .help(tab.currentURL.path)
    }

    private var background: Color {
        if isActive { return Color.accentColor.opacity(0.16) }
        if hovered { return Color.primary.opacity(0.06) }
        return Color.clear
    }
}

/// 标签栏内部拖拽排序
private struct TabDropDelegate: DropDelegate {
    let targetID: UUID
    let tabs: TabsModel
    @Binding var draggingID: UUID?

    func dropEntered(info: DropInfo) {
        guard let draggingID,
              let from = tabs.tabs.firstIndex(where: { $0.id == draggingID }),
              let to = tabs.tabs.firstIndex(where: { $0.id == targetID }),
              from != to else { return }
        tabs.moveTab(from: from, to: to > from ? to + 1 : to)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        draggingID = nil
        return true
    }
}
