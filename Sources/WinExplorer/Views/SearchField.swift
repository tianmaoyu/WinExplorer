import AppKit
import SwiftUI

/// 地址栏右侧的搜索框。用 NSSearchField 拿到系统自带的放大镜与清除按钮，
/// 打字时实时过滤当前目录（`controlTextDidChange`）。
struct SearchField: NSViewRepresentable {
    var text: String
    /// 变成新的 UUID 时把焦点抢到搜索框并全选（⌘F）
    var focusToken: UUID?
    var placeholder: String = "搜索"
    var onChange: (String) -> Void
    var onSubmit: () -> Void
    var onCancel: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.delegate = context.coordinator
        field.placeholderString = placeholder
        field.sendsWholeSearchString = false
        field.sendsSearchStringImmediately = true
        field.controlSize = .small
        field.font = .systemFont(ofSize: 12)
        field.bezelStyle = .roundedBezel
        field.focusRingType = .default
        field.stringValue = text
        // 空的时候完全透明，不抢面包屑的视觉重心
        field.alphaValue = 1
        context.coordinator.field = field
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text {
            field.stringValue = text
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
