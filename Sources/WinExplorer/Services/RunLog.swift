import AppKit
import Darwin
import Foundation

/// 运行日志（adr/0015）。
///
/// 偶发问题（右键菜单不弹、列表突然全空）没法靠在仓库里跑自检复现，
/// 只能靠「出事那一刻程序在干什么」的现场记录。所以这里做四件事：
///
/// 1. **关键路径打点**：目录读取、右键菜单构建、目录监听、文件夹大小统计；
/// 2. **主线程卡顿检测**：后台每 100ms 敲一次主线程，超时就记下卡了多久，
///    并把卡住之前的最近事件一起 dump —— 这样能看出「卡在哪个操作之后」；
/// 3. **资源采样**：每 30s 记一次打开的文件描述符数、线程数、常驻内存。
///    句柄/线程泄漏会在这里显形（跑久了才坏的问题十有八九是泄漏）；
/// 4. **落盘**：`~/Library/Logs/WinExplorer/`，按天分文件、单文件超 2MB 轮转。
///
/// 默认开启（`WINEXPLORER_LOG=0` 关掉）。只记路径、数量、耗时，不记文件内容。
final class RunLog {
    static let shared = RunLog()

    /// 日志分类。定宽打印，方便 grep 和肉眼扫。
    enum Category: String {
        case app      // 启动/退出/窗口
        case load     // 目录读取
        case menu     // 右键菜单与子菜单构建
        case watch    // 目录监听与自动刷新
        case size     // 文件夹大小统计
        case perf     // 卡顿与慢操作
        case sys      // 资源采样（fd / 线程 / 内存）
        case user     // 用户动作（导航、重命名、删除…）

        var width: String {
            switch self {
            case .app: return "app  "
            case .load: return "load "
            case .menu: return "menu "
            case .watch: return "watch"
            case .size: return "size "
            case .perf: return "perf "
            case .sys: return "sys  "
            case .user: return "user "
            }
        }
    }

    /// 单文件大小上限，超了就换下一个序号
    private let maxBytes = 2 * 1024 * 1024
    /// 保留的历史文件个数
    private let keepFiles = 5
    /// 主线程超过这个时长没响应就算卡顿
    private let hangThreshold: TimeInterval = 0.5
    /// 卡顿时一并 dump 的最近事件条数
    private let ringCapacity = 40

    /// 日志目录（UI「打开运行日志」用）
    let directory: URL
    /// 当前正在写的文件
    private(set) var currentFile: URL?

    let isEnabled: Bool

    private let writeQueue = DispatchQueue(label: "com.eric.winexplorer.runlog", qos: .utility)
    private let hangQueue = DispatchQueue(label: "com.eric.winexplorer.runlog.hang", qos: .utility)
    private var handle: FileHandle?
    private var bytesWritten = 0

    // 最近事件环形缓冲（卡顿时 dump）
    private let ringLock = NSLock()
    private var ring: [String] = []

    // 主线程心跳状态
    private let beatLock = NSLock()
    private var beatSentAt: Date?
    private var beatReported = false
    private var lastHangEndedAt: Date?

