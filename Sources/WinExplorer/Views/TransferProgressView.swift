import SwiftUI

/// 复制 / 跨卷移动的进度卡片，贴在窗口底部中央。
/// 不挡列表操作，只提供进度与取消。
struct TransferProgressView: View {
    let progress: TransferProgress
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(progress.title)
                    .font(.system(size: 12, weight: .semibold))
                Spacer(minLength: 12)
                Text("\(number(progress.completed))/\(number(progress.total)) · \(percent)%")
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            // 自绘进度条：系统 ProgressView 在每秒几十次更新时会被截图抓到空状态
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.primary.opacity(0.10))
                    Capsule()
                        .fill(Color.accentColor)
                        .frame(width: max(2, geometry.size.width * progress.fraction))
                }
            }
            .frame(height: 6)

            HStack(spacing: 8) {
                Text(progress.currentName.isEmpty ? "准备中…" : progress.currentName)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                Button("取消", action: onCancel)
                    .controlSize(.small)
            }
        }
        .padding(12)
        .frame(width: 340)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.15), radius: 14, y: 6)
        .padding(.bottom, 18)
        .transition(.opacity.combined(with: .move(edge: .bottom)))
    }

    private var percent: Int {
        Int((progress.fraction * 100).rounded())
    }

    private func number(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.groupingSeparator = ","
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }
}
