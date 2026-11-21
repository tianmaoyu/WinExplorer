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

            for key in keys {
                postKey(key, to: window)
            }
            // 给 SwiftUI 一点时间把选中态与滚动动画画出来
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                capture(window: window, to: path)
            }
        }
    }

    private static func capture(window: NSWindow, to path: String) {
        guard let view = window.contentView else {
            NSApp.terminate(nil)
            return
        }
        let bounds = view.bounds
        if let rep = view.bitmapImageRepForCachingDisplay(in: bounds) {
            view.cacheDisplay(in: bounds, to: rep)
            if let data = rep.representation(using: .png, properties: [:]) {
                try? data.write(to: URL(fileURLWithPath: path))
                FileHandle.standardError.write(Data("snapshot: 已写入 \(path)\n".utf8))
            }
        }
        NSApp.terminate(nil)
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
            "space": (49, " ")
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

    /// 只覆盖截图脚本会用到的字母键
    private static func keyCodeForCharacter(_ character: String) -> UInt16 {
        let table: [String: UInt16] = [
            "a": 0, "c": 8, "n": 45, "o": 31, "r": 15, "h": 4
        ]
        return table[character] ?? 0
    }
}
