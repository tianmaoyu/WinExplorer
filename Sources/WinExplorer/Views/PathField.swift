import AppKit
import SwiftUI

/// 地址栏输入框：自动获得焦点并全选当前路径。
/// Enter 提交、Esc 取消、Tab 补全（补全后的文本由 onComplete 算出来）。
struct PathField: NSViewRepresentable {
    let text: String
    /// 返回 false 表示不接受这次提交（路径不存在），此时保持编辑态
    let onCommit: (String) -> Bool
    let onCancel: () -> Void
    /// 返回补全后的完整文本，nil 表示没有可补全的内容
    let onComplete: (String) -> String?

    func makeCoordinator() -> Coordinator {
        Coordinator(onCommit: onCommit, onCancel: onCancel, onComplete: onComplete)
    }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(string: text)
        field.delegate = context.coordinator
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.backgroundColor = .clear
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 12.5)
        field.usesSingleLineMode = true
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        field.lineBreakMode = .byTruncatingMiddle

        context.coordinator.field = field

        DispatchQueue.main.async {
            guard let window = field.window else { return }
            window.makeFirstResponder(field)
            if let editor = field.currentEditor() {
                editor.selectedRange = NSRange(location: 0, length: (field.stringValue as NSString).length)
            }
        }
        return field
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {}

    final class Coordinator: NSObject, NSTextFieldDelegate {
        private let onCommit: (String) -> Bool
        private let onCancel: () -> Void
        private let onComplete: (String) -> String?

        weak var field: NSTextField?
        private var finished = false

        init(
            onCommit: @escaping (String) -> Bool,
            onCancel: @escaping () -> Void,
            onComplete: @escaping (String) -> String?
        ) {
            self.onCommit = onCommit
            self.onCancel = onCancel
            self.onComplete = onComplete
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            // Tab = 补全
            if commandSelector == #selector(NSResponder.insertTab(_:)) {
                if let completed = onComplete(textView.string) {
                    field?.stringValue = completed
                    textView.string = completed
                    textView.setSelectedRange(NSRange(location: (completed as NSString).length, length: 0))
                } else {
                    NSSound.beep()
                }
                return true
            }

            // Esc = 取消编辑
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                guard !finished else { return true }
                finished = true
                onCancel()
                return true
            }

            return false
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

            let text = (obj.object as? NSTextField)?.stringValue ?? ""
            if onCommit(text) {
                return
            }

            // 路径不合法：留在编辑态，把焦点还回输入框
            finished = false
            DispatchQueue.main.async { [weak self] in
                guard let self, let field = self.field, let window = field.window else { return }
                window.makeFirstResponder(field)
                field.currentEditor()?.selectedRange = NSRange(
                    location: (field.stringValue as NSString).length,
                    length: 0
                )
            }
        }
    }
}
