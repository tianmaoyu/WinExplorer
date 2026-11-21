import SwiftUI

/// 菜单栏命令。快捷键和 Windows 习惯对齐：⌘[ / ⌘] 后退前进，⌘↑ 上一级。
struct ExplorerCommands: Commands {
    @ObservedObject var tabs: TabsModel

    /// 菜单永远作用于当前标签
    private var model: BrowserModel { tabs.active }

    var body: some Commands {
        CommandGroup(replacing: .undoRedo) {
            Button(model.undoTitle.map { "撤销\($0)" } ?? "撤销") {
                // 正在重命名时，⌘Z 应该撤销文字编辑
                if let editor = model.textEditor, let undoManager = editor.undoManager {
                    undoManager.undo()
                } else {
                    model.undo()
                }
            }
            .keyboardShortcut("z", modifiers: .command)
            .disabled(!model.canUndo)

            Button(model.redoTitle.map { "重做\($0)" } ?? "重做") {
                if let editor = model.textEditor, let undoManager = editor.undoManager {
                    undoManager.redo()
                } else {
                    model.redo()
                }
            }
            .keyboardShortcut("z", modifiers: [.command, .shift])
            .disabled(!model.canRedo)
        }

        CommandGroup(replacing: .newItem) {
            Button("新建标签页") {
                tabs.newTab()
            }
            .keyboardShortcut("t", modifiers: .command)

            Button("关闭标签页") {
                tabs.closeActiveTab()
            }
            .keyboardShortcut("w", modifiers: .command)
            .disabled(tabs.count == 1)

            Divider()

            Button("新建文件夹") {
                model.createFolder()
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])

            Button("打开") {
                model.openSelection()
            }
            .keyboardShortcut("o", modifiers: .command)
            .disabled(!model.hasSelection)

            Button("显示简介") {
                model.showInfo()
            }
            .keyboardShortcut("i", modifiers: .command)
            .disabled(!model.hasSelection)

            Button("快速预览") {
                model.toggleQuickLook()
            }
            .keyboardShortcut(.space, modifiers: [])
            .disabled(!model.hasSelection)

            Button("重命名…") {
                model.beginRename()
            }
            .keyboardShortcut(KeyEquivalent("\u{F705}"), modifiers: [])
            .disabled(model.selection.count != 1)

            Button("刷新") {
                model.reload()
            }
            .keyboardShortcut("r", modifiers: .command)
        }

        // 用文件语义的"编辑"菜单替换系统剪贴板菜单：
        // 正在重命名时，动作交回给文本框，所以不会打断打字时的复制粘贴。
        CommandGroup(replacing: .pasteboard) {
            Button("剪切") {
                if let editor = model.textEditor { editor.cut(nil) } else { model.cutSelection() }
            }
            .keyboardShortcut("x", modifiers: .command)
            .disabled(model.textEditor == nil && !model.hasSelection)

            Button("复制") {
                if let editor = model.textEditor { editor.copy(nil) } else { model.copySelection() }
            }
            .keyboardShortcut("c", modifiers: .command)
            .disabled(model.textEditor == nil && !model.hasSelection)

            Button("粘贴") {
                if let editor = model.textEditor { editor.paste(nil) } else { model.paste() }
            }
            .keyboardShortcut("v", modifiers: .command)
            .disabled(model.textEditor == nil && (!model.canPaste || model.isTransferring))

            Divider()

            Button("复制路径") {
                model.copySelectedPaths()
            }
            .keyboardShortcut("c", modifiers: [.command, .option])
            .disabled(!model.hasSelection)

            Divider()

            Button("移到废纸篓") {
                model.moveSelectionToTrash()
            }
            .keyboardShortcut(KeyEquivalent("\u{8}"), modifiers: .command)
            .disabled(!model.hasSelection)

            Button("彻底删除…") {
                model.requestPermanentDelete()
            }
            .keyboardShortcut(KeyEquivalent("\u{8}"), modifiers: [.command, .shift])
            .disabled(!model.hasSelection)

            Divider()

            Button("全选") {
                if let editor = model.textEditor { editor.selectAll(nil) } else { model.selectAll() }
            }
            .keyboardShortcut("a", modifiers: .command)
            .disabled(model.textEditor == nil && model.items.isEmpty)
        }

        CommandMenu("视图") {
            Button("详细信息") {
                model.viewMode = .details
            }
            .keyboardShortcut("1", modifiers: .command)

            Button("列表") {
                model.viewMode = .list
            }
            .keyboardShortcut("2", modifiers: .command)

            Button("图标") {
                model.viewMode = .icons
            }
            .keyboardShortcut("3", modifiers: .command)

            Divider()

            Button("自动调整列宽") {
                model.autoFitAllColumns()
            }
            .keyboardShortcut("0", modifiers: .command)
            .disabled(model.viewMode != .details)

            Toggle("显示隐藏文件", isOn: Binding(
                get: { model.showHidden },
                set: { model.showHidden = $0 }
            ))
            .keyboardShortcut(".", modifiers: [.command, .shift])
        }

        CommandMenu("前往") {
            Button("编辑地址栏…") {
                model.beginPathEditing()
            }
            .keyboardShortcut("l", modifiers: .command)

            Button("搜索当前文件夹…") {
                model.beginSearch()
            }
            .keyboardShortcut("f", modifiers: .command)

            Divider()

            Button("下一个标签页") {
                tabs.selectNext(true)
            }
            .keyboardShortcut(.tab, modifiers: .control)
            .disabled(tabs.count == 1)

            Button("上一个标签页") {
                tabs.selectNext(false)
            }
            .keyboardShortcut(.tab, modifiers: [.control, .shift])
            .disabled(tabs.count == 1)

            Button("添加到收藏夹") {
                model.addCurrentDirectoryToFavorites()
            }
            .disabled(model.isCurrentDirectoryFavorite)

            Divider()

            Button("后退") {
                model.goBack()
            }
            .keyboardShortcut("[", modifiers: .command)
            .disabled(!model.canGoBack)

            Button("前进") {
                model.goForward()
            }
            .keyboardShortcut("]", modifiers: .command)
            .disabled(!model.canGoForward)

            Button("上一级") {
                model.goUp()
            }
            .keyboardShortcut(.upArrow, modifiers: .command)
            .disabled(!model.canGoUp)

            Divider()

            Button("个人文件夹") {
                model.goHome()
            }
            .keyboardShortcut("h", modifiers: [.command, .shift])

            Button("应用程序") {
                model.navigate(to: URL(fileURLWithPath: "/Applications"))
            }
        }
    }
}
