import SwiftUI

/// 菜单栏命令。快捷键和 Windows 习惯对齐：⌘[ / ⌘] 后退前进，⌘↑ 上一级。
struct ExplorerCommands: Commands {
    @ObservedObject var model: BrowserModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("新建文件夹") {
                model.createFolder()
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])

            Button("刷新") {
                model.reload()
            }
            .keyboardShortcut("r", modifiers: .command)

            Button("打开") {
                model.openSelection()
            }
            .keyboardShortcut("o", modifiers: .command)
            .disabled(!model.hasSelection)
        }

        CommandMenu("前往") {
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

        CommandGroup(after: .sidebar) {
            Toggle("显示隐藏文件", isOn: $model.showHidden)
                .keyboardShortcut(".", modifiers: [.command, .shift])
        }
    }
}
