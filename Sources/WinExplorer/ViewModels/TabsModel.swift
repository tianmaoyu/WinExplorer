import AppKit
import Foundation

/// 一个窗口里的多个标签页。每个标签是一份完整的 BrowserModel
/// （各自的目录、历史栈、选择、搜索），互不干扰；剪贴板与拖放是全局共享的。
final class TabsModel: ObservableObject {
    @Published private(set) var tabs: [BrowserModel]
    @Published private(set) var activeIndex: Int

    init(startAt url: URL? = nil) {
        let first = BrowserModel(startAt: url)
        tabs = [first]
        activeIndex = 0
    }

    /// 自检用：直接注入若干已存在的标签
    init(tabs: [BrowserModel], activeIndex: Int = 0) {
        precondition(!tabs.isEmpty)
        self.tabs = tabs
        self.activeIndex = min(max(activeIndex, 0), tabs.count - 1)
    }

    var active: BrowserModel {
        tabs[min(max(activeIndex, 0), tabs.count - 1)]
    }

    var count: Int { tabs.count }

    /// 新标签默认沿用当前目录（Windows 11 是打开「主文件夹」，这里选更少惊喜的做法）
    @discardableResult
    func newTab(at url: URL? = nil) -> BrowserModel {
        let target = url ?? active.currentURL
        let model = BrowserModel(startAt: target)
        tabs.insert(model, at: activeIndex + 1)
        activeIndex += 1
        return model
    }

    /// 关闭指定标签。只剩一个时不关窗口，回到个人文件夹（和「关掉最后一个标签」的心智一致）
    func closeTab(at index: Int) {
        guard tabs.indices.contains(index) else { return }
        guard tabs.count > 1 else {
            tabs[0].goHome()
            return
        }
        tabs.remove(at: index)
        if activeIndex >= tabs.count {
            activeIndex = tabs.count - 1
        } else if index < activeIndex {
            activeIndex -= 1
        }
    }

    func closeActiveTab() {
        closeTab(at: activeIndex)
    }

    func select(_ index: Int) {
        guard tabs.indices.contains(index) else { return }
        tabs[index].closeInfo()
        activeIndex = index
    }

    /// ⌃Tab / ⌃⇧Tab
    func selectNext(_ forward: Bool) {
        guard tabs.count > 1 else { return }
        let delta = forward ? 1 : -1
        let next = (activeIndex + delta + tabs.count) % tabs.count
        select(next)
    }

    func selectTab(withID id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        select(index)
    }

    /// 拖拽排序（从 from 挪到 to 之前）
    func moveTab(from: Int, to: Int) {
        guard tabs.indices.contains(from), to >= 0, to <= tabs.count else { return }
        let activeID = active.id
        let moved = tabs.remove(at: from)
        let target = to > from ? to - 1 : to
        tabs.insert(moved, at: min(max(target, 0), tabs.count))
        if let index = tabs.firstIndex(where: { $0.id == activeID }) {
            activeIndex = index
        }
    }

    // MARK: - 拖文件到标签上传文件（adr/0006）

    /// 把拖进来的文件放入指定标签的当前目录，并切到那个标签。
    /// 标签间与窗口间传文件共用这一个入口。
    func receiveDrop(_ urls: [URL], intoTabAt index: Int, modifiers: NSEvent.ModifierFlags) {
        guard tabs.indices.contains(index) else { return }
        select(index)
        let target = tabs[index]
        target.drop(urls: urls, into: target.currentURL, modifiers: modifiers)
    }

    /// 拖文件到 + 号：新建一个标签（沿用当前目录）并直接放入
    func receiveDropOnPlus(_ urls: [URL], modifiers: NSEvent.ModifierFlags) {
        guard !urls.isEmpty else { return }
        let model = newTab()
        model.drop(urls: urls, into: model.currentURL, modifiers: modifiers)
    }

    /// 文件悬停在标签 chip 上 0.6 秒后自动切过去（Chrome / Windows 11 行为）。
    /// 必须主线程调度 —— dropEntered 回调本来就在主线程。
    private var pendingSwitchWork: DispatchWorkItem?

    func scheduleAutoSwitch(to id: UUID) {
        pendingSwitchWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if let index = tabs.firstIndex(where: { $0.id == id }) {
                select(index)
            }
        }
        pendingSwitchWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    func cancelAutoSwitch() {
        pendingSwitchWork?.cancel()
        pendingSwitchWork = nil
    }
}

extension BrowserModel: Identifiable {
    /// SwiftUI 的 ForEach / 标签栏需要稳定身份（每个标签一个 UUID）
    var id: UUID { tabID }
}
