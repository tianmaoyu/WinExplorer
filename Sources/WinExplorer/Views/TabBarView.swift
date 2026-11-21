import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// 标签栏（Windows 11 资源管理器那种），常驻显示并嵌入窗口工具栏中央：
/// 标签 chip + `+`（新建标签）永远可见，单标签也不例外。
///
/// 两种拖拽共用 chips：
/// - 拖 chip 本身 = 排序（text provider）
/// - 拖文件进来 = 传文件：悬停 0.6s 自动切到那个标签，松手落入其当前目录；
///   拖到 `+` 上 = 新建一个标签并直接放入（adr/0006）
struct TabBarView: View {
    @ObservedObject var tabs: TabsModel
    static let height: CGFloat = 32

    @State private var draggingID: UUID?
    /// 文件拖拽悬停的标签（蓝色描边反馈）
    @State private var fileDropTargetID: UUID?
    @State private var plusTargeted = false

    var body: some View {
        HStack(spacing: 2) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(Array(tabs.tabs.enumerated()), id: \.element.id) { index, tab in
                        chip(tab: tab, index: index)
                    }
                }
                .padding(.horizontal, 6)
            }

            plusButton
                .padding(.trailing, 6)
        }
        .frame(height: Self.height)
    }

    private func chip(tab: BrowserModel, index: Int) -> some View {
        // 注意：标签栏只观察 TabsModel，单个标签的目录变化（titleText/图标）
        // 必须由 TabChip 自己观察，否则标题会停在旧目录名上。
        TabChip(
            tab: tab,
            index: index,
            isActive: index == tabs.activeIndex,
            showsClose: tabs.count > 1,
            isFileDropTarget: fileDropTargetID == tab.id,
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
        .onDrop(
            of: [UTType.text, UTType.fileURL],
            delegate: TabDropDelegate(
                targetID: tab.id,
                tabs: tabs,
                draggingID: $draggingID,
                fileDropTargetID: $fileDropTargetID
            )
        )
    }

    private var plusButton: some View {
        Button {
            tabs.newTab()
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 22, height: 20)
                .background {
                    RoundedRectangle(cornerRadius: 5)
                        .fill(Color.accentColor.opacity(plusTargeted ? 0.22 : 0))
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(plusTargeted ? Color.accentColor : Color.secondary)
        .help(L("新建标签页（⌘T）—— 把文件拖到这里会新建标签并放入", "New Tab (⌘T) — drop files here to open them in a new tab"))
        // 拖文件到 + 号：新建一个标签并直接放入（adr/0006）
        .onDrop(of: [UTType.fileURL], isTargeted: $plusTargeted) { providers in
            DropSupport.loadURLs(from: providers) { urls in
                tabs.receiveDropOnPlus(urls, modifiers: NSEvent.modifierFlags)
            }
            return true
        }
    }
}

/// 单个标签。单独成视图是为了让它观察自己那个 BrowserModel。
private struct TabChip: View {
    @ObservedObject var tab: BrowserModel
    let index: Int
    let isActive: Bool
    let showsClose: Bool
    let isFileDropTarget: Bool
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
                .stroke(strokeColor, lineWidth: 1)
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

    private var strokeColor: Color {
        if isFileDropTarget { return Color.accentColor }
        if isActive { return Color.accentColor.opacity(0.35) }
        return .clear
    }
}

/// 标签 chip 的落点委托：同时接住「拖 chip 排序」和「拖文件传文件」。
/// 两类拖拽用 provider 类型区分：chip 排序带 .text，文件带 .fileURL。
private struct TabDropDelegate: DropDelegate {
    let targetID: UUID
    let tabs: TabsModel
    @Binding var draggingID: UUID?
    @Binding var fileDropTargetID: UUID?

    private var isFileDrag: Bool { fileDropTargetID != nil }

    func dropEntered(info: DropInfo) {
        if info.hasItemsConforming(to: [UTType.fileURL.identifier]) {
            // 文件拖进来：点亮标签，0.6s 后自动切过去（松手前切换 = 落入它的目录）
            fileDropTargetID = targetID
            tabs.scheduleAutoSwitch(to: targetID)
            return
        }
        // 标签 chip 排序
        guard let draggingID,
              let from = tabs.tabs.firstIndex(where: { $0.id == draggingID }),
              let to = tabs.tabs.firstIndex(where: { $0.id == targetID }),
              from != to else { return }
        tabs.moveTab(from: from, to: to > from ? to + 1 : to)
    }

    func dropExited(info: DropInfo) {
        if fileDropTargetID == targetID {
            fileDropTargetID = nil
            tabs.cancelAutoSwitch()
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: isFileDrag ? .copy : .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        if isFileDrag {
            fileDropTargetID = nil
            tabs.cancelAutoSwitch()
            DropSupport.loadURLs(from: info.itemProviders(for: [.fileURL])) { urls in
                guard !urls.isEmpty else { return }
                let index = tabs.tabs.firstIndex(where: { $0.id == targetID })
                    ?? tabs.activeIndex
                tabs.receiveDrop(urls, intoTabAt: index, modifiers: NSEvent.modifierFlags)
            }
            draggingID = nil
            return true
        }
        draggingID = nil
        return true
    }
}
