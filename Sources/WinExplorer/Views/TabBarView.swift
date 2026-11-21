import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// 标签栏（Windows 11 资源管理器那种），常驻显示并嵌入窗口工具栏最左侧：
/// 标签 chip + `+`（新建标签）永远可见，单标签也不例外。
///
/// 两种拖拽共用 chips：
/// - 拖 chip 本身 = 排序（text provider）
/// - 拖文件进来 = 传文件：悬停 0.6s 自动切到那个标签，松手落入其当前目录；
///   拖到 `+` 上 = 新建一个标签并直接放入（adr/0006）
struct TabBarView: View {
    @ObservedObject var tabs: TabsModel
    static let height: CGFloat = 34
    /// 梯形模式下标签条的总高（= 工具栏 item 的可用高度）。
    /// 唯一需要设置的尺寸：chip 高度、顶部呼吸、形状圆角/外撇全部由它派生
    static let trapezoidBarHeight: CGFloat = 52

    @State private var draggingID: UUID?
    /// 文件拖拽悬停的标签（蓝色描边反馈）
    @State private var fileDropTargetID: UUID?
    @State private var plusTargeted = false

    var body: some View {
        if TabCardStyle.current == .trapezoid {
            // 只设一个高度即可生效：顶部呼吸量按比例派生，chip 填满剩余高度、
            // 底部贴齐，宽度 / 斜边 / 形状比例全部自适应（adr/0009 修订）。
            // 注意不能依赖容器提案高度 —— 工具栏 item 连高度也只给理想值，
            // 必须自己把总高定下来，chip 内部的 maxHeight(.infinity) 才吃得满。
            bar
                .padding(.top, Self.trapezoidBarHeight * 0.1)
                .frame(height: Self.trapezoidBarHeight)
        } else {
            bar.frame(height: Self.height)
        }
    }

    private var bar: some View {
        HStack(spacing: 2) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(Array(tabs.tabs.enumerated()), id: \.element.id) { index, tab in
                        chip(tab: tab, index: index)
                    }
                }
                .padding(.horizontal, 6)
            }

            plusButton
                .padding(.trailing, 6)
        }
    }

    private func chip(tab: BrowserModel, index: Int) -> some View {
        // 注意：标签栏只观察 TabsModel，单个标签的目录变化（titleText/图标）
        // 必须由 TabChip 自己观察，否则标题会停在旧目录名上。
        TabChip(
            tab: tab,
            index: index,
            isActive: index == tabs.activeIndex,
            showsClose: tabs.count > 1,
            isFileDropTarget: fileDropTargetID == tab.id,
            onSelect: {
                tabs.select(index)
                DispatchQueue.main.async { FocusKeeper.shared.reclaim(force: true) }
            },
            onClose: { tabs.closeTab(at: index) }
        )
        .onDrag {
            draggingID = tab.id
            return NSItemProvider(object: tab.id.uuidString as NSString)
        }
        .onDrop(
            of: [UTType.text, UTType.fileURL],
            delegate: TabDropDelegate(
                targetID: tab.id,
                tabs: tabs,
                draggingID: $draggingID,
                fileDropTargetID: $fileDropTargetID
            )
        )
    }

    private var plusButton: some View {
        Button {
            tabs.newTab()
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 24, height: 22)
                .background {
                    RoundedRectangle(cornerRadius: 5)
                        .fill(Color.accentColor.opacity(plusTargeted ? 0.22 : 0))
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(plusTargeted ? Color.accentColor : Color.secondary)
        .help(L("新建标签页（⌘T）—— 把文件拖到这里会新建标签并放入", "New Tab (⌘T) — drop files here to open them in a new tab"))
        // 拖文件到 + 号：新建一个标签并直接放入（adr/0006）
        .onDrop(of: [UTType.fileURL], isTargeted: $plusTargeted) { providers in
            DropSupport.loadURLs(from: providers) { urls in
                tabs.receiveDropOnPlus(urls, modifiers: NSEvent.modifierFlags)
            }
            return true
        }
    }
}

