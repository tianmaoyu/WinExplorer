import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// 面包屑地址栏：点任意一级跳转、把文件拖到某一级上、点空白处或 ⌘L 切换成可编辑路径。
struct PathBar: View {
    @ObservedObject var model: BrowserModel
    @State private var targetedCrumb: URL?

    var body: some View {
        Group {
            if model.isEditingPath {
                editingBar
            } else {
                crumbsBar
            }
        }
        .onChange(of: model.isEditingPath) { _, editing in
            // 退出编辑后把键盘焦点还给列表，方向键才能继续用
            if !editing {
                DispatchQueue.main.async { FocusKeeper.shared.reclaim(force: true) }
            }
        }
    }

    // MARK: - 面包屑

    private var crumbsBar: some View {
        ZStack(alignment: .leading) {
            // 空白处点一下即可输入路径（和资源管理器的地址栏一致）
            Color(nsColor: .windowBackgroundColor)
                .contentShape(Rectangle())
                .onTapGesture {
                    model.beginPathEditing()
                }

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
        }
        .frame(height: 34)
        .help("点空白处输入路径（⌘L）")
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

    // MARK: - 编辑态

    private var editingBar: some View {
        HStack(spacing: 8) {
            Image(systemName: model.pathError == nil ? "folder" : "exclamationmark.triangle.fill")
                .font(.system(size: 12))
                .foregroundStyle(model.pathError == nil ? Color.secondary : Color.orange)

            PathField(
                text: model.pathDraft,
                onCommit: { model.commitPathEditing($0) },
                onCancel: { model.cancelPathEditing() },
                onComplete: { model.completePath($0) }
            )
            .frame(height: 20)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background {
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color(nsColor: .textBackgroundColor))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 5)
                    .stroke(model.pathError == nil ? Color.accentColor : Color.red, lineWidth: 1.5)
            }

            if let error = model.pathError {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            } else {
                Text("Tab 补全")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .frame(height: 34)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
