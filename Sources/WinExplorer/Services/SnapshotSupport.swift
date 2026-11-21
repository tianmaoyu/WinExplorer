import AppKit
import Quartz

/// 开发期自检工具：
/// - `WINEXPLORER_SNAPSHOT=/tmp/x.png` 窗口渲染完成后自截图并退出
/// - `WINEXPLORER_KEYS=down,down,return` 截图前先向窗口发送按键（走真实响应链，验证键盘处理）
/// 用于在无「屏幕录制 / 辅助功能」权限的环境下验证 UI 与键盘。
enum SnapshotSupport {
    private static var hasScheduled = false

    /// 由根视图在出现时调用，把模型交给截图脚本使用（支持 nav:/路径 这类开发指令）。
    /// 传了 tabs 时，所有指令都作用于「当前标签」，并额外支持 tab: 开头的标签指令。
    static func scheduleIfNeeded(model: BrowserModel, tabs: TabsModel? = nil) {
        // 标签样式对比图：WINEXPLORER_TAB_COMPARE=/path.png，独立对比窗口截图后退出
        if TabStyleCompare.runIfNeeded() { return }

        let env = ProcessInfo.processInfo.environment
        guard env["WINEXPLORER_SNAPSHOT"] != nil else { return }
        guard !hasScheduled else { return }
        hasScheduled = true

        // 截图验收会用 sizes:on / cmd+3 之类的钩子改视图偏好，绝不能写进用户真实的
        // UserDefaults —— 否则一次截图就把「计算文件夹大小」永久打开，重启后
        // 后台递归扫 ~/音乐/Music，引来反复的系统授权弹框。
        Preferences.enabled = false

        let path = env["WINEXPLORER_SNAPSHOT"]!

        let keys = (env["WINEXPLORER_KEYS"] ?? "")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
            guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }) else {
                FileHandle.standardError.write(Data("snapshot: 找不到窗口\n".utf8))
                NSApp.terminate(nil)
                return
            }

            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            FocusKeeper.shared.reclaim()

            if keys.isEmpty {
                capture(window: window, to: path)
                return
            }

            // 逐个按键发送并留出间隔：像 F2 打开输入框这类操作需要等 UI 更新、焦点转移完成
            for (index, key) in keys.enumerated() {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.12 * Double(index)) {
                    let active = tabs?.active ?? model
                    if key.hasPrefix("nav:") {
                        let target = String(key.dropFirst("nav:".count))
                        active.navigate(to: URL(fileURLWithPath: target))
                        return
                    }
                    if key.hasPrefix("tab:") {
                        // tab:new / tab:close / tab:next / tab:prev，验证标签页
                        guard let tabs else { return }
                        switch String(key.dropFirst("tab:".count)) {
                        case "new": tabs.newTab()
                        case "close": tabs.closeActiveTab()
                        case "next": tabs.selectNext(true)
                        case "prev": tabs.selectNext(false)
                        default: break
                        }
                        return
                    }
                    if key.hasPrefix("favorite:") {
                        // favorite:add / favorite:clear，验证收藏夹
                        switch String(key.dropFirst("favorite:".count)) {
                        case "add": _ = FavoritesStore.shared.add(active.currentURL)
                        case "clear":
                            for place in FavoritesStore.shared.items {
                                FavoritesStore.shared.remove(place.url)
                            }
                        default: break
                        }
                        return
                    }
                    if key.hasPrefix("sel:") {
                        // sel:片段 = 选中名字里包含该片段的全部项目（第一个作为焦点，供截图用）
                        let needle = String(key.dropFirst("sel:".count))
                        let matches = active.items.filter { $0.name.contains(needle) }
                        if let first = matches.first {
                            active.handleClick(on: first, modifiers: [])
                            for item in matches.dropFirst() {
                                active.handleClick(on: item, modifiers: [.command])
                            }
                        }
                        return
                    }
                    if key.hasPrefix("rename:") {
                        // rename:batch 或 rename:batch:基名 = 打开批量重命名面板
                        let payload = String(key.dropFirst("rename:".count))
                        let parts = payload.split(separator: ":", maxSplits: 1).map(String.init)
                        if parts.first == "batch" {
                            if active.selection.count < 2 { active.selectAll() }
                            active.beginBatchRename()
                            if parts.count > 1, !parts[1].isEmpty {
                                let base = parts[1]
                                active.updateBatchRename {
                                    $0.baseName = base
                                    $0.digits = 2
                                }
                            }
                        }
                        return
                    }
                    if key == "about" {
                        // 打开关于面板，用于截图验收
                        active.showAbout()
                        return
                    }
                    if key.hasPrefix("sizes:") {
                        // sizes:on / sizes:off，切换文件夹大小统计
                        active.showsFolderSizes = key.hasSuffix("on")
                        return
                    }
                    if key.hasPrefix("new:") {
                        // new:txt|md|csv|rtf|docx|xlsx|pptx，验证右键新建文件
                        let ext = String(key.dropFirst("new:".count))
                        if let kind = NewFileKind.allCases.first(where: { $0.fileExtension == ext }) {
                            active.createFile(kind)
                        }
                        return
                    }
                    if key.hasPrefix("archive:") {
                        // archive:zip / archive:unzip，验证压缩与解压（作用于当前选区）
                        switch String(key.dropFirst("archive:".count)) {
                        case "zip": active.compressSelection()
                        case "unzip": active.extractSelection(toOwnFolder: true)
                        case "unzip-here": active.extractSelection(toOwnFolder: false)
                        default: break
                        }
                        return
                    }
                    if key.hasPrefix("drag:") {
                        dryRunDrag(path: String(key.dropFirst("drag:".count)), window: window)
                        return
                    }
                    if key.hasPrefix("drop:") {
                        // 手动点亮某个落点，用于截图确认拖拽高亮
                        active.dropTargetURL = URL(fileURLWithPath: String(key.dropFirst("drop:".count)))
                        return
                    }
                    if key.hasPrefix("info:") {
                        // 选中并打开属性面板：用于截图验收受保护目录的「跳过统计」说明
                        let name = String(key.dropFirst("info:".count))
                        if let item = active.items.first(where: { $0.name == name }) {
                            active.selectOnly(item)
                            active.showInfo()
                        }
                        return
                    }
                    if key.hasPrefix("open:") {
                        // 选中并"打开"某个项目：用于截图验收未授权项的授权浮层
                        let raw = String(key.dropFirst("open:".count))
                        let url = raw.hasPrefix("/")
                            ? URL(fileURLWithPath: raw)
                            : active.currentURL.appendingPathComponent(raw)
                        let target = url.standardizedFileURL
                        if let item = active.items.first(where: { $0.url.standardizedFileURL.path == target.path }) {
                            active.selectOnly(item)
                            active.open(item)
                        }
                        return
                    }
                    if key.hasPrefix("preview:") {
                        // 选中某个文件并打开 Quick Look（不依赖列表焦点，便于截图验收）
                        let url = URL(fileURLWithPath: String(key.dropFirst("preview:".count)))
                        active.focus(url: url, scroll: false)
                        active.toggleQuickLook()
                        return
                    }
                    if key.hasPrefix("type:") {
                        // 往当前焦点文本框里输入一段文字（模拟打字，用于地址栏/搜索框验证）
                        typeText(String(key.dropFirst("type:".count)))
                        return
                    }
                    if key.hasPrefix("touch:") {
                        // 在当前目录里造一个文件，用来验证目录监听是否真的会触发自动刷新
                        let name = String(key.dropFirst("touch:".count))
                        let url = active.currentURL.appendingPathComponent(name)
                        FileManager.default.createFile(atPath: url.path, contents: Data("snapshot hook".utf8))
                        return
                    }
                    if key == "scroll:end" {
                        // 滚到列表最底部（露出底部留白），截图验收「留空白」用。
                        // 刚 nav: 完布局还没就绪时首次 scrollTo 会扑空，隔 0.35s 重发一次
                        // （token 变化保证 onChange 一定会再触发）。
                        active.scrollRequest = ScrollRequest(trailingBlank: true)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                            active.scrollRequest = ScrollRequest(trailingBlank: true)
                        }
                        return
                    }
                    postKey(key, to: window)
                }
            }
            // WINEXPLORER_SNAPSHOT_DELAY 可以拉长截图前的等待时间，用来抓复制进度这类瞬时状态
            let overrideDelay = ProcessInfo.processInfo.environment["WINEXPLORER_SNAPSHOT_DELAY"]
                .flatMap(Double.init)
            let totalDelay = overrideDelay ?? (0.12 * Double(keys.count) + 0.5)
            DispatchQueue.main.asyncAfter(deadline: .now() + totalDelay) {
                capture(window: window, to: path)
            }
        }
    }

    /// 在指定行上模拟"按下 + 拖动"，配合 WINEXPLORER_DRAG_DRYRUN=1 验证拖拽发起逻辑
    private static func dryRunDrag(path: String, window: NSWindow) {        let url = URL(fileURLWithPath: path)
        guard let frame = RowProbeRegistry.shared.windowFrame(for: url) else {
            FileHandle.standardError.write(Data("snapshot: 找不到行 \(path)\n".utf8))
            return
        }

        let start = NSPoint(x: frame.midX, y: frame.midY)
        sendMouse(.leftMouseDown, at: start, window: window)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            sendMouse(.leftMouseDragged, at: NSPoint(x: start.x + 14, y: start.y + 14), window: window)
        }
    }

    /// 往当前焦点文本框里插入文字（替换选区）
    private static func typeText(_ text: String) {
        guard let editor = NSApp.keyWindow?.firstResponder as? NSTextView else {
            FileHandle.standardError.write(Data("snapshot: 当前没有可输入的文本框\n".utf8))
            return
        }
        editor.insertText(text, replacementRange: editor.selectedRange())
    }

    private static func sendMouse(_ type: NSEvent.EventType, at point: NSPoint, window: NSWindow) {
        guard let event = NSEvent.mouseEvent(
            with: type,
            location: point,
            modifierFlags: NSEvent.modifierFlags,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ) else { return }
        NSApp.sendEvent(event)
    }

    private static func capture(window: NSWindow, to path: String) {
        // contentView 不含标题栏与工具栏（NSWindow 的 chrome 不在 contentView 里）；
        // 验收工具栏（如标签栏）时用 WINEXPLORER_SNAPSHOT_FULL=1 抓整个窗口视图
        if ProcessInfo.processInfo.environment["WINEXPLORER_SNAPSHOT_FULL"] == "1",
           let fullView = window.contentView?.superview {
            // 强制走完绘制事务：工具栏 item 是 layer 宿主，布局更新后不画一遍
            // 会抓到「item 在、像素空」的空壳图；被别的窗口挡住时 layer 也可能
            // 没进绘制事务，先前置再画
            window.orderFrontRegardless()
            window.layoutIfNeeded()
            window.displayIfNeeded()
            if capture(view: fullView, to: path) {
                // 渲染过窗口 chrome 后 NSApp.terminate 会卡在绘制事务里被外层杀掉
                //（exit 137），截图模式本来就用于自退，直接退出
                exit(0)
            }
        }
        capture(view: window.contentView, to: path)

        // SwiftUI 的 alert 会以 sheet 形式出现，主窗口截图里看不到，单独存一张
        if let sheet = window.attachedSheet {
            let sheetPath = path.replacingOccurrences(of: ".png", with: "-sheet.png")
            capture(view: sheet.contentView, to: sheetPath)
        }

        // Quick Look 面板是独立窗口，主窗口截图里看不到，单独存一张
        if QLPreviewPanel.sharedPreviewPanelExists(),
           let panel = QLPreviewPanel.shared(), panel.isVisible, let view = panel.contentView {
            let qlPath = path.replacingOccurrences(of: ".png", with: "-ql.png")
            capture(view: view, to: qlPath)
        }

        // 有 sheet（例如删除确认框）在时 terminate 会被模态会话挡住，直接退出进程
        if window.attachedSheet != nil {
            exit(0)
        }
        // 调试用：截图后留在原地，方便用系统截图抓 QuickLook 这类跨进程渲染的窗口
        if ProcessInfo.processInfo.environment["WINEXPLORER_KEEPALIVE"] == "1" {
            FileHandle.standardError.write(Data("snapshot: 保持运行（KEEPALIVE）\n".utf8))
            return
        }
        NSApp.terminate(nil)
    }

    @discardableResult
    private static func capture(view: NSView?, to path: String) -> Bool {
        guard let view else { return false }
        let bounds = view.bounds
        guard let rep = view.bitmapImageRepForCachingDisplay(in: bounds) else { return false }
        view.cacheDisplay(in: bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return false }
        try? data.write(to: URL(fileURLWithPath: path))
        FileHandle.standardError.write(Data("snapshot: 已写入 \(path)\n".utf8))
        return true
    }

    private static func postKey(_ name: String, to window: NSWindow) {
        let map: [String: (UInt16, String)] = [
            "up": (126, "\u{F700}"),
            "down": (125, "\u{F701}"),
            "pageup": (116, "\u{F72C}"),
            "pagedown": (121, "\u{F72D}"),
            "home": (115, "\u{F729}"),
            "end": (119, "\u{F72B}"),
            "return": (36, "\r"),
            "escape": (53, "\u{1B}"),
            "space": (49, " "),
            "tab": (48, "\t"),
            "f2": (120, "\u{F705}"),
            "delete": (51, "\u{7F}"),
            "forwarddelete": (117, "\u{F728}")
        ]

        // 支持 "cmd+a" / "shift+down" 这种带修饰键的写法
        // "menu:cmd+a" 表示直接走菜单快捷键派发，用来验证快捷键绑定是否存在
        var spec = name
        var useMenu = false
        if spec.hasPrefix("menu:") {
            useMenu = true
            spec = String(spec.dropFirst("menu:".count))
        }

        var parts = spec.split(separator: "+").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        guard let finalKey = parts.popLast() else { return }

        var flags: NSEvent.ModifierFlags = []
        for part in parts {
            switch part {
            case "cmd", "command": flags.insert(.command)
            case "shift": flags.insert(.shift)
            case "opt", "option", "alt": flags.insert(.option)
            case "ctrl", "control": flags.insert(.control)
            case "fn", "function": flags.insert(.function)
            default: break
            }
        }

        let keyCode: UInt16
        let characters: String
        if let mapped = map[finalKey] {
            keyCode = mapped.0
            characters = mapped.1
        } else if finalKey.count == 1 {
            characters = finalKey
            keyCode = keyCodeForCharacter(finalKey)
        } else {
            FileHandle.standardError.write(Data("snapshot: 未知按键 \(name)\n".utf8))
            return
        }

        guard let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: flags,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: keyCode
        ) else { return }

        if useMenu {
            let handled = NSApp.mainMenu?.performKeyEquivalent(with: event) ?? false
            FileHandle.standardError.write(Data("snapshot: 菜单快捷键 \(spec) handled=\(handled)\n".utf8))
        } else {
            NSApp.sendEvent(event)
        }
    }

    /// 覆盖截图脚本会用到的字母键（美式键位 keyCode）
    private static func keyCodeForCharacter(_ character: String) -> UInt16 {
        let table: [String: UInt16] = [
            "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7,
            "c": 8, "v": 9, "b": 11, "q": 12, "w": 13, "e": 14, "r": 15,
            "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22,
            "5": 23, "9": 25, "7": 26, "8": 28, "0": 29, "o": 31, "u": 32,
            "i": 34, "p": 35, "l": 37, "j": 38, "k": 40, "n": 45, "m": 46
        ]
        return table[character] ?? 0
    }
}
