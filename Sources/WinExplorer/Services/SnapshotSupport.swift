import AppKit

/// 开发期自检工具：设置环境变量 WINEXPLORER_SNAPSHOT=/tmp/x.png 启动时，
/// 窗口渲染完成后把内容截成 PNG 再退出。用于在无"屏幕录制"权限的环境下验证 UI。
enum SnapshotSupport {
    static func scheduleIfNeeded() {
        guard let path = ProcessInfo.processInfo.environment["WINEXPLORER_SNAPSHOT"] else { return }

        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }),
                  let view = window.contentView else {
                FileHandle.standardError.write(Data("snapshot: 找不到窗口\n".utf8))
                NSApp.terminate(nil)
                return
            }

            let bounds = view.bounds
            if let rep = view.bitmapImageRepForCachingDisplay(in: bounds) {
                view.cacheDisplay(in: bounds, to: rep)
                if let data = rep.representation(using: .png, properties: [:]) {
                    try? data.write(to: URL(fileURLWithPath: path))
                }
            }

            NSApp.terminate(nil)
        }
    }
}
