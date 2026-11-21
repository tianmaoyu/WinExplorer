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

    // MARK: 列表样式（对齐访达，adr/0017）

    /// 选中高亮的圆角。访达列表视图约 5pt，比 Windows 的直角高亮柔和
    static let selectionCornerRadius: CGFloat = 5
    /// 选中高亮左右留白：访达不会贴到窗口边缘，两侧各让出一点
    static let selectionHorizontalInset: CGFloat = 5
    /// 选中高亮上下留白：访达几乎贴满行高，只上下各让 1pt
    static let selectionVerticalInset: CGFloat = 1

    /// 列分隔线：高度比行高略短，视觉上像表格里的一道细缝而不是切开的块
    static let columnDividerInset: CGFloat = 5
    /// 列分隔线宽度（1px 在 Retina 上正好是发丝线）
    static let columnDividerWidth: CGFloat = 1

    /// 交替条纹的底色。用系统语义色，深浅色模式自动切换，
    /// 且和 `textBackgroundColor` 的对比度是系统调好的，不会刺眼。
    static var stripeColor: Color {
        let colors = NSColor.alternatingContentBackgroundColors
        if colors.count > 1 { return Color(nsColor: colors[1]) }
        return Color.primary.opacity(0.035)
    }

    /// 列分隔线颜色。`separatorColor` 叠在表头底色上几乎看不见（实测只差 5 级灰），
    /// 所以直接用「主色 13%」：浅色下是接近 210 的灰、深色下是比底色亮一档，
    /// 两个模式下都能一眼看出列边界。
    static var columnDividerColor: Color {
        Color.primary.opacity(0.13)
    }

    /// 某一列的边界竖线（相对行/表头左缘的 x）画成一根发丝线
    static func columnDivider(_ column: ResizableColumn, widths: ColumnWidths,
                              totalWidth: CGFloat, height: CGFloat) -> some View {
        Rectangle()
            .fill(columnDividerColor)
            .frame(width: columnDividerWidth, height: max(0, height))
            .offset(
                x: dividerX(column, widths: widths, totalWidth: totalWidth) - columnDividerWidth / 2
            )
    }

    /// 底部留白：只加在滚动内容的最底部（顶部/中间/左右都不加）。
    /// 密集列表也能向下滚出一段空白，右键空白的「新建」菜单永远可达（adr/0010）。
    static let trailingBlankHeight: CGFloat = 240
    /// 底部留白的滚动定位 id（ScrollRequest .trailingBlank / scroll:end 钩子用）
    static let trailingBlankID = "winexplorer.trailing-blank"

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
    /// 鼠标悬在哪条列分隔线上（悬停时线变强调色，提示「这里可以拖」）
    @State private var hoveredDivider: ResizableColumn?

    var body: some View {
        GeometryReader { geometry in
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    ZStack(alignment: .top) {
                        // 空白区域点一下清空选择；行在 ZStack 上层，会先拿到点击
                        Color(nsColor: .textBackgroundColor)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                // 点空白 = 放下当前一切输入状态（adr/0005）：
                                // 取消选中、退出地址栏编辑；搜索过滤词保留
                                model.cancelPathEditing()
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

                        VStack(spacing: 0) {
                            switch model.viewMode {
                            case .details:
                                detailsContent(width: geometry.size.width)
                            case .list:
                                listContent
                            case .icons:
                                iconsContent(width: geometry.size.width)
                            }
                            // 底部留白：仅在滚动内容最底部加这一段空白，滚到底即露出。
                            // allowsHitTesting(false) 让点击/右键/拖放穿透到底层空白色，
                            // 与原有空白区行为完全一致（清选择、空白右键菜单、拖入当前目录）。
                            Color.clear
                                .frame(height: FileListLayout.trailingBlankHeight)
                                .allowsHitTesting(false)
                                .id(FileListLayout.trailingBlankID)
                        }
                    }
                    .frame(minHeight: geometry.size.height, alignment: .top)
                }
                .onChange(of: model.scrollRequest) { _, request in
                    guard let request else { return }
                    withAnimation(.easeOut(duration: 0.12)) {
                        switch request.target {
                        case .item(let url):
                            proxy.scrollTo(url, anchor: nil)
                        case .trailingBlank:
                            // 对齐底部留白的下缘 = 滚到最大滚动位置
                            proxy.scrollTo(FileListLayout.trailingBlankID, anchor: .bottom)
                        }
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
                    // 用索引算奇偶：访达式的交替条纹
                    ForEach(Array(model.items.enumerated()), id: \.element.id) { index, item in
                        row(for: item, striped: !index.isMultiple(of: 2))
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
        ZStack {
            // 透明拖拽热区（比可见线宽，好抓）
            Rectangle()
                .fill(Color.clear)

            // 可见分隔线：平时是发丝线，悬停时加粗并变强调色 —— 拖拽的手感来自这里
            Rectangle()
                .fill(hoveredDivider == column
                      ? Color.accentColor
                      : FileListLayout.columnDividerColor)
                .frame(width: hoveredDivider == column ? 2 : FileListLayout.columnDividerWidth)
                .padding(.vertical, FileListLayout.columnDividerInset)
                .allowsHitTesting(false)
        }
        .frame(width: FileListLayout.dividerHitWidth, height: FileListLayout.rowHeight)
        .contentShape(Rectangle())
        .onHover { inside in
            hoveredDivider = inside ? column : (hoveredDivider == column ? nil : hoveredDivider)
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

    private func row(for item: FileItem, striped: Bool = false) -> some View {
        let renaming = model.renamingURL == item.url
        return interactive(item: item, renaming: renaming) {
            FileRow(
                model: model,
                item: item,
                isSelected: model.selection.contains(item.url) && !renaming,
                isRenaming: renaming,
                isCut: model.cutURLs.contains(item.url),
                isDropTarget: model.isDropTarget(item.url),
                widths: model.columnWidths,
                isStriped: striped
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
        // 菜单构建在主线程：这里只允许读内存缓存和常量（adr/0016）。
        // 任何同步磁盘 / LaunchServices 查询都会让菜单「点了不出来」。
        let inSelection = model.selection.contains(item.url)
        // 记一笔：卡顿 dump 里能看到「最后一个动作是构建 X 的右键菜单」
        let _ = RunLog.shared.recordMenuBuild()

        Button(L("打开", "Open")) {
            if inSelection {
                model.openSelection()
            } else {
                model.open(item)
            }
        }
        // 「打开方式」：候选应用一次性打开 + 选其他应用 + 设为默认（adr/0010）
        Menu(L("打开方式", "Open With")) {
            let candidates = model.openWithCandidates(for: item)
            let defaultApp = model.defaultOpenWithApp(for: item)

            if candidates.isEmpty {
                // 候选是后台查的：第一次右键可能还没回来，说清楚而不是骗用户「没有」
                Text(model.isOpenWithLoading(for: item)
                     ? L("正在读取候选应用…", "Loading apps…")
                     : L("没有可用的应用", "No apps available"))
            } else {
                ForEach(candidates) { app in
                    Button(app.id == defaultApp?.id
                           ? L("\(app.name)（默认）", "\(app.name) (default)")
                           : app.name) {
                        model.open(item, withApp: app)
                    }
                }
            }

            Divider()

            Button(L("其他…", "Other…")) {
                model.openWithPicker(item)
            }
            // 文件夹没有「默认打开方式」的概念，不给这一项
            if !item.isFolderLike {
                Button(L("设为默认打开方式…", "Set Default App…")) {
                    model.setDefaultOpenWithApp(item)
                }
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
            Menu(L("在终端中打开", "Open in Terminal")) {
                ForEach(TerminalService.available) { app in
                    Button(app.name) {
                        model.openInTerminal(item.url, app: app)
                    }
                }
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
        let _ = RunLog.shared.recordMenuBuild()
        Menu(L("新建", "New")) {
            Button(L("文件夹", "Folder")) {
                model.createFolder()
            }
            Divider()
            ForEach(NewFileKind.allCases) { kind in
                Button {
                    model.createFile(kind)
                } label: {
                    Label(kind.displayName, systemImage: kind.symbolName)
                }
            }
        }
        Menu(L("在终端中打开", "Open in Terminal")) {
            if TerminalService.available.isEmpty {
                Text(L("没有找到终端应用", "No terminal app found"))
            } else {
                ForEach(TerminalService.available) { app in
                    Button(app.name) {
                        model.openInTerminal(nil, app: app)
                    }
                }
            }
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
    /// 奇数行底色（访达式交替条纹）
    var isStriped: Bool = false

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
        // 先把高度撑满整行：`background` 只覆盖内容尺寸（约 16pt），
        // 不先定高的话条纹只会画成一条细带，上下露出父视图的底色。
        .frame(height: FileListLayout.rowHeight)
        // 上层：选中 / 悬停高亮。访达的比例：左右各让 5pt，上下各让 1pt，圆角 5。
        // 注意 background 的叠放顺序：**先写的那层更靠上**，所以高亮必须放在前面，
        // 否则条纹会盖住选中色。
        .background {
            RoundedRectangle(cornerRadius: FileListLayout.selectionCornerRadius)
                .fill(backgroundColor)
                .padding(.horizontal, FileListLayout.selectionHorizontalInset)
                .padding(.vertical, FileListLayout.selectionVerticalInset)
        }
        // 下层：交替条纹 + 贯穿的列分隔线（选中时被上面的高亮整块盖住）
        .background {
            GeometryReader { geometry in
                ZStack(alignment: .topLeading) {
                    if isStriped {
                        FileListLayout.stripeColor
                    }
                    ForEach(ResizableColumn.allCases, id: \.self) { column in
                        FileListLayout.columnDivider(
                            column,
                            widths: widths,
                            totalWidth: geometry.size.width,
                            height: FileListLayout.rowHeight - FileListLayout.columnDividerInset * 2
                        )
                        .offset(y: FileListLayout.columnDividerInset)
                    }
                }
                // 显式撑满：ZStack 的尺寸由子视图决定，不铺开的话条纹只画出一条细带
                .frame(width: geometry.size.width, height: geometry.size.height,
                       alignment: .topLeading)
            }
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
        if !item.isAccessible {
            return L("未授权：「\(item.name)」需要授权后才能打开", "Not authorized: “\(item.name)” needs permission to open")
        }
        if ProtectedPaths.shouldSkipRecursiveRead(item.url) {
            return L(
                "「\(item.name)」受 macOS 隐私保护，不自动统计大小；仍可正常打开",
                "“\(item.name)” is protected by macOS — size isn't scanned, but you can still open it"
            )
        }
        return item.name
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
        if !item.isAccessible {
            return L("未授权：「\(item.name)」需要授权后才能打开", "Not authorized: “\(item.name)” needs permission to open")
        }
        if ProtectedPaths.shouldSkipRecursiveRead(item.url) {
            return L(
                "「\(item.name)」受 macOS 隐私保护，不自动统计大小；仍可正常打开",
                "“\(item.name)” is protected by macOS — size isn't scanned, but you can still open it"
            )
        }
        return item.name
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
        if !item.isAccessible {
            return L("未授权：「\(item.name)」需要授权后才能打开", "Not authorized: “\(item.name)” needs permission to open")
        }
        if ProtectedPaths.shouldSkipRecursiveRead(item.url) {
            return L(
                "「\(item.name)」受 macOS 隐私保护，不自动统计大小；仍可正常打开",
                "“\(item.name)” is protected by macOS — size isn't scanned, but you can still open it"
            )
        }
        return item.name
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
