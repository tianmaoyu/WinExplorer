import Foundation

/// 一条可撤销的操作。undo / redo 都只做文件系统层面的动作，
/// 界面刷新由 BrowserModel 统一负责。
struct UndoEntry {
    let title: String
    let undo: () -> Void
    let redo: () -> Void
}
