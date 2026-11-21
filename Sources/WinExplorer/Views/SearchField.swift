import AppKit
import SwiftUI

/// 地址栏右侧搜索框。
///
/// 容器与地址栏完全同一套（填充 / 描边 / 圆角 / 高度 / 聚焦环，见 adr/0001 与 0005）；
/// `NSSearchField` 本体只负责键盘行为（实时过滤、Esc 两次语义、⌘F 全选），
/// 外观全部由这里的 SwiftUI 容器接管 —— 系统 bezel 与地址栏并排时像两个时代的控件。
struct SearchBox: View {
    var text: String
    /// 变成新的 UUID 时把焦点抢到搜索框并全选（⌘F）
    var focusToken: UUID?
    var placeholder: String
    var cornerRadius: CGFloat
    var onChange: (String) -> Void
    var onSubmit: () -> Void
    var onCancel: () -> Void
    /// 聚焦 / 失焦（驱动焦点环与放大镜颜色；聚焦开始时顺带退出地址栏编辑态）
    var onEditingChange: (Bool) -> Void

    @State private var isEditing = false

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(isEditing ? Color.accentColor : Color.secondary)

            SearchField(
                text: text,
                focusToken: focusToken,
                placeholder: placeholder,
                onChange: onChange,
                onSubmit: onSubmit,
                onCancel: onCancel,
                onEditingChange: {
                    isEditing = $0
                    onEditingChange($0)
                }
            )

            if !text.isEmpty {
                // 点击清空：把空串发回 onChange，updateNSView 会同步到 field，
                // 焦点保持在搜索框里
                Button {
                    onChange("")
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(L("清除搜索词", "Clear search"))
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 8)
        .frame(maxHeight: .infinity)
        .background {
            RoundedRectangle(cornerRadius: cornerRadius)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.55))
        }
        .overlay {
            RoundedRectangle(cornerRadius: cornerRadius)
                .stroke(
                    isEditing ? Color.accentColor : Color.primary.opacity(0.09),
                    lineWidth: isEditing ? 1.5 : 1
                )
        }
        .animation(.easeOut(duration: 0.12), value: isEditing)
        .animation(.easeOut(duration: 0.12), value: text.isEmpty)
    }
}

/// 汇报焦点变化的搜索框本体。
///
/// 不能用 `controlTextDidBeginEditing` 判定聚焦：⌘F 或点击只是让 field 成为
/// first responder，**用户还没打字时编辑会话没开始**，那个回调不触发 ——
/// 实测焦点环就没出现。`becomeFirstResponder / resignFirstResponder`
/// 覆盖所有聚焦路径（⌘F、点击、Tab），且带去重。
private final class FocusReportingSearchField: NSSearchField {
    var onFocusChange: ((Bool) -> Void)?
    private var reportedFocus = false

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted, !reportedFocus {
            reportedFocus = true
            onFocusChange?(true)
        }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        if accepted, reportedFocus {
            reportedFocus = false
            onFocusChange?(false)
        }
        return accepted
    }
}

/// 无边框的搜索输入本体。占满容器给它的空间，字体与地址栏一致。
struct SearchField: NSViewRepresentable {
    var text: String
    var focusToken: UUID?
    var placeholder: String
    var onChange: (String) -> Void
    var onSubmit: () -> Void
    var onCancel: () -> Void
    var onEditingChange: (Bool) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSSearchField {
        let field = FocusReportingSearchField()
        field.onFocusChange = { [weak coordinator = context.coordinator] focused in
            coordinator?.parent.onEditingChange(focused)
        }
        field.delegate = context.coordinator
        field.placeholderString = placeholder
        field.sendsWholeSearchString = false
        field.sendsSearchStringImmediately = true
        // 字号与地址栏面包屑一致
        field.controlSize = .large
        field.font = .systemFont(ofSize: 12.5)
        // 外观全部交给 SwiftUI 容器（adr/0005）：无 bezel、无系统焦点环、
        // 隐藏系统放大镜与清除按钮（容器里自画）
        field.isBezeled = false
        field.drawsBackground = false
        field.isBordered = false
        field.focusRingType = .none
        if let cell = field.cell as? NSSearchFieldCell {
            cell.searchButtonCell = nil
            cell.cancelButtonCell = nil
        }
        field.stringValue = text
        context.coordinator.field = field
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text {
            field.stringValue = text
        }
        // 占位文案跟着当前目录名走（「搜索 下载」），切目录后要跟着换
        if field.placeholderString != placeholder {
            field.placeholderString = placeholder
        }
        if context.coordinator.lastFocusToken != focusToken, let token = focusToken {
            context.coordinator.lastFocusToken = token
            DispatchQueue.main.async {
                guard let window = field.window else { return }
                window.makeFirstResponder(field)
                field.currentEditor()?.selectAll(nil)
            }
        }
    }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var parent: SearchField
        weak var field: NSSearchField?
        var lastFocusToken: UUID?

        init(parent: SearchField) {
            self.parent = parent
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSSearchField else { return }
            parent.onChange(field.stringValue)
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            switch commandSelector {
            case #selector(NSResponder.cancelOperation(_:)):
                // 第一次 Esc 清空搜索词，再按一次才退出搜索回到列表
                if let field = control as? NSSearchField, !field.stringValue.isEmpty {
                    field.stringValue = ""
                    parent.onChange("")
                } else {
                    parent.onCancel()
                }
                return true
            case #selector(NSResponder.insertNewline(_:)):
                parent.onSubmit()
                return true
            default:
                return false
            }
        }
    }
}
