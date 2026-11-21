import SwiftUI

struct StatusBar: View {
    @ObservedObject var model: BrowserModel

    var body: some View {
        HStack(spacing: 6) {
            if let flash = model.flash {
                Text(flash)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.accentColor)
            } else {
                summary
            }

            if let progress = model.folderSizeProgress {
                Text("·")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                Text(L("正在统计文件夹大小 \(progress.done)/\(progress.total)",
                       "Calculating folder sizes \(progress.done)/\(progress.total)"))
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
            }

            Spacer(minLength: 12)

            Text(model.currentURL.path)
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.head)
        }
        .padding(.horizontal, 12)
        .frame(height: 24)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    @ViewBuilder
    private var summary: some View {
        if model.selection.count > 1 {
            Text(L("已选 \(model.selection.count) 项", "\(model.selection.count) selected"))
                .font(.system(size: 11))
                .foregroundStyle(Color.accentColor)
            Text("·")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
            Text(L("共 \(byteText(model.selectedTotalSize))", "\(byteText(model.selectedTotalSize)) total"))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            if model.selectedItems.contains(where: \.isDirectory) {
                Text(L("（不含文件夹大小）", "(folders not counted)"))
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
            }
        } else if model.selection.count == 1, let item = model.selectedItems.first {
            Text(item.name)
                .font(.system(size: 11))
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(.secondary)
            if item.size != nil {
                Text("· \(item.sizeText)")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
        } else {
            if model.isSearching {
                Text(L("搜索「\(model.searchQuery)」", "Search “\(model.searchQuery)”"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(L("· \(model.items.count) 项匹配", "· \(model.items.count) matches"))
                    .font(.system(size: 11))
                    .foregroundStyle(model.items.isEmpty ? Color.secondary : Color.accentColor)
            } else {
                Text(L("\(model.items.count) 个项目", "\(model.items.count) items"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func byteText(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
