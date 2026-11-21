import Foundation

/// 一次压缩 / 解压任务的可取消句柄。
/// 真正的耗时工作是 `ditto` / `zip` 子进程，取消就是给它发 SIGTERM，
/// 然后由上层把没写完的产物删掉，避免留下半成品。
final class ArchiveTask {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func attach(_ process: Process) {
        lock.lock()
        self.process = process
        let shouldTerminate = cancelled
        lock.unlock()
        if shouldTerminate { process.terminate() }
    }

    func detach() {
        lock.lock()
        process = nil
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let running = process
        lock.unlock()
        running?.terminate()
    }
}

/// ZIP 压缩 / 解压。
/// - 单个项目用 `ditto --keepParent`：保留权限、时间、扩展属性，压缩包里带一层同名目录/文件
/// - 多个项目用 `zip -r`：ditto 不支持多源归档，zip 会把每个项目平铺在包根目录（和 Windows 一致）
/// - 解压统一用 `ditto -x -k`
enum ArchiveService {

    enum Failure: LocalizedError {
        case cancelled
        case tool(String)
        case unsupported(String)
        case invalid(String)
        case conflicts([String])

        var errorDescription: String? {
            switch self {
            case .cancelled:
                return "已取消"
            case .tool(let message):
                return message
            case .unsupported(let name):
                return "「\(name)」不是 zip 压缩包"
            case .invalid(let message):
                return message
            case .conflicts(let names):
                let list = names.prefix(3).joined(separator: "、")
                    + (names.count > 3 ? " 等" : "")
                return "目标位置已存在同名项目：\(list)，未解压（可改用「解压到同名文件夹」）"
            }
        }
    }

    static func isArchive(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == "zip"
    }

    // MARK: - 目标命名

    /// 压缩包的落点：单个项目用项目名，多个项目用当前文件夹名（Windows 的行为）
    static func compressDestination(for items: [URL], in directory: URL) -> URL {
        let base: String
        if items.count == 1 {
            let name = items[0].lastPathComponent
            let stem = (name as NSString).deletingPathExtension
            base = stem.isEmpty ? name : stem
        } else {
            let folder = directory.lastPathComponent
            base = folder.isEmpty ? "归档" : folder
        }
        return unique(directory.appendingPathComponent(base + ".zip"))
    }

    /// 「解压到「xxx」」用的文件夹落点
    static func extractDestination(for archive: URL, in directory: URL) -> URL {
        let name = archive.lastPathComponent as NSString
        let stem = name.deletingPathExtension
        let base = stem.isEmpty ? archive.lastPathComponent : stem
        return unique(directory.appendingPathComponent(base), isDirectory: true)
    }

    /// 重名时按「名称 2.zip」「名称 3」往后编号，绝不覆盖已有文件
    static func unique(_ url: URL, isDirectory: Bool = false) -> URL {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return url }

        let name = url.lastPathComponent as NSString
        let ext = isDirectory ? "" : name.pathExtension
        let stem = ext.isEmpty ? url.lastPathComponent : name.deletingPathExtension
        let suffix = ext.isEmpty ? "" : "." + ext

