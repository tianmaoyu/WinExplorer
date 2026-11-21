import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// 表头与数据行共用同一套列骨架，保证任何屏幕上都不会错列。
enum FileListLayout {
    static let rowHeight: CGFloat = 26
    static let compactRowHeight: CGFloat = 22
    static let horizontalPadding: CGFloat = 10
    static let sizeTrailingPadding: CGFloat = 16
    static let dateTrailingPadding: CGFloat = 4
    static let dividerHitWidth: CGFloat = 7

    @ViewBuilder
    static func row<Name: View, Size: View, Date: View, Kind: View>(
        widths: ColumnWidths,
        @ViewBuilder name: () -> Name,
        @ViewBuilder size: () -> Size,
        @ViewBuilder date: () -> Date,
        @ViewBuilder kind: () -> Kind
    ) -> some View {
        HStack(spacing: 0) {
            name()
                .frame(maxWidth: .infinity, alignment: .leading)
            size()
                .frame(width: widths.size, alignment: .trailing)
                .padding(.trailing, sizeTrailingPadding)
            date()
                .frame(width: widths.date, alignment: .leading)
                .padding(.trailing, dateTrailingPadding)
            kind()
                .frame(width: widths.kind, alignment: .leading)
        }
        .padding(.horizontal, horizontalPadding)
    }

    /// 列边界距表头左缘的 x（从右往左推算，保证和 row 的骨架完全一致）
    static func dividerX(_ column: ResizableColumn, widths: ColumnWidths, totalWidth: CGFloat) -> CGFloat {
        let kindLeft = totalWidth - horizontalPadding - widths.kind
        switch column {
        case .kind:
            return kindLeft
        case .date:
            return kindLeft - dateTrailingPadding - widths.date
        case .size:
            return kindLeft - dateTrailingPadding - widths.date - sizeTrailingPadding - widths.size
        }
    }
}

/// 三种视图共用的列表容器：详细信息 / 列表 / 图标。
struct FileListView: View {
    @ObservedObject var model: BrowserModel
    /// 拖到列表空白处 = 拖进当前文件夹
    @State private var emptyAreaTargeted = false
    /// 列宽拖拽的起始宽度（一次只拖一条边界）
    @State private var resizeStart: CGFloat?
    @State private var resizingColumn: ResizableColumn?

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

                        switch model.viewMode {
                        case .details:
                            detailsContent(width: geometry.size.width)
                        case .list:
                            listContent
                        case .icons:
                            iconsContent(width: geometry.size.width)
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

    // MARK: - 详细信息

    private func detailsContent(width: CGFloat) -> some View {
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

    private var header: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                FileListLayout.row(widths: model.columnWidths) {
                    headerButton(SortColumn.name.title, column: .name, alignment: .leading)
                } size: {
                    headerButton(SortColumn.size.title, column: .size, alignment: .trailing)
                } date: {
                    headerButton(SortColumn.modified.title, column: .modified, alignment: .leading)
                } kind: {
                    headerButton(SortColumn.kind.title, column: .kind, alignment: .leading)
                }
                .frame(height: FileListLayout.rowHeight)
                .background(Color(nsColor: .controlBackgroundColor))

                // 列边界：拖拽改宽度，双击按内容自适应
                ForEach(ResizableColumn.allCases, id: \.self) { column in
                    dividerHandle(column)
                        .offset(
                            x: FileListLayout.dividerX(
                                column,
                                widths: model.columnWidths,
                                totalWidth: geometry.size.width
                            ) - FileListLayout.dividerHitWidth / 2
                        )
                }
            }
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
        .help(L("按\(title)排序", "Sort by \(title)"))
    }

