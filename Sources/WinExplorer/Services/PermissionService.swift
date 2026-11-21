import AppKit
import Foundation

/// 访问权限的探测与授权入口。
///
/// 设计原则：**探测一律只读**。列目录、画列表、算大小都不应该引出系统弹窗；
/// 只有用户主动点「授权」时，才由 `pickInPanel` 拉起一次系统打开面板。
enum PermissionService {

    // MARK: - 探测

    /// 能不能读。`isReadableFile` 只做 access(2) 检查，不打开文件、不触发 TCC 弹窗。
    static func isReadable(_ url: URL) -> Bool {
        FileManager.default.isReadableFile(atPath: url.path)
    }

    /// 目录读取失败是不是「权限」原因（EACCES / EPERM / NSFileReadNoPermission）。
    static func isPermissionDenied(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain,
           nsError.code == CocoaError.fileReadNoPermission.rawValue {
            return true
        }
        if nsError.domain == NSPOSIXErrorDomain,
           nsError.code == Int(EACCES) || nsError.code == Int(EPERM) {
            return true
        }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
            return isPermissionDenied(underlying)
        }
        return false
    }

    /// 属于 TCC 保护的位置：这类拒绝没法靠「重新选一次」解决，得去系统设置。
    /// 规则和后台递归跳过共用一份，免得两处判定漂移。
    static func needsSystemSettings(_ url: URL) -> Bool {
        ProtectedPaths.shouldSkipRecursiveRead(url)
    }

    // MARK: - 授权入口

    /// 让用户在系统面板里明确指向这个项目。返回用户选中的 URL（取消返回 nil）。
    ///
    /// 面板本身不会改变文件权限，作用是把「我确实要给这个项目授权」这件事变成
    /// 一次显式操作；真正的结果以回来之后的 `isReadable` 探测为准。
    static func pickInPanel(target: URL) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.directoryURL = target.deletingLastPathComponent()
        panel.nameFieldStringValue = target.lastPathComponent
        panel.prompt = L("授权", "Authorize")
        panel.message = L(
            "选中「\(target.lastPathComponent)」以确认授权",
            "Select “\(target.lastPathComponent)” to confirm access"
        )
        return panel.runModal() == .OK ? panel.url : nil
    }

    /// 打开「系统设置 → 隐私与安全性 → 文件与文件夹」
    @discardableResult
    static func openPrivacySettings() -> Bool {
        let candidates = [
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_FilesAndFolders",
            "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders"
        ]
        for string in candidates {
            if let url = URL(string: string), NSWorkspace.shared.open(url) {
                return true
            }
        }
        return false
    }
}