/// 单个标签。单独成视图是为了让它观察自己那个 BrowserModel。
///
/// 视觉按 Windows 11 资源管理器的标签卡（adr/0009）：
/// - 激活：白色圆角卡片 + 细边框 + 轻投影，浮在工具栏底色上（深色模式自适应成深卡片）
/// - 未激活：透明（只剩图标 + 文字），悬停浮出浅色卡
/// - `×`：激活标签常显；未激活标签悬停才显示（槽位保留，不产生布局跳动）
/// - 拖文件悬停：accent 描边高亮（功能反馈，Win11 同样高亮目标标签）
private struct TabChip: View {
    @ObservedObject var tab: BrowserModel
    let index: Int
    let isActive: Bool
    let showsClose: Bool
    let isFileDropTarget: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    @State private var hovered = false

    var body: some View {
        HStack(spacing: 6) {
            Image(nsImage: IconProvider.shared.icon(for: tab.currentURL))
                .resizable()
                .frame(width: 15, height: 15)
                .opacity(isActive ? 1 : 0.75)

            Text(tab.titleText)
                .font(.system(size: 13, weight: isActive ? .medium : .regular))
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(isActive ? Color.primary : Color.secondary)
                .frame(maxWidth: 168, alignment: .leading)

            if showsClose {
                // 占位保留（否则悬停出现 × 时整卡宽度会跳），用透明度控制显隐
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .opacity(showsCloseButton ? 1 : 0)
                .help(L("关闭标签页（⌘W）", "Close Tab (⌘W)"))
            }
        }
        .padding(.horizontal, TabCardShape.horizontalPadding(for: .current))
        // 高度占满可用区域（容器给多少吃多少，不被压缩）：形状 rect = 卡片全高，
        // 底部脚贴齐容器底边 —— Win11 标签正是整条标签带高度、下方贴齐（adr/0009）
        .frame(maxHeight: .infinity)
        .background {
            TabCardShape()
                .fill(background)
        }
        .overlay {
            TabCardShape()
                .stroke(strokeColor, lineWidth: 1)
        }
        .compositingGroup()
        .shadow(
            color: .black.opacity(isActive && !isFileDropTarget ? 0.16 : 0),
            radius: 2, y: 1
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onHover { hovered = $0 }
        .help(tab.currentURL.path)
    }

    /// Win11 规则：激活常显 `×`，未激活悬停才显示
    private var showsCloseButton: Bool { isActive || hovered }

    private var background: Color {
        // 激活 = 标签卡：textBackgroundColor 在浅色模式是白、深色模式是深卡片底
        if isActive { return Color(nsColor: .textBackgroundColor) }
        if hovered { return Color.primary.opacity(0.06) }
        return Color.clear
    }

    private var strokeColor: Color {
        if isFileDropTarget { return Color.accentColor }
        if isActive { return Color.primary.opacity(0.10) }
        return .clear
    }
}

// MARK: - 标签卡形状

/// 标签卡的视觉风格：圆角卡片（默认）或 Win11 梯形切角（adr/0009 试验）。
/// 用 `WINEXPLORER_TAB_STYLE=card|trapezoid` 切换，供截图对比两种形态。
enum TabCardStyle {
    case card, trapezoid

    static let current: TabCardStyle = {
        ProcessInfo.processInfo.environment["WINEXPLORER_TAB_STYLE"] == "trapezoid"
            ? .trapezoid : .card
    }()
}

/// 标签卡轮廓：圆角矩形或 Win11 梯形切角。
///
/// 尺寸契约（adr/0009 修订）：
/// - **只由高度驱动**：所有圆角 / 凹圆角 / 外撇都按 `rect.height` 的固定比例
///   派生，任何尺寸下形状比例不变，不需要额外的宽度或尺寸参数；
/// - **宽度随容器**：竖边位置由宽度减去外撇量得出，窄容器自动收窄；
/// - **底部贴齐**：形状填满 rect 全高，底部脚落在 rect 底边上（高度占满可用
///   区域，特别是下方），高度不会被压缩。
///
/// Win11 的标签形状（`trapezoid`）：上边两个圆角，左右侧边垂直，
/// 到底部向外撇出一个脚，衔接处是一段**凹**圆角 —— 切点处切线分别
/// 与竖边、底边相切，正是 Win11 TabView 的 profile。
struct TabCardShape: Shape {
    /// 样式可显式指定（对比视图要同时渲染两种），默认跟随全局设置
    var style: TabCardStyle = .current

    /// 内容到卡边缘的左右留白：梯形需要给外撇的脚留出空间
    static func horizontalPadding(for style: TabCardStyle) -> CGFloat {
        style == .trapezoid ? 15 : 8
    }

