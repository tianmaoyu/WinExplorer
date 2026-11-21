import SwiftUI

/// 菜单栏命令。快捷键和 Windows 习惯对齐：⌘[ / ⌘] 后退前进，⌘↑ 上一级。
struct ExplorerCommands: Commands {
    @ObservedObject var tabs: TabsModel

    /// 菜单永远作用于当前标签
    private var model: BrowserModel { tabs.active }

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button(L("关于 WinExplorer", "About WinExplorer")) {
                model.showAbout()
            }
        }

        CommandGroup(replacing: .undoRedo) {
            Button(model.undoTitle.map { "\(L("撤销", "Undo")) \($0)" } ?? L("撤销", "Undo")) {
                // 正在重命名时，⌘Z 应该撤销文字编辑
                if let editor = model.textEditor, let undoManager = editor.undoManager {
                    undoManager.undo()
                } else {
                    model.undo()
                }
            }
            .keyboardShortcut("z", modifiers: .command)
            .disabled(!model.canUndo)

            Button(model.redoTitle.map { "\(L("重做", "Redo")) \($0)" } ?? L("重做", "Redo")) {
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
            Button(L("新建标签页", "New Tab")) {
                tabs.newTab()
            }
            .keyboardShortcut("t", modifiers: .command)

            Button(L("关闭标签页", "Close Tab")) {
                tabs.closeActiveTab()
            }
            .keyboardShortcut("w", modifiers: .command)
            .disabled(tabs.count == 1)

            Divider()

            Button(L("新建文件夹", "New Folder")) {
                model.createFolder()
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])

            Button(L("打开", "Open")) {
                model.openSelection()
            }
            .keyboardShortcut("o", modifiers: .command)
            .disabled(!model.hasSelection)

            Button(L("显示简介", "Get Info")) {
                model.showInfo()
            }
            .keyboardShortcut("i", modifiers: .command)
            .disabled(!model.hasSelection)

            Button(L("快速预览", "Quick Look")) {
                model.toggleQuickLook()
            }
            .keyboardShortcut(.space, modifiers: [])
            .disabled(!model.hasSelection)

            Button(L("重命名…", "Rename…")) {
                model.beginRename()
            }
            .keyboardShortcut(KeyEquivalent("\u{F705}"), modifiers: [])
            .disabled(!model.hasSelection)

            Button(L("批量重命名…", "Batch Rename…")) {
                model.beginBatchRename()
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])
            .disabled(model.selection.count < 2)

            Divider()

            Button(L("压缩为 zip", "Compress to ZIP")) {
                model.compressSelection()
            }
            .disabled(!model.canCompress)

            Button(L("解压到同名文件夹", "Extract to Folder")) {
                model.extractSelection(toOwnFolder: true)
            }
            .disabled(!model.canExtract)

            Button(L("解压到当前文件夹", "Extract Here")) {
                model.extractSelection(toOwnFolder: false)
            }
            .disabled(!model.canExtract || model.selection.count != 1)

            Button(L("刷新", "Refresh")) {
                model.reload()
            }
            .keyboardShortcut("r", modifiers: .command)
        }

        // 用文件语义的"编辑"菜单替换系统剪贴板菜单：
        // 正在重命名时，动作交回给文本框，所以不会打断打字时的复制粘贴。
        CommandGroup(replacing: .pasteboard) {
            Button(L("剪切", "Cut")) {
                if let editor = model.textEditor { editor.cut(nil) } else { model.cutSelection() }
            }
            .keyboardShortcut("x", modifiers: .command)
            .disabled(model.textEditor == nil && !model.hasSelection)

            Button(L("复制", "Copy")) {
                if let editor = model.textEditor { editor.copy(nil) } else { model.copySelection() }
            }
            .keyboardShortcut("c", modifiers: .command)
            .disabled(model.textEditor == nil && !model.hasSelection)

            Button(L("粘贴", "Paste")) {
                if let editor = model.textEditor { editor.paste(nil) } else { model.paste() }
            }
            .keyboardShortcut("v", modifiers: .command)
            .disabled(model.textEditor == nil && (!model.canPaste || model.isTransferring))

            Divider()

            Button(L("复制路径", "Copy Path")) {
                model.copySelectedPaths()
            }
            .keyboardShortcut("c", modifiers: [.command, .option])
            .disabled(!model.hasSelection)

            Divider()

            Button(L("移到废纸篓", "Move to Trash")) {
                model.moveSelectionToTrash()
            }
            .keyboardShortcut(KeyEquivalent("\u{8}"), modifiers: .command)
            .disabled(!model.hasSelection)

            Button(L("彻底删除…", "Delete Immediately…")) {
                model.requestPermanentDelete()
            }
            .keyboardShortcut(KeyEquivalent("\u{8}"), modifiers: [.command, .shift])
            .disabled(!model.hasSelection)

            Divider()

            Button(L("全选", "Select All")) {
                if let editor = model.textEditor { editor.selectAll(nil) } else { model.selectAll() }
            }
            .keyboardShortcut("a", modifiers: .command)
            .disabled(model.textEditor == nil && model.items.isEmpty)
        }

        CommandMenu(L("视图", "View")) {
            Button(L("详细信息", "Details")) {
                model.viewMode = .details
            }
            .keyboardShortcut("1", modifiers: .command)

            Button(L("列表", "List")) {
                model.viewMode = .list
            }
            .keyboardShortcut("2", modifiers: .command)

            Button(L("图标", "Icons")) {
                model.viewMode = .icons
            }
            .keyboardShortcut("3", modifiers: .command)

            Divider()

            Button(L("自动调整列宽", "Size Columns to Fit")) {
                model.autoFitAllColumns()
            }
            .keyboardShortcut("0", modifiers: .command)
            .disabled(model.viewMode != .details)

            Toggle(L("显示隐藏文件", "Show Hidden Files"), isOn: Binding(
                get: { model.showHidden },
                set: { model.showHidden = $0 }
            ))
            .keyboardShortcut(".", modifiers: [.command, .shift])

            Toggle(L("计算文件夹大小", "Calculate Folder Sizes"), isOn: Binding(
                get: { model.showsFolderSizes },
                set: { model.showsFolderSizes = $0 }
            ))

            Divider()

            Toggle(L("菜单栏图标", "Menu Bar Icon"), isOn: Binding(
                get: { Preferences.showsMenuBarIcon },
                set: { value in
                    Preferences.showsMenuBarIcon = value
                    AppIntegration.apply()
                }
            ))

            Toggle(L("全局快捷键 ⌥⌘E", "Global Shortcut ⌥⌘E"), isOn: Binding(
                get: { Preferences.enablesGlobalHotKey },
                set: { value in
                    Preferences.enablesGlobalHotKey = value
                    AppIntegration.apply()
                }
            ))
        }

        CommandMenu(L("前往", "Go")) {
            Button(L("编辑地址栏…", "Edit Path…")) {
                model.beginPathEditing()
            }
            .keyboardShortcut("l", modifiers: .command)

            Button(L("搜索当前文件夹…", "Search This Folder…")) {
                model.beginSearch()
            }
            .keyboardShortcut("f", modifiers: .command)

            Divider()

            Button(L("下一个标签页", "Next Tab")) {
                tabs.selectNext(true)
            }
            .keyboardShortcut(.tab, modifiers: .control)
            .disabled(tabs.count == 1)

            Button(L("上一个标签页", "Previous Tab")) {
                tabs.selectNext(false)
            }
            .keyboardShortcut(.tab, modifiers: [.control, .shift])
            .disabled(tabs.count == 1)

            Button(L("添加到收藏夹", "Add to Favorites")) {
                model.addCurrentDirectoryToFavorites()
            }
            .disabled(model.isCurrentDirectoryFavorite)

            Divider()

            Button(L("后退", "Back")) {
                model.goBack()
            }
            .keyboardShortcut("[", modifiers: .command)
            .disabled(!model.canGoBack)

            Button(L("前进", "Forward")) {
                model.goForward()
            }
            .keyboardShortcut("]", modifiers: .command)
            .disabled(!model.canGoForward)

            Button(L("上一级", "Enclosing Folder")) {
                model.goUp()
            }
            .keyboardShortcut(.upArrow, modifiers: .command)
            .disabled(!model.canGoUp)

            Divider()

            Button(L("个人文件夹", "Home")) {
                model.goHome()
            }
            .keyboardShortcut("h", modifiers: [.command, .shift])

            Button(L("应用程序", "Applications")) {
                model.navigate(to: URL(fileURLWithPath: "/Applications"))
            }
        }
    }
}
