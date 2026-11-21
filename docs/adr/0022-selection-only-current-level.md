# ADR 0022 · 选中后删除没反应（选中项只在当前层里找）

- 状态：已实施（v1.5.3）
- 起因：用户报「选中后删除没有效果」，截图里选中的是树形展开出来的子层文件夹。
- 关联：[ADR 0019](0019-tree-folder-management.md)（树形展开）
- **性质：v1.5.0 引入树形时带进来的回归。**

## 根因

```swift
var selectedItems: [FileItem] {
    items.filter { selection.contains($0.url) }   // items = 当前目录的直接子项
}
```

`items` 从 v1.5.0 起只是「当前目录的直接子项」。
树形展开后，用户选中的项常常位于**子层**（`treeRows` 里、`items` 之外），
于是 `selectedItems` 返回空数组。

而所有批量操作的入口都是同一个形状：

```swift
func requestTrash() {
    let targets = selectedItems
    guard !targets.isEmpty else { return }    // ← 静默返回，什么都不发生
    ...
}
```

**点击有反馈（菜单关闭了），但没有任何操作**——正是用户描述的现象。

## 影响面（都是同一个根因）

删除、彻底删除、复制、剪切、重命名、批量重命名、压缩、解压、移动到…、
打开方式、拖拽发起（`dragURLs`）——全部失效。
状态栏的「已选 N 项 / 共 X」统计也不准。

## 为什么自检没抓到

树形那一批断言只覆盖了「展开 / 折叠 / 缩进 / 层级」，
操作类断言全部基于扁平列表（选中必然在 `items` 里）。
**这提醒一件事：新增一种「列表的呈现方式」时，要重新验证所有「基于列表的选择」的消费方。**

## 修法

引入一个与「可见行」一一对应的数组：

```swift
@Published private(set) var visibleItems: [FileItem] = []
```

在 `rebuildTreeRows` 里同步维护：树形是 `rows.map(\.item)`，扁平就是 `items`。
然后把所有「选中项查询」改为走它：

| 位置 | 原来 | 现在 |
|---|---|---|
| `selectedItems` | `items.filter { selection.contains }` | `visibleItems.filter { … }` |
| `dragURLs` | 同上 | 同上 |
| `index(of:)`（键盘焦点） | `items.firstIndex` | `visibleItems.firstIndex` |
| `moveFocus` / `focusEdge` | `items` | `visibleItems` |
| `focus` / `applyPendingReveal` | 树形时临时 `treeRows.map` | 统一 `visibleItems` |

`visibleItems` 同时是 **`@Published`**：删除后行数变化会带动界面刷新，
状态栏的选中统计也跟着对。

## 有意保留 `items` 的地方

- `selectAll`（⌘A）：访达只选当前文件夹的直接子项，不连带展开出来的子项。
- 文件夹大小统计、目录签名、排序缓存：它们本来就是「当前目录」的概念。
- `creationDirectory` / 新建落点：建在当前目录。

## 验证

自检新增 6 条，重点是**在子层选中再删**：

- 子层选中：`selectedItems` 不是空的
- 子层选中：拖拽也能带走
- 子层选中：删除会进入确认而不是静默返回（`pendingTrash?.count == 1`）
- 子层选中：确认后文件真的被删掉
- 子层选中：删除后选中集合被清空
- 子层选中：可见行里不再有它（等异步重读完成后）

全部自检 zh / en `SELFTEST OK`（373 项）。

## 取舍

- `visibleItems` 是 `rebuildTreeRows` 的副产物，**不是独立的真相来源**。
  单一真相仍然是 `items` + `expandedPaths` + `treeChildren`；
  这个数组只是「当前这一刻界面上有哪些项」的快照，供操作层使用。
- 每次重建多一次 `map` 分配（最多几百个元素），换来操作层不再需要知道树形的存在。
