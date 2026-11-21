import SwiftUI

struct BrowserView: View {
    @ObservedObject var model: BrowserModel

    var body: some View {
        NavigationSplitView {
            SidebarView(model: model)
                .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 260)
        } detail: {
            detailPane
        }
        .navigationSplitViewStyle(.balanced)
        .toolbar { toolbarContent }
        .onAppear {
            SnapshotSupport.scheduleIfNeeded(model: model)
            installDragSource()
            ShortcutMonitor.shared.install(
                isBlocked: { model.hasModalOverlay },
                onUndo: { model.undo() },
                onRedo: { model.redo() },
                onShortcut: { event in
                    // SwiftUI 会在菜单层把这些组合吃掉且不调用 action（和 ⌘Z 同一个坑），
                    // 只能在 sendEvent 之前接管。
                    switch event.keyCode {
                    case 34: // I = 显示简介 / 再按一次关闭
                        if model.info != nil {
                            model.closeInfo()
                        } else if !model.hasModalOverlay {
                            model.showInfo()
                        }
                        return true
                    case 3: // F = 搜索当前目录
                        if !model.hasModalOverlay { model.beginSearch() }
                        return true
                    default:
                        return false
                    }
                }
            )
        }
        .overlay {
            if let targets = model.pendingPermanentDelete {
                DeleteConfirmView(
                    items: targets,
                    onCancel: { model.cancelPermanentDelete() },
                    onConfirm: { model.confirmPermanentDelete() }
                )
            }
        }
        .overlay {
            if let info = model.info {
                InfoPanelView(
                    state: info,
                    onReveal: { model.revealInfoTarget() },
                    onClose: { model.closeInfo() }
                )
            }
        }
        .overlay(alignment: .topLeading) {
            // 零尺寸的键盘接收视图，保证方向键/回车不被 SwiftUI 的焦点系统吞掉
            KeyCaptureView(onKey: handleKey)
                .frame(width: 0, height: 0)
                .allowsHitTesting(false)
        }
        .overlay(alignment: .bottom) {
            if let progress = model.transfer {
                TransferProgressView(progress: progress) {
                    model.cancelTransfer()
                }
            }
        }
    }

    private var detailPane: some View {
        VStack(spacing: 0) {
            if let error = model.errorMessage {
                errorBanner(error)
            }
            PathBar(model: model)
            Divider()
            FileListView(model: model)
            Divider()
            StatusBar(model: model)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .navigationTitle(model.titleText)
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12))
                .foregroundStyle(.orange)
            Text(message)
                .font(.system(size: 12))
                .lineLimit(2)
            Spacer(minLength: 8)
            Button("重试") { model.reload() }
                .buttonStyle(.link)
                .font(.system(size: 12))
            Button {
                model.dismissError()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Color.orange.opacity(0.12))
    }

    // MARK: - 拖拽

    /// 拖拽由 AppKit 会话发起（见 DragSupport），这里告诉它「这一次要拖哪些文件」
    private func installDragSource() {
        DragCoordinator.shared.install()
        DragCoordinator.shared.resolveURLs = { url, _ in
            if model.selection.contains(url), model.dragURLs.count > 0 {
                return model.dragURLs
            }
            // 拖未选中的行：先选中它，再只拖这一个（与 Windows 一致）
            if let item = model.items.first(where: {
                $0.url.standardizedFileURL.path == url.standardizedFileURL.path
            }) {
                model.selectOnly(item)
            }
            return [url]
        }
    }

    // MARK: - 键盘

    /// 返回 true 表示事件已被消费。
    /// ⌘/⌃/⌥ 组合默认放行给菜单栏，但"全选"和删除单独在这里兜底：
    /// 有些用户把 Command 重映射成了别的键，菜单快捷键可能收不到。
    private func handleKey(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags

        // 浮层（彻底删除确认 / 属性面板）打开时拦住所有按键：
        // Esc 或 Return 关闭，⌘I 切掉属性面板，其它一律忽略，避免在浮层后面误操作列表
        if model.hasModalOverlay {
            if event.keyCode == 53 || event.keyCode == 36 || event.keyCode == 76 {
                model.cancelPermanentDelete()
                model.closeInfo()
            } else if event.keyCode == 34 {
                model.closeInfo()
            }
            return true
        }

        // I = 显示简介（⌘I），兼容 Command 被重映射后的 fn+I
        if event.keyCode == 34 {
            let infoFlags: NSEvent.ModifierFlags = [.command, .function]
            if !flags.intersection(infoFlags).isEmpty, !flags.contains(.control) {
                model.showInfo()
                return true
            }
        }

        // F = 搜索当前目录（⌘F），同样兼容 fn+F
        if event.keyCode == 3 {
            let findFlags: NSEvent.ModifierFlags = [.command, .function]
            if !flags.intersection(findFlags).isEmpty, !flags.contains(.control) {
                model.beginSearch()
                return true
            }
        }

        // A = 全选：兼容 ⌘A、以及 Command 被重映射后的 fn+A / ⌥+A
        if event.keyCode == 0 {
            let selectAllFlags: NSEvent.ModifierFlags = [.command, .function, .option]
            if !flags.intersection(selectAllFlags).isEmpty {
                model.selectAll()
                return true
            }
        }

        // C / X / V = 复制、剪切、粘贴。同样兼容 Command 被重映射后的 fn / ⌥ 版本；
        // ⌥⌘C 是"复制路径"，留给菜单处理。
        if [7, 8, 9].contains(event.keyCode) {
            let clipboardFlags: NSEvent.ModifierFlags = [.command, .function, .option]
            let isCopyPath = event.keyCode == 8
                && flags.contains(.command)
                && flags.contains(.option)
            if !flags.intersection(clipboardFlags).isEmpty,
               !isCopyPath,
               !flags.contains(.control) {
                switch event.keyCode {
                case 7: model.cutSelection()
                case 8: model.copySelection()
                default: model.paste()
                }
                return true
            }
        }

        // Delete（keyCode 51）/ 前向删除（117）：⌘⌫ 进废纸篓，⇧⌘⌫ 彻底删除
        if event.keyCode == 51 || event.keyCode == 117, flags.contains(.command) {
            if flags.contains(.shift) {
                model.requestPermanentDelete()
            } else {
                model.moveSelectionToTrash()
            }
            return true
        }

        // Z = 撤销 / ⇧Z 重做，同样兼容 Command 被重映射后的 fn / ⌥ 版本
        if event.keyCode == 6 {
            let undoFlags: NSEvent.ModifierFlags = [.command, .function, .option]
            if !flags.intersection(undoFlags).isEmpty, !flags.contains(.control) {
                if flags.contains(.shift) {
                    model.redo()
                } else {
                    model.undo()
                }
                return true
            }
        }

        // 1 / 2 / 3 = 切换视图模式（⌘1 详细信息、⌘2 列表、⌘3 图标）
        if [18, 19, 20].contains(event.keyCode) {
            let modeFlags: NSEvent.ModifierFlags = [.command, .function]
            if !flags.intersection(modeFlags).isEmpty, !flags.contains(.control) {
                switch event.keyCode {
                case 18: model.viewMode = .details
                case 19: model.viewMode = .list
                default: model.viewMode = .icons
                }
                return true
            }
        }

        // L = 编辑地址栏（⌘L），同样兼容 Command 被重映射后的 fn+L
        if event.keyCode == 37 {
            let editFlags: NSEvent.ModifierFlags = [.command, .function]
            if !flags.intersection(editFlags).isEmpty, !flags.contains(.control) {
                model.beginPathEditing()
                return true
            }
        }

        // 0 = 自动调整列宽。菜单项在刚切换视图时可能是陈旧的禁用态，这里兜底
        if event.keyCode == 29 {
            let fitFlags: NSEvent.ModifierFlags = [.command, .function]
            if !flags.intersection(fitFlags).isEmpty, !flags.contains(.control) {
                model.autoFitAllColumns()
                return true
            }
        }

        let reserved: NSEvent.ModifierFlags = [.command, .control, .option]
        if !flags.intersection(reserved).isEmpty {
            return false
        }

        switch event.keyCode {
        case 120: // F2
            model.beginRename()
        case 126: // ↑
            model.moveFocusVertically(by: -1)
        case 125: // ↓
            model.moveFocusVertically(by: 1)
        case 123: // ←（仅图标视图用来横向移动）
            if model.viewMode == .icons { model.moveFocus(by: -1) }
        case 124: // →（仅图标视图用来横向移动）
            if model.viewMode == .icons { model.moveFocus(by: 1) }
        case 116: // Page Up
            model.moveFocusVertically(by: model.viewMode == .icons ? -3 : -12)
        case 121: // Page Down
            model.moveFocusVertically(by: model.viewMode == .icons ? 3 : 12)
        case 115: // Home
            model.focusEdge(first: true)
        case 119: // End
            model.focusEdge(first: false)
        case 36, 76: // Return / 小键盘 Enter
            model.openSelection()
        case 53: // Esc
            if model.isSearching {
                // 先退出搜索，再按一次才是清空选择
                model.clearSearch()
            } else if model.isTransferring {
                model.cancelTransfer()
            } else {
                model.clearSelection()
            }
        default:
            return false
        }
        return true
    }

    // MARK: - 工具栏

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button(action: model.goBack) {
                Image(systemName: "chevron.left")
            }
            .disabled(!model.canGoBack)
            .help("后退（⌘[）")

            Button(action: model.goForward) {
                Image(systemName: "chevron.right")
            }
            .disabled(!model.canGoForward)
            .help("前进（⌘]）")

            Button(action: model.goUp) {
                Image(systemName: "arrow.up")
            }
            .disabled(!model.canGoUp)
            .help("上一级（⌘↑）")
        }

        ToolbarItemGroup(placement: .primaryAction) {
            Picker("视图模式", selection: $model.viewMode) {
                ForEach(ViewMode.allCases) { mode in
                    Image(systemName: mode.symbolName)
                        .tag(mode)
                        .help(mode.title)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 116)
            .help("视图模式（⌘1 详细信息 / ⌘2 列表 / ⌘3 图标）")

            Button {
                model.paste()
            } label: {
                Label("粘贴", systemImage: "doc.on.clipboard")
            }
            .disabled(!model.canPaste || model.isTransferring)
            .help("粘贴到当前文件夹（⌘V）")

            Button(action: model.createFolder) {
                Label("新建文件夹", systemImage: "folder.badge.plus")
            }
            .help("新建文件夹（⇧⌘N）")

            Menu {
                Section("视图模式") {
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
                }

                Section("排序方式") {
                    ForEach(SortColumn.allCases) { column in
                        Button {
                            model.toggleSort(column)
                        } label: {
                            if model.sortColumn == column {
                                Label(
                                    column.title,
                                    systemImage: model.sortAscending ? "chevron.up" : "chevron.down"
                                )
                            } else {
                                Text(column.title)
                            }
                        }
                    }
                }

                Divider()

                Toggle("显示隐藏文件", isOn: $model.showHidden)

                Divider()

                Button("刷新") { model.reload() }
            } label: {
                Label("视图选项", systemImage: "slider.horizontal.3")
            }
            .help("排序与显示选项")
        }
    }
}
