import SwiftUI

/// 删除确认层（移到废纸篓 / 彻底删除共用）。
///
/// 刻意做成窗口内的浮层而不是系统 sheet：
/// 系统 sheet 在 App 退出时会以"默认按钮"结束，可能被误当成确认而删掉文件。
/// 这里只有真实鼠标点击确认按钮才会执行。
///
/// 文件夹会连子项一起删掉（访达行为），所以进来先异步数一遍里面有多少东西，
/// 在确认框里写清楚「3 个子文件夹、12 个文件将一并删除」——
/// 用户按下确认之前就知道级联范围（adr/0019）。
struct DeleteConfirmView: View {
    enum Mode {
        case trash
        case permanent

        var title: String {
            switch self {
            case .trash: return L("移到废纸篓", "Move to Trash")
            case .permanent: return L("彻底删除", "Delete Immediately")
            }
        }

        var confirmTitle: String {
            switch self {
            case .trash: return L("移到废纸篓", "Move to Trash")
            case .permanent: return L("彻底删除", "Delete")
            }
        }

        var icon: String {
            switch self {
            case .trash: return "trash"
            case .permanent: return "exclamationmark.triangle.fill"
            }
        }

        var iconTint: Color {
            switch self {
            case .trash: return .secondary
            case .permanent: return .orange
            }
        }
    }

    let items: [FileItem]
    var mode: Mode = .permanent
    let onCancel: () -> Void
    let onConfirm: () -> Void

    /// 级联统计结果；nil 表示还在数
    @State private var cascade: Cascade?

    /// 文件夹里有多少东西。只用于文案，不参与删除逻辑。
    struct Cascade {
        var folders = 0
        var files = 0
        var truncated = false

        var isEmpty: Bool { folders == 0 && files == 0 }
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.18)
                .ignoresSafeArea()
                .onTapGesture(perform: onCancel)

            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: mode.icon)
                        .foregroundStyle(mode.iconTint)
                    Text(mode.title)
                        .font(.system(size: 13, weight: .semibold))
                }

                Text(message)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let cascade, !cascade.isEmpty {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.turn.down.right")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.tertiary)
                        Text(cascadeText(cascade))
                            .font(.system(size: 11.5))
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                HStack(spacing: 8) {
                    Spacer()
                    Button(L("取消", "Cancel"), action: onCancel)
                        .keyboardShortcut(.cancelAction)
                    Button(mode.confirmTitle, action: onConfirm)
                        .buttonStyle(.borderedProminent)
                        .tint(mode == .permanent ? .red : .accentColor)
                }
            }
            .padding(16)
            .frame(width: 400, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.18), radius: 18, y: 8)
        }
        .transition(.opacity)
        .onAppear(perform: startCounting)
    }

    // MARK: - 文案

    private var message: String {
        let names = items.prefix(3).map(\.name).joined(separator: L("、", ", "))
        let suffix = items.count > 3 ? L(" 等 \(items.count) 项", " and \(items.count) items") : ""
        switch mode {
        case .trash:
            return L(
                "确定要把「\(names)」\(suffix)移到废纸篓吗？可以从废纸篓恢复。",
                "Move “\(names)”\(suffix) to the Trash? You can restore from the Trash."
            )
        case .permanent:
            return L(
                "确定要彻底删除「\(names)」\(suffix)吗？此操作不可恢复，不会进入废纸篓。",
                "Delete “\(names)”\(suffix) permanently? This cannot be undone and does not go to the Trash."
            )
        }
    }

    private func cascadeText(_ cascade: Cascade) -> String {
        var parts: [String] = []
        if cascade.folders > 0 {
            parts.append(L("\(cascade.folders) 个子文件夹", "\(cascade.folders) subfolder(s)"))
        }
        if cascade.files > 0 {
            parts.append(L("\(cascade.files) 个文件", "\(cascade.files) file(s)"))
        }
        let body = parts.joined(separator: L("、", ", "))
        let tail = cascade.truncated ? L("（数量已截断）", " (count capped)") : ""
        return L("其中包含 \(body)\(tail)，会一并删除",
                 "Includes \(body)\(tail) — they’ll be deleted too")
    }

    // MARK: - 级联统计

    private func startCounting() {
        let folders = items.filter(\.isDirectory).map(\.url)
        guard !folders.isEmpty else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Self.count(folders)
            DispatchQueue.main.async { cascade = result }
        }
    }

    /// 递归数一遍。上限 2000 项：确认框只是给个量级，不值得为几十万文件卡住。
    private static func count(_ folders: [URL]) -> Cascade {
        var result = Cascade()
        let keys: [URLResourceKey] = [.isDirectoryKey]
        for folder in folders {
            guard let enumerator = FileManager.default.enumerator(
                at: folder,
                includingPropertiesForKeys: keys,
                options: []
            ) else { continue }
            for case let child as URL in enumerator {
                guard let values = try? child.resourceValues(forKeys: Set(keys)) else { continue }
                if values.isDirectory == true { result.folders += 1 } else { result.files += 1 }
                if result.folders + result.files >= 2000 {
                    result.truncated = true
                    return result
                }
            }
        }
        return result
    }
}
