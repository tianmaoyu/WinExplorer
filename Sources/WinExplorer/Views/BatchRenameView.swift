import SwiftUI

/// 批量重命名面板（多选后 F2 / 菜单 / 右键进入）。
/// 和彻底删除确认一样是窗口内浮层：所有冲突先在预览里算清楚，点「开始重命名」才动磁盘。
struct BatchRenameView: View {
    @ObservedObject var model: BrowserModel

    @FocusState private var focused: Field?
    @State private var escapeMonitor: Any?

    private enum Field: Hashable {
        case base
        case find
        case replace
    }

    private var state: BatchRenameState {
        model.batchRename ?? BatchRenameState(items: [])
    }

    private var plan: BatchRenamePlan {
        model.batchRenamePlan ?? BatchRenamePlan(rows: [], changes: [], problems: [])
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.18)
                .ignoresSafeArea()
                .onTapGesture { model.cancelBatchRename() }

            VStack(spacing: 0) {
                header
                Divider()
                controls
                    .padding(.horizontal, 18)
                    .padding(.vertical, 14)
                Divider()
                preview
                Divider()
                footer
            }
            .frame(width: 580)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.18), radius: 18, y: 8)
        }
        .transition(.opacity)
        .onAppear {
            // 输入框在某些情况下会抢回焦点（Esc 在文本框里也要能关面板），用本地事件监听兜住
            escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                if event.keyCode == 53 {
                    model.cancelBatchRename()
                    return nil
                }
                return event
            }
            DispatchQueue.main.async {
                focused = state.mode == .sequence ? .base : .find
            }
        }
        .onDisappear {
            if let escapeMonitor {
                NSEvent.removeMonitor(escapeMonitor)
                self.escapeMonitor = nil
            }
        }
    }

    // MARK: - 标题

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "character.cursor.ibeam")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 2) {
                Text(L("批量重命名", "Batch Rename"))
                    .font(.system(size: 13, weight: .semibold))
                Text(L("已选 \(state.items.count) 个项目，按列表顺序编号", "\(state.items.count) items selected, numbered in list order"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            Button {
                model.cancelBatchRename()
            } label: {
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
        .padding(.vertical, 13)
    }

    // MARK: - 规则

    private var controls: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 0) {
                Picker("", selection: modeBinding) {
                    ForEach(BatchRenameMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 220)
                Spacer(minLength: 0)
            }

            if state.mode == .sequence {
                sequenceControls
            } else {
                replaceControls
            }

            Toggle(L("保留扩展名", "Keep extension"), isOn: boolBinding(\.keepExtension))
                .toggleStyle(.checkbox)
                .font(.system(size: 11.5))
        }
    }

    private var sequenceControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                fieldLabel(L("基名", "Base name"))
                TextField(L("例如：旅行照片", "e.g. Vacation"), text: stringBinding(\.baseName))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 190)
                    .focused($focused, equals: .base)

                fieldLabel(L("起始序号", "Start at"))
                TextField("1", value: intBinding(\.startIndex, 0...9999), format: .number)
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 62)
            }

            HStack(spacing: 10) {
                fieldLabel(L("分隔符", "Separator"))
                Picker("", selection: stringBinding(\.separator)) {
                    Text(L("空格", "Space")).tag(" ")
                    Text(L("下划线", "Underscore")).tag("_")
                    Text(L("连字符", "Hyphen")).tag("-")
                    Text(L("无", "None")).tag("")
                }
                .labelsHidden()
                .frame(width: 96)

                fieldLabel(L("序号位数", "Digits"))
                Picker("", selection: intBinding(\.digits, 0...4)) {
                    Text(L("不补零", "No padding")).tag(0)
                    Text(L("2 位", "2 digits")).tag(2)
                    Text(L("3 位", "3 digits")).tag(3)
                    Text(L("4 位", "4 digits")).tag(4)
                }
                .labelsHidden()
                .frame(width: 96)
            }
        }
    }

    private var replaceControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                fieldLabel(L("查找", "Find"))
                TextField(L("要替换的文字", "Text to replace"), text: stringBinding(\.findText))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 190)
                    .focused($focused, equals: .find)

                fieldLabel(L("替换为", "Replace with"))
                TextField(L("留空即删除", "Leave empty to delete"), text: stringBinding(\.replaceText))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 190)
                    .focused($focused, equals: .replace)
            }

            Toggle(L("区分大小写", "Case sensitive"), isOn: boolBinding(\.caseSensitive))
                .toggleStyle(.checkbox)
                .font(.system(size: 11.5))
        }
    }

    private func fieldLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11.5))
            .foregroundStyle(.secondary)
    }

    // MARK: - 预览

    private var preview: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(L("预览", "Preview"))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                if plan.changedCount > 0 {
                    Text(L("\(plan.changedCount) 项将被改名", "\(plan.changedCount) items will be renamed"))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 10)

            ScrollView {
                VStack(spacing: 0) {
                    ForEach(plan.rows) { row in
                        HStack(spacing: 8) {
                            Text(row.originalName)
                                .font(.system(size: 11.5, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .frame(width: 210, alignment: .leading)

                            Image(systemName: "arrow.right")
                                .font(.system(size: 8, weight: .semibold))
                                .foregroundStyle(.tertiary)

                            Text(row.newName)
                                .font(.system(size: 11.5, design: .monospaced))
                                .foregroundStyle(row.problem == nil ? Color.primary : Color.red)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .frame(maxWidth: .infinity, alignment: .leading)

                            if let problem = row.problem {
                                Text(problem)
                                    .font(.system(size: 10.5))
                                    .foregroundStyle(.red)
                                    .lineLimit(1)
                            } else if !row.isChanged {
                                Text(L("不变", "unchanged"))
                                    .font(.system(size: 10.5))
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .padding(.horizontal, 18)
                        .frame(height: 21)
                    }
                }
                .padding(.vertical, 4)
            }
            .frame(maxHeight: 168)
        }
        .padding(.bottom, 10)
    }

    // MARK: - 底部

    private var footer: some View {
        HStack(spacing: 10) {
            Text(statusText)
                .font(.system(size: 11))
                .foregroundStyle(plan.problems.isEmpty ? Color.secondary : Color.orange)
                .lineLimit(1)

            Spacer(minLength: 8)

            Button(L("取消", "Cancel")) { model.cancelBatchRename() }
                .keyboardShortcut(.cancelAction)

            Button(L("开始重命名", "Rename")) { model.applyBatchRename() }
                .buttonStyle(.borderedProminent)
                .disabled(!plan.isApplicable)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 11)
    }

    private var statusText: String {
        if let problem = plan.problems.first { return problem }
        if plan.rows.contains(where: { $0.problem != nil }) {
            return L("有项目存在冲突，修正后才能执行", "Fix the conflicts before renaming")
        }
        if plan.changes.isEmpty { return L("名称没有变化", "Names would not change") }
        return L("将重命名 \(plan.changedCount) 项，可用 ⌘Z 整体撤销", "\(plan.changedCount) items will be renamed — ⌘Z undoes the whole batch")
    }

    // MARK: - 绑定

    private var modeBinding: Binding<BatchRenameMode> {
        Binding(
            get: { state.mode },
            set: { newValue in
                model.updateBatchRename { $0.mode = newValue }
                focused = newValue == .sequence ? .base : .find
            }
        )
    }

    private func stringBinding(_ keyPath: WritableKeyPath<BatchRenameState, String>) -> Binding<String> {
        Binding(
            get: { state[keyPath: keyPath] },
            set: { value in model.updateBatchRename { $0[keyPath: keyPath] = value } }
        )
    }

    private func boolBinding(_ keyPath: WritableKeyPath<BatchRenameState, Bool>) -> Binding<Bool> {
        Binding(
            get: { state[keyPath: keyPath] },
            set: { value in model.updateBatchRename { $0[keyPath: keyPath] = value } }
        )
    }

    private func intBinding(
        _ keyPath: WritableKeyPath<BatchRenameState, Int>,
        _ range: ClosedRange<Int>
    ) -> Binding<Int> {
        Binding(
            get: { state[keyPath: keyPath] },
            set: { value in
                model.updateBatchRename {
                    $0[keyPath: keyPath] = min(max(value, range.lowerBound), range.upperBound)
                }
            }
        )
    }
}
