import AppKit

/// 文件图标缓存。用系统真实图标，视觉上和 Windows 资源管理器一样"认得出文件"。
///
/// 为什么要有异步入口：`NSWorkspace.icon(forFile:)` 会真的去问 LaunchServices + 读文件，
/// 在行视图的 `body` 里同步调用意味着「进一个有 500 项的目录 = 主线程 500 次同步查询」，
/// 首次渲染会明显卡一下。列表统一走 `iconAsync(for:)`：先用占位图标顶上，
/// 取到后回填；标签栏 / 路径栏这种一次只画一两个的地方继续用同步版。
final class IconProvider {
    static let shared = IconProvider()

    private let cache = NSCache<NSURL, NSImage>()
    /// 串行队列：一次只生成一个图标，不把 LaunchServices 打满
    private let queue = DispatchQueue(label: "com.eric.winexplorer.icon", qos: .userInitiated)

    private init() {
        // 大目录滚动时 600 太小：淘汰后又要重新问系统
        cache.countLimit = 2000
    }

    /// 只查缓存，绝不触发系统调用（视图首帧用来判断要不要显示占位图标）
    func cached(for url: URL) -> NSImage? {
        cache.object(forKey: url as NSURL)
    }

    /// 同步取图标。只给「一次只画一两个」的地方用（标签 chip、路径栏、侧边栏、属性面板）。
    func icon(for url: URL) -> NSImage {
        if let cached = cached(for: url) { return cached }
        return makeIcon(for: url)
    }

    /// 异步取图标：命中缓存立即返回，否则在后台队列生成。列表行专用。
    func iconAsync(for url: URL) async -> NSImage {
        if let cached = cached(for: url) { return cached }
        return await withCheckedContinuation { continuation in
            queue.async {
                let image = self.makeIcon(for: url)
                DispatchQueue.main.async { continuation.resume(returning: image) }
            }
        }
    }

    /// 真正问系统要图标的唯一入口（会写缓存）
    private func makeIcon(for url: URL) -> NSImage {
        let image = NSWorkspace.shared.icon(forFile: url.path)
        image.size = NSSize(width: 16, height: 16)
        cache.setObject(image, forKey: url as NSURL)
        return image
    }
}
