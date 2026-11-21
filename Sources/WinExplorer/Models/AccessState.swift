import Foundation

/// 一个项目对当前进程的「可否读取」状态。
///
/// 只描述读：写操作失败仍然走原来那套错误提示，不在这里建模。
/// 判定完全靠只读探测（`isReadableFile` / `resourceValues.isReadable`），
/// **不打开文件、不取图标、不递归**，所以列目录时不会引出任何系统授权弹窗。
enum AccessState: String, Hashable {
    /// 正常可读：图标、大小、打开、复制等一律按常规处理
    case granted
    /// 系统不让我们读（POSIX 权限 / ACL / TCC 保护）
    case denied

    var isDenied: Bool { self == .denied }
}

/// 一次「这个项目需要用户授权」的请求，交给窗口内浮层展示。
///
/// 只在用户主动打开 / 操作未授权项，或者主动进入一个打不开的目录时才产生；
/// 仅仅列目录不会生成任何请求。
struct AccessRequest: Identifiable {
    let id = UUID()
    /// 要授权的目标（单个项目，或打不开的那个目录）
    let target: URL
    /// 触发请求的项目。为空表示这是「进入目录被拒」，不是「点了某个项目」
    let items: [FileItem]
    /// 底层原因（目录读取的错误描述 / 上一次授权尝试的结果）
    let reason: String?
    /// 属于 TCC 保护的位置（桌面、文稿、下载、外置卷），需要去系统设置里放开
    let needsSystemSettings: Bool

    /// 标题里显示的名字
    var displayName: String {
        items.count == 1 ? items[0].name : target.lastPathComponent
    }
}
