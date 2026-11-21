import Foundation

/// 树形列表里的一行（adr/0019）。
///
/// 并不存在一棵真实的「树」对象：磁盘本身就是树，这里只保存
/// 「哪些文件夹展开了」+「展开过的文件夹里有什么」，
/// 每次需要展示时把它**扁平化**成一个数组交给 `LazyVStack`。
/// 这样列表视图的渲染、选择、拖拽全部沿用原来的实现，只是多了一列缩进。
struct TreeRow: Identifiable {
    let item: FileItem
    /// 缩进层级：当前目录为 0，每展开一层 +1
    let depth: Int
    /// 这一行是不是展开状态（只有文件夹可能为 true）
    let isExpanded: Bool

    /// 用 URL 作为唯一标识：文件系统里路径天然唯一，
    /// 不需要额外造 ID，也不怕重名（重名只可能出现在不同目录）。
    var id: URL { item.url }
}
