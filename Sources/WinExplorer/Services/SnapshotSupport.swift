import AppKit

/// 开发期自检工具：
/// - `WINEXPLORER_SNAPSHOT=/tmp/x.png` 窗口渲染完成后自截图并退出
/// - `WINEXPLORER_KEYS=down,down,return` 截图前先向窗口发送按键（走真实响应链，验证键盘处理）
/// 用于在无「屏幕录制 / 辅助功能」权限的环境下验证 UI 与键盘。
enum SnapshotSupport {
    static func scheduleIfNeeded() {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["WINEXPLORER_SNAPSHOT"] else { return }

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
                    postKey(key, to: window)
                }
            }
            let totalDelay = 0.12 * Double(keys.count) + 0.5
            DispatchQueue.main.asyncAfter(deadline: .now() + totalDelay) {
                capture(window: window, to: path)
            }
        }
    }

    private static func capture(window: NSWindow, to path: String) {
        capture(view: window.contentView, to: path)

        // SwiftUI 的 alert 会以 sheet 形式出现，主窗口截图里看不到，单独存一张
        if let sheet = window.attachedSheet {
            let sheetPath = path.replacingOccurrences(of: ".png", with: "-sheet.png")
            capture(view: sheet.contentView, to: sheetPath)
        }

        // 有 sheet（例如删除确认框）在时 terminate 会被模态会话挡住，直接退出进程
        if window.attachedSheet != nil {
            exit(0)
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
