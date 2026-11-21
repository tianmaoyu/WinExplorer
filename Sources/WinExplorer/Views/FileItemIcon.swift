import AppKit
import SwiftUI

/// 列表里一行的图标。
///
/// 两种情况**不去问系统要图标**（`NSWorkspace.icon(forFile:)` 会多一次文件访问）：
/// - 未授权的项：拿不到真实图标，还会再触发一次访问；
/// - 媒体资料库项（如 `~/音乐/Music`、照片图库包）：单是取图标就可能引出
///   系统授权框。
///
/// 注意「受保护但可读」的目录（桌面 / 文稿 / 下载 …）**仍然用系统真实图标**：
/// 它们只是不参与后台统计，不是不能访问，画成灰色会和未授权项混淆。
struct FileItemIcon: View {
    let item: FileItem
    let size: CGFloat

    /// 异步取到的真实图标；nil 时显示占位
    @State private var loadedIcon: NSImage?

    private var usesGenericIcon: Bool {
        !item.isAccessible || ProtectedPaths.shouldAvoidSystemIcon(item.url)
    }

    /// 未授权项画成淡灰 + 锁；媒体资料库项（可读）画成正常蓝色、无锁
    private var genericTint: Color {
        item.access.isDenied
            ? Color.secondary.opacity(0.55)
            : Color.accentColor.opacity(0.85)
    }

    /// 触发一次图标加载的标识：路径或权限状态变了都要重新取
    private var loadKey: String {
        "\(item.url.path)#\(usesGenericIcon)"
    }

    var body: some View {
        content
            // 图标一律异步取：`NSWorkspace.icon(forFile:)` 会读文件 + 问 LaunchServices，
            // 放在 body 里同步调用会让「进大目录」卡一下（adr/0012）
            .task(id: loadKey) {
                guard !usesGenericIcon else {
                    loadedIcon = nil
                    return
                }
                // 缓存命中就不用起后台任务，首帧直接画真图标
                if let cached = IconProvider.shared.cached(for: item.url) {
                    loadedIcon = cached
                    return
                }
                loadedIcon = nil
                let image = await IconProvider.shared.iconAsync(for: item.url)
                guard !Task.isCancelled else { return }
                loadedIcon = image
            }
    }

    @ViewBuilder
    private var content: some View {
        if !usesGenericIcon {
            if let loadedIcon {
                Image(nsImage: loadedIcon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: size, height: size)
            } else {
                // 占位：和真图标同尺寸同形状，取图期间不跳布局
                Image(systemName: item.isDirectory ? "folder.fill" : "doc.fill")
                    .resizable()
                    .scaledToFit()
                    .frame(width: size * 0.86, height: size * 0.86)
                    .foregroundStyle(Color.secondary.opacity(0.3))
                    .frame(width: size, height: size)
            }
        } else {
            Image(systemName: item.isDirectory ? "folder.fill" : "doc.fill")
                .resizable()
                .scaledToFit()
                .frame(width: size * 0.86, height: size * 0.86)
                .foregroundStyle(genericTint)
                .frame(width: size, height: size)
                .overlay(alignment: .bottomTrailing) {
                    if item.access.isDenied {
                        // 16pt 的行里徽标只有 8pt 左右，实心圆会把锁糊成一坨橙色，
                        // 所以只画锁本身，加一圈底色描边把它从灰色图标上"抠"出来
                        Image(systemName: "lock.fill")
                            .font(.system(size: max(8, size * 0.44), weight: .bold))
                            .foregroundStyle(Color.orange)
                            .shadow(color: Color(nsColor: .windowBackgroundColor), radius: 0.9)
                            .offset(x: size * 0.12, y: size * 0.1)
                    }
                }
        }
    }
}
