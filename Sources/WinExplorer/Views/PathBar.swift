import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// 面包屑地址栏，视觉对齐 Windows 11 资源管理器（见 docs/adr/0001）：一整条浅色圆角容器
/// + 左侧当前位置图标 + 段间细 chevron；当前目录只用字重区分，不再加蓝色胶囊。
///
/// 交互与旧版完全一致：点某一段跳转、把文件拖到某一段上、点空白处或 ⌘L 进入编辑。
struct PathBar: View {
    @ObservedObject var model: BrowserModel

    @State private var targetedCrumb: URL?
    @State private var hoveredCrumb: URL?

    /// 地址栏与搜索框同高（Win11 一致）
    private let barHeight: CGFloat = 28
    /// 行高 = 容器 28 + 上下各 5 留白
    private let rowHeight: CGFloat = 38
    private let cornerRadius: CGFloat = 6

    var body: some View {
        HStack(spacing: 8) {
            if model.isEditingPath {
                editingBar
            } else {
                crumbsBar
            }

            searchBox
                .frame(width: 190, height: barHeight)
        }
        .padding(.horizontal, 10)
        .frame(height: rowHeight)
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
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture {
                    model.beginPathEditing()
                }

            HStack(spacing: 0) {
                currentIcon
                    .padding(.leading, 8)
                    .padding(.trailing, 2)

                ForEach(Array(displayCrumbs.enumerated()), id: \.element.id) { index, item in
                    if index > 0 {
                        separator
                    }
                    switch item.kind {
                    case .crumb(let crumb):
                        crumbButton(crumb, isCurrent: item.isCurrent)
                    case .ellipsis(let hidden):
                        ellipsisButton(hidden)
                    }
                }

                Spacer(minLength: 0)
            }
            .padding(.trailing, 6)
        }
        .frame(height: barHeight)
        .background {
            RoundedRectangle(cornerRadius: cornerRadius)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.55))
        }
        .overlay {
            RoundedRectangle(cornerRadius: cornerRadius)
                .stroke(Color.primary.opacity(0.09), lineWidth: 1)
        }
        .help(L("点空白处输入路径（⌘L）", "Click the empty area to type a path (⌘L)"))
    }

    /// 左侧当前位置图标：只作装饰，点击穿透到空白区（进入编辑）
    private var currentIcon: some View {
        Image(nsImage: IconProvider.shared.icon(for: model.currentURL))
            .frame(width: 16, height: 16)
            .allowsHitTesting(false)
    }

    private var separator: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 7.5, weight: .semibold))
            .foregroundStyle(Color.primary.opacity(0.30))
            .padding(.horizontal, 1)
    }

    private func crumbButton(_ crumb: Crumb, isCurrent: Bool) -> some View {
        let targeted = targetedCrumb == crumb.url
        let hovered = hoveredCrumb == crumb.url

        return Button {
            model.navigate(to: crumb.url)
        } label: {
            Text(crumb.title)
                .font(.system(size: 12.5, weight: isCurrent ? .medium : .regular))
                .lineLimit(1)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(backgroundColor(targeted: targeted, hovered: hovered))
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
        .foregroundStyle(isCurrent ? Color.primary : Color.secondary)
        .onHover { inside in
            if inside {
                hoveredCrumb = crumb.url
            } else if hoveredCrumb == crumb.url {
                hoveredCrumb = nil
            }
        }
        .help(crumb.url.path)
        .onDrop(of: [UTType.fileURL], isTargeted: targetedBinding(for: crumb.url)) { providers in
            DropSupport.loadURLs(from: providers) { urls in
                guard !urls.isEmpty else { return }
                model.drop(urls: urls, into: crumb.url, modifiers: NSEvent.modifierFlags)
            }
            return true
        }
    }

    /// 被折叠的中段：点开是下拉菜单，列出全部隐藏的段
    private func ellipsisButton(_ hidden: [Crumb]) -> some View {
        Menu {
            ForEach(hidden) { crumb in
                Button(crumb.title) {
                    model.navigate(to: crumb.url)
                }
            }
        } label: {
            Text("…")
                .font(.system(size: 12.5, weight: .medium))
                .lineLimit(1)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .foregroundStyle(Color.secondary)
        .help(hidden.map(\.url.path).joined(separator: "\n"))
    }

    private func backgroundColor(targeted: Bool, hovered: Bool) -> Color {
        if targeted { return Color.accentColor.opacity(0.18) }
        return hovered ? Color.primary.opacity(0.07) : Color.clear
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

    // MARK: - 折叠

    /// 一段面包屑在地址栏里的展示形态：普通段，或合并了若干个隐藏段的省略号
    private struct DisplayCrumb: Identifiable {
        enum Kind {
            case crumb(Crumb)
            case ellipsis([Crumb])
        }

        let id: String
        let kind: Kind
        let isCurrent: Bool
    }

    /// 段数超过 5 时折叠为「首段 › … › 末两段」，与 Win11 的处理一致。
    /// 阈值按段数而不是实测宽度：SwiftUI 里逐段量宽在窗口缩放时容易抖动，
    /// 而折叠掉的信息并没有丢——`…` 菜单里全都列着。
    private var displayCrumbs: [DisplayCrumb] {
        let crumbs = model.crumbs
        guard crumbs.count > 5 else {
            return crumbs.enumerated().map { offset, crumb in
                DisplayCrumb(
                    id: crumb.url.path,
                    kind: .crumb(crumb),
                    isCurrent: offset == crumbs.count - 1
                )
            }
        }

        var result = [DisplayCrumb(id: crumbs[0].url.path, kind: .crumb(crumbs[0]), isCurrent: false)]
        result.append(DisplayCrumb(
            id: "ellipsis",
            kind: .ellipsis(Array(crumbs[1..<(crumbs.count - 2)])),
            isCurrent: false
        ))
        let tail = crumbs.suffix(2)
        for (offset, crumb) in tail.enumerated() {
            result.append(DisplayCrumb(
                id: crumb.url.path,
                kind: .crumb(crumb),
                isCurrent: offset == tail.count - 1
            ))
        }
        return result
    }

    // MARK: - 编辑态

    /// 编辑态复用同一个容器：白底 + 强调色焦点环，不再套第二层圆角框
    private var editingBar: some View {
        HStack(spacing: 6) {
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

            if let error = model.pathError {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .layoutPriority(1)
            } else {
                Text(L("Tab 补全", "Tab to complete"))
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .fixedSize()
            }
        }
        .padding(.horizontal, 8)
        .frame(height: barHeight)
        .background {
            RoundedRectangle(cornerRadius: cornerRadius)
                .fill(Color(nsColor: .textBackgroundColor))
        }
        .overlay {
            RoundedRectangle(cornerRadius: cornerRadius)
                .stroke(model.pathError == nil ? Color.accentColor : Color.red, lineWidth: 1.5)
        }
    }

    // MARK: - 搜索框

    /// 右上角搜索框：只过滤当前文件夹，不递归。占位文案带上当前目录名（对齐 Win11）
    private var searchBox: some View {
        SearchField(
            text: model.searchText,
            focusToken: model.searchFocusRequest,
            placeholder: searchPlaceholder,
            onChange: { model.searchText = $0 },
            onSubmit: {
                // 回车确认搜索：焦点还回列表，方向键可以继续挑结果
                DispatchQueue.main.async { FocusKeeper.shared.reclaim(force: true) }
            },
            onCancel: {
                model.clearSearch()
                DispatchQueue.main.async { FocusKeeper.shared.reclaim(force: true) }
            }
        )
    }

    private var searchPlaceholder: String {
        let raw = model.crumbs.last?.title ?? model.titleText
        // 名字太长时先截断，避免搜索框里出现半截没省略号的文字
        let name = raw.count > 12 ? String(raw.prefix(11)) + "…" : raw
        return L("搜索 \(name)", "Search \(name)")
    }
}
