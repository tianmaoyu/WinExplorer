import AppKit
import SwiftUI

/// 行内重命名输入框：自动获得焦点，默认只选中主文件名（不含扩展名），
/// 回车提交、Esc 取消、失焦提交（与 Windows 资源管理器一致）。
struct RenameField: NSViewRepresentable {
    let text: String
    let selectionLength: Int
    let onCommit: (String) -> Bool
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onCommit: onCommit, onCancel: onCancel)
    }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(string: text)
        field.delegate = context.coordinator
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.backgroundColor = .clear
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 13)
        field.usesSingleLineMode = true
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        field.lineBreakMode = .byTruncatingMiddle

        context.coordinator.field = field
        context.coordinator.selectionLength = selectionLength

        DispatchQueue.main.async {
            guard let window = field.window else { return }
            window.makeFirstResponder(field)
            if let editor = field.currentEditor() {
                let length = min(selectionLength, (field.stringValue as NSString).length)
                editor.selectedRange = NSRange(location: 0, length: length)
            }
        }
        return field
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {}

    final class Coordinator: NSObject, NSTextFieldDelegate {
        private let onCommit: (String) -> Bool
        private let onCancel: () -> Void

        weak var field: NSTextField?
        var selectionLength: Int = 0
        private var finished = false

        init(onCommit: @escaping (String) -> Bool, onCancel: @escaping () -> Void) {
            self.onCommit = onCommit
            self.onCancel = onCancel
        }

        func controlTextDidEndEditing(_ obj: Notification) {
            guard !finished else { return }
            finished = true

            let movement = (obj.userInfo?["NSTextMovement"] as? Int)
                .flatMap(NSTextMovement.init(rawValue:))

            if movement == .cancel {
                onCancel()
                return
            }

            let newName = (obj.object as? NSTextField)?.stringValue ?? ""
            if onCommit(newName) {
                return
            }

            // 提交失败（重名/非法字符）：留在编辑态，把焦点还给输入框让用户继续改
            finished = false
            let length = selectionLength
            DispatchQueue.main.async { [weak self] in
                guard let self, let field = self.field, let window = field.window else { return }
                window.makeFirstResponder(field)
                if let editor = field.currentEditor() {
                    let textLength = (field.stringValue as NSString).length
                    editor.selectedRange = NSRange(location: 0, length: min(length, textLength))
                }
            }
        }
    }
}
