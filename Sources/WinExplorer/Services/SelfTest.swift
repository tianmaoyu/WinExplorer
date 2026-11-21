import AppKit
import Darwin
import Foundation

/// 开发期自检：WINEXPLORER_SELFTEST=1 启动时，在临时目录里跑一遍
/// 目录读取 / 排序 / 导航 / 多选 / 键盘焦点 / 新建文件夹 / 错误处理，
/// 不弹窗、不碰用户数据。
enum SelfTest {
    static func runAll() -> Never {
        var failures = 0

        func check(_ name: String, _ condition: Bool, _ detail: String = "") {
            if condition {
                print("PASS  \(name)")
            } else {
                failures += 1
                print("FAIL  \(name) \(detail)")
            }
        }

        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("winexplorer-selftest-\(UUID().uuidString)")
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        // 造测试数据：2 个文件夹 + 2 个不同大小的文件 + 1 个隐藏文件
        let folderA = root.appendingPathComponent("alpha")
        let folderB = root.appendingPathComponent("beta")
        try? fm.createDirectory(at: folderA, withIntermediateDirectories: false)
        try? fm.createDirectory(at: folderB, withIntermediateDirectories: false)
        fm.createFile(atPath: root.appendingPathComponent("small.txt").path,
                      contents: Data(repeating: 0, count: 10))
        fm.createFile(atPath: root.appendingPathComponent("big.bin").path,
                      contents: Data(repeating: 0, count: 5_000))
        fm.createFile(atPath: root.appendingPathComponent(".secret").path,
                      contents: Data(repeating: 0, count: 1))

        let model = BrowserModel(startAt: root)

        // MARK: 基础列表
        check("读取目录并过滤隐藏文件", model.items.count == 4, "实际 \(model.items.count) 项")
        check("文件夹优先", model.items.prefix(2).allSatisfy { $0.isDirectory })
        check("名称自然排序",
              Array(model.items.map(\.name).suffix(2)) == ["big.bin", "small.txt"],
              "实际 \(model.items.map(\.name))")
        check("文件夹不显示大小", model.items.prefix(2).allSatisfy { $0.sizeText == "—" })
        check("文件类型不是文件夹", model.items.first { $0.name == "small.txt" }?.kind != "文件夹")

        model.showHidden = true
        check("显示隐藏文件", model.items.contains { $0.name == ".secret" })
        model.showHidden = false

        model.sortColumn = .size
        model.sortAscending = false
        check("按大小降序", model.items.first(where: { !$0.isDirectory })?.name == "big.bin")
        model.sortColumn = .name
        model.sortAscending = true

        // MARK: 多选
        let first = model.items[0]
        let second = model.items[1]
        let third = model.items[2]

        model.handleClick(on: first, modifiers: [])
        check("单击单选", model.selection == [first.url], "实际 \(model.selection.count) 项")

        model.handleClick(on: second, modifiers: [.command])
        check("⌘ 点击加选", model.selection == [first.url, second.url])

        model.handleClick(on: second, modifiers: [.command])
        check("⌘ 再点取消该项", model.selection == [first.url])

        // ⌘ 点击会移动锚点，之后 Shift 从新锚点开始连选（与 Windows 一致）
        model.handleClick(on: second, modifiers: [.command])
        model.handleClick(on: third, modifiers: [.shift])
        check("Shift 从最近一次点击连选", model.selection.count == 2 && model.selection.contains(third.url),
              "实际 \(model.selection.count) 项")

        model.clearSelection()
        model.handleClick(on: first, modifiers: [])
        model.handleClick(on: third, modifiers: [.shift])
        check("Shift 从锚点连选三项", model.selection.count == 3,
              "实际 \(model.selection.count) 项")

        model.selectAll()
        check("⌘A 全选", model.selection.count == model.items.count)
        check("全选后统计总大小", model.selectedTotalSize == 5_010,
              "实际 \(model.selectedTotalSize)")

        model.clearSelection()
        check("清空选择", model.selection.isEmpty && model.focusedURL == nil)

        // MARK: 键盘焦点
        model.moveFocus(by: 1)
        check("↓ 从无选中开始落到第一项", model.focusedURL == model.items[0].url)
        model.moveFocus(by: 1)
        check("再按 ↓ 前进一项", model.focusedURL == model.items[1].url)
        check("键盘移动带滚动请求", model.scrollRequest?.url == model.items[1].url)

        model.moveFocus(by: 12)
        check("↓ 越界不飞出列表", model.focusedURL == model.items.last?.url)

        model.moveFocus(by: -1)
        check("↑ 退回上一项", model.focusedURL == model.items[model.items.count - 2].url)

        model.focusEdge(first: true)
        check("Home 到首项", model.focusedURL == model.items.first?.url)
        model.focusEdge(first: false)
        check("End 到末项", model.focusedURL == model.items.last?.url)

        model.moveFocus(by: -1)
        check("键盘选择只选一项", model.selection.count == 1)

        // MARK: 导航
        model.navigate(to: folderA)
        check("进入子目录",
              model.currentURL == folderA.standardizedFileURL && model.items.isEmpty,
              "currentURL=\(model.currentURL.path)")
        check("进入目录后清空选择", model.selection.isEmpty && model.focusedURL == nil)
        check("记录后退栈", model.canGoBack)

        model.goBack()
        check("后退回根目录",
              model.currentURL == root.standardizedFileURL && model.canGoForward)
        model.goForward()
        check("前进到子目录", model.currentURL == folderA.standardizedFileURL)
        model.goUp()
        check("上一级", model.currentURL == root.standardizedFileURL)

        // MARK: 新建与错误
        model.createFolder()
        check("新建文件夹", fm.fileExists(atPath: root.appendingPathComponent("新建文件夹").path))
        model.createFolder()
        check("重名自动编号", fm.fileExists(atPath: root.appendingPathComponent("新建文件夹 2").path))
        check("新建后选中并聚焦",
              model.selection.count == 1
                && model.focusedURL?.lastPathComponent == "新建文件夹 2",
              "选中 \(model.selection.count) 项，焦点 \(model.focusedURL?.lastPathComponent ?? "nil")")

        let before = model.currentURL
        model.navigate(to: root.appendingPathComponent("no-such-dir"))
        check("打不开的目录给出提示而不是崩溃",
              model.errorMessage != nil && model.currentURL == before)

        print(failures == 0 ? "SELFTEST OK" : "SELFTEST FAILED (\(failures) 项)")
        exit(failures == 0 ? 0 : 1)
    }
}
