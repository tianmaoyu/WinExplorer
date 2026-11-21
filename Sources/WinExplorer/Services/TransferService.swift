import Foundation

/// 一次传输任务：把 source 搬到/复制到 destination（destination 是完整目标路径）
struct TransferRequest {
    enum Mode {
        case copy
        case move
    }

    let source: URL
    let destination: URL
    let mode: Mode
}

/// 传输进度。completed / total 以「叶子文件数」计，所以单个大目录也能看到推进。
/// 压缩 / 解压这类交给系统子进程、拿不到细粒度进度的工作用 `indeterminate` 显示忙碌条。
struct TransferProgress: Equatable {
    var title: String
    var completed: Int
    var total: Int
    var currentName: String
    var indeterminate: Bool = false

    var fraction: Double {
        guard total > 0 else { return 0 }
        return min(1, Double(completed) / Double(total))
    }
}

/// 跨线程的取消标记
final class TransferCancellation {
    private let lock = NSLock()
    private var flag = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return flag
    }

    func cancel() {
        lock.lock()
        flag = true
        lock.unlock()
    }
}

/// 文件复制 / 移动。复制走逐文件递归，好处是能报告细粒度进度、能在文件之间取消，
/// 同时仍然用 FileManager.copyItem 复制每个叶子文件，元数据（标签、扩展属性）由系统处理。
enum TransferService {

    struct Result {
        var moved: [URL] = []
        var copied: [URL] = []
        var failures: [String] = []
        var cancelled = false
    }

    enum TransferError: Error, LocalizedError {
        case cancelled

        var errorDescription: String? {
            switch self {
            case .cancelled: return L("已取消", "Cancelled")
            }
        }
    }

    // MARK: - 卷与命名

    /// 是否同一个卷（同卷移动可以用 moveItem 瞬时完成）
    static func sameVolume(_ a: URL, _ b: URL) -> Bool {
        let keys: Set<URLResourceKey> = [.volumeIdentifierKey]
        let va = try? a.resourceValues(forKeys: keys).volumeIdentifier
        let vb = try? b.resourceValues(forKeys: keys).volumeIdentifier
        guard let va, let vb else {
            // 取不到就退回用挂载点前缀猜
            return a.path.hasPrefix("/") && b.path.hasPrefix("/")
        }
        return String(describing: va) == String(describing: vb)
    }

    /// 同名时生成 Windows 风格的「副本」名字：报告.pdf → 报告 副本.pdf → 报告 副本 2.pdf
    static func uniqueDestination(for source: URL, in directory: URL) -> URL {
        let fm = FileManager.default
        let name = source.lastPathComponent
        let direct = directory.appendingPathComponent(name)
        guard fm.fileExists(atPath: direct.path) else { return direct }

        let nsName = name as NSString
        let ext = nsName.pathExtension
        let base = nsName.deletingPathExtension
        let safeBase = base.isEmpty ? name : base

        var index = 1
        while index < 1000 {
            let suffix = index == 1 ? L(" 副本", " copy") : L(" 副本 \(index)", " copy \(index)")
            let candidate = ext.isEmpty
                ? safeBase + suffix
                : safeBase + suffix + "." + ext
            let url = directory.appendingPathComponent(candidate)
            if !fm.fileExists(atPath: url.path) { return url }
            index += 1
        }
        return directory.appendingPathComponent(
            ext.isEmpty ? "\(safeBase)\(L(" 副本", " copy")) \(UUID().uuidString.prefix(4))"
                        : "\(safeBase)\(L(" 副本", " copy")) \(UUID().uuidString.prefix(4)).\(ext)"
        )
    }

    /// 统计叶子文件数（用于进度总量）。符号链接按 1 个算，不跟随。
    static func countFiles(_ url: URL, limit: Int = 100_000) -> Int {
        let fm = FileManager.default
        var count = 0
        var stack = [url]
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey]

