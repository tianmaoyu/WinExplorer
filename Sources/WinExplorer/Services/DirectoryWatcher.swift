import Foundation

/// 监听一个目录的条目变化（新建 / 删除 / 改名），用于自动刷新。
///
/// 用 vnode 事件源（`DispatchSource.makeFileSystemObjectSource`）而不是 FSEventStream：
/// - 资源管理器只需要知道「这个目录的内容变了」，不需要递归监听整棵子树；
/// - vnode 只占一个文件描述符，没有全局流、不需要 runloop 调度，随导航开关成本极低。
///
/// 连续事件用 0.25s 防抖合并（拷贝几千个文件时事件非常密集）。
final class DirectoryWatcher {
    private var source: DispatchSourceFileSystemObject?
    private var descriptor: CInt = -1
    private var debounce: DispatchWorkItem?
    private(set) var watchedPath: String?

    /// 防抖后的变化回调，主线程调用
    var onChange: (() -> Void)?
    /// 防抖间隔（自检里调小，便于快速验证）
    var debounceInterval: TimeInterval = 0.25

    deinit { stop() }

    func watch(_ url: URL) {
        let path = url.standardizedFileURL.path
        guard path != watchedPath else { return }
        stop()

        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else {
            watchedPath = nil
            return
        }
        descriptor = fd
        watchedPath = path

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .delete, .rename, .attrib, .extend],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            self?.scheduleFire()
        }
        source.setCancelHandler {
            close(fd)
        }
        self.source = source
        source.resume()
    }

    func stop() {
        debounce?.cancel()
        debounce = nil
        source?.cancel()
        source = nil
        descriptor = -1
        watchedPath = nil
    }

    private func scheduleFire() {
        debounce?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.debounce = nil
            self?.onChange?()
        }
        debounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + debounceInterval, execute: work)
    }
}
