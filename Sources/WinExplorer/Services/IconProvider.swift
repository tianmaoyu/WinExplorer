import AppKit

/// 文件图标缓存。用系统真实图标，视觉上和 Windows 资源管理器一样"认得出文件"。
final class IconProvider {
    static let shared = IconProvider()

    private let cache = NSCache<NSURL, NSImage>()

    private init() {
        cache.countLimit = 600
    }

    func icon(for url: URL) -> NSImage {
        let key = url as NSURL
        if let cached = cache.object(forKey: key) {
            return cached
        }
        let image = NSWorkspace.shared.icon(forFile: url.path)
        image.size = NSSize(width: 16, height: 16)
        cache.setObject(image, forKey: key)
        return image
    }
}
