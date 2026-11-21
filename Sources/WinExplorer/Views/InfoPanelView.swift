import SwiftUI

/// 属性面板（对应 Windows 的「属性」/ Finder 的「显示简介」）。
/// 和彻底删除确认一样做成窗口内浮层：不依赖系统 sheet，退出 App 也不会被当成确认。
struct InfoPanelView: View {
    let state: InfoSheetState
    let onReveal: () -> Void
    let onClose: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.16)
                .ignoresSafeArea()
                .onTapGesture(perform: onClose)

            VStack(alignment: .leading, spacing: 0) {
                header
                Divider()

                VStack(alignment: .leading, spacing: 7) {
                    ForEach(state.fields) { field in
                        fieldRow(field)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)

                if let note = state.note {
                    HStack(spacing: 6) {
                        ProgressView()
                            .controlSize(.small)
                            .scaleEffect(0.7)
                            .frame(width: 12, height: 12)
                        Text(note)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 18)
                    .padding(.bottom, 8)
                }

                Divider()

                HStack(spacing: 8) {
                    Button(L("在 Finder 中显示", "Show in Finder"), action: onReveal)
                        .buttonStyle(.link)
                        .font(.system(size: 12))
                    Spacer()
                    Button(L("好", "OK"), action: onClose)
                        .keyboardShortcut(.defaultAction)
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
            }
            .frame(width: 440)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.18), radius: 18, y: 8)
        }
        .transition(.opacity)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            // 媒体资料库项不去问系统要图标（会引出授权框），其余保持系统真实图标
            if ProtectedPaths.shouldAvoidSystemIcon(state.iconURL) {
                Image(systemName: "folder.fill")
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(Color.accentColor.opacity(0.85))
                    .frame(width: 46, height: 46)
                    .frame(width: 52, height: 52)
            } else {
                Image(nsImage: IconProvider.shared.icon(for: state.iconURL))
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 52, height: 52)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(state.title)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                Text(state.kind)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 2)

            Spacer(minLength: 8)

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .padding(4)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help(L("关闭（Esc）", "Close (Esc)"))
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    private func fieldRow(_ field: InfoField) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(field.label)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .frame(width: 64, alignment: .trailing)
            Text(field.value)
                .font(.system(size: 11.5))
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}
