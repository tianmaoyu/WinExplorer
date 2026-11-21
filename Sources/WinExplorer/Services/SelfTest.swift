import AppKit
import Darwin
import Foundation

/// 开发期自检：WINEXPLORER_SELFTEST=1 启动时，在临时目录里跑一遍
/// 目录读取 / 排序 / 导航 / 多选 / 键盘焦点 / 新建文件夹 / 错误处理，
/// 不弹窗、不碰用户数据。
enum SelfTest {
    static func runAll() -> Never {
        // 自检不碰系统剪贴板，复制/移动同步执行以便断言
        BrowserModel.syncsSystemPasteboard = false
        BrowserModel.runsTransfersSynchronously = true

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

        // MARK: 重命名与删除（全部限制在临时目录内，不碰任何用户文件）
        let work = root.appendingPathComponent("ops")
        try? fm.createDirectory(at: work, withIntermediateDirectories: false)
        fm.createFile(atPath: work.appendingPathComponent("草稿.txt").path,
                      contents: Data("x".utf8))
        fm.createFile(atPath: work.appendingPathComponent("已存在.txt").path,
                      contents: Data("y".utf8))
        let sentinel = root.appendingPathComponent("不要动我.txt")
        fm.createFile(atPath: sentinel.path, contents: Data("keep".utf8))

        model.navigate(to: work)
        check("进入操作测试目录", model.currentURL == work.standardizedFileURL)

        // 重命名成功
        if let draft = model.items.first(where: { $0.name == "草稿.txt" }) {
            model.focus(url: draft.url)
            model.beginRename()
            check("进入行内重命名", model.renamingURL?.lastPathComponent == "草稿.txt")
            let ok = model.commitRename("报告-最终.txt")
            check("重命名成功", ok && fm.fileExists(atPath: work.appendingPathComponent("报告-最终.txt").path))
            check("旧文件名已不存在", !fm.fileExists(atPath: work.appendingPathComponent("草稿.txt").path))
        } else {
            check("进入行内重命名", false, "找不到测试文件")
            check("重命名成功", false, "找不到测试文件")
            check("旧文件名已不存在", false, "找不到测试文件")
        }

        // 重名冲突：必须拒绝，且原文件不丢
        if let renamed = model.items.first(where: { $0.name == "报告-最终.txt" }) {
            model.beginRename(item: renamed)
            let conflict = model.commitRename("已存在.txt")
            check("重名被拒绝", !conflict)
            check("重名后原文件仍在",
                  fm.fileExists(atPath: work.appendingPathComponent("报告-最终.txt").path))
            check("重名后保持编辑态", model.renamingURL != nil)

            let illegal = model.commitRename("a/b.txt")
            check("含斜杠的名称被拒绝", !illegal)
            let empty = model.commitRename("   ")
            check("空名称被拒绝", !empty)
            model.cancelRename()
            check("取消重命名", model.renamingURL == nil)
        } else {
            check("重名被拒绝", false, "重命名未生效")
        }

        // 彻底删除：先确认，再执行
        let victim = work.appendingPathComponent("待删除.txt")
        fm.createFile(atPath: victim.path, contents: Data("z".utf8))
        model.reload()
        model.focus(url: victim)
        model.requestPermanentDelete()
        check("彻底删除需要二次确认", model.pendingPermanentDelete?.count == 1)
        check("确认前文件还在", fm.fileExists(atPath: victim.path))
        model.confirmPermanentDelete()
        check("确认后文件被删除", !fm.fileExists(atPath: victim.path))
        check("删除后清空待确认状态", model.pendingPermanentDelete == nil)
        check("临时目录外的文件未被触碰", fm.fileExists(atPath: sentinel.path))

        // MARK: 剪贴板：复制 / 剪切 / 粘贴
        let clipSrc = root.appendingPathComponent("剪贴板源")
        let clipDst = root.appendingPathComponent("剪贴板目标")
        try? fm.createDirectory(at: clipSrc, withIntermediateDirectories: false)
        try? fm.createDirectory(at: clipDst, withIntermediateDirectories: false)
        try? fm.createDirectory(at: clipSrc.appendingPathComponent("子目录"), withIntermediateDirectories: false)
        fm.createFile(atPath: clipSrc.appendingPathComponent("甲.txt").path, contents: Data("A".utf8))
        fm.createFile(atPath: clipSrc.appendingPathComponent("丙.txt").path, contents: Data("C".utf8))
        fm.createFile(atPath: clipSrc.appendingPathComponent("子目录/乙.txt").path, contents: Data("B".utf8))

        func text(_ url: URL) -> String {
            (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        }

        model.navigate(to: clipSrc)
        model.reload()
        check("同卷判定", TransferService.sameVolume(clipSrc, clipDst))

        // 复制 + 同目录粘贴 → 生成「副本」
        if let jia = model.items.first(where: { $0.name == "甲.txt" }) {
            model.focus(url: jia.url)
            model.copySelection()
            check("复制后可以粘贴", model.canPaste && model.clipboard?.mode == .copy)
            model.paste()
            let duplicated = clipSrc.appendingPathComponent("甲 副本.txt")
            check("同目录粘贴生成「副本」", fm.fileExists(atPath: duplicated.path))
            check("副本内容一致", text(duplicated) == "A", "实际 \(text(duplicated))")
            check("复制后剪贴板仍保留", model.clipboard?.mode == .copy)
            check("粘贴后选中新项目",
                  model.selection.contains {
                      $0.standardizedFileURL.path == duplicated.standardizedFileURL.path
                  },
                  "选中 \(model.selection.map(\.lastPathComponent))")

            model.paste()
            let second = clipSrc.appendingPathComponent("甲 副本 2.txt")
            check("再次粘贴编号递增", fm.fileExists(atPath: second.path))
        } else {
            check("同目录粘贴生成「副本」", false, "找不到甲.txt")
        }

        // 复制目录（连内容）
        if let dir = model.items.first(where: { $0.name == "子目录" }) {
            model.focus(url: dir.url)
            model.copySelection()
            model.paste()
            let copiedDir = clipSrc.appendingPathComponent("子目录 副本")
            check("复制文件夹", fm.fileExists(atPath: copiedDir.path, isDirectory: nil))
            check("文件夹内容一并复制",
                  text(copiedDir.appendingPathComponent("乙.txt")) == "B")
        } else {
            check("复制文件夹", false, "找不到子目录")
        }

        // 多选复制
        if let jia = model.items.first(where: { $0.name == "甲.txt" }),
           let bing = model.items.first(where: { $0.name == "丙.txt" }) {
            model.handleClick(on: jia, modifiers: [])
            model.handleClick(on: bing, modifiers: [.command])
            check("多选两项", model.selection.count == 2, "实际 \(model.selection.count)")
            model.copySelection()
            model.paste()
            check("多选粘贴各自生成副本",
                  fm.fileExists(atPath: clipSrc.appendingPathComponent("甲 副本 3.txt").path)
                    && fm.fileExists(atPath: clipSrc.appendingPathComponent("丙 副本.txt").path))
        }

        // 剪切 + 换目录粘贴 → 真正移动
        let moving = clipSrc.appendingPathComponent("待移动.txt")
        fm.createFile(atPath: moving.path, contents: Data("M".utf8))
        model.reload()
        if let item = model.items.first(where: { $0.name == "待移动.txt" }) {
            model.focus(url: item.url)
            model.cutSelection()
            check("剪切状态可识别", model.cutURLs.contains(item.url))
            model.navigate(to: clipDst)
            model.paste()
            check("剪切后源文件消失", !fm.fileExists(atPath: moving.path))
            check("粘贴后到达目标目录",
                  fm.fileExists(atPath: clipDst.appendingPathComponent("待移动.txt").path))
            check("剪切粘贴后清空剪贴板", model.clipboard == nil)
        } else {
            check("剪切后源文件消失", false, "找不到待移动.txt")
        }

        // 剪切遇到同名：整批拒绝，两边都不动
        let clashSrc = clipSrc.appendingPathComponent("冲突.txt")
        let clashDst = clipDst.appendingPathComponent("冲突.txt")
        fm.createFile(atPath: clashSrc.path, contents: Data("src".utf8))
        fm.createFile(atPath: clashDst.path, contents: Data("dst".utf8))
        model.navigate(to: clipSrc)
        if let item = model.items.first(where: { $0.name == "冲突.txt" }) {
            model.focus(url: item.url)
            model.cutSelection()
            model.navigate(to: clipDst)
            model.paste()
            check("同名剪切被拒绝", model.errorMessage != nil)
            check("冲突时目标文件未被覆盖", text(clashDst) == "dst", "实际 \(text(clashDst))")
            check("冲突时源文件仍在", fm.fileExists(atPath: clashSrc.path))
            model.dismissError()
        } else {
            check("同名剪切被拒绝", false, "找不到冲突.txt")
        }

        // 原地剪切粘贴：不产生副本
        model.navigate(to: clipSrc)
        model.reload()
        let beforeCount = model.items.count
        if let item = model.items.first(where: { $0.name == "丙.txt" }) {
            model.focus(url: item.url)
            model.cutSelection()
            model.paste()
            check("原地剪切粘贴不复制", model.items.count == beforeCount,
                  "\(beforeCount) → \(model.items.count)")
            check("原地剪切粘贴给出提示", model.flash != nil)
        }

        // 不能粘贴到自己的子目录
        let selfTarget = clipSrc.appendingPathComponent("子目录")
        if let dirItem = model.items.first(where: { $0.name == "子目录" }) {
            model.focus(url: dirItem.url)
            model.copySelection()
            model.paste(into: selfTarget)
            check("禁止把文件夹粘贴进自己", model.errorMessage != nil)
            check("禁止粘贴时不产生内容",
                  !fm.fileExists(atPath: selfTarget.appendingPathComponent("子目录 副本").path))
            model.dismissError()
        } else {
            check("禁止把文件夹粘贴进自己", false, "找不到子目录")
        }

        // 粘贴目标不是文件夹
        model.paste(into: clipSrc.appendingPathComponent("甲.txt"))
        check("目标是文件时拒绝粘贴", model.errorMessage != nil)
        model.dismissError()

        let before = model.currentURL
        model.navigate(to: root.appendingPathComponent("no-such-dir"))
        check("打不开的目录给出提示而不是崩溃",
              model.errorMessage != nil && model.currentURL == before)

        print(failures == 0 ? "SELFTEST OK" : "SELFTEST FAILED (\(failures) 项)")
        exit(failures == 0 ? 0 : 1)
    }
}
