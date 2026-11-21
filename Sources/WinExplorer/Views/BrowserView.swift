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
        .overlay(alignment: .topLeading) {
            // 零尺寸的键盘接收视图，保证方向键/回车不被 SwiftUI 的焦点系统吞掉
            KeyCaptureView(onKey: handleKey)
                .frame(width: 0, height: 0)
                .allowsHitTesting(false)
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

    // MARK: - 键盘

    /// 返回 true 表示事件已被消费。
    /// ⌘/⌃/⌥ 组合默认放行给菜单栏，但"全选"单独在这里兜底：
    /// 有些用户把 Command 重映射成了别的键，菜单快捷键可能收不到。
    private func handleKey(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags

        // A = 全选：兼容 ⌘A、以及 Command 被重映射后的 fn+A / ⌥+A
        if event.keyCode == 0 {
            let selectAllFlags: NSEvent.ModifierFlags = [.command, .function, .option]
            if !flags.intersection(selectAllFlags).isEmpty {
                model.selectAll()
                return true
            }
        }

        let reserved: NSEvent.ModifierFlags = [.command, .control, .option]
        if !flags.intersection(reserved).isEmpty {
            return false
        }

        switch event.keyCode {
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
            model.clearSelection()
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
