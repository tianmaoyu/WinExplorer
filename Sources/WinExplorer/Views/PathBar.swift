import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// 面包屑地址栏：点任意一级都能跳过去，也能把文件拖到某一级上。
struct PathBar: View {
    @ObservedObject var model: BrowserModel
    @State private var targetedCrumb: URL?

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
        let targeted = targetedCrumb == crumb.url

        return Button {
            model.navigate(to: crumb.url)
        } label: {
            Text(crumb.title)
                .font(.system(size: 12))
                .lineLimit(1)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(backgroundColor(isLast: isLast, targeted: targeted))
                }
                .overlay {
                    if targeted {
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(Color.accentColor, lineWidth: 1.5)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(isLast ? Color.primary : Color.secondary)
        .help(crumb.url.path)
        .onDrop(of: [UTType.fileURL], isTargeted: targetedBinding(for: crumb.url)) { providers in
            DropSupport.loadURLs(from: providers) { urls in
                guard !urls.isEmpty else { return }
                model.drop(urls: urls, into: crumb.url, modifiers: NSEvent.modifierFlags)
            }
            return true
        }
    }

    private func backgroundColor(isLast: Bool, targeted: Bool) -> Color {
        if targeted { return Color.accentColor.opacity(0.22) }
        return isLast ? Color.accentColor.opacity(0.12) : Color.clear
    }

    private func targetedBinding(for url: URL) -> Binding<Bool> {
        Binding(
            get: { targetedCrumb == url },
            set: { isTargeted in
                if isTargeted {
                    targetedCrumb = url
                } else if targetedCrumb == url {
                    targetedCrumb = nil
                }
            }
        )
    }
}
