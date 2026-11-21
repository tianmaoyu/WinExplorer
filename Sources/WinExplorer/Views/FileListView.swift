import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// 表头与数据行共用同一套列骨架，保证任何屏幕上都不会错列。
enum FileListLayout {
    static let sizeWidth: CGFloat = 90
    static let dateWidth: CGFloat = 150
    static let kindWidth: CGFloat = 120
    static let rowHeight: CGFloat = 26
    static let horizontalPadding: CGFloat = 10

    @ViewBuilder
    static func row<Name: View, Size: View, Date: View, Kind: View>(
        @ViewBuilder name: () -> Name,
        @ViewBuilder size: () -> Size,
        @ViewBuilder date: () -> Date,
        @ViewBuilder kind: () -> Kind
    ) -> some View {
        HStack(spacing: 0) {
            name()
                .frame(maxWidth: .infinity, alignment: .leading)
            size()
                .frame(width: sizeWidth, alignment: .trailing)
                .padding(.trailing, 16)
            date()
                .frame(width: dateWidth, alignment: .leading)
                .padding(.trailing, 4)
            kind()
                .frame(width: kindWidth, alignment: .leading)
        }
        .padding(.horizontal, horizontalPadding)
    }
}

/// Windows 资源管理器式的"详细信息"列表：表头可排序，行可多选、可双击打开。
struct FileListView: View {
    @ObservedObject var model: BrowserModel
    /// 拖到列表空白处 = 拖进当前文件夹
    @State private var emptyAreaTargeted = false

