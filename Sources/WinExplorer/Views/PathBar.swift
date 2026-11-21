import SwiftUI

/// 面包屑地址栏：点任意一级都能跳过去。
struct PathBar: View {
    @ObservedObject var model: BrowserModel

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                ForEach(Array(model.crumbs.enumerated()), id: \.element.id) { index, crumb in
                    if index > 0 {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 1)
                    }
                    crumbButton(crumb, isLast: index == model.crumbs.count - 1)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func crumbButton(_ crumb: Crumb, isLast: Bool) -> some View {
        Button {
            model.navigate(to: crumb.url)
        } label: {
            Text(crumb.title)
                .font(.system(size: 12))
                .lineLimit(1)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(isLast ? Color.accentColor.opacity(0.12) : Color.clear)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(isLast ? Color.primary : Color.secondary)
        .help(crumb.url.path)
    }
}
