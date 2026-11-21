import Foundation

/// 文件夹大小统计的协调者：任务生命周期、缓存命中、后台计算、进度回填。
///
/// 从 BrowserModel 里拆出来的第一块职责（重构第一步，行为不变），顺带修掉两个
/// 卡点：缓存校验（每项一次 `stat`）挪到后台队列；嵌套的受保护目录在递归时剪枝
/// （见 `FolderSizeService.measure`）。
///
/// 所有方法只在主线程调用（和 BrowserModel 一样的约定）。
final class FolderSizeCoordinator: ObservableObject {

    /// 已算出来的大小（path → 大小）
    @Published private(set) var sizes: [String: FolderSizeService.Size] = [:]

    private var job: FolderSizeJob?
    /// 单次最多排队的目录数：一次冲进太多目录只会让磁盘队列排长队
    private let maxPending = 200

    /// 待发布的结果。**不能算完一个就发一次 `@Published`**：
    /// 每次发布都会让整个文件列表重建（连带每一行预先构建整套右键菜单），
    /// 200 个文件夹就是 200 次全量重建 × 行数，主线程直接被拖死。
    /// 所以攒起来，每 150ms 一次批量发布（adr/0016）。
    private var pendingSizes: [String: FolderSizeService.Size] = [:]
    private var flushScheduled = false

    /// 重排统计任务。`enabled == false`（视图没开「计算文件夹大小」）时只清空结果。
    /// `synchronously` 仅供自检：缓存校验与统计都同步完成，方便断言。
    func refresh(folders: [URL], enabled: Bool, synchronously: Bool = false) {
        job?.cancel()
        pendingSizes.removeAll()
        let job = FolderSizeJob()
        self.job = job

        guard enabled, !folders.isEmpty else {
            sizes = [:]
            return
        }

        if synchronously {
            var known: [String: FolderSizeService.Size] = [:]
            for url in folders {
                if let cached = FolderSizeService.shared.cached(url) {
                    known[url.standardizedFileURL.path] = cached
                }
            }
            apply(known: known, folders: folders, job: job, synchronously: true)
            return
        }

        FolderSizeService.shared.cachedSizes(for: folders) { [weak self] known in
            guard let self, !job.isCancelled else { return }
            self.apply(known: known, folders: folders, job: job, synchronously: false)
        }
    }

    func clear() {
        job?.cancel()
        job = nil
        pendingSizes.removeAll()
        sizes = [:]
    }

    // MARK: - 内部

    private func apply(
        known: [String: FolderSizeService.Size],
        folders: [URL],
        job: FolderSizeJob,
        synchronously: Bool
    ) {
        sizes = known
        let pending = folders
            .filter { known[$0.standardizedFileURL.path] == nil }
            .prefix(maxPending)
        guard !pending.isEmpty else { return }

        if synchronously {
            var result = known
            for url in pending {
                let size = FolderSizeService.measure(url)
                FolderSizeService.shared.store(size, for: url)
                result[url.standardizedFileURL.path] = size
            }
            sizes = result
            return
        }

        FolderSizeService.shared.compute(Array(pending), job: job) { [weak self] url, size in
            guard let self, !job.isCancelled else { return }
            FolderSizeService.shared.store(size, for: url)
            self.enqueue(size, for: url)
        }
    }

    /// 攒一小会儿再一次性发布，把「每个文件夹一次刷新」压成「每 150ms 一次」
    private func enqueue(_ size: FolderSizeService.Size, for url: URL) {
        pendingSizes[url.standardizedFileURL.path] = size
        guard !flushScheduled else { return }
        flushScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.flush()
        }
    }

    private func flush() {
        flushScheduled = false
        guard !pendingSizes.isEmpty else { return }
        var merged = sizes
        for (key, size) in pendingSizes { merged[key] = size }
        pendingSizes.removeAll()
        sizes = merged
    }
}