    var body: some View {
        GeometryReader { geometry in
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    ZStack(alignment: .top) {
                        // 空白区域点一下清空选择；行在 ZStack 上层，会先拿到点击
                        Color(nsColor: .textBackgroundColor)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                model.clearSelection()
                            }
                            .contextMenu {
                                emptyAreaMenu
                            }
                            .onDrop(
                                of: [UTType.fileURL],
                                isTargeted: $emptyAreaTargeted
                            ) { providers in
                                DropSupport.loadURLs(from: providers) { urls in
                                    guard !urls.isEmpty else { return }
                                    model.drop(urls: urls, into: model.currentURL, modifiers: NSEvent.modifierFlags)
                                }
                                return true
                            }

                        LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                            Section {
                                VStack(spacing: 0) {
                                    ForEach(model.items) { item in
                                        row(for: item)
                                            .id(item.url)
                                    }
                                }
                                .padding(.vertical, 4)
                            } header: {
                                VStack(spacing: 0) {
                                    header
                                    Divider()
                                }
                            }
                        }
                    }
                    .frame(minHeight: geometry.size.height, alignment: .top)
                }
                .onChange(of: model.scrollRequest) { _, request in
                    guard let request else { return }
                    withAnimation(.easeOut(duration: 0.12)) {
                        proxy.scrollTo(request.url, anchor: nil)
                    }
                }
                .overlay {
                    if emptyAreaTargeted {
                        RoundedRectangle(cornerRadius: 2)
                            .stroke(Color.accentColor, lineWidth: 2)
                            .allowsHitTesting(false)
                    }
                }
            }

            if model.items.isEmpty {
                emptyState
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    // MARK: - 表头

    private var header: some View {
        FileListLayout.row {
            headerButton("名称", column: .name, alignment: .leading)
        } size: {
            headerButton("大小", column: .size, alignment: .trailing)
        } date: {
            headerButton("修改日期", column: .modified, alignment: .leading)
        } kind: {
            headerButton("类型", column: .kind, alignment: .leading)
        }
        .frame(height: FileListLayout.rowHeight)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func headerButton(_ title: String, column: SortColumn, alignment: Alignment) -> some View {
        Button {
            model.toggleSort(column)
        } label: {
            HStack(spacing: 3) {
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                if model.sortColumn == column {
                    Image(systemName: model.sortAscending ? "chevron.up" : "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                }
            }
            .foregroundStyle(model.sortColumn == column ? Color.primary : Color.secondary)
            .frame(maxWidth: .infinity, alignment: alignment)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("按\(title)排序")
    }

    // MARK: - 行

    @ViewBuilder
    private func row(for item: FileItem) -> some View {
        let renaming = model.renamingURL == item.url

        let base = FileRow(
            item: item,
            isSelected: model.selection.contains(item.url) && !renaming,
            isRenaming: renaming,
            isCut: model.cutURLs.contains(item.url),
            isDropTarget: model.isDropTarget(item.url),
            onCommitRename: { newName in
                let ok = model.commitRename(newName)
                if ok {
                    DispatchQueue.main.async { FocusKeeper.shared.reclaim() }
                }
                return ok
            },
            onCancelRename: {
                model.cancelRename()
                DispatchQueue.main.async { FocusKeeper.shared.reclaim() }
            }
        )
        .frame(height: FileListLayout.rowHeight)
        .contentShape(Rectangle())
        // 拖拽发起用的命中探针（不参与点击）
        .background(RowProbe(url: item.url))

        if renaming {
            base
        } else {
            base
                .onTapGesture(count: 2) {
                    model.open(item)
                }
                .simultaneousGesture(
                    TapGesture(count: 1).onEnded {
                        // 点击后把键盘焦点拿回来（正在重命名时先结束编辑再拿）
                        FocusKeeper.shared.reclaim(force: true)
                        model.handleClick(on: item, modifiers: NSEvent.modifierFlags)
                    }
                )
                .contextMenu {
                    contextMenu(for: item)
                }
                .modifier(FolderDropModifier(model: model, item: item))
        }
    }

    @ViewBuilder
    private func contextMenu(for item: FileItem) -> some View {
        let inSelection = model.selection.contains(item.url)

        Button("打开") {
            if inSelection {
                model.openSelection()
            } else {
                model.open(item)
            }
        }
        Button("在 Finder 中显示") {
            model.revealInFinder(item)
        }
        Divider()
        Button("剪切") {
            if !inSelection { model.selectOnly(item) }
            model.cutSelection()
        }
        Button("复制") {
            if !inSelection { model.selectOnly(item) }
            model.copySelection()
        }
        if item.isFolderLike {
            Button("粘贴到此处") {
                model.paste(into: item.url)
            }
            .disabled(!model.canPaste || model.isTransferring)
        }
        if inSelection && model.selection.count > 1 {
            Button("复制 \(model.selection.count) 项路径") {
                model.copySelectedPaths()
            }
        } else {
            Button("复制路径") {
                model.copyPath(item)
            }
        }
        Divider()
        Button("重命名…") {
            model.beginRename(item: item)
        }
        Divider()
        Button("移到废纸篓") {
            if !inSelection { model.selectOnly(item) }
            model.moveSelectionToTrash()
        }
        Button("彻底删除…") {
            if !inSelection { model.selectOnly(item) }
            model.requestPermanentDelete()
        }
        Divider()
        Button("刷新") {
            model.reload()
        }
    }

    /// 空白区域右键菜单（Windows 在文件夹空白处右键的效果）
    @ViewBuilder
    private var emptyAreaMenu: some View {
        Button("新建文件夹") {
            model.createFolder()
        }
        Button("粘贴") {
            model.paste()
        }
        .disabled(!model.canPaste || model.isTransferring)
        Divider()
        Button("全选") {
            model.selectAll()
        }
        .disabled(model.items.isEmpty)
        Button("刷新") {
            model.reload()
        }
        Divider()
        Button("在 Finder 中显示") {
            model.revealCurrentDirectory()
        }
        Button("复制当前文件夹路径") {
            model.copyCurrentDirectoryPath()
        }
        Divider()
        Toggle("显示隐藏文件", isOn: $model.showHidden)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "folder")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(.quaternary)
            Text("此文件夹为空")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            Text("⇧⌘N 可以新建文件夹")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
    }
}

/// 只有文件夹行接受拖放；拖到文件行上不做任何事。
private struct FolderDropModifier: ViewModifier {
    @ObservedObject var model: BrowserModel
    let item: FileItem

    @ViewBuilder
    func body(content: Content) -> some View {
        if item.isFolderLike {
            content.onDrop(of: [UTType.fileURL], isTargeted: targeted) { providers in
                DropSupport.loadURLs(from: providers) { urls in
                    guard !urls.isEmpty else { return }
                    model.drop(urls: urls, into: item.url, modifiers: NSEvent.modifierFlags)
                }
                return true
            }
        } else {
            content
        }
    }

    private var targeted: Binding<Bool> {
        Binding(
            get: { model.isDropTarget(item.url) },
            set: { isTargeted in
                if isTargeted {
                    model.dropTargetURL = item.url
                } else if model.isDropTarget(item.url) {
                    model.dropTargetURL = nil
                }
            }
        )
    }
}

/// 单行。列宽/内边距全部来自 FileListLayout，和表头严格对齐。
struct FileRow: View {
    let item: FileItem
    let isSelected: Bool
    var isRenaming: Bool = false
    var isCut: Bool = false
    var isDropTarget: Bool = false
    var onCommitRename: (String) -> Bool = { _ in false }
    var onCancelRename: () -> Void = {}

    @State private var hovered = false

    var body: some View {
        FileListLayout.row {
            HStack(spacing: 7) {
                Image(nsImage: IconProvider.shared.icon(for: item.url))
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 16, height: 16)

                if isRenaming {
                    RenameField(
                        text: item.name,
                        selectionLength: Self.baseNameLength(of: item.name),
                        onCommit: onCommitRename,
                        onCancel: onCancelRename
                    )
                    .frame(height: 18)
                    .padding(.horizontal, 3)
                    .background {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color(nsColor: .textBackgroundColor))
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: 3)
                            .stroke(Color.accentColor, lineWidth: 1.5)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Text(item.name)
                        .font(.system(size: 13))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(isSelected ? Color.white : Color.primary)
                    Spacer(minLength: 0)
                }
            }
        } size: {
            Text(item.sizeText)
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(secondaryColor)
        } date: {
            Text(item.modifiedText)
                .font(.system(size: 12))
                .foregroundStyle(secondaryColor)
        } kind: {
            Text(item.kind)
                .font(.system(size: 12))
                .lineLimit(1)
                .foregroundStyle(secondaryColor)
        }
        .background {
            RoundedRectangle(cornerRadius: 5)
                .fill(backgroundColor)
                .padding(.horizontal, 4)
        }
        // 剪切中的项整体变淡，和 Windows 的"待移动"观感一致
        .opacity(isCut ? 0.5 : 1)
        .overlay {
            if isDropTarget {
                RoundedRectangle(cornerRadius: 4)
                    // 行被选中时底色就是强调色，描边改成白色并往里缩一点才看得见
                    .stroke(isSelected ? Color.white : Color.accentColor, lineWidth: 2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .allowsHitTesting(false)
            }
        }
        .onHover { hovered = $0 }
    }

    /// 主文件名长度（不含扩展名），重命名时默认只选中这一段
    static func baseNameLength(of name: String) -> Int {
        let nsName = name as NSString
        guard !nsName.pathExtension.isEmpty else { return nsName.length }
        let base = nsName.deletingPathExtension
        guard !base.isEmpty else { return nsName.length }
        return (base as NSString).length
    }

    private var secondaryColor: Color {
        isSelected ? Color.white.opacity(0.88) : Color.secondary
    }

    private var backgroundColor: Color {
        if isSelected { return Color.accentColor }
        if hovered { return Color.primary.opacity(0.06) }
        return Color.clear
    }
}
