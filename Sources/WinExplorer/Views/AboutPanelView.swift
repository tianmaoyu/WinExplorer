import AppKit
import SwiftUI

/// 关于面板（窗口内浮层，和属性面板同一套观感）。
struct AboutPanelView: View {
    let onClose: () -> Void

    private var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    }

    private var build: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.16)
                .ignoresSafeArea()
                .onTapGesture(perform: onClose)

            VStack(spacing: 0) {
                header
                Divider()

                VStack(alignment: .leading, spacing: 9) {
                    row(L("版本", "Version"), "\(version) (\(build))")
                    row(L("界面语言", "Language"), L10n.currentLanguageName)
                    row(L("全局唤起", "Show anywhere"), GlobalHotKey.shortcutText)
                    row(L("技术栈", "Built with"), "SwiftUI + Swift · macOS 14+")

                    Text(L(
                        "完全用原生 Swift 实现，没有第三方依赖；所有文件操作都在系统 API 上完成，不进废纸篓的删除也会再确认一次。",
                        "Written entirely in Swift with no third-party dependencies. Every file operation goes through system APIs, and permanent deletes always ask first."
                    ))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
                .frame(maxWidth: .infinity, alignment: .leading)

                Divider()

                HStack {
                    Button(L("复制诊断信息", "Copy diagnostics")) {
                        let text = """
                        WinExplorer \(version) (\(build))
                        macOS \(ProcessInfo.processInfo.operatingSystemVersionString)
                        \(L10n.currentLanguageName)
                        """
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(text, forType: .string)
                    }
                    .buttonStyle(.link)
                    .font(.system(size: 12))

                    Spacer()
                    Button(L("好", "OK"), action: onClose)
                        .keyboardShortcut(.defaultAction)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 11)
            }
            .frame(width: 430)
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
        HStack(alignment: .center, spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage ?? NSImage())
                .resizable()
                .interpolation(.high)
                .frame(width: 64, height: 64)

            VStack(alignment: .leading, spacing: 3) {
                Text("WinExplorer")
                    .font(.system(size: 17, weight: .semibold))
                Text(L("macOS 上的 Windows 资源管理器", "A Windows Explorer for macOS"))
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }

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
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(label)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .frame(width: 76, alignment: .trailing)
            Text(value)
                .font(.system(size: 11.5))
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
    }
}
