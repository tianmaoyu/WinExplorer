import AppKit
import Foundation
import UniformTypeIdentifiers

/// 「打开方式」——把一个或多个文件交给指定应用打开，也可以把它设为该类型
/// 文件的默认应用（adr/0010）。
///
/// 全部走 LaunchServices（`NSWorkspace`），不用 AppleScript：后者会触发
/// 「想控制某应用」的自动化授权弹框，而这里只是把文件 URL 递过去。
enum OpenWithService {

    /// 一个候选应用（`.app` 包）
    struct App: Identifiable, Hashable {
        let url: URL
        let name: String
        var id: String { url.standardizedFileURL.path }
    }

    enum Failure: Error {
        /// 应用已被移动 / 删除 / 不是应用包
        case applicationUnavailable(String)
        /// 文件本身读不了（权限不足）
        case permissionDenied(String)
        /// LaunchServices 返回的其他错误
        case failed(String)
    }

    // MARK: - 查询

    /// 系统里能打开该文件的候选应用：去重、按名称排序、默认应用排最前
    static func applications(for fileURL: URL, limit: Int = 8) -> [App] {
        let urls = NSWorkspace.shared.urlsForApplications(toOpen: fileURL)
        let fm = FileManager.default

        var seen = Set<String>()
        var apps: [App] = []
        for url in urls.map({ $0.standardizedFileURL })
            .filter({ fm.fileExists(atPath: $0.path) })
            .sorted(by: { displayName($0).localizedStandardCompare(displayName($1)) == .orderedAscending }) {
            // 同一个应用可能有多个副本（/Applications 与 ~/Applications），按 bundle id 去重
            let key = Bundle(url: url)?.bundleIdentifier ?? url.path
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            apps.append(App(url: url, name: displayName(url)))
        }

        // 默认应用提到最前，一眼能看出「现在双击会用谁」
        if let current = defaultApplication(for: fileURL),
           let index = apps.firstIndex(where: { $0.id == current.id }) {
            apps.insert(apps.remove(at: index), at: 0)
        }
        return Array(apps.prefix(limit))
    }

    /// 当前默认打开方式
    static func defaultApplication(for fileURL: URL) -> App? {
        guard let url = NSWorkspace.shared.urlForApplication(toOpen: fileURL) else { return nil }
        return App(url: url.standardizedFileURL, name: displayName(url))
    }

    /// 应用显示名（去掉 .app 后缀）
    static func displayName(_ appURL: URL) -> String {
        let name = FileManager.default.displayName(atPath: appURL.path)
        return name.hasSuffix(".app") ? String(name.dropLast(4)) : name
    }

    /// 应用是否还在（被拖进废纸篓 / 移动过就为 false）
    static func isAvailable(_ app: App) -> Bool {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(
            atPath: app.url.path, isDirectory: &isDirectory
        )
        return exists && isDirectory.boolValue
    }

    // MARK: - 打开

    /// 用指定应用**一次性**打开这些文件，不改系统默认应用。
    ///
    /// 失败路径全部通过 completion 回到主线程：应用不可用、文件无权限、
    /// LaunchServices 报错——都不抛异常、不弹系统框，交给调用方决定怎么提示。
    static func open(_ files: [URL], with app: App, completion: @escaping (Failure?) -> Void) {
        let targets = files.map(\.standardizedFileURL)
        guard !targets.isEmpty else {
            completion(nil)
            return
        }
        guard isAvailable(app) else {
            completion(.applicationUnavailable(app.name))
            return
        }
        // 权限不足的文件 LaunchServices 会静默失败，这里先挡一道给出可读提示
        if let denied = targets.first(where: { !FileManager.default.isReadableFile(atPath: $0.path) }) {
            completion(.permissionDenied(denied.lastPathComponent))
            return
        }

        NSWorkspace.shared.open(
            targets,
            withApplicationAt: app.url,
            configuration: NSWorkspace.OpenConfiguration()
        ) { _, error in
            DispatchQueue.main.async {
                completion(error.map { .failed($0.localizedDescription) })
            }
        }
    }

    /// 把应用设为该类文件的默认打开方式（`LSSetDefaultRoleHandler` 的现代包装）
    static func setDefault(_ app: App, for fileURL: URL) -> Failure? {
        guard isAvailable(app) else { return .applicationUnavailable(app.name) }
        do {
            try NSWorkspace.shared.setDefaultApplication(at: app.url, toOpenFileAt: fileURL)
            return nil
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    // MARK: - 选择应用

    /// 弹系统选应用面板。用户取消返回 nil —— 取消是正常路径，不算错误。
    static func pickApplication() -> App? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.resolvesAliases = true
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = L("选择", "Choose")
        panel.message = L("选择一个应用来打开所选项目", "Choose an app to open the selected items")
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return App(url: url.standardizedFileURL, name: displayName(url))
    }

    // MARK: - 文案

    /// 统一把失败翻译成给用户看的一句话（自检也断言这里）
    static func message(for failure: Failure) -> String {
        switch failure {
        case .applicationUnavailable(let name):
            return L("找不到应用「\(name)」，它可能已被移动或删除",
                     "Can’t find “\(name)” — it may have been moved or deleted")
        case .permissionDenied(let name):
            return L("没有权限读取「\(name)」，请先在系统设置中授予访问权限",
                     "No permission to read “\(name)” — grant access in System Settings first")
        case .failed(let reason):
            return L("打开失败：\(reason)", "Couldn’t open: \(reason)")
        }
    }
}