    private func dividerHandle(_ column: ResizableColumn) -> some View {
        Rectangle()
            .fill(Color.clear)
            .frame(width: FileListLayout.dividerHitWidth, height: FileListLayout.rowHeight)
            .contentShape(Rectangle())
            .onHover { inside in
                // 用 set 而不是 push/pop：视图被重建时 push 容易和 pop 失配，鼠标指针会卡住
                if inside {
                    NSCursor.resizeLeftRight.set()
                } else {
                    NSCursor.arrow.set()
                }
            }
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        if resizingColumn != column {
                            resizingColumn = column
                            resizeStart = model.width(for: column)
                        }
                        let start = resizeStart ?? model.width(for: column)
                        model.resizeColumn(column, to: start - value.translation.width)
                    }
                    .onEnded { _ in
                        resizingColumn = nil
                        resizeStart = nil
                    }
            )
            .onTapGesture(count: 2) {
                model.autoFitColumn(column)
            }
    }

    // MARK: - 列表（紧凑单列）

    private var listContent: some View {
        LazyVStack(spacing: 0) {
            ForEach(model.items) { item in
                compactRow(for: item)
                    .id(item.url)
            }
        }
        .padding(.vertical, 4)
        .padding(.top, 2)
    }

    // MARK: - 图标

    private func iconsContent(width: CGFloat) -> some View {
        let spacing: CGFloat = 8
        let itemWidth: CGFloat = 104
        let available = max(width - FileListLayout.horizontalPadding * 2, itemWidth)
        let columns = max(1, Int((available + spacing) / (itemWidth + spacing)))
        let gridWidth = CGFloat(columns) * itemWidth + CGFloat(columns - 1) * spacing

        return HStack(spacing: 0) {
            Spacer(minLength: 0)

            LazyVGrid(
                columns: Array(repeating: GridItem(.fixed(itemWidth), spacing: spacing), count: columns),
                spacing: 10
            ) {
                ForEach(model.items) { item in
                    iconCell(for: item)
                        .id(item.url)
                }
            }
            .frame(width: gridWidth)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, FileListLayout.horizontalPadding)
        .padding(.vertical, 12)
        .onAppear { model.gridColumnCount = columns }
        .onChange(of: columns) { _, newValue in model.gridColumnCount = newValue }
    }

    // MARK: - 行（三种模式共用交互）

    private func row(for item: FileItem) -> some View {
        let renaming = model.renamingURL == item.url
        return interactive(item: item, renaming: renaming) {
            FileRow(
                model: model,
                item: item,
                isSelected: model.selection.contains(item.url) && !renaming,
                isRenaming: renaming,
                isCut: model.cutURLs.contains(item.url),
                isDropTarget: model.isDropTarget(item.url),
                widths: model.columnWidths
            )
            .frame(height: FileListLayout.rowHeight)
        }
    }

    private func compactRow(for item: FileItem) -> some View {
        let renaming = model.renamingURL == item.url
        return interactive(item: item, renaming: renaming) {
            CompactRow(
                model: model,
                item: item,
                isSelected: model.selection.contains(item.url) && !renaming,
                isRenaming: renaming,
                isCut: model.cutURLs.contains(item.url),
                isDropTarget: model.isDropTarget(item.url)
            )
            .frame(height: FileListLayout.compactRowHeight)
        }
    }

    private func iconCell(for item: FileItem) -> some View {
        let renaming = model.renamingURL == item.url
        return interactive(item: item, renaming: renaming) {
            IconCell(
                model: model,
                item: item,
                isSelected: model.selection.contains(item.url) && !renaming,
                isRenaming: renaming,
                isCut: model.cutURLs.contains(item.url),
                isDropTarget: model.isDropTarget(item.url)
            )
        }
    }

    /// 点击 / 双击 / 右键 / 拖放 / 拖拽探针，三种模式行为一致
    @ViewBuilder
    private func interactive<Content: View>(
        item: FileItem,
        renaming: Bool,
        @ViewBuilder content: () -> Content
    ) -> some View {
        let base = content()
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

        Button(L("打开", "Open")) {
            if inSelection {
                model.openSelection()
            } else {
                model.open(item)
            }
        }
        Button(L("快速预览", "Quick Look")) {
            if !inSelection { model.selectOnly(item) }
            model.toggleQuickLook()
        }
        Button(L("在 Finder 中显示", "Show in Finder")) {
            model.revealInFinder(item)
        }
        Button(L("显示简介", "Get Info")) {
            if !inSelection { model.selectOnly(item) }
            model.showInfo()
        }
        if item.isFolderLike {
            Button(L("添加到收藏夹", "Add to Favorites")) {
                model.addToFavorites(item)
            }
        }
        Divider()
        Button(L("剪切", "Cut")) {
            if !inSelection { model.selectOnly(item) }
            model.cutSelection()
        }
        Button(L("复制", "Copy")) {
            if !inSelection { model.selectOnly(item) }
            model.copySelection()
        }
        if item.isFolderLike {
            Button(L("粘贴到此处", "Paste Into Folder")) {
                model.paste(into: item.url)
            }
            .disabled(!model.canPaste || model.isTransferring)
        }
        if inSelection && model.selection.count > 1 {
            Button(L("复制 \(model.selection.count) 项路径", "Copy Paths of \(model.selection.count) Items")) {
                model.copySelectedPaths()
            }
        } else {
            Button(L("复制路径", "Copy Path")) {
                model.copyPath(item)
            }
        }
        Divider()
        Button(inSelection && model.selection.count > 1
               ? L("批量重命名…", "Batch Rename…")
               : L("重命名…", "Rename…")) {
            if inSelection && model.selection.count > 1 {
                model.beginBatchRename()
            } else {
                model.beginRename(item: item)
            }
        }
        Divider()
        Button(L("压缩为 zip", "Compress to ZIP")) {
            if !inSelection { model.selectOnly(item) }
            model.compressSelection()
        }
        .disabled(!model.canCompress)
        if ArchiveService.isArchive(item.url) {
            let folderName = ArchiveService.extractDestination(for: item.url, in: model.currentURL).lastPathComponent
            Button(L("解压到「\(folderName)」", "Extract to “\(folderName)”")) {
                if !inSelection { model.selectOnly(item) }
                model.extractSelection(toOwnFolder: true)
            }
            .disabled(!model.canExtract)
            Button(L("解压到当前文件夹", "Extract Here")) {
                if !inSelection { model.selectOnly(item) }
                model.extractSelection(toOwnFolder: false)
            }
            .disabled(!model.canExtract)
        }
        Divider()
        Button(L("移到废纸篓", "Move to Trash")) {
            if !inSelection { model.selectOnly(item) }
            model.moveSelectionToTrash()
        }
        Button(L("彻底删除…", "Delete Immediately…")) {
            if !inSelection { model.selectOnly(item) }
            model.requestPermanentDelete()
        }
        Divider()
        Button(L("刷新", "Refresh")) {
            model.reload()
        }
    }

    /// 空白区域右键菜单（Windows 在文件夹空白处右键的效果）
    @ViewBuilder
    private var emptyAreaMenu: some View {
        Button(L("新建文件夹", "New Folder")) {
            model.createFolder()
        }
        Button(L("搜索当前文件夹…", "Search This Folder…")) {
            model.beginSearch()
        }
        Button(L("将当前文件夹添加到收藏夹", "Add This Folder to Favorites")) {
            model.addCurrentDirectoryToFavorites()
        }
        .disabled(model.isCurrentDirectoryFavorite)
        Button(L("粘贴", "Paste")) {
            model.paste()
        }
        .disabled(!model.canPaste || model.isTransferring)
        Divider()
        Button(L("全选", "Select All")) {
            model.selectAll()
        }
        .disabled(model.items.isEmpty)
        Button(L("刷新", "Refresh")) {
            model.reload()
        }
        Divider()
        ForEach(ViewMode.allCases) { mode in
            Button {
                model.viewMode = mode
            } label: {
                if model.viewMode == mode {
                    Label(mode.title, systemImage: "checkmark")
                } else {
                    Text(mode.title)
                }
            }
        }
        Divider()
        Button(L("在 Finder 中显示", "Show in Finder")) {
            model.revealCurrentDirectory()
        }
        Button(L("复制当前文件夹路径", "Copy Folder Path")) {
            model.copyCurrentDirectoryPath()
        }
        Divider()
        Toggle(L("显示隐藏文件", "Show Hidden Files"), isOn: $model.showHidden)
        Toggle(L("计算文件夹大小", "Calculate Folder Sizes"), isOn: $model.showsFolderSizes)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: model.isSearching ? "magnifyingglass" : "folder")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(.quaternary)
            if model.isSearching {
                Text(L("没有与「\(model.searchQuery)」匹配的项目",
                       "No items match “\(model.searchQuery)”"))
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                Text(L("Esc 退出搜索，⌘F 换个关键词", "Esc to exit search, ⌘F for another keyword"))
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            } else {
                Text(L("此文件夹为空", "This folder is empty"))
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                Text(L("⇧⌘N 可以新建文件夹", "⇧⌘N to create a folder"))
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

// MARK: - 落点

/// 只有文件夹接受拖放；拖到文件上不做任何事。
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

// MARK: - 重命名输入框（三种模式共用）

private struct RenameInlineView: View {
    @ObservedObject var model: BrowserModel
    let item: FileItem
    var fontSize: CGFloat = 13

    var body: some View {
        RenameField(
            text: item.name,
            selectionLength: FileRow.baseNameLength(of: item.name),
            onCommit: { newName in
                let ok = model.commitRename(newName)
                if ok {
                    DispatchQueue.main.async { FocusKeeper.shared.reclaim() }
                }
                return ok
            },
            onCancel: {
                model.cancelRename()
                DispatchQueue.main.async { FocusKeeper.shared.reclaim() }
            }
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
    }
}

// MARK: - 详细信息行

struct FileRow: View {
    @ObservedObject var model: BrowserModel
    let item: FileItem
    let isSelected: Bool
    var isRenaming: Bool = false
    var isCut: Bool = false
    var isDropTarget: Bool = false
    let widths: ColumnWidths

    @State private var hovered = false

    var body: some View {
        FileListLayout.row(widths: widths) {
            HStack(spacing: 7) {
                FileItemIcon(item: item, size: 16)

                if isRenaming {
                    RenameInlineView(model: model, item: item)
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
            Text(model.sizeText(for: item))
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
        // 剪切中的项整体变淡（Windows 的"待移动"观感）；未授权项更淡一些
        .opacity(rowOpacity)
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
        .help(helpText)
    }

    /// 悬停提示：未授权项直接说清楚"打开时会提示授权"，避免用户以为是坏了
    private var helpText: String {
        item.isAccessible
            ? item.name
            : L("未授权：「\(item.name)」需要授权后才能打开", "Not authorized: “\(item.name)” needs permission to open")
    }

    /// 未授权项整体变淡；剪切中的项也变淡，两者取更淡的那个
    private var rowOpacity: Double {
        var value = 1.0
        if isCut { value = 0.5 }
        if item.access.isDenied { value = min(value, 0.42) }
        return value
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

// MARK: - 紧凑列表行

struct CompactRow: View {
    @ObservedObject var model: BrowserModel
    let item: FileItem
    let isSelected: Bool
    var isRenaming: Bool = false
    var isCut: Bool = false
    var isDropTarget: Bool = false

    @State private var hovered = false

    var body: some View {
        HStack(spacing: 7) {
            FileItemIcon(item: item, size: 16)

            if isRenaming {
                RenameInlineView(model: model, item: item)
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
        .padding(.horizontal, FileListLayout.horizontalPadding)
        .frame(maxWidth: .infinity)
        .background {
            RoundedRectangle(cornerRadius: 5)
                .fill(backgroundColor)
                .padding(.horizontal, 4)
        }
        .opacity(rowOpacity)
        .overlay {
            if isDropTarget {
                RoundedRectangle(cornerRadius: 4)
                    .stroke(isSelected ? Color.white : Color.accentColor, lineWidth: 2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .allowsHitTesting(false)
            }
        }
        .onHover { hovered = $0 }
        .help(helpText)
    }

    /// 悬停提示：未授权项直接说清楚"打开时会提示授权"，避免用户以为是坏了
    private var helpText: String {
        item.isAccessible
            ? item.name
            : L("未授权：「\(item.name)」需要授权后才能打开", "Not authorized: “\(item.name)” needs permission to open")
    }

    /// 未授权项整体变淡；剪切中的项也变淡，两者取更淡的那个
    private var rowOpacity: Double {
        var value = 1.0
        if isCut { value = 0.5 }
        if item.access.isDenied { value = min(value, 0.42) }
        return value
    }

    private var backgroundColor: Color {
        if isSelected { return Color.accentColor }
        if hovered { return Color.primary.opacity(0.06) }
        return Color.clear
    }
}

// MARK: - 图标格

struct IconCell: View {
    @ObservedObject var model: BrowserModel
    let item: FileItem
    let isSelected: Bool
    var isRenaming: Bool = false
    var isCut: Bool = false
    var isDropTarget: Bool = false

    @State private var hovered = false

    var body: some View {
        VStack(spacing: 4) {
            FileItemIcon(item: item, size: 44)

            if isRenaming {
                RenameInlineView(model: model, item: item, fontSize: 11)
                    .frame(maxWidth: .infinity)
            } else {
                Text(item.name)
                    .font(.system(size: 11))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .truncationMode(.middle)
                    .foregroundStyle(isSelected ? Color.white : Color.primary)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(6)
        .frame(width: 104, height: 84, alignment: .top)
        .background {
            RoundedRectangle(cornerRadius: 6)
                .fill(backgroundColor)
        }
        .opacity(rowOpacity)
        .overlay {
            if isDropTarget {
                RoundedRectangle(cornerRadius: 6)
                    .stroke(isSelected ? Color.white : Color.accentColor, lineWidth: 2)
                    .padding(1)
                    .allowsHitTesting(false)
            }
        }
        .onHover { hovered = $0 }
        .help(helpText)
    }

    /// 悬停提示：未授权项直接说清楚"打开时会提示授权"，避免用户以为是坏了
    private var helpText: String {
        item.isAccessible
            ? item.name
            : L("未授权：「\(item.name)」需要授权后才能打开", "Not authorized: “\(item.name)” needs permission to open")
    }

    /// 未授权项整体变淡；剪切中的项也变淡，两者取更淡的那个
    private var rowOpacity: Double {
        var value = 1.0
        if isCut { value = 0.5 }
        if item.access.isDenied { value = min(value, 0.42) }
        return value
    }

    private var backgroundColor: Color {
        if isSelected { return Color.accentColor }
        if hovered { return Color.primary.opacity(0.06) }
        return Color.clear
    }
}
