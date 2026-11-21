import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - 行探针

/// 每行铺一个透明探针，只回答一个问题：这个窗口坐标落在哪一行上。
/// 不参与点击（hitTest 返回 nil），所以不影响 SwiftUI 的单击/双击/右键。
final class RowProbeView: NSView {
    var url: URL?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var isOpaque: Bool { false }
}

struct RowProbe: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> RowProbeView {
        let view = RowProbeView()
        view.url = url
        RowProbeRegistry.shared.add(view)
        return view
    }

    func updateNSView(_ nsView: RowProbeView, context: Context) {
        nsView.url = url
        RowProbeRegistry.shared.add(nsView)
    }

    static func dismantleNSView(_ nsView: RowProbeView, coordinator: ()) {
        RowProbeRegistry.shared.remove(nsView)
    }
}

final class RowProbeRegistry {
    static let shared = RowProbeRegistry()

    private var probes: [ObjectIdentifier: WeakProbe] = [:]

    private struct WeakProbe {
        weak var view: RowProbeView?
    }

    func add(_ view: RowProbeView) {
        probes[ObjectIdentifier(view)] = WeakProbe(view: view)
    }

    func remove(_ view: RowProbeView) {
        probes.removeValue(forKey: ObjectIdentifier(view))
    }

    /// point 用窗口坐标（AppKit 左下原点）
    func url(atWindowPoint point: NSPoint) -> URL? {
        probes = probes.filter { $0.value.view != nil && $0.value.view?.window != nil }
        for probe in probes.values {
            guard let view = probe.view, let url = view.url, view.window != nil else { continue }
            let frameInWindow = view.convert(view.bounds, to: nil)
            if frameInWindow.contains(point) { return url }
        }
        return nil
    }

    /// 某个 URL 当前在窗口里的矩形（开发期自检用）
    func windowFrame(for url: URL) -> CGRect? {
        let target = url.standardizedFileURL.path
        for probe in probes.values {
            guard let view = probe.view,
                  let probeURL = view.url,
                  probeURL.standardizedFileURL.path == target,
                  view.window != nil else { continue }
            return view.convert(view.bounds, to: nil)
        }
        return nil
    }
}

// MARK: - 拖拽发起

/// 监听鼠标按下/拖动，命中行时启动一个 AppKit 拖拽会话。
/// 用会话而不是 SwiftUI 的 .onDrag，是因为只有 NSDraggingItem 才能一次带多个文件，
/// 拖到 Finder 也是完整的多个文件。
final class DragCoordinator {
    static let shared = DragCoordinator()

    /// 拖拽开始前的回调：参数是这次被拖的 URL 列表
    var resolveURLs: ((URL, NSEvent) -> [URL])?

    private var downPoint: NSPoint?
    private var downURL: URL?
    private var dragging = false
    private var source: DragSourceDelegate?
    private var monitors: [Any] = []

    private init() {}

    /// 开发期的"干跑"：只记录这次会拖哪些文件，不真的进拖拽会话（会话是模态的，无法自动结束）
    private let dryRun = ProcessInfo.processInfo.environment["WINEXPLORER_DRAG_DRYRUN"] == "1"

    func install() {
        guard monitors.isEmpty else { return }

        let down = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] event in
            self?.handleMouseDown(event)
            return event
        }
        let dragged = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDragged]) { [weak self] event in
            guard let self else { return event }
            if self.handleMouseDragged(event) { return nil }
            return event
        }
        let up = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseUp]) { [weak self] event in
            self?.reset()
            return event
        }

        monitors = [down, dragged, up].compactMap { $0 }
    }

    private func handleMouseDown(_ event: NSEvent) {
        reset()
        guard event.window != nil else { return }
        downPoint = event.locationInWindow
        downURL = RowProbeRegistry.shared.url(atWindowPoint: event.locationInWindow)
    }

    /// 返回 true 表示这次事件已被拖拽消费
    private func handleMouseDragged(_ event: NSEvent) -> Bool {
        guard !dragging, let start = downPoint, let url = downURL else { return false }
        guard let window = event.window, let contentView = window.contentView else { return false }

        let dx = event.locationInWindow.x - start.x
        let dy = event.locationInWindow.y - start.y
        guard dx * dx + dy * dy > 20 else { return false }

        let urls = resolveURLs?(url, event) ?? [url]
        guard !urls.isEmpty else { return false }

        dragging = true
        defer { reset() }

        if dryRun {
            let names = urls.map(\.lastPathComponent).joined(separator: ", ")
            FileHandle.standardError.write(Data("drag: 将拖动 \(urls.count) 项 [\(names)]\n".utf8))
            return true
        }

        let origin = contentView.convert(event.locationInWindow, from: nil)

        var items: [NSDraggingItem] = []
        for (index, draggedURL) in urls.enumerated() {
            let item = NSDraggingItem(pasteboardWriter: draggedURL as NSURL)
            let offset = CGFloat(index) * 6
            let rect = CGRect(
                x: origin.x - 24 + offset,
                y: origin.y - 24 - offset,
                width: 48,
                height: 48
            )
            item.setDraggingFrame(rect, contents: IconProvider.shared.icon(for: draggedURL))
            items.append(item)
        }

        let delegate = DragSourceDelegate()
        source = delegate
        let session = contentView.beginDraggingSession(with: items, event: event, source: delegate)
        session.animatesToStartingPositionsOnCancelOrFail = true
        return true
    }

    private func reset() {
        downPoint = nil
        downURL = nil
        dragging = false
        source = nil
    }
}

final class DragSourceDelegate: NSObject, NSDraggingSource {
    func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        // 拖到别的 App（Finder 等）默认复制；应用内由落点自己判断移动还是复制
        context == .withinApplication ? [.copy, .move] : .copy
    }

    /// 让 ⌥ / ⌘ 这类修饰键继续影响光标与落点判断
    func ignoreModifierKeys(for session: NSDraggingSession) -> Bool { false }
}

// MARK: - 落点解析

enum DropSupport {
    /// 把 onDrop 给的一串 provider 解析成文件 URL
    static func loadURLs(from providers: [NSItemProvider], completion: @escaping ([URL]) -> Void) {
        guard !providers.isEmpty else {
            completion([])
            return
        }

        let group = DispatchGroup()
        let lock = NSLock()
        var ordered = [Int: URL]()

        for (index, provider) in providers.enumerated() {
            group.enter()
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                defer { group.leave() }

                var url: URL?
                switch item {
                case let value as URL: url = value
                case let value as NSURL: url = value as URL
                case let data as Data: url = URL(dataRepresentation: data, relativeTo: nil)
                default: break
                }
                if let url {
                    lock.lock()
                    ordered[index] = url
                    lock.unlock()
                }
            }
        }

        group.notify(queue: .main) {
            completion(ordered.keys.sorted().compactMap { ordered[$0] })
        }
    }
}
