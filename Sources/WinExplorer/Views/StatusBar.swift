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
                Text("\(model.items.count) 个项目")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)

                if let item = model.selectedItem {
                    Text("·")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
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
                }
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
}
