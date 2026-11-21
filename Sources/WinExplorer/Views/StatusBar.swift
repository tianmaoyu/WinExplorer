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
            Text("已选 \(model.selection.count) 项")
                .font(.system(size: 11))
                .foregroundStyle(Color.accentColor)
            Text("·")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
            Text("共 \(byteText(model.selectedTotalSize))")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            if model.selectedItems.contains(where: \.isDirectory) {
                Text("（不含文件夹大小）")
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
            Text("\(model.items.count) 个项目")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    private func byteText(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
