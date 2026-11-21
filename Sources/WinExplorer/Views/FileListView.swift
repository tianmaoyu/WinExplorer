import AppKit
import SwiftUI

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

/// Windows 资源管理器式的"详细信息"列表：表头可排序，行可双击打开。
struct FileListView: View {
    @ObservedObject var model: BrowserModel

    var body: some View {
        Group {
            if model.items.isEmpty {
                VStack(spacing: 0) {
                    header
                    Divider()
                    emptyState
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                // 表头必须和数据行处在同一个滚动容器里，否则滚动条占用的宽度
                // 会让表头和数据列整体错开（15pt 级偏差）。
                ScrollView(.vertical) {
                    LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                        Section {
                            VStack(spacing: 0) {
                                ForEach(model.items) { item in
                                    row(for: item)
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

    private func row(for item: FileItem) -> some View {
        FileRow(item: item, isSelected: item.url == model.selection)
            .frame(height: FileListLayout.rowHeight)
            .contentShape(Rectangle())
            .onTapGesture(count: 2) {
                model.selection = item.url
                model.open(item)
            }
            .simultaneousGesture(
                TapGesture(count: 1).onEnded {
                    model.selection = item.url
                }
            )
            .contextMenu {
                contextMenu(for: item)
            }
    }

    @ViewBuilder
    private func contextMenu(for item: FileItem) -> some View {
        Button("打开") {
            model.open(item)
        }
        Button("在 Finder 中显示") {
            model.revealInFinder(item)
        }
        Divider()
        Button("复制路径") {
            model.copyPath(item)
        }
        Divider()
        Button("刷新") {
            model.reload()
        }
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

/// 单行。列宽/内边距全部来自 FileListLayout，和表头严格对齐。
struct FileRow: View {
    let item: FileItem
    let isSelected: Bool

    @State private var hovered = false

    var body: some View {
        FileListLayout.row {
            HStack(spacing: 7) {
                Image(nsImage: IconProvider.shared.icon(for: item.url))
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 16, height: 16)
                Text(item.name)
                    .font(.system(size: 13))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(isSelected ? Color.white : Color.primary)
                Spacer(minLength: 0)
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
        .onHover { hovered = $0 }
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