    // 高度比例（来自 Win11 截图实测：顶圆角 ≈ 0.19h）——形状不变形的关键
    private static let topRadiusRatio: CGFloat = 0.18
    private static let filletRatio: CGFloat = 0.20
    private static let splayRatio: CGFloat = 0.18

    func path(in rect: CGRect) -> Path {
        let h = rect.height
        switch style {
        case .card:
            return RoundedRectangle(
                cornerRadius: h * Self.topRadiusRatio, style: .continuous
            ).path(in: rect)
        case .trapezoid:
            return trapezoidPath(in: rect)
        }
    }

    private func trapezoidPath(in rect: CGRect) -> Path {
        let h = rect.height
        let topRadius = h * Self.topRadiusRatio
        let fillet = h * Self.filletRatio
        // 外撇量同样按高度派生；窄容器时收窄，保证形状不自交
        let splay = min(h * Self.splayRatio, max(0, rect.width * 0.5 - topRadius))

        let minX = rect.minX, maxX = rect.maxX
        let minY = rect.minY, maxY = rect.maxY
        let left = minX + splay          // 左侧竖边
        let right = maxX - splay         // 右侧竖边
        let bottomFilletY = maxY - fillet

        var p = Path()
        // 顶边（左圆角 → 右圆角）
        p.move(to: CGPoint(x: left + topRadius, y: minY))
        p.addLine(to: CGPoint(x: right - topRadius, y: minY))
        p.addArc(
            center: CGPoint(x: right - topRadius, y: minY + topRadius),
            radius: topRadius,
            startAngle: .degrees(-90), endAngle: .degrees(0), clockwise: false
        )
        // 右侧竖边向下，到凹圆角起点
        p.addLine(to: CGPoint(x: right, y: bottomFilletY))
        // 凹圆角外撇到右脚（切线：竖 → 横）
        p.addQuadCurve(
            to: CGPoint(x: maxX, y: maxY),
            control: CGPoint(x: right, y: maxY)
        )
        // 底边（贴齐容器底）
        p.addLine(to: CGPoint(x: minX, y: maxY))
        // 左脚凹圆角收回竖边
        p.addQuadCurve(
            to: CGPoint(x: left, y: bottomFilletY),
            control: CGPoint(x: left, y: maxY)
        )
        // 左侧竖边向上，闭合到顶边左圆角
        p.addLine(to: CGPoint(x: left, y: minY + topRadius))
        p.addArc(
            center: CGPoint(x: left + topRadius, y: minY + topRadius),
            radius: topRadius,
            startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false
        )
        p.closeSubpath()
        return p
    }
}

/// 标签 chip 的落点委托：同时接住「拖 chip 排序」和「拖文件传文件」。
/// 两类拖拽用 provider 类型区分：chip 排序带 .text，文件带 .fileURL。
private struct TabDropDelegate: DropDelegate {
    let targetID: UUID
    let tabs: TabsModel
    @Binding var draggingID: UUID?
    @Binding var fileDropTargetID: UUID?

    private var isFileDrag: Bool { fileDropTargetID != nil }

    func dropEntered(info: DropInfo) {
        if info.hasItemsConforming(to: [UTType.fileURL.identifier]) {
            // 文件拖进来：点亮标签，0.6s 后自动切过去（松手前切换 = 落入它的目录）
            fileDropTargetID = targetID
            tabs.scheduleAutoSwitch(to: targetID)
            return
        }
        // 标签 chip 排序
        guard let draggingID,
              let from = tabs.tabs.firstIndex(where: { $0.id == draggingID }),
              let to = tabs.tabs.firstIndex(where: { $0.id == targetID }),
              from != to else { return }
        tabs.moveTab(from: from, to: to > from ? to + 1 : to)
    }

    func dropExited(info: DropInfo) {
        if fileDropTargetID == targetID {
            fileDropTargetID = nil
            tabs.cancelAutoSwitch()
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: isFileDrag ? .copy : .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        if isFileDrag {
            fileDropTargetID = nil
            tabs.cancelAutoSwitch()
            DropSupport.loadURLs(from: info.itemProviders(for: [.fileURL])) { urls in
                guard !urls.isEmpty else { return }
                let index = tabs.tabs.firstIndex(where: { $0.id == targetID })
                    ?? tabs.activeIndex
                tabs.receiveDrop(urls, intoTabAt: index, modifiers: NSEvent.modifierFlags)
            }
            draggingID = nil
            return true
        }
        draggingID = nil
        return true
    }
}
