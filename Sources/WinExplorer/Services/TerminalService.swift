import AppKit
import Foundation

/// 「在终端中打开」——把文件夹交给终端应用，由它开新窗口并切到该目录。
///
/// 走 LaunchServices 而不是 AppleScript：`do script` 这类 Apple Events 会触发
/// 「想控制 Terminal」的自动化授权弹框，而我们根本不需要控制终端，
/// 只是把一个文件夹 URL 递给它 —— Terminal / iTerm / Warp 都会自行 `cd`。
enum TerminalService {

    struct App: Identifiable, Hashable {
        let name: String
        let url: URL
        var id: String { name }
    }

    /// 系统自带 Terminal 的标准位置
    private static let systemTerminal = "/System/Applications/Utilities/Terminal.app"

    /// 本机可用的终端，按优先级排列；Terminal 永远兜底（系统自带）
    static var available: [App] {
        let fm = FileManager.default
        var result: [App] = []

        let thirdParty: [(name: String, bundle: String)] = [
            ("iTerm", "iTerm.app"),
            ("Warp", "Warp.app")
        ]
        for candidate in thirdParty {
            let url = URL(fileURLWithPath: "/Applications/\(candidate.bundle)")
            if fm.fileExists(atPath: url.path) {
                result.append(App(name: candidate.name, url: url))
            }
        }

        // Terminal：优先用户在 /Applications 的副本，再回退到系统位置
        if fm.fileExists(atPath: "/Applications/Terminal.app") {
            result.append(App(name: "Terminal", url: URL(fileURLWithPath: "/Applications/Terminal.app")))
        } else if fm.fileExists(atPath: systemTerminal) {
            result.append(App(name: "Terminal", url: URL(fileURLWithPath: systemTerminal)))
        }
        return result
    }

    /// 纯构造，供自检断言与 dry-run 展示；不做任何系统调用
    static func handOffDescription(directory: URL, app: App) -> String {
        "open -a \(app.url.path) \(directory.standardizedFileURL.path)"
    }

    /// 在指定终端里打开文件夹。只做一次 LaunchServices 转交，同步返回。
    @discardableResult
    static func open(_ directory: URL, app: App, dryRun: Bool = false) -> Bool {
        let target = directory.standardizedFileURL
        if dryRun { return true }

        let configuration = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.open([target], withApplicationAt: app.url, configuration: configuration)
        return true
    }
}
