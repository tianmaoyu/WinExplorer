import SwiftUI

/// 彻底删除确认层。刻意做成窗口内的浮层而不是系统 sheet：
/// 系统 sheet 在 App 退出时会以"默认按钮"结束，可能被误当成确认而删掉文件。
/// 这里只有真实鼠标点击「彻底删除」才会执行。
struct DeleteConfirmView: View {
    let items: [FileItem]
    let onCancel: () -> Void
    let onConfirm: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.18)
                .ignoresSafeArea()
                .onTapGesture(perform: onCancel)

            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(L("彻底删除", "Delete Immediately"))
                        .font(.system(size: 13, weight: .semibold))
                }

                Text(message)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 8) {
                    Spacer()
                    Button(L("取消", "Cancel"), action: onCancel)
                        .keyboardShortcut(.cancelAction)
                    Button(L("彻底删除", "Delete"), action: onConfirm)
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                }
            }
            .padding(16)
            .frame(width: 380, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.18), radius: 18, y: 8)
        }
        .transition(.opacity)
    }

    private var message: String {
        let names = items.prefix(3).map(\.name).joined(separator: L("、", ", "))
        let suffix = items.count > 3 ? L(" 等 \(items.count) 项", " and \(items.count) items") : ""
        return L(
            "确定要彻底删除「\(names)」\(suffix)吗？此操作不可恢复，不会进入废纸篓。",
            "Delete “\(names)”\(suffix) permanently? This cannot be undone and does not go to the Trash."
        )
    }
}
