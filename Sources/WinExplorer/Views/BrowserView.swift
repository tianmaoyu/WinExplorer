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
                model.errorMessage = nil
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