        var index = 2
        while index < 1000 {
            let candidate = url.deletingLastPathComponent()
                .appendingPathComponent("\(stem) \(index)\(suffix)")
            if !fm.fileExists(atPath: candidate.path) { return candidate }
            index += 1
        }
        return url.deletingLastPathComponent()
            .appendingPathComponent("\(stem) \(UUID().uuidString.prefix(4))\(suffix)")
    }

    // MARK: - 压缩

    /// 把一批项目压缩成 destination（调用线程同步执行）
    static func compress(items: [URL], to destination: URL, task: ArchiveTask) throws {
        guard !items.isEmpty else { throw Failure.invalid("没有要压缩的项目") }

        var arguments: [String]
        var workingDirectory: URL?

        if items.count == 1 {
            // --keepParent 对文件夹保留它本身，对文件却会连父目录一起塞进去，
            // 所以只给文件夹加这个参数，单个文件直接放在包根。
            var isDirectory: ObjCBool = false
            FileManager.default.fileExists(atPath: items[0].path, isDirectory: &isDirectory)
            arguments = ["-c", "-k", "--sequesterRsrc"]
            if isDirectory.boolValue { arguments.append("--keepParent") }
            arguments.append(contentsOf: [items[0].path, destination.path])
        } else {
            // zip 需要在父目录里用相对路径打包，否则会把绝对路径写进压缩包
            guard let parent = commonParent(of: items) else {
                throw Failure.invalid("这些项目不在同一个文件夹里，无法一起压缩")
            }
            workingDirectory = parent
            let relatives = items.map { relativePath(of: $0, from: parent) }
            arguments = ["-r", "-y", "-q", destination.path] + relatives
        }

        let tool = items.count == 1 ? "/usr/bin/ditto" : "/usr/bin/zip"
        do {
            try run(tool, arguments, workingDirectory: workingDirectory, task: task)
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    // MARK: - 解压

    /// 解压到指定目录。
    /// 先解到同目录下的临时文件夹，再按最终结构搬过去，这样：
    /// - 包里只有一个顶层文件夹时不会多出一层嵌套（和「归档实用工具」一致）
    /// - 目标是已有目录时能先看清真实文件名再判断冲突，绝不静默覆盖
    /// - 中途失败或取消时只留下干净的现场
    static func extract(archive: URL, to directory: URL, task: ArchiveTask) throws {
        guard isArchive(archive) else { throw Failure.unsupported(archive.lastPathComponent) }
        guard FileManager.default.fileExists(atPath: archive.path) else {
            throw Failure.invalid("「\(archive.lastPathComponent)」已经不在了")
        }

        let fm = FileManager.default
        let destinationExists = fm.fileExists(atPath: directory.path)
        let staging = directory.deletingLastPathComponent()
            .appendingPathComponent(".winexplorer-unzip-\(UUID().uuidString)")

        func cleanup() {
            try? fm.removeItem(at: staging)
        }

        do {
            try fm.createDirectory(at: staging, withIntermediateDirectories: true)
            try run("/usr/bin/ditto", ["-x", "-k", archive.path, staging.path],
                    workingDirectory: nil, task: task)

            let entries = topLevelEntries(of: staging)
            let source = flattenedSource(staging: staging, entries: entries)

            if destinationExists {
                // 目标已有内容：只允许整批无冲突地并进去
                let conflicts = entries.filter {
                    fm.fileExists(atPath: directory.appendingPathComponent($0).path)
                }
                if !conflicts.isEmpty { throw Failure.conflicts(conflicts) }

                if let source {
                    try fm.moveItem(at: source, to: directory)
                } else {
                    for entry in entries {
                        try fm.moveItem(
                            at: staging.appendingPathComponent(entry),
                            to: directory.appendingPathComponent(entry)
                        )
                    }
                }
                cleanup()
            } else {
                if let source {
                    try fm.moveItem(at: source, to: directory)
                    cleanup()
                } else {
                    // 整个暂存目录直接改名成目标目录
                    try fm.moveItem(at: staging, to: directory)
                }
            }
        } catch {
            cleanup()
            throw error
        }
    }

    /// 暂存目录里的顶层项（跳过 macOS 的隐藏伴生目录）
    private static func topLevelEntries(of directory: URL) -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names
            .filter { $0 != "__MACOSX" && $0 != ".DS_Store" }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// 包里只有一个顶层文件夹时返回它（用来消掉多余的一层嵌套），否则返回 nil
    private static func flattenedSource(staging: URL, entries: [String]) -> URL? {
        guard entries.count == 1, let only = entries.first else { return nil }
        let url = staging.appendingPathComponent(only)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return nil }
        return url
    }

    // MARK: - 子进程

    private static func run(
        _ tool: String,
        _ arguments: [String],
        workingDirectory: URL?,
        task: ArchiveTask
    ) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        if let workingDirectory { process.currentDirectoryURL = workingDirectory }

        let errorPipe = Pipe()
        process.standardError = errorPipe
        process.standardOutput = Pipe()

        task.attach(process)
        do {
            try process.run()
        } catch {
            task.detach()
            throw Failure.tool("无法启动系统压缩工具：\(error.localizedDescription)")
        }
        process.waitUntilExit()
        task.detach()

        if task.isCancelled { throw Failure.cancelled }

        guard process.terminationStatus == 0 else {
            let data = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let raw = String(data: data, encoding: .utf8) ?? ""
            let message = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            throw Failure.tool(message.isEmpty
                               ? "压缩工具退出码 \(process.terminationStatus)"
                               : message)
        }
    }

    // MARK: - 路径工具

    private static func commonParent(of urls: [URL]) -> URL? {
        var components = urls[0].deletingLastPathComponent().standardizedFileURL.pathComponents
        for url in urls.dropFirst() {
            let other = url.deletingLastPathComponent().standardizedFileURL.pathComponents
            var shared: [String] = []
            for (lhs, rhs) in zip(components, other) where lhs == rhs {
                shared.append(lhs)
            }
            components = shared
            if components.isEmpty { return nil }
        }
        guard !components.isEmpty else { return nil }
        return URL(fileURLWithPath: NSString.path(withComponents: components))
    }

    private static func relativePath(of url: URL, from base: URL) -> String {
        let baseComponents = base.standardizedFileURL.pathComponents
        let target = url.standardizedFileURL.pathComponents
        guard target.count > baseComponents.count,
              Array(target.prefix(baseComponents.count)) == baseComponents else {
            return url.lastPathComponent
        }
        return target.dropFirst(baseComponents.count).joined(separator: "/")
    }
}
