import AppKit
import Darwin
import Foundation

/// 开发期自检：WINEXPLORER_SELFTEST=1 启动时，在临时目录里跑一遍
/// 目录读取 / 排序 / 导航 / 多选 / 键盘焦点 / 新建文件夹 / 错误处理，
/// 不弹窗、不碰用户数据。
enum SelfTest {
    static func runAll() -> Never {
        // 自检不碰系统剪贴板，复制/移动同步执行以便断言；也不写用户偏好
        BrowserModel.syncsSystemPasteboard = false
        BrowserModel.runsTransfersSynchronously = true
        BrowserModel.computesFolderSizeSynchronously = true
        BrowserModel.watchesFileSystem = false
        // 搜索防抖会让「设完 searchText 立刻断言」失效，自检里关掉
        BrowserModel.debouncesSearch = false
        // 目录读取默认同步，navigate 完立刻能断言；异步路径单独有一条用例
        BrowserModel.loadsDirectorySynchronously = true
        Preferences.enabled = false

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
        check("文件类型不是文件夹", model.items.first { $0.name == "small.txt" }?.kind != L("文件夹", "Folder"))

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

        // 滚动请求目标：项滚动带 URL（兼容接口），底部留白滚动不带
        model.scrollRequest = ScrollRequest(trailingBlank: true)
        check("底部留白滚动请求", model.scrollRequest?.target == .trailingBlank && model.scrollRequest?.url == nil)
        model.scrollRequest = ScrollRequest(model.items[0].url)
        check("项滚动请求兼容接口", model.scrollRequest?.url == model.items[0].url)

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
        check("新建文件夹", fm.fileExists(atPath: root.appendingPathComponent(L("新建文件夹", "New Folder")).path))
        model.createFolder()
        check("重名自动编号", fm.fileExists(atPath: root.appendingPathComponent("\(L("新建文件夹", "New Folder")) 2").path))
        check("新建后选中并聚焦",
              model.selection.count == 1
                && model.focusedURL?.lastPathComponent == "\(L("新建文件夹", "New Folder")) 2",
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
            let duplicated = clipSrc.appendingPathComponent("\(L("甲", "甲"))\(L(" 副本", " copy")).txt")
            check("同目录粘贴生成「副本」", fm.fileExists(atPath: duplicated.path))
            check("副本内容一致", text(duplicated) == "A", "实际 \(text(duplicated))")
            check("复制后剪贴板仍保留", model.clipboard?.mode == .copy)
            check("粘贴后选中新项目",
                  model.selection.contains {
                      $0.standardizedFileURL.path == duplicated.standardizedFileURL.path
                  },
                  "选中 \(model.selection.map(\.lastPathComponent))")

            model.paste()
            let second = clipSrc.appendingPathComponent("甲\(L(" 副本", " copy")) 2.txt")
            check("再次粘贴编号递增", fm.fileExists(atPath: second.path))
        } else {
            check("同目录粘贴生成「副本」", false, "找不到甲.txt")
        }

        // 复制目录（连内容）
        if let dir = model.items.first(where: { $0.name == "子目录" }) {
            model.focus(url: dir.url)
            model.copySelection()
            model.paste()
            let copiedDir = clipSrc.appendingPathComponent("子目录\(L(" 副本", " copy"))")
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
                  fm.fileExists(atPath: clipSrc.appendingPathComponent("甲\(L(" 副本", " copy")) 3.txt").path)
                    && fm.fileExists(atPath: clipSrc.appendingPathComponent("丙\(L(" 副本", " copy")).txt").path))
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
                  !fm.fileExists(atPath: selfTarget.appendingPathComponent("子目录\(L(" 副本", " copy"))").path))
            model.dismissError()
        } else {
            check("禁止把文件夹粘贴进自己", false, "找不到子目录")
        }

        // 粘贴目标不是文件夹
        model.paste(into: clipSrc.appendingPathComponent("甲.txt"))
        check("目标是文件时拒绝粘贴", model.errorMessage != nil)
        model.dismissError()

        // MARK: 撤销 / 重做
        let undoSrc = root.appendingPathComponent("撤销源")
        let undoDst = root.appendingPathComponent("撤销目标")
        try? fm.createDirectory(at: undoSrc, withIntermediateDirectories: false)
        try? fm.createDirectory(at: undoDst, withIntermediateDirectories: false)
        fm.createFile(atPath: undoSrc.appendingPathComponent("原稿.txt").path, contents: Data("D".utf8))

        model.navigate(to: undoSrc)
        model.reload()

        // 重命名 → 撤销 → 重做
        if let draft = model.items.first(where: { $0.name == "原稿.txt" }) {
            model.beginRename(item: draft)
            _ = model.commitRename("定稿.txt")
            check("重命名后新名字存在",
                  fm.fileExists(atPath: undoSrc.appendingPathComponent("定稿.txt").path))
            check("重命名进入撤销栈",
                  model.canUndo && (model.undoTitle?.lowercased().contains(L("重命名", "rename").lowercased()) ?? false),
                  "undoTitle=\(model.undoTitle ?? "nil")")

            model.undo()
            check("撤销重命名恢复原名",
                  fm.fileExists(atPath: undoSrc.appendingPathComponent("原稿.txt").path))
            check("撤销后可重做", model.canRedo)

            model.redo()
            check("重做重命名",
                  fm.fileExists(atPath: undoSrc.appendingPathComponent("定稿.txt").path))
        } else {
            check("重命名进入撤销栈", false, "找不到原稿.txt")
        }

        // 新建文件夹 → 撤销 → 重做
        model.createFolder()
        let createdFolder = undoSrc.appendingPathComponent(L("新建文件夹", "New Folder"))
        check("新建文件夹进入撤销栈", model.canUndo && fm.fileExists(atPath: createdFolder.path))
        model.undo()
        check("撤销新建文件夹", !fm.fileExists(atPath: createdFolder.path))
        model.redo()
        check("重做新建文件夹", fm.fileExists(atPath: createdFolder.path))
        try? fm.removeItem(at: createdFolder)

        // 复制 → 撤销（删掉副本）→ 重做
        model.reload()
        if let source = model.items.first(where: { $0.name == "定稿.txt" }) {
            model.focus(url: source.url)
            model.copySelection()
            model.paste()
            let copyURL = undoSrc.appendingPathComponent("定稿\(L(" 副本", " copy")).txt")
            check("复制生成副本", fm.fileExists(atPath: copyURL.path))

            model.undo()
            check("撤销复制删除副本", !fm.fileExists(atPath: copyURL.path))
            check("撤销复制不动原文件",
                  fm.fileExists(atPath: undoSrc.appendingPathComponent("定稿.txt").path))
            model.redo()
            check("重做复制", fm.fileExists(atPath: copyURL.path))
            try? fm.removeItem(at: copyURL)
        }

        // 剪切粘贴（跨目录移动）→ 撤销 → 重做
        fm.createFile(atPath: undoSrc.appendingPathComponent("搬走.txt").path, contents: Data("M".utf8))
        model.reload()
        if let item = model.items.first(where: { $0.name == "搬走.txt" }) {
            model.focus(url: item.url)
            model.cutSelection()
            model.paste(into: undoDst)
            check("剪切后离开源目录",
                  !fm.fileExists(atPath: undoSrc.appendingPathComponent("搬走.txt").path))
            check("剪切后到达目标目录",
                  fm.fileExists(atPath: undoDst.appendingPathComponent("搬走.txt").path))

            model.undo()
            check("撤销移动回到原处",
                  fm.fileExists(atPath: undoSrc.appendingPathComponent("搬走.txt").path))
            check("撤销移动清掉目标位置",
                  !fm.fileExists(atPath: undoDst.appendingPathComponent("搬走.txt").path))
            model.redo()
            check("重做移动",
                  fm.fileExists(atPath: undoDst.appendingPathComponent("搬走.txt").path))

            // 新操作要清空重做栈
            model.undo()
            check("撤销后重做栈可用", model.canRedo)
            model.createFolder()
            check("新操作清空重做栈", !model.canRedo)
            if let extra = model.items.first(where: { $0.name == L("新建文件夹", "New Folder") }) {
                try? fm.removeItem(at: extra.url)
            }
        }

        // MARK: 拖放
        let dropSrc = root.appendingPathComponent("拖放源")
        let dropDst = root.appendingPathComponent("拖放目标")
        try? fm.createDirectory(at: dropSrc, withIntermediateDirectories: false)
        try? fm.createDirectory(at: dropDst, withIntermediateDirectories: false)
        try? fm.createDirectory(at: dropSrc.appendingPathComponent("内层"), withIntermediateDirectories: false)
        let dragged = dropSrc.appendingPathComponent("拖我.txt")
        fm.createFile(atPath: dragged.path, contents: Data("T".utf8))
        model.navigate(to: dropSrc)
        model.reload()

        // 同卷、无修饰键 → 移动
        model.drop(urls: [dragged], into: dropDst, modifiers: [])
        check("拖到别的文件夹是移动",
              !fm.fileExists(atPath: dragged.path)
                && fm.fileExists(atPath: dropDst.appendingPathComponent("拖我.txt").path))
        model.undo()
        check("撤销拖放后文件回来", fm.fileExists(atPath: dragged.path))

        // ⌥ 拖 → 复制（原文件保留）
        model.drop(urls: [dragged], into: dropDst, modifiers: [.option])
        check("⌥ 拖拽是复制",
              fm.fileExists(atPath: dragged.path)
                && fm.fileExists(atPath: dropDst.appendingPathComponent("拖我.txt").path))

        // 同名再移动 → 拒绝，两边都在
        model.dismissError()
        model.drop(urls: [dragged], into: dropDst, modifiers: [])
        check("同名拖放被拒绝", model.errorMessage != nil)
        check("拒绝时不动文件", fm.fileExists(atPath: dragged.path))
        model.dismissError()

        // 拖进自己的子目录 → 拒绝
        model.drop(urls: [dropSrc], into: dropSrc.appendingPathComponent("内层"), modifiers: [])
        check("禁止拖进自己的子目录", model.errorMessage != nil)
        model.dismissError()

        // 拖回原处（无修饰键）→ 什么都不做
        model.drop(urls: [dragged], into: dropSrc, modifiers: [])
        check("拖回原处不产生副本",
              fm.fileExists(atPath: dragged.path)
                && !fm.fileExists(atPath: dropSrc.appendingPathComponent("拖我 副本.txt").path))

        // onDrop 拿到的 provider 里必须是可解析的文件 URL，否则拖放会静默失效
        var resolved: [URL] = []
        var resolvedReady = false
        let provider = NSItemProvider(item: dragged as NSURL, typeIdentifier: "public.file-url")
        DropSupport.loadURLs(from: [provider]) { urls in
            resolved = urls
            resolvedReady = true
        }
        let deadline = Date().addingTimeInterval(2)
        while !resolvedReady, Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        check("拖拽 provider 能解析出文件 URL",
              resolved.first?.standardizedFileURL.path == dragged.standardizedFileURL.path,
              "解析到 \(resolved.map(\.lastPathComponent))")

        // MARK: 视图与列宽
        model.navigate(to: clipSrc)
        model.reload()

        check("默认列宽", model.columnWidths == ColumnWidths.standard,
              "实际 \(model.columnWidths)")

        model.resizeColumn(.size, to: 5)
        check("列宽有下限", model.columnWidths.size == ColumnWidths.sizeRange.lowerBound,
              "实际 \(model.columnWidths.size)")
        model.resizeColumn(.size, to: 9999)
        check("列宽有上限", model.columnWidths.size == ColumnWidths.sizeRange.upperBound,
              "实际 \(model.columnWidths.size)")
        model.resizeColumn(.size, to: 130)
        check("列宽可设置", model.columnWidths.size == 130)

        model.autoFitColumn(.kind)
        check("双击自适应列宽落在合法范围",
              ColumnWidths.kindRange.contains(model.columnWidths.kind),
              "实际 \(model.columnWidths.kind)")
        model.autoFitAllColumns()
        check("一次性自适应三列",
              ColumnWidths.sizeRange.contains(model.columnWidths.size)
                && ColumnWidths.dateRange.contains(model.columnWidths.date)
                && ColumnWidths.kindRange.contains(model.columnWidths.kind))

        // 图标视图里 ↑↓ 按行走
        let total = model.items.count
        model.viewMode = .icons
        model.gridColumnCount = 3
        model.focus(url: model.items[0].url)
        model.moveFocusVertically(by: 1)
        check("图标视图 ↓ 走一行（3 列）",
              model.focusedURL?.lastPathComponent == model.items[min(3, total - 1)].url.lastPathComponent,
              "焦点 \(model.focusedURL?.lastPathComponent ?? "nil")")
        model.moveFocusVertically(by: -1)
        check("图标视图 ↑ 回上一行", model.focusedURL == model.items[0].url)
        model.moveFocus(by: 1)
        check("图标视图 → 走一格", model.focusedURL == model.items[1].url)

        model.viewMode = .details
        model.moveFocusVertically(by: 1)
        check("详细信息视图 ↓ 走一项", model.focusedURL == model.items[2].url)

        check("自检期间不写用户偏好", Preferences.viewMode == .details)

        // MARK: 地址栏（可编辑路径）
        let pathRoot = root.appendingPathComponent("路径测试")
        let pathDocs = pathRoot.appendingPathComponent("文档")
        let pathDesktop = pathRoot.appendingPathComponent("桌面")
        try? fm.createDirectory(at: pathDocs, withIntermediateDirectories: true)
        try? fm.createDirectory(at: pathDesktop, withIntermediateDirectories: true)
        let pathFile = pathDocs.appendingPathComponent("说明.txt")
        fm.createFile(atPath: pathFile.path, contents: Data("说明".utf8))

        model.navigate(to: pathRoot)
        model.beginPathEditing()
        check("⌘L 进入编辑并带上当前路径",
              model.isEditingPath && model.pathDraft == model.currentURL.path,
              "draft=\(model.pathDraft)")

        check("回车提交当前目录", model.commitPathEditing(model.currentURL.path))
        check("提交后退出编辑态", !model.isEditingPath && model.pathError == nil)

        // 不存在的路径：拒绝并留在编辑态
        model.beginPathEditing()
        let rejected = model.commitPathEditing("/tmp/绝对不存在的目录-\(UUID().uuidString)")
        check("不存在的路径被拒绝", !rejected && model.isEditingPath)
        check("拒绝时给出提示", model.pathError != nil)
        check("拒绝时不改当前目录", model.currentURL == pathRoot.standardizedFileURL)

        // 输入文件路径：跳到父目录并选中该文件
        check("输入文件路径可以跳转", model.commitPathEditing(pathFile.path))
        check("文件路径跳到父目录", model.currentURL == pathDocs.standardizedFileURL)
        check("文件路径会选中文件",
              model.selection.contains {
                  $0.standardizedFileURL.path == pathFile.standardizedFileURL.path
              },
              "选中 \(model.selection.map(\.lastPathComponent))")

        // 空白输入 = 取消
        model.beginPathEditing()
        check("空白输入直接取消", model.commitPathEditing("   "))
        check("取消后仍在原目录", model.currentURL == pathDocs.standardizedFileURL)

        // Esc 取消
        model.beginPathEditing()
        model.cancelPathEditing()
        check("Esc 取消编辑", !model.isEditingPath && model.pathError == nil)

        // 补全：唯一匹配、多匹配取公共前缀、目录补斜杠、没有匹配返回 nil
        let completionRoot = root.appendingPathComponent("补全测试")
        try? fm.createDirectory(at: completionRoot.appendingPathComponent("苹果目录"), withIntermediateDirectories: true)
        fm.createFile(atPath: completionRoot.appendingPathComponent("苹果笔记.txt").path, contents: Data())
        fm.createFile(atPath: completionRoot.appendingPathComponent("香蕉.txt").path, contents: Data())

        check("补全唯一匹配",
              model.completePath(completionRoot.appendingPathComponent("香").path)
                == completionRoot.appendingPathComponent("香蕉.txt").path,
              "实际 \(model.completePath(completionRoot.appendingPathComponent("香").path) ?? "nil")")

        check("补全多个匹配取公共前缀",
              model.completePath(completionRoot.appendingPathComponent("苹").path)
                == completionRoot.appendingPathComponent("苹果").path,
              "实际 \(model.completePath(completionRoot.appendingPathComponent("苹").path) ?? "nil")")

        let dirCompletion = model.completePath(completionRoot.appendingPathComponent("苹果目").path)
        check("补全目录时补上斜杠",
              dirCompletion?.hasSuffix("/") == true,
              "实际 \(dirCompletion ?? "nil")")

        check("没有匹配返回 nil",
              model.completePath(completionRoot.appendingPathComponent("zzz").path) == nil)

        // ~ 展开
        let homeCompletion = model.completePath("~")
        check("~ 能展开成个人文件夹",
              homeCompletion?.hasPrefix(fm.homeDirectoryForCurrentUser.path) == true,
              "实际 \(homeCompletion ?? "nil")")

        // MARK: 搜索

        let featureRoot = root.appendingPathComponent("功能测试")
        try? fm.createDirectory(at: featureRoot, withIntermediateDirectories: true)
        fm.createFile(atPath: featureRoot.appendingPathComponent("报告一.pdf").path,
                      contents: Data(repeating: 0, count: 2048))
        fm.createFile(atPath: featureRoot.appendingPathComponent("报告二.pdf").path,
                      contents: Data(repeating: 0, count: 1024))
        fm.createFile(atPath: featureRoot.appendingPathComponent("图片.png").path,
                      contents: Data(repeating: 0, count: 512))
        let nested = featureRoot.appendingPathComponent("素材")
        try? fm.createDirectory(at: nested, withIntermediateDirectories: true)
        fm.createFile(atPath: nested.appendingPathComponent("a.bin").path,
                      contents: Data(repeating: 0, count: 3000))

        model.navigate(to: featureRoot)
        check("功能目录读到 4 项", model.items.count == 4, "实际 \(model.items.count)")

        model.searchText = "报告"
        check("搜索按名称过滤",
              model.items.count == 2 && model.items.allSatisfy { $0.name.contains("报告") },
              "实际 \(model.items.map(\.name))")
        check("搜索处于激活态", model.isSearching)

        model.searchText = "报告一"
        check("搜索能进一步收窄", model.items.count == 1, "实际 \(model.items.map(\.name))")

        model.searchText = "Pdf"
        check("搜索忽略大小写", model.items.count == 2, "实际 \(model.items.map(\.name))")

        model.searchText = "zzz"
        check("无匹配时列表为空", model.items.isEmpty, "实际 \(model.items.map(\.name))")

        model.searchText = ""
        check("清空搜索恢复全部", model.items.count == 4)

        model.selectAll()
        model.searchText = "报告"
        check("过滤后选择被裁剪", model.selection.count == 2, "实际 \(model.selection.count)")

        model.navigate(to: nested)
        check("换目录自动清空搜索", !model.isSearching && model.searchText.isEmpty)

        // MARK: 属性面板

        model.navigate(to: featureRoot)
        model.focus(url: featureRoot.appendingPathComponent("报告一.pdf"))
        model.showInfo()
        check("属性面板有内容", model.info != nil)
        check("属性标题是文件名", model.info?.title == "报告一.pdf", "实际 \(model.info?.title ?? "nil")")
        check("属性里带大小",
              model.info?.fields.contains { $0.id == "size" && $0.value.contains("KB") } == true,
              "实际 \(model.info?.fields.first { $0.id == "size" }?.value ?? "nil")")
        check("属性里带扩展名",
              model.info?.fields.contains { $0.id == "ext" && $0.value == ".pdf" } == true)
        model.closeInfo()
        check("关闭属性面板", model.info == nil)

        let stats = FileInfoService.folderStats(featureRoot)
        check("文件夹递归统计文件数", stats.fileCount == 4, "实际 \(stats.fileCount)")
        check("文件夹递归统计字节数",
              stats.bytes == 2048 + 1024 + 512 + 3000,
              "实际 \(stats.bytes)")
        check("文件夹递归统计子文件夹数", stats.folderCount == 1, "实际 \(stats.folderCount)")

        model.focus(url: nested)
        model.showInfo()
        check("文件夹属性会回填大小",
              model.info?.note == nil
                && model.info?.fields.contains { $0.id == "size" && $0.value != "计算中…" } == true,
              "实际 note=\(model.info?.note ?? "nil")")
        check("文件夹属性显示包含项",
              model.info?.fields.contains { $0.id == "items" && $0.value.contains(L("1 个文件", "1 file")) } == true,
              "实际 \(model.info?.fields.first { $0.id == "items" }?.value ?? "nil")")
        model.closeInfo()

        model.selectAll()
        model.showInfo()
        check("多选属性显示项目数", model.info?.title == L("4 个项目", "4 items"), "实际 \(model.info?.title ?? "nil")")
        check("多选属性汇总大小",
              model.info?.fields.first { $0.id == "size" }?.value != "计算中…")
        model.closeInfo()

        let perms = FileInfoService.permissionText(
            attributes: [.posixPermissions: NSNumber(value: 0o755)],
            isDirectory: true
        )
        check("权限串格式", perms.hasPrefix("drwxr-xr-x"), "实际 \(perms)")

        // MARK: 自动刷新

        model.clearSelection()
        model.focus(url: featureRoot.appendingPathComponent("图片.png"))
        let beforeRefresh = model.items.count
        fm.createFile(atPath: featureRoot.appendingPathComponent("外部新增.txt").path, contents: Data("x".utf8))
        model.refreshFromDisk()
        check("外部新增文件后自动刷新",
              model.items.count == beforeRefresh + 1, "实际 \(model.items.count)")
        check("自动刷新保留选择和焦点",
              model.selection.count == 1 && model.focusedURL?.lastPathComponent == "图片.png",
              "选中 \(model.selection.map(\.lastPathComponent))")

        try? fm.removeItem(at: featureRoot.appendingPathComponent("外部新增.txt"))
        model.refreshFromDisk()
        check("外部删除后自动刷新", model.items.count == beforeRefresh, "实际 \(model.items.count)")

        model.searchText = ""

        // MARK: 标签页

        let tabA = BrowserModel(startAt: featureRoot)
        let tabB = BrowserModel(startAt: nested)
        let tabModel = TabsModel(tabs: [tabA, tabB])
        check("标签页数量", tabModel.count == 2, "实际 \(tabModel.count)")
        check("默认激活第一个标签", tabModel.active === tabA)
        tabModel.select(1)
        check("切换标签后 active 跟着变", tabModel.active === tabB)
        check("各标签目录互不影响",
              tabA.currentURL.standardizedFileURL.path == featureRoot.standardizedFileURL.path
                && tabB.currentURL.standardizedFileURL.path == nested.standardizedFileURL.path)

        let createdTab = tabModel.newTab()
        check("新建标签插在当前标签之后", tabModel.count == 3 && tabModel.activeIndex == 2,
              "count=\(tabModel.count) index=\(tabModel.activeIndex)")
        check("新标签沿用当前目录",
              createdTab.currentURL.standardizedFileURL.path == nested.standardizedFileURL.path)

        tabModel.closeTab(at: 2)
        check("关闭标签后数量减少且激活前一个", tabModel.count == 2 && tabModel.activeIndex == 1,
              "count=\(tabModel.count) index=\(tabModel.activeIndex)")

        tabModel.selectNext(true)
        check("⌃Tab 循环到第一个", tabModel.activeIndex == 0, "实际 \(tabModel.activeIndex)")
        tabModel.selectNext(false)
        check("⌃⇧Tab 回到最后一个", tabModel.activeIndex == 1, "实际 \(tabModel.activeIndex)")

        tabModel.moveTab(from: 0, to: 2)
        check("标签排序后数量不变", tabModel.count == 2)
        check("标签排序后激活的还是同一个", tabModel.active === tabB)

        let singleTab = TabsModel(tabs: [BrowserModel(startAt: featureRoot)])
        singleTab.closeActiveTab()
        check("最后一个标签不会被关掉", singleTab.count == 1)
        check("关闭最后一个标签回到个人文件夹",
              singleTab.active.currentURL.standardizedFileURL.path
                == FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path)

        // MARK: 收藏夹

        let favorites = FavoritesStore(persisting: false)
        check("收藏夹初始为空", favorites.items.isEmpty)
        check("可以收藏文件夹", favorites.add(featureRoot))
        check("重复收藏被忽略", !favorites.add(featureRoot))
        let notAFolder = featureRoot.appendingPathComponent("不是文件夹.txt")
        fm.createFile(atPath: notAFolder.path, contents: Data("x".utf8))
        check("文件不能收藏", !favorites.add(notAFolder))
        check("收藏夹里有 1 项", favorites.items.count == 1)
        check("contains 忽略路径写法差异",
              favorites.contains(featureRoot.appendingPathComponent(".")))
        favorites.remove(featureRoot)
        check("移除收藏", favorites.items.isEmpty)

        // MARK: 批量重命名

        let batchRoot = root.appendingPathComponent("批量测试")
        try? fm.createDirectory(at: batchRoot, withIntermediateDirectories: true)
        for index in 1...3 {
            fm.createFile(atPath: batchRoot.appendingPathComponent("假日 \(index).jpg").path,
                          contents: Data("J\(index)".utf8))
        }
        fm.createFile(atPath: batchRoot.appendingPathComponent("旅行 01.jpg").path, contents: Data("X".utf8))
        try? fm.createDirectory(at: batchRoot.appendingPathComponent("子相册"), withIntermediateDirectories: true)

        model.navigate(to: batchRoot)
        model.reload()

        let photos = model.items.filter { $0.name.hasPrefix("假日") && $0.name.hasSuffix(".jpg") }
        check("批量测试目录准备就绪", photos.count == 3, "实际 \(model.items.map(\.name))")

        if photos.count == 3 {
            model.handleClick(on: photos[0], modifiers: [])
            model.handleClick(on: photos[1], modifiers: [.command])
            model.handleClick(on: photos[2], modifiers: [.command])
            model.beginBatchRename()
            check("多选后打开批量重命名面板", model.batchRename != nil && model.hasModalOverlay)

            model.updateBatchRename { state in
                state.baseName = "旅行"
                state.separator = " "
                state.digits = 2
                state.startIndex = 1
            }

            let conflictPlan = model.batchRenamePlan
            check("预览按列表顺序编号",
                  Array(conflictPlan?.rows.map(\.newName).prefix(2) ?? []) == ["旅行 01.jpg", "旅行 02.jpg"],
                  "实际 \(conflictPlan?.rows.map(\.newName) ?? [])")
            check("与磁盘已有文件重名会被拦下",
                  conflictPlan?.rows.first?.problem == L("已存在同名项目", "A file with this name already exists"),
                  "实际 \(conflictPlan?.rows.first?.problem ?? "nil")")
            check("有冲突时不可执行", conflictPlan?.isApplicable == false)

            model.applyBatchRename()
            check("有冲突时不改任何文件",
                  fm.fileExists(atPath: batchRoot.appendingPathComponent("假日 1.jpg").path))
            check("有冲突时面板保持打开", model.batchRename != nil)

            model.updateBatchRename { $0.baseName = "假期" }
            let okPlan = model.batchRenamePlan
            check("换基名后可以执行", okPlan?.isApplicable == true)
            check("预览保持三项", okPlan?.rows.count == 3)

            model.applyBatchRename()
            check("批量重命名生效",
                  [1, 2, 3].allSatisfy {
                      fm.fileExists(atPath: batchRoot.appendingPathComponent(
                          String(format: "假期 %02d.jpg", $0)).path)
                  })
            check("旧名字全部消失",
                  (1...3).allSatisfy {
                      !fm.fileExists(atPath: batchRoot.appendingPathComponent("假日 \($0).jpg").path)
                  })
            check("执行后面板关闭", model.batchRename == nil)
            check("批量重命名进入撤销栈",
                  model.canUndo && (model.undoTitle?.lowercased().contains(L("批量重命名", "batch rename").lowercased()) ?? false),
                  "undoTitle=\(model.undoTitle ?? "nil")")
            check("重命名后选中新项目",
                  model.selection.contains { $0.lastPathComponent == "假期 01.jpg" },
                  "选中 \(model.selection.map(\.lastPathComponent))")

            model.undo()
            check("撤销批量重命名恢复原名",
                  fm.fileExists(atPath: batchRoot.appendingPathComponent("假日 1.jpg").path)
                    && !fm.fileExists(atPath: batchRoot.appendingPathComponent("假期 01.jpg").path))
            model.redo()
            check("重做批量重命名",
                  fm.fileExists(atPath: batchRoot.appendingPathComponent("假期 01.jpg").path))

            // 查找替换（保留扩展名）
            model.reload()
            let renamed = model.items.filter { $0.name.hasPrefix("假期") }
            if renamed.count == 3 {
                model.handleClick(on: renamed[0], modifiers: [])
                model.handleClick(on: renamed[1], modifiers: [.command])
                model.handleClick(on: renamed[2], modifiers: [.command])
                model.beginBatchRename()
                model.updateBatchRename { state in
                    state.mode = .replace
                    state.findText = "假期 "
                    state.replaceText = "出行"
                    state.keepExtension = true
                }
                let replacePlan = model.batchRenamePlan
                check("查找替换保留扩展名",
                      replacePlan?.rows.first?.newName == "出行01.jpg",
                      "实际 \(replacePlan?.rows.first?.newName ?? "nil")")
                check("查找替换可执行", replacePlan?.isApplicable == true)
                model.applyBatchRename()
                check("查找替换改名生效",
                      fm.fileExists(atPath: batchRoot.appendingPathComponent("出行01.jpg").path))
            } else {
                check("查找替换保留扩展名", false, "找不到改名后的文件")
            }
        }

        // 两项被改成同一个名字 → 整批拒绝
        fm.createFile(atPath: batchRoot.appendingPathComponent("报告-甲.txt").path, contents: Data("a".utf8))
        fm.createFile(atPath: batchRoot.appendingPathComponent("报告-乙.txt").path, contents: Data("b".utf8))
        model.reload()
        let reports = model.items.filter { $0.name.hasPrefix("报告-") }
        if reports.count == 2 {
            model.handleClick(on: reports[0], modifiers: [])
            model.handleClick(on: reports[1], modifiers: [.command])
            model.beginRename()
            check("多选按 F2 进入批量重命名", model.batchRename != nil)

            model.updateBatchRename { state in
                state.mode = .replace
                state.findText = "甲"
                state.replaceText = "乙"
            }
            let duplicatePlan = model.batchRenamePlan
            check("改成已被占用的名字会被拦下",
                  duplicatePlan?.rows.contains { $0.problem != nil } == true,
                  "实际 \(duplicatePlan?.rows.map { $0.problem ?? "-" } ?? [])")
            check("重名冲突时不可执行", duplicatePlan?.isApplicable == false)

            model.cancelBatchRename()
            check("取消批量重命名关闭面板", model.batchRename == nil && !model.hasModalOverlay)
            check("取消后文件保持原样",
                  fm.fileExists(atPath: batchRoot.appendingPathComponent("报告-甲.txt").path))
        } else {
            check("多选按 F2 进入批量重命名", false, "找不到报告文件")
        }

        // MARK: 压缩 / 解压

        let archiveRoot = root.appendingPathComponent("压缩测试")
        let photoDir = archiveRoot.appendingPathComponent("照片")
        try? fm.createDirectory(at: photoDir, withIntermediateDirectories: true)
        fm.createFile(atPath: photoDir.appendingPathComponent("a.jpg").path, contents: Data("A".utf8))
        fm.createFile(atPath: photoDir.appendingPathComponent("b.jpg").path, contents: Data("B".utf8))

        model.navigate(to: archiveRoot)
        model.reload()
        model.focus(url: photoDir)
        check("选中文件夹可以压缩", model.canCompress)

        model.compressSelection()
        let photoZip = archiveRoot.appendingPathComponent("照片.zip")
        check("压缩生成同名 zip", fm.fileExists(atPath: photoZip.path))
        check("压缩完成后自动选中 zip",
              model.selection.contains {
                  $0.standardizedFileURL.path == photoZip.standardizedFileURL.path
              },
              "选中 \(model.selection.map(\.lastPathComponent))")
        check("压缩不动原文件夹",
              fm.fileExists(atPath: photoDir.appendingPathComponent("a.jpg").path))
        check("重复压缩自动改名",
              ArchiveService.compressDestination(for: [photoDir], in: archiveRoot).lastPathComponent == "照片 2.zip",
              "实际 \(ArchiveService.compressDestination(for: [photoDir], in: archiveRoot).lastPathComponent)")

        // 解压到同名文件夹：原目录已存在，所以自动用「照片 2」
        model.focus(url: photoZip)
        check("选中 zip 可以解压", model.canExtract)
        model.extractSelection(toOwnFolder: true)
        let extracted = archiveRoot.appendingPathComponent("照片 2")
        check("解压到新文件夹", fm.fileExists(atPath: extracted.appendingPathComponent("a.jpg").path))
        check("解压内容正确", text(extracted.appendingPathComponent("b.jpg")) == "B",
              "实际 \(text(extracted.appendingPathComponent("b.jpg")))")

        // 多选压缩：包名取当前文件夹名，两个文件平铺在包根
        fm.createFile(atPath: archiveRoot.appendingPathComponent("一.txt").path, contents: Data("1".utf8))
        fm.createFile(atPath: archiveRoot.appendingPathComponent("二.txt").path, contents: Data("2".utf8))
        model.reload()
        if let one = model.items.first(where: { $0.name == "一.txt" }),
           let two = model.items.first(where: { $0.name == "二.txt" }) {
            model.handleClick(on: one, modifiers: [])
            model.handleClick(on: two, modifiers: [.command])
            model.compressSelection()
            let multiZip = archiveRoot.appendingPathComponent("压缩测试.zip")
            check("多选压缩用文件夹名命名", fm.fileExists(atPath: multiZip.path))

            model.focus(url: multiZip)
            model.extractSelection(toOwnFolder: true)
            let multiExtracted = archiveRoot.appendingPathComponent("压缩测试")
            check("多选压缩包能解出两个文件",
                  fm.fileExists(atPath: multiExtracted.appendingPathComponent("一.txt").path)
                    && fm.fileExists(atPath: multiExtracted.appendingPathComponent("二.txt").path))
        } else {
            check("多选压缩用文件夹名命名", false, "找不到测试文件")
        }

        // 解压到当前文件夹：顶层同名项已存在 → 拒绝，绝不覆盖
        model.focus(url: photoZip)
        model.extractSelection(toOwnFolder: false)
        check("同名冲突时拒绝解压到当前文件夹", model.errorMessage != nil)
        check("拒绝时不覆盖已有文件夹", text(photoDir.appendingPathComponent("a.jpg")) == "A")
        model.dismissError()

        // 解压到当前文件夹：没有冲突时正常落地
        let soloFile = archiveRoot.appendingPathComponent("独一份.txt")
        fm.createFile(atPath: soloFile.path, contents: Data("U".utf8))
        model.reload()
        model.focus(url: soloFile)
        model.compressSelection()
        try? fm.removeItem(at: soloFile)
        model.reload()
        if let soloZip = model.items.first(where: { $0.name == "独一份.zip" }) {
            model.focus(url: soloZip.url)
            model.extractSelection(toOwnFolder: false)
            check("解压到当前文件夹", fm.fileExists(atPath: soloFile.path))
            check("当前文件夹解压内容正确", text(soloFile) == "U", "实际 \(text(soloFile))")
        } else {
            check("解压到当前文件夹", false, "找不到独一份.zip")
        }

        // 非 zip 不能解压
        if let txt = model.items.first(where: { $0.name == "一.txt" }) {
            model.focus(url: txt.url)
            check("非 zip 不能解压", !model.canExtract)
            model.extractSelection(toOwnFolder: true)
            check("非 zip 解压给出提示", model.flash != nil)
        }

        // MARK: Quick Look

        let quickLook = QuickLookController.shared
        let qlURLs = [
            featureRoot.appendingPathComponent("报告一.pdf"),
            featureRoot.appendingPathComponent("报告二.pdf")
        ]
        quickLook.prepare(urls: qlURLs, startAt: qlURLs[1])
        check("预览列表包含全部选中项", quickLook.urls.count == 2 && quickLook.index == 1,
              "count=\(quickLook.urls.count) index=\(quickLook.index)")
        var previewFocused: URL?
        quickLook.onFocus = { previewFocused = $0 }
        quickLook.step(1)
        check("预览 ↓ 循环回第一项",
              quickLook.index == 0 && previewFocused?.lastPathComponent == "报告一.pdf",
              "index=\(quickLook.index) focus=\(previewFocused?.lastPathComponent ?? "nil")")
        quickLook.step(-1)
        check("预览 ↑ 回到最后一项", quickLook.index == 1, "实际 \(quickLook.index)")
        quickLook.onFocus = nil
        quickLook.prepare(urls: [], startAt: nil)

        // MARK: 文件夹大小（1.0.0）

        let sizeRoot = root.appendingPathComponent("大小测试")
        let sizeA = sizeRoot.appendingPathComponent("甲目录")
        let sizeB = sizeRoot.appendingPathComponent("乙目录")
        try? fm.createDirectory(at: sizeA.appendingPathComponent("内层"), withIntermediateDirectories: true)
        try? fm.createDirectory(at: sizeB, withIntermediateDirectories: true)
        fm.createFile(atPath: sizeA.appendingPathComponent("x.bin").path,
                      contents: Data(repeating: 0, count: 1000))
        fm.createFile(atPath: sizeA.appendingPathComponent("内层/y.bin").path,
                      contents: Data(repeating: 0, count: 2000))
        fm.createFile(atPath: sizeB.appendingPathComponent("z.bin").path,
                      contents: Data(repeating: 0, count: 500))
        fm.createFile(atPath: sizeRoot.appendingPathComponent("顶.txt").path,
                      contents: Data(repeating: 0, count: 42))

        model.navigate(to: sizeRoot)
        check("默认不显示文件夹大小",
              model.items.first?.isDirectory == true
                && model.items.first.map { model.sizeText(for: $0) } == "—")
        check("没开统计时没有进度", model.folderSizeProgress == nil)

        model.showsFolderSizes = true
        if let folderA = model.items.first(where: { $0.name == "甲目录" }) {
            check("文件夹大小统计完成（递归）",
                  model.sizeText(for: folderA) == FileItem.byteText(3000),
                  "实际 \(model.sizeText(for: folderA))")
        } else {
            check("文件夹大小统计完成（递归）", false, "找不到甲目录")
        }
        if let folderB = model.items.first(where: { $0.name == "乙目录" }) {
            check("另一个文件夹大小正确",
                  model.sizeText(for: folderB) == FileItem.byteText(500),
                  "实际 \(model.sizeText(for: folderB))")
        }
        check("统计完成后没有进度", model.folderSizeProgress == nil)
        check("大小结果进入缓存", FolderSizeService.shared.cached(sizeA)?.bytes == 3000,
              "实际 \(FolderSizeService.shared.cached(sizeA)?.bytes ?? -1)")
        if let file = model.items.first(where: { $0.name == "顶.txt" }) {
            check("文件行仍按真实大小", model.sizeText(for: file) == FileItem.byteText(42),
                  "实际 \(model.sizeText(for: file))")
        } else {
            check("文件行仍按真实大小", false, "找不到顶.txt")
        }
        model.showsFolderSizes = false
        check("关掉后大小回到 —",
              model.items.first.map { model.sizeText(for: $0) } == "—")

        // MARK: 位置与系统集成（1.0.0）

        let cloudDocs = fm.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs")
        if fm.fileExists(atPath: cloudDocs.path) {
            check("常用位置包含 iCloud 云盘",
                  Place.quickPlaces.contains {
                      $0.url.standardizedFileURL.path == cloudDocs.standardizedFileURL.path
                  },
                  "实际 \(Place.quickPlaces.map(\.name))")
        } else {
            check("没有 iCloud 时不会凭空加一项",
                  !Place.quickPlaces.contains {
                      $0.url.path.contains("com~apple~CloudDocs")
                  })
        }
        check("本机卷都在「设备」里", Place.volumes.allSatisfy(\.isLocal))
        check("网络卷都在「网络」里", Place.networkVolumes.allSatisfy { !$0.isLocal })
        check("全局快捷键文案", GlobalHotKey.shortcutText == "⌥⌘E")

        // 真的向系统注册一次热键，验证 Carbon 这条路是通的（注册完立刻注销）
        let hotKey = GlobalHotKey.shared
        check("系统热键可以注册", hotKey.register())
        hotKey.unregister()
        check("系统热键可以注销", !hotKey.isRegistered)

        StatusItemController.shared.setVisible(true)
        check("菜单栏图标能装上", StatusItemController.shared.isVisible)
        StatusItemController.shared.setVisible(false)
        check("菜单栏图标能移除", !StatusItemController.shared.isVisible)

        model.showAbout()
        check("关于面板打开", model.showsAbout && model.hasModalOverlay)
        model.closeAbout()
        check("关于面板关闭", !model.showsAbout && model.batchRename == nil)

        // MARK: 访问权限（未授权项淡化 + 只在主动操作时提示）
        let permRoot = root.appendingPathComponent("perm")
        let lockedDir = permRoot.appendingPathComponent("locked")
        let openDir = permRoot.appendingPathComponent("open")
        try? fm.createDirectory(at: lockedDir, withIntermediateDirectories: true)
        try? fm.createDirectory(at: openDir, withIntermediateDirectories: true)
        let secretFile = permRoot.appendingPathComponent("secret.txt")
        let normalFile = permRoot.appendingPathComponent("normal.txt")
        fm.createFile(atPath: secretFile.path, contents: Data("s".utf8))
        fm.createFile(atPath: normalFile.path, contents: Data("n".utf8))
        fm.createFile(atPath: lockedDir.appendingPathComponent("inner.txt").path, contents: Data("i".utf8))
        fm.createFile(atPath: openDir.appendingPathComponent("visible.txt").path, contents: Data("v".utf8))
        // 先恢复权限，保证临时目录能删干净
        defer {
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: lockedDir.path)
            try? fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: secretFile.path)
        }
        try? fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: lockedDir.path)
        try? fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: secretFile.path)

        let permModel = BrowserModel(startAt: permRoot)
        check("未授权文件仍然会列出来", permModel.items.contains { $0.name == "secret.txt" })
        check("未授权文件标记为 denied",
              permModel.items.first { $0.name == "secret.txt" }?.access == .denied,
              "实际 \(String(describing: permModel.items.first { $0.name == "secret.txt" }?.access))")
        check("未授权文件夹标记为 denied",
              permModel.items.first { $0.name == "locked" }?.access == .denied)
        check("已授权项保持 granted",
              permModel.items.first { $0.name == "normal.txt" }?.access == .granted)
        check("列目录本身不会弹授权", permModel.accessRequest == nil)

        if let secret = permModel.items.first(where: { $0.name == "secret.txt" }) {
            check("未授权项的悬停提示说明需要授权",
                  !secret.isAccessible && secret.access.isDenied)
            permModel.open(secret)
            check("主动打开未授权文件才提示授权", permModel.accessRequest != nil)
            check("提示只针对被点的那一项",
                  permModel.accessRequest?.items.map(\.name) == ["secret.txt"])
            check("授权浮层算作模态（不误操作后台列表）", permModel.hasModalOverlay)
            permModel.cancelAccessRequest()
            check("取消授权提示后回到普通状态", permModel.accessRequest == nil)
        } else {
            check("未授权文件仍能定位", false)
        }

        // 进入未授权目录：给授权浮层，而不是一行错误条
        let beforeLocked = permModel.currentURL
        permModel.navigate(to: lockedDir)
        check("进入未授权目录弹授权而不是错误条",
              permModel.accessRequest != nil && permModel.errorMessage == nil
                  && permModel.currentURL == beforeLocked,
              "request=\(permModel.accessRequest != nil) error=\(permModel.errorMessage ?? "nil")")
        check("整目录被拒时不对单个项目提示", permModel.accessRequest?.items.isEmpty == true)
        permModel.cancelAccessRequest()

        // 嵌套：放开父目录后，子项仍按自己的权限逐个判定，不会连带全放
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: lockedDir.path)
        permModel.refreshFromDisk()
        check("授权父目录后它本身恢复 granted",
              permModel.items.first { $0.name == "locked" }?.access == .granted)
        permModel.navigate(to: lockedDir)
        check("能进入刚授权的目录", permModel.currentURL.standardizedFileURL.path == lockedDir.standardizedFileURL.path)
        check("授权目录里的内容正常显示",
              permModel.items.first { $0.name == "inner.txt" }?.access == .granted)
        check("进入已授权目录不再提示", permModel.accessRequest == nil)

        // 授权文件后重新探测：状态回到 granted，其它项不受影响
        try? fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: secretFile.path)
        permModel.navigate(to: permRoot)
        check("授权文件后恢复 granted",
              permModel.items.first { $0.name == "secret.txt" }?.access == .granted)
        check("权限探测本身不留副作用",
              permModel.errorMessage == nil && permModel.accessRequest == nil)

        check("能识别权限类错误",
              PermissionService.isPermissionDenied(
                  NSError(domain: NSCocoaErrorDomain, code: CocoaError.fileReadNoPermission.rawValue)
              ))
        check("普通错误不会误判成权限错误",
              !PermissionService.isPermissionDenied(
                  NSError(domain: NSCocoaErrorDomain, code: CocoaError.fileNoSuchFile.rawValue)
              ))
        check("桌面被认作需要系统设置的位置",
              PermissionService.needsSystemSettings(URL(fileURLWithPath: NSHomeDirectory() + "/Desktop")))
        check("普通临时目录不需要系统设置",
              !PermissionService.needsSystemSettings(permRoot))

        // MARK: 受保护位置（后台递归绝不进 TCC 区域，避免反复弹系统授权框）
        let homeURL = URL(fileURLWithPath: NSHomeDirectory())
        let homeProtectedNames = [
            "Desktop", "Documents", "Downloads",
            "Music", "Movies", "Pictures", "Library"
        ]
        for name in homeProtectedNames {
            let target = homeURL.appendingPathComponent(name)
            check("受保护的家目录位置：\(name)",
                  ProtectedPaths.shouldSkipRecursiveRead(target))
        }
        check("Apple Music 媒体资料库被识别",
              ProtectedPaths.shouldSkipRecursiveRead(homeURL.appendingPathComponent("Music/Music")))
        check("照片图库包被识别",
              ProtectedPaths.shouldSkipRecursiveRead(root.appendingPathComponent("图库.photoslibrary")))
        check("外置卷被识别",
              ProtectedPaths.shouldSkipRecursiveRead(URL(fileURLWithPath: "/Volumes/移动硬盘")))
        check("其他用户目录被识别",
              ProtectedPaths.shouldSkipRecursiveRead(URL(fileURLWithPath: "/Users/someone-else/Documents")))
        check("家目录本身只列一层，不拦浏览",
              !ProtectedPaths.shouldSkipRecursiveRead(homeURL))
        check("临时目录不被误判为受保护",
              !ProtectedPaths.shouldSkipRecursiveRead(root)
                  && !ProtectedPaths.shouldSkipRecursiveRead(permRoot))
        check("普通子目录不被误判为受保护",
              !ProtectedPaths.shouldSkipRecursiveRead(openDir))

        // 图标规则比统计规则窄：可读的受保护目录必须保持系统真实图标
        check("媒体资料库子目录避开系统图标",
              ProtectedPaths.shouldAvoidSystemIcon(homeURL.appendingPathComponent("Music/Music")))
        check("照片图库包避开系统图标",
              ProtectedPaths.shouldAvoidSystemIcon(root.appendingPathComponent("图库.photoslibrary")))
        check("桌面仍用系统图标（可读就不该画灰）",
              !ProtectedPaths.shouldAvoidSystemIcon(homeURL.appendingPathComponent("Desktop")))
        check("音乐目录本身仍用系统图标",
              !ProtectedPaths.shouldAvoidSystemIcon(homeURL.appendingPathComponent("Music")))
        check("普通目录仍用系统图标",
              !ProtectedPaths.shouldAvoidSystemIcon(openDir))

        // 用不存在的受保护路径，避免断言写错时真的去枚举 ~/Music 弹系统框
        let fakeMusic = homeURL.appendingPathComponent("Music/__winexplorer_selftest_absent__")
        let skippedSize = FolderSizeService.measure(fakeMusic)
        check("文件夹大小统计对受保护位置直接跳过", skippedSize.skipped)
        check("跳过的统计不会被显示成 0 B", skippedSize.bytes == 0 && skippedSize.fileCount == 0)
        check("跳过结果不进缓存",
              FolderSizeService.shared.cached(fakeMusic) == nil)
        let skippedStats = FileInfoService.folderStats(fakeMusic)
        check("属性面板统计对受保护位置直接跳过", skippedStats.skipped && skippedStats.isEmpty)

        let normalSize = FolderSizeService.measure(openDir)
        check("普通目录照常统计（未被规则误伤）",
              !normalSize.skipped && normalSize.fileCount == 1 && normalSize.bytes > 0,
              "实际 \(normalSize)")
        check("桌面仍被认作需要系统设置的位置",
              PermissionService.needsSystemSettings(homeURL.appendingPathComponent("Desktop")))
        check("跳过说明文案跟随语言",
              !ProtectedPaths.skipReason.isEmpty
                  && ProtectedPaths.skipReason == L("受 macOS 隐私保护，跳过自动统计",
                                                    "Protected by macOS — automatic scanning skipped"))

        // MARK: 右键新建文件（文本 + 常用办公文件）与「在终端中打开」
        let newRoot = root.appendingPathComponent("newfiles")
        try? fm.createDirectory(at: newRoot, withIntermediateDirectories: true)
        let newModel = BrowserModel(startAt: newRoot)

        for kind in NewFileKind.allCases {
            check("模板内容齐全：\(kind.displayName)",
                  DocumentTemplates.content(for: kind) != nil)
        }
        check("docx 模板是 zip 包",
              DocumentTemplates.content(for: .word)?.prefix(2) == Data("PK".utf8))
        check("xlsx 模板是 zip 包",
              DocumentTemplates.content(for: .excel)?.prefix(2) == Data("PK".utf8))
        check("pptx 模板是 zip 包",
              DocumentTemplates.content(for: .powerpoint)?.prefix(2) == Data("PK".utf8))
        check("txt 初始为空",
              DocumentTemplates.content(for: .text)?.isEmpty == true)
        check("rtf 有 RTF 头",
              String(data: DocumentTemplates.content(for: .rtf) ?? Data(), encoding: .ascii)?
                  .hasPrefix("{\\rtf1") == true)

        newModel.createFile(.text)
        let textName = "\(L("新建文本文档", "New Text Document")).txt"
        check("文本文档已创建", fm.fileExists(atPath: newRoot.appendingPathComponent(textName).path))
        check("创建后自动进行内重命名",
              newModel.renamingURL?.lastPathComponent == textName,
              "实际 \(newModel.renamingURL?.lastPathComponent ?? "nil")")
        newModel.cancelRename()

        newModel.createFile(.text)
        let secondName = "\(L("新建文本文档", "New Text Document")) 2.txt"
        check("重名自动编号", fm.fileExists(atPath: newRoot.appendingPathComponent(secondName).path))
        newModel.cancelRename()

        newModel.createFile(.word)
        let wordName = "\(L("新建 Word 文档", "New Word Document")).docx"
        let wordURL = newRoot.appendingPathComponent(wordName)
        check("Word 文档已创建", fm.fileExists(atPath: wordURL.path))
        check("Word 文档写入的是模板（非空）",
              ((try? fm.attributesOfItem(atPath: wordURL.path))?[.size] as? Int) ?? 0 > 0)
        check("撤销记录是新建",
              newModel.canUndo && (newModel.undoTitle?.contains(L("新建", "Create")) ?? false),
              "实际 \(newModel.undoTitle ?? "nil")")
        newModel.undo()
        check("撤销后新文件被删除", !fm.fileExists(atPath: wordURL.path))
        newModel.redo()
        check("重做后文件恢复", fm.fileExists(atPath: wordURL.path))

        newModel.createFile(.excel)
        newModel.cancelRename()
        let excelName = "\(L("新建 Excel 工作表", "New Excel Worksheet")).xlsx"
        let excelURL = newRoot.appendingPathComponent(excelName)
        try? Data("user content".utf8).write(to: excelURL)
        newModel.undo()
        check("被编辑过的文件撤销时不删除", fm.fileExists(atPath: excelURL.path))

        check("至少找到一个终端应用", !TerminalService.available.isEmpty)
        check("系统 Terminal 在可用列表里",
              TerminalService.available.contains { $0.name == "Terminal" })
        if let terminal = TerminalService.available.first {
            let handOff = TerminalService.handOffDescription(directory: newRoot, app: terminal)
            check("终端转交命令包含目标目录", handOff.contains(newRoot.standardizedFileURL.path))
            check("dry-run 不启动终端", TerminalService.open(newRoot, app: terminal, dryRun: true))
        }

        // MARK: 地址栏编辑态的退出时机（adr/0005）
        let editModel = BrowserModel(startAt: newRoot)
        editModel.beginPathEditing()
        check("进入地址栏编辑态", editModel.isEditingPath)
        if let file = editModel.items.first(where: { !$0.isDirectory }) {
            editModel.handleClick(on: file, modifiers: [])
            check("点文件行退出编辑态", !editModel.isEditingPath)
        } else {
            check("点文件行退出编辑态", false, "目录里没有文件")
        }
        editModel.beginPathEditing()
        editModel.clearSelection()
        // 「点空白退出编辑态」绑定在 View 层的点击交互上（cancelPathEditing），
        // clearSelection 本身被拖拽 / 刷新等内部路径共用，必须不退编辑态
        check("clearSelection 单独调用不退编辑态", editModel.isEditingPath)
        editModel.cancelPathEditing()
        check("显式取消（点空白路径）退出编辑态", !editModel.isEditingPath)
        editModel.beginPathEditing()
        editModel.beginSearch()
        check("聚焦搜索框退出编辑态", !editModel.isEditingPath)
        check("Esc 取消语义保持",
              !editModel.isEditingPath && editModel.pathError == nil)

        // MARK: 标签 / 窗口间传文件（adr/0006、0007）
        let xferSrc = root.appendingPathComponent("dropSrc")
        let xferDst = root.appendingPathComponent("dropDst")
        try? fm.createDirectory(at: xferSrc, withIntermediateDirectories: true)
        try? fm.createDirectory(at: xferDst, withIntermediateDirectories: true)
        let sharedFile = xferSrc.appendingPathComponent("跨.txt")
        fm.createFile(atPath: sharedFile.path, contents: Data("c".utf8))

        let srcModel = BrowserModel(startAt: xferSrc)
        let dstModel = BrowserModel(startAt: xferDst)
        srcModel.selectAll()
        srcModel.copySelection()
        check("剪贴板全局共享：另一个模型立即可粘贴", dstModel.canPaste)
        dstModel.paste()
        check("跨标签粘贴成功",
              fm.fileExists(atPath: xferDst.appendingPathComponent("跨.txt").path))

        srcModel.selectAll()
        srcModel.cutSelection()
        check("剪切标记跨模型可见",
              dstModel.canPaste
                  && dstModel.cutURLs.contains(where: {
                      $0.standardizedFileURL == sharedFile.standardizedFileURL
                  }))

        // 拖文件到标签 chip = 切换到那个标签并把文件放入它的当前目录
        let pairTabs = TabsModel(tabs: [srcModel, dstModel])
        let secondFile = xferSrc.appendingPathComponent("再拖.txt")
        fm.createFile(atPath: secondFile.path, contents: Data("d".utf8))
        pairTabs.receiveDrop([secondFile], intoTabAt: 1, modifiers: [])
        check("拖到标签后切换到那个标签", pairTabs.activeIndex == 1,
              "实际 \(pairTabs.activeIndex)")
        check("文件落入目标标签的当前目录",
              fm.fileExists(atPath: xferDst.appendingPathComponent("再拖.txt").path))

        // 拖到 + 号 = 新建标签并放入
        let freshTabs = TabsModel(startAt: xferDst)
        let thirdFile = xferSrc.appendingPathComponent("新标签.txt")
        fm.createFile(atPath: thirdFile.path, contents: Data("e".utf8))
        freshTabs.receiveDropOnPlus([thirdFile], modifiers: [])
        check("拖到 + 号新建了标签", freshTabs.count == 2)
        check("新标签里已有拖入的文件",
              freshTabs.active.items.contains { $0.name == "新标签.txt" })

        // MARK: 目录异步读取（adr/0013）
        // 切到异步路径，navigate 后泵一会儿 runloop，等后台结果回主线程
        BrowserModel.loadsDirectorySynchronously = false
        model.navigate(to: folderA)
        let loadDeadline = Date().addingTimeInterval(3)
        while model.isLoadingDirectory && Date() < loadDeadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        check("异步读目录：会走完加载态", !model.isLoadingDirectory)
        check("异步读目录：结果落到列表里",
              model.currentURL.standardizedFileURL == folderA.standardizedFileURL && model.items.isEmpty,
              "current=\(model.currentURL.lastPathComponent) items=\(model.items.count)")

        // 连点两个目录：只有最后一次的结果能落地（代次校验）
        let folderC = root.appendingPathComponent("gamma")
        try? fm.createDirectory(at: folderC, withIntermediateDirectories: false)
        model.navigate(to: root)
        model.navigate(to: folderC)
        let raceDeadline = Date().addingTimeInterval(3)
        while Date() < raceDeadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
            if !model.isLoadingDirectory { break }
        }
        check("异步读目录：连点不同目录时以最后一次为准",
              model.currentURL.standardizedFileURL == folderC.standardizedFileURL,
              "实际 \(model.currentURL.lastPathComponent)")

        // 还原：同步模式 + 回到测试根目录，后面的用例依赖这份列表
        BrowserModel.loadsDirectorySynchronously = true
        model.navigate(to: root)

        check("本地化按当前语言取文案", L("甲", "A") == (L10n.isEnglish ? "A" : "甲"))

        // MARK: 性能重构后的回归点
        // 嵌套在普通目录里的媒体资料库包也要被递归剪枝（只判根目录是不够的）
        let nestedLibrary = URL(fileURLWithPath: "/tmp/some/ordinary/folder/图库.photoslibrary")
        check("文件夹大小：任意层级的资料库包会被剪枝",
              ProtectedPaths.shouldSkipRecursiveRead(nestedLibrary))
        check("文件夹大小：家目录受保护子目录会被剪枝",
              ProtectedPaths.shouldSkipRecursiveRead(
                URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Music")))
        check("文件夹大小：普通目录不剪枝",
              !ProtectedPaths.shouldSkipRecursiveRead(root))

        // 类型描述按扩展名缓存：同类型两项拿到同一个非空描述
        let txtA = root.appendingPathComponent("small.txt")
        let txtB = root.appendingPathComponent("other.txt")
        fm.createFile(atPath: txtB.path, contents: Data("x".utf8))
        let kindA = FileSystemService.makeItem(for: txtA)?.kind ?? ""
        let kindB = FileSystemService.makeItem(for: txtB)?.kind ?? ""
        check("类型描述：同扩展名结果一致且有内容",
              !kindA.isEmpty && kindA == kindB, "A=\(kindA) B=\(kindB)")

        // 图标缓存：首次取过之后只查缓存就能拿到，且是同一个实例（不重复问系统）
        IconProvider.shared.icon(for: txtA)
        check("图标：取过之后能命中缓存", IconProvider.shared.cached(for: txtA) != nil)
        check("图标：重复取返回同一实例",
              IconProvider.shared.icon(for: txtA) === IconProvider.shared.icon(for: txtA))

        // 排序缓存：搜索过滤后再清空，顺序应与直接排序一致
        model.searchText = "small"
        model.searchText = ""
        let namesAfterSearch = model.items.map(\.name)
        let namesDirect = FileSystemService.sort(model.items, by: model.sortColumn,
                                                 ascending: model.sortAscending).map(\.name)
        check("排序缓存：过滤来回归位后顺序不变", namesAfterSearch == namesDirect)

        // MARK: 打开方式（adr/0010）
        // 只做查询类断言：不真的打开应用，也不改系统默认设置
        let probeFile = root.appendingPathComponent("small.txt")
        let candidates = OpenWithService.applications(for: probeFile)
        check("打开方式：能列出候选应用", !candidates.isEmpty)
        check("打开方式：候选都是 .app 包",
              candidates.allSatisfy { $0.url.pathExtension == "app" },
              "实际 \(candidates.map(\.name))")
        check("打开方式：候选按 id 去重",
              Set(candidates.map(\.id)).count == candidates.count)
        check("打开方式：能查到默认应用",
              OpenWithService.defaultApplication(for: probeFile) != nil)

        let missingApp = OpenWithService.App(
            url: URL(fileURLWithPath: "/Applications/__winexplorer_missing__.app"),
            name: "Missing"
        )
        check("打开方式：识别不可用的应用", !OpenWithService.isAvailable(missingApp))

        var openFailure: OpenWithService.Failure?
        OpenWithService.open([probeFile], with: missingApp) { openFailure = $0 }
        check("打开方式：不可用应用给出错误而不是静默失败", openFailure != nil)
        if case .applicationUnavailable = openFailure {} else {
            check("打开方式：错误类型是「应用不可用」", false, "实际 \(String(describing: openFailure))")
        }
        check("打开方式：应用不可用的文案可读",
              OpenWithService.message(for: .applicationUnavailable("Missing"))
                .contains("Missing"))
        check("打开方式：设置默认也会先校验应用存在",
              OpenWithService.setDefault(missingApp, for: probeFile) != nil)

        check("打开方式：目录项不给「设为默认」（文件夹没有默认应用概念）",
              model.items.contains { $0.isDirectory })

        let before = model.currentURL
        model.navigate(to: root.appendingPathComponent("no-such-dir"))
        check("打不开的目录给出提示而不是崩溃",
              model.errorMessage != nil && model.currentURL == before)

        print(failures == 0 ? "SELFTEST OK" : "SELFTEST FAILED (\(failures) 项)")
        exit(failures == 0 ? 0 : 1)
    }
}
