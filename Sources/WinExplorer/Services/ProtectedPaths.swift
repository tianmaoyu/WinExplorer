import Foundation

/// macOS 隐私保护（TCC）位置的集中判定。
///
/// 起因：v1.0.0 加的「计算文件夹大小」会对当前目录里的每个文件夹递归枚举。
/// 用户站在个人文件夹时，它会钻进 `~/音乐/Music`，macOS 立刻弹出
/// 「“WinExplorer.app” 想访问 Apple Music、你的音乐与视频活动以及你的媒体资料库」；
/// 每刷一次目录就再问一次，看起来就是「一直弹框」。
///
/// 系统对下列位置的**内容读取**做隐私保护，应用去枚举会触发授权框：
/// 桌面 / 文稿 / 下载、音乐 / 影片 / 图片（含媒体资料库）、资源库（含 iCloud 云盘
/// 与其他 App 容器）、外置与网络卷、其他用户的家目录、照片 / 音乐资料库包。
///
/// 规则分两层，别混为一谈：
/// - 用户**主动进入**某个目录：照常列出这一层，这是用户预期内的行为，不拦。
/// - 应用**后台自动递归**（文件夹大小、属性面板统计、取系统图标）：一律不进。
///
/// 换句话说：这里管的是「我们主动深入受保护的地盘」，不是「用户点开看一眼」。
/// 所有判断只做字符串比较，不碰文件系统，不会引出任何额外访问。
enum ProtectedPaths {

    /// 家目录第一层里受 TCC 保护 / 含系统资料库的位置（小写比较）
    private static let homeProtected: Set<String> = [
        "desktop", "documents", "downloads",
        "music", "movies", "pictures",
        "library"
    ]

    /// 媒体 / 照片资料库包的扩展名（任意位置都不主动深入）
    private static let mediaBundles: Set<String> = [
        "musiclibrary", "ituneslibrary", "photoslibrary",
        "aplibrary", "migrantlibrary", "photolibrary"
    ]

    private static var homePath: String {
        URL(fileURLWithPath: NSHomeDirectory()).standardizedFileURL.path
    }

    private static var homeName: String {
        (homePath as NSString).lastPathComponent
    }

    /// 是否属于「不该自动递归读取内容」的位置。
    /// 也是授权浮层判断是否要给「打开系统设置」入口的依据。
    static func shouldSkipRecursiveRead(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        let home = homePath

        // 任意位置的媒体 / 照片资料库包，例如「图库.photoslibrary」
        if mediaBundles.contains((path as NSString).pathExtension.lowercased()) {
            return true
        }

        // 家目录本身不拦（用户就站在这里，只列一层是允许的），
        // 拦的是它下面的受保护子树。
        if path == home { return false }
        if path.hasPrefix(home + "/") {
            let rest = String(path.dropFirst(home.count + 1))
            let first = (rest as NSString).pathComponents.first?.lowercased() ?? ""
            return homeProtected.contains(first)
        }

        // 其他用户的家目录（/Users/Shared 也一并跳过）
        if path.hasPrefix("/Users/") {
            let rest = String(path.dropFirst("/Users/".count))
            let user = (rest as NSString).pathComponents.first ?? ""
            if !user.isEmpty, user != homeName { return true }
        }

        // 外置卷 / 网络卷（TCC RemovableVolumes / NetworkVolumes）
        if path == "/Volumes" || path.hasPrefix("/Volumes/") { return true }

        return false
    }

    /// 是否连「取系统图标」都要避开。
    ///
    /// 比 `shouldSkipRecursiveRead` 窄得多：只有真正会被系统当成媒体资料库的项
    /// （`*.photoslibrary` / `~/音乐/Music` 这类）才避开 `NSWorkspace.icon(forFile:)`。
    /// 家目录里的「图片 / 文稿 / 下载 …」是**可读的**，图标必须保持正常，
    /// 否则会和上一版「未授权项淡显」混淆。
    static func shouldAvoidSystemIcon(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        if mediaBundles.contains((path as NSString).pathExtension.lowercased()) {
            return true
        }
        let home = homePath
        guard path.hasPrefix(home + "/") else { return false }
        let rest = String(path.dropFirst(home.count + 1))
        let parts = (rest as NSString).pathComponents.map { $0.lowercased() }
        guard let first = parts.first,
              ["music", "movies", "pictures"].contains(first),
              parts.count >= 2 else { return false }
        return true
    }

    /// 给界面用的一句解释（本地化）
    static var skipReason: String {
        L(
            "受 macOS 隐私保护，跳过自动统计",
            "Protected by macOS — automatic scanning skipped"
        )
    }
}
