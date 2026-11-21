import SwiftUI

/// 窗口内的「需要授权」浮层。
///
/// 刻意不用系统 alert / sheet：这里不是告警，而是给用户一个明确的授权入口，
/// 而且它只在用户主动打开或操作某个未授权项时出现（列目录永远不会触发）。
struct AccessRequestView: View {
    let request: AccessRequest
    let onCancel: () -> Void
    let onAuthorize: () -> Void
    let onReveal: () -> Void
    let onOpenSettings: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.18)
                .ignoresSafeArea()
                .onTapGesture(perform: onCancel)

            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "lock.shield.fill")
                        .foregroundStyle(.orange)
                    Text(L("需要授权才能访问", "Access Required"))
                        .font(.system(size: 13, weight: .semibold))
                    Spacer(minLength: 0)
                }

                Text(summary)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let reason = request.reason, !reason.isEmpty {
                    Text(reason)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Text(L(
                    "只是列目录不会打扰你：未授权的项目会显示成浅色带锁，只有你主动打开或操作它时才会出现这个提示。",
                    "Listing a folder never interrupts you: unauthorized items are shown dimmed with a lock, and this prompt only appears when you open or act on one."
                ))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

                if request.needsSystemSettings {
                    Label(
                        L("这个位置受系统隐私保护，需要先在系统设置里放开。",
                          "This location is protected by macOS privacy — allow it in System Settings first."),
                        systemImage: "gearshape"
                    )
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                }

                HStack(spacing: 8) {
                    Button(L("在 Finder 中显示", "Show in Finder"), action: onReveal)
                        .buttonStyle(.bordered)
                        .controlSize(.small)

                    if request.needsSystemSettings {
                        Button(L("打开系统设置", "Open Settings"), action: onOpenSettings)
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }

                    Spacer(minLength: 8)

                    Button(L("取消", "Cancel"), action: onCancel)
                        .keyboardShortcut(.cancelAction)

                    Button(L("选择此项目以授权…", "Choose This Item…"), action: onAuthorize)
                        .buttonStyle(.borderedProminent)
                }
            }
            .padding(16)
            .frame(width: 460, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.18), radius: 18, y: 8)
        }
        .transition(.opacity)
    }

    private var summary: String {
        if request.items.count > 1 {
            return L(
                "选中的 \(request.items.count) 个项目里存在未授权项，需要逐个授权后才能继续。",
                "Some of the \(request.items.count) selected items aren’t authorized. Authorize them to continue."
            )
        }
        if request.items.isEmpty {
            return L(
                "打开「\(request.displayName)」需要访问权限，当前被系统拒绝。",
                "Opening “\(request.displayName)” requires access that macOS is currently denying."
            )
        }
        return L(
            "「\(request.displayName)」当前不可读取，所以在列表里显示为浅色。",
            "“\(request.displayName)” can’t be read right now, so it appears dimmed in the list."
        )
    }
}
