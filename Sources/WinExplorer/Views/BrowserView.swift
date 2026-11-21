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
                isBlocked: { model.pendingPermanentDelete != nil },
                onUndo: { model.undo() },
                onRedo: { model.redo() }
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

        // 确认层打开时拦住所有按键，只允许 Esc 取消，避免在浮层后面误操作列表
        if model.pendingPermanentDelete != nil {
            if event.keyCode == 53 {
                model.cancelPermanentDelete()
            }
            return true
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

        let reserved: NSEvent.ModifierFlags = [.command, .control, .option]
        if !flags.intersection(reserved).isEmpty {
            return false
        }

        switch event.keyCode {
        case 120: // F2
            model.beginRename()
        case 126: // ↑
            model.moveFocus(by: -1)
        case 125: // ↓
            model.moveFocus(by: 1)
        case 116: // Page Up
            model.moveFocus(by: -12)
        case 121: // Page Down
            model.moveFocus(by: 12)
        case 115: // Home
            model.focusEdge(first: true)
        case 119: // End
            model.focusEdge(first: false)
        case 36, 76: // Return / 小键盘 Enter
            model.openSelection()
        case 53: // Esc
            if model.pendingPermanentDelete != nil {
                model.cancelPermanentDelete()
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
