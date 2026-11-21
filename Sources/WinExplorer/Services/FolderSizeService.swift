import Foundation

/// 一次文件夹大小统计任务的取消标记（跨线程安全，避免后台读主线程状态）
final class FolderSizeJob {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
}

/// 文件夹大小的后台统计。
/// - 串行队列：一次只扫一个目录，不把磁盘抢满
/// - 结果按「路径 + 目录修改时间」缓存，目录内容没变就直接复用
/// - 单个目录超过文件数上限就停下，避免卡在几十万文件的目录里
final class FolderSizeService {
    static let shared = FolderSizeService()

    struct Size: Equatable {
        var bytes: Int64
        var fileCount: Int
        /// 命中上限提前结束，界面上加「≥」提示
        var truncated: Bool
        /// 位置受 macOS 隐私保护：没去枚举，界面上显示「—」而不是 0 B
        var skipped: Bool = false

        static var skippedSize: Size {
            Size(bytes: 0, fileCount: 0, truncated: false, skipped: true)
        }
    }

    /// 单个目录最多统计这么多文件
    static let fileLimit = 20_000

    private let queue = DispatchQueue(label: "com.eric.winexplorer.foldersize", qos: .utility)
    /// 只在主线程读写
    private var cache: [String: (modified: Date, size: Size)] = [:]

    private init() {}

    // MARK: - 缓存

    func cached(_ url: URL) -> Size? {
        let standardized = url.standardizedFileURL
        guard let entry = cache[standardized.path] else { return nil }
        guard let modified = Self.modificationDate(of: standardized), modified == entry.modified else {
            cache[standardized.path] = nil
            return nil
        }
        return entry.size
    }

    func store(_ size: Size, for url: URL) {
        // 跳过结果不缓存：规则或系统授权状态变了，下次应该重新判
        guard !size.skipped else { return }
        let standardized = url.standardizedFileURL
        guard let modified = Self.modificationDate(of: standardized) else { return }
        cache[standardized.path] = (modified, size)
    }

    func clear() {
        cache.removeAll()
    }

    // MARK: - 统计

    /// 顺序统计一批目录；每个结果回到主线程回调。`job` 取消后立即停止。
    func compute(
        _ urls: [URL],
        job: FolderSizeJob,
        onResult: @escaping (URL, Size) -> Void
    ) {
        guard !urls.isEmpty else { return }
        queue.async {
            for url in urls {
                if job.isCancelled { return }
                let size = Self.measure(url)
                DispatchQueue.main.async {
                    guard !job.isCancelled else { return }
                    onResult(url, size)
                }
            }
        }
    }

    /// 递归统计（符号链接不跟随；包内部也统计，和 Finder 口径一致）
    ///
    /// 受 macOS 隐私保护的位置**不启动枚举**：`~/音乐/Music` 这类媒体资料库
    /// 只要被递归扫到就会弹系统授权框，而且每次刷新都问一遍。
    /// 用户主动双击进去正常浏览，但「后台自动深入读内容」不做。
    static func measure(_ url: URL) -> Size {
        guard !ProtectedPaths.shouldSkipRecursiveRead(url) else {
            return .skippedSize
        }

        let keys: [URLResourceKey] = [
            .isDirectoryKey,
            .fileSizeKey,
            .totalFileSizeKey,
            .isSymbolicLinkKey
        ]
        var bytes: Int64 = 0
        var count = 0
        var truncated = false

        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: keys,
            options: [],
            errorHandler: { _, _ in true }
        ) else {
            return Size(bytes: 0, fileCount: 0, truncated: false)
        }

        for case let child as URL in enumerator {
            guard let values = try? child.resourceValues(forKeys: Set(keys)) else { continue }
            if values.isSymbolicLink == true { continue }
            if values.isDirectory == true { continue }
            bytes += Int64(values.totalFileSize ?? values.fileSize ?? 0)
            count += 1
            if count >= fileLimit {
                truncated = true
                break
            }
        }

        return Size(bytes: bytes, fileCount: count, truncated: truncated)
    }

    private static func modificationDate(of url: URL) -> Date? {
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
        return values?.contentModificationDate
    }
}