    private static let stamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter
    }()

    private static let day: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private init() {
        let env = ProcessInfo.processInfo.environment
        // 自检默认不打日志：几百条断言会刷屏，需要时显式 WINEXPLORER_LOG=1
        let selftest = env["WINEXPLORER_SELFTEST"] == "1"
        isEnabled = env["WINEXPLORER_LOG"].map { $0 != "0" } ?? !selftest

        let base = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/WinExplorer", isDirectory: true)
        directory = base
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        openTodayFile()
    }

    /// 启动后台任务（卡顿检测 + 资源采样）。由 App 启动时调一次。
    func start() {
        guard isEnabled else { return }
        info(.app, "启动 pid=\(getpid()) version=\(Bundle.main.shortVersion) macOS=\(ProcessInfo.processInfo.operatingSystemVersionString)")
        startHangDetection()
        startResourceSampling()
    }

    /// 右键菜单构建计数。SwiftUI 会为每一行预先构建整套菜单，
    /// 这个数字直接反映「列表重算有多频繁」——资源采样时一起打出来。
    private var menuBuilds = 0
    private let counterLock = NSLock()

    /// 轻量计数（不做格式化、不写盘），可以每行每帧调用
    func recordMenuBuild() {
        guard isEnabled else { return }
        counterLock.lock()
        menuBuilds += 1
        counterLock.unlock()
    }

    private func drainMenuBuilds() -> Int {
        counterLock.lock()
        let value = menuBuilds
        menuBuilds = 0
        counterLock.unlock()
        return value
    }

    // MARK: - 对外接口

    func log(_ category: Category, _ message: @autoclosure () -> String) {
        guard isEnabled else { return }
        let line = format(category, message())
        appendToRing(line)
        writeQueue.async { [weak self] in self?.write(line) }
    }

    func info(_ category: Category, _ message: @autoclosure () -> String) {
        log(category, message())
    }

    /// 只进环形缓冲、不写盘。用于高频动作（每行菜单求值、每次监听触发），
    /// 平时不落盘免得刷爆，出卡顿时才会跟着 dump 出来。
    ///
    /// **必须节流**：SwiftUI 会为列表每一行预先构建右键菜单，一帧内能调几百次；
    /// 而 `format` 里的 DateFormatter 是重活 —— 不节流的话日志本身就成了卡顿源。
    /// 50ms 内同类事件只留一条，参数用 autoclosure 保证被丢弃的调用不白算。
    private var lastNoteAt: [String: Date] = [:]

    func note(_ category: Category, _ message: @autoclosure () -> String) {
        guard isEnabled else { return }
        let now = Date()
        if let last = lastNoteAt[category.rawValue],
           now.timeIntervalSince(last) < 0.05 {
            return
        }
        lastNoteAt[category.rawValue] = now
        appendToRing(format(category, message()))
    }

    /// 记录一次可能很慢的同步操作：正常就返回结果，超阈值才落盘一条。
    @discardableResult
    func timed<T>(_ category: Category, _ label: @autoclosure () -> String,
                  threshold: TimeInterval = 0.15, _ body: () -> T) -> T {
        guard isEnabled else { return body() }
        let started = Date()
        let result = body()
        let elapsed = Date().timeIntervalSince(started)
        let text = label()
        if elapsed >= threshold {
            log(category, "\(text) 耗时 \(ms(elapsed))")
        } else {
            note(category, "\(text) 耗时 \(ms(elapsed))")
        }
        return result
    }

    /// 把日志目录暴露给 Finder（「打开运行日志」菜单用）
    func revealInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([currentFile ?? directory])
    }

    // MARK: - 写盘

    private func format(_ category: Category, _ message: String) -> String {
        "\(Self.stamp.string(from: Date())) [\(category.width)] \(message)"
    }

    private func appendToRing(_ line: String) {
        ringLock.lock()
        ring.append(line)
        if ring.count > ringCapacity {
            ring.removeFirst(ring.count - ringCapacity)
        }
        ringLock.unlock()
    }

    private func drainRing() -> [String] {
        ringLock.lock()
        let copy = ring
        ringLock.unlock()
        return copy
    }

    private func openTodayFile() {
        let name = "WinExplorer-\(Self.day.string(from: Date()))"
        var url = directory.appendingPathComponent("\(name).log")
        var index = 2
        // 当天已有且写满 → 换序号
        while let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int,
              size >= maxBytes {
            url = directory.appendingPathComponent("\(name)-\(index).log")
            index += 1
        }
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        handle = try? FileHandle(forWritingTo: url)
        handle?.seekToEndOfFile()
        bytesWritten = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        currentFile = url
        pruneOldFiles()
    }

    private func write(_ line: String) {
        guard let data = (line + "\n").data(using: .utf8) else { return }
        if bytesWritten + data.count > maxBytes {
            try? handle?.close()
            handle = nil
            openTodayFile()
            let rotated = "\(Self.stamp.string(from: Date())) [app  ] 日志轮转到 \(currentFile?.lastPathComponent ?? "?")"
            if let extra = (rotated + "\n").data(using: .utf8) {
                handle?.write(extra)
                bytesWritten += extra.count
            }
        }
        handle?.write(data)
        bytesWritten += data.count
    }

    /// 只保留最近 keepFiles 个日志文件，避免长期运行把盘写满
    private func pruneOldFiles() {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey]
        )) ?? []
        let logs = files
            .filter { $0.pathExtension == "log" }
            .sorted { a, b in
                let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return da > db
            }
        for url in logs.dropFirst(keepFiles) where url != currentFile {
            try? FileManager.default.removeItem(at: url)
        }
    }

    // MARK: - 主线程卡顿检测

    /// 后台往主队列投心跳：投出去后迟迟不执行，说明主线程被堵住了。
    /// 这一招不需要 hook runloop，也不受任何业务代码影响。
    private func startHangDetection() {
        let timer = DispatchSource.makeTimerSource(queue: hangQueue)
        timer.schedule(deadline: .now() + 0.1, repeating: 0.1, leeway: .milliseconds(20))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let now = Date()

            self.beatLock.lock()
            let pending = self.beatSentAt
            self.beatLock.unlock()

            if let pending {
                let elapsed = now.timeIntervalSince(pending)
                if elapsed >= self.hangThreshold {
                    self.beatLock.lock()
                    let already = self.beatReported
                    self.beatReported = true
                    self.beatLock.unlock()
                    if !already {
                        self.recordHang(seconds: elapsed)
                    }
                }
                return   // 上一拍还没回来，不再继续投，避免事件刷屏
            }

            self.beatLock.lock()
            self.beatSentAt = now
            self.beatReported = false
            self.beatLock.unlock()

            DispatchQueue.main.async {
                self.beatLock.lock()
                let startedAt = self.beatSentAt
                self.beatSentAt = nil
                let wasReported = self.beatReported
                self.beatReported = false
                if wasReported { self.lastHangEndedAt = Date() }
                self.beatLock.unlock()

                // 卡顿结束后补一条时长，方便把「开始」和「恢复」对上
                if wasReported, let startedAt {
                    let total = Date().timeIntervalSince(startedAt)
                    self.log(.perf, "主线程恢复，本次卡顿共 \(self.ms(total))")
                }
            }
        }
        timer.resume()
        hangTimer = timer
    }

    private var hangTimer: DispatchSourceTimer?

    private func recordHang(seconds: TimeInterval) {
        var lines = ["主线程卡顿 ≥ \(ms(seconds))，正在 dump 卡住前最近 \(ringCapacity) 条事件："]
        for event in drainRing() {
            lines.append("    │ \(event)")
        }
        lines.append("主线程尚未恢复（后续会有一条「主线程恢复」）")
        for line in lines {
            write(format(.perf, line))
        }
    }

    // MARK: - 资源采样

    /// 句柄/线程/内存泄漏会在这里逐次爬升 —— 这是「跑久了才坏」的典型特征
    private func startResourceSampling() {
        let timer = DispatchSource.makeTimerSource(queue: hangQueue)
        timer.schedule(deadline: .now() + 5, repeating: 30, leeway: .seconds(3))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let sample = Self.resources()
            let menuBuilds = self.drainMenuBuilds()
            DispatchQueue.main.async {
                let geometry = Self.windowGeometry()
                // menuBuilds 是这一轮的「列表重算强度」：异常高说明视图在反复全量刷新
                self.log(.sys, "fd=\(sample.fd) threads=\(sample.threads) rss=\(sample.rssMB)MB menuBuilds=\(menuBuilds) \(geometry)")
            }
        }
        timer.resume()
        resourceTimer = timer
    }

    private var resourceTimer: DispatchSourceTimer?

    /// 主窗口内容区的尺寸。用户报「列表一片空白」时，这一项能立刻区分
    /// 「数据为空」和「视图被压成 0 尺寸」——两者修法完全不同。
    @MainActor
    static func windowGeometry() -> String {
        let windows = NSApp.windows.filter { $0.isVisible && $0.contentView != nil }
        guard let main = windows.first(where: { $0.contentView?.bounds.height ?? 0 > 100 }) ?? windows.first
        else { return "windows=0" }
        let bounds = main.contentView?.bounds ?? .zero
        return "windows=\(windows.count) content=\(Int(bounds.width))x\(Int(bounds.height))"
    }

    /// 当前进程的 fd 数 / 线程数 / 常驻内存
    static func resources() -> (fd: Int, threads: Int, rssMB: Int) {
        let fd = (try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count) ?? -1
        var info = proc_taskinfo()
        let size = Int32(MemoryLayout<proc_taskinfo>.size)
        let ok = proc_pidinfo(getpid(), PROC_PIDTASKINFO, 0, &info, size)
        guard ok > 0 else { return (fd, -1, -1) }
        return (fd, Int(info.pti_threadnum), Int(info.pti_resident_size / 1_048_576))
    }

    private func ms(_ seconds: TimeInterval) -> String {
        String(format: "%.0fms", seconds * 1000)
    }
}

extension Bundle {
    /// 版本号（日志里带上，方便对照是哪一版出的问题）
    var shortVersion: String {
        (infoDictionary?["CFBundleShortVersionString"] as? String) ?? "?"
    }
}