        while let current = stack.popLast() {
            let values = try? current.resourceValues(forKeys: keys)
            if values?.isDirectory == true, values?.isSymbolicLink != true {
                if let children = try? fm.contentsOfDirectory(
                    at: current,
                    includingPropertiesForKeys: Array(keys),
                    options: []
                ) {
                    stack.append(contentsOf: children)
                }
            } else {
                count += 1
                if count >= limit { return count }
            }
        }
        return max(count, 1)
    }

    // MARK: - 执行

    /// 在调用线程同步执行；进度回调切到主线程，并按 50ms 节流。
    static func perform(
        requests: [TransferRequest],
        title: String,
        progress: @escaping (TransferProgress) -> Void,
        isCancelled: () -> Bool
    ) -> Result {
        var result = Result()
        let total = requests.reduce(0) { $0 + countFiles($1.source) }
        var completed = 0
        var lastReport = Date.distantPast

        func report(_ name: String, force: Bool = false) {
            let now = Date()
            // 200ms 一次：每一条进度都会让整个文件列表重建（含每行右键菜单），
            // 50ms 的节奏在大列表上等于每秒上千次菜单构建（adr/0016）
            guard force || now.timeIntervalSince(lastReport) > 0.2 else { return }
            lastReport = now
            let snapshot = TransferProgress(
                title: title,
                completed: completed,
                total: max(total, 1),
                currentName: name
            )
            DispatchQueue.main.async { progress(snapshot) }
        }

        report("", force: true)

        for request in requests {
            if isCancelled() {
                result.cancelled = true
                break
            }
            do {
                switch request.mode {
                case .copy:
                    try copyTree(
                        source: request.source,
                        destination: request.destination,
                        isCancelled: isCancelled
                    ) { url in
                        completed += 1
                        report(url.lastPathComponent)
                    }
                    result.copied.append(request.destination)
                case .move:
                    if sameVolume(request.source, request.destination) {
                        try FileManager.default.moveItem(at: request.source, to: request.destination)
                        completed += countFiles(request.destination)
                        report(request.source.lastPathComponent)
                    } else {
                        // 跨卷移动 = 复制 + 删源；删源放在整棵树复制成功之后
                        try copyTree(
                            source: request.source,
                            destination: request.destination,
                            isCancelled: isCancelled
                        ) { url in
                            completed += 1
                            report(url.lastPathComponent)
                        }
                        if isCancelled() { throw TransferError.cancelled }
                        try FileManager.default.removeItem(at: request.source)
                    }
                    result.moved.append(request.destination)
                }
            } catch TransferError.cancelled {
                // 取消时清掉这次没拷完的目标，避免留下半个文件夹。
                // destination 一定是本次新建的路径（重名已提前生成唯一名/被拒绝），删它是安全的。
                try? FileManager.default.removeItem(at: request.destination)
                result.cancelled = true
                break
            } catch {
                result.failures.append("\(request.source.lastPathComponent)：\(error.localizedDescription)")
            }
        }

        return result
    }

    // MARK: - 递归复制

    /// 逐层复制。目录先建出来再往里走，符号链接按链接本身重建（不跟随，避免复制到无穷）。
    private static func copyTree(
        source: URL,
        destination: URL,
        isCancelled: () -> Bool,
        step: (URL) -> Void
    ) throws {
        if isCancelled() { throw TransferError.cancelled }

        let fm = FileManager.default
        let values = try source.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])

        if values.isSymbolicLink == true {
            let target = try fm.destinationOfSymbolicLink(atPath: source.path)
            try fm.createSymbolicLink(atPath: destination.path, withDestinationPath: target)
            step(source)
            return
        }

        if values.isDirectory == true {
            try fm.createDirectory(at: destination, withIntermediateDirectories: true)

            let children = try fm.contentsOfDirectory(
                at: source,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: []
            )
            for child in children {
                if isCancelled() { throw TransferError.cancelled }
                try copyTree(
                    source: child,
                    destination: destination.appendingPathComponent(child.lastPathComponent),
                    isCancelled: isCancelled,
                    step: step
                )
            }

            // 目录本身的时间与权限最后还原，免得被子项的写入改掉
            if let attrs = try? fm.attributesOfItem(atPath: source.path) {
                var restored: [FileAttributeKey: Any] = [:]
                if let date = attrs[.modificationDate] { restored[.modificationDate] = date }
                if let permissions = attrs[.posixPermissions] { restored[.posixPermissions] = permissions }
                try? fm.setAttributes(restored, ofItemAtPath: destination.path)
            }
            return
        }

        try fm.copyItem(at: source, to: destination)
        step(source)
    }
}
