import AppKit
import SwiftUI

/// 列表里一行的图标。
///
/// 未授权的项**不去问系统要图标**：`NSWorkspace.icon(forFile:)` 对被拒的路径拿不到真实
/// 图标，还可能触发额外的文件访问。这里画一个同色系的淡符号 + 右下角橙色锁徽标，
/// 既省一次 IO，也让"这一项打不开"在视觉上一眼可辨。
struct FileItemIcon: View {
    let item: FileItem
    let size: CGFloat

    var body: some View {
        if item.isAccessible {
            Image(nsImage: IconProvider.shared.icon(for: item.url))
                .resizable()
                .interpolation(.high)
                .frame(width: size, height: size)
        } else {
            Image(systemName: item.isDirectory ? "folder.fill" : "doc.fill")
                .resizable()
                .scaledToFit()
                .frame(width: size * 0.86, height: size * 0.86)
                .foregroundStyle(Color.secondary.opacity(0.55))
                .frame(width: size, height: size)
                .overlay(alignment: .bottomTrailing) {
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
