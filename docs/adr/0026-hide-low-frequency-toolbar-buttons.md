# ADR 0026 · 工具栏隐藏「粘贴」「新建文件夹」

- 状态：已实施（v1.5.6）
- 起因：这两颗按钮在实机上长期是低频/禁用状态（没有可粘贴内容时「粘贴」一直是灰的），
  占着右侧按钮组的位置，却每次都要参与命中判断与重绘。
- 关联：[ADR 0008](0008-toolbar-tabs-left-aligned-no-title.md)（工具栏布局与右对齐）

## 改了什么

`BrowserView.toolbarContent` 的 `.primaryAction` 分组里删掉两个 `Button`：

| 原按钮 | 图标 | 现在从哪用 |
|---|---|---|
| 粘贴 | `doc.on.clipboard` | 右键菜单「粘贴」、文件菜单「粘贴」<kbd>⌘V</kbd> |
| 新建文件夹 | `folder.badge.plus` | 右键菜单「新建文件夹」、文件菜单 <kbd>⇧⌘N</kbd> |

只删 UI，不删能力。两个动作的实现在 `BrowserModel.paste()` / `createFolder()`，
菜单项在 `ExplorerCommands`，快捷键本来就绑在菜单上（不是绑在工具栏按钮上），
所以删按钮不影响任何快捷键。

工具栏剩下：视图模式分段控件 + 「更多」菜单（视图模式 / 排序 / 显示隐藏文件 …）。

## 布局为什么不需要额外调整

- 右侧分组由 `NSToolbarItem.Identifier.flexibleSpace` 顶到最右（[ADR 0008](0008-toolbar-tabs-left-aligned-no-title.md)），
  组内是紧凑排列，删掉中间两项后剩余控件自动靠拢，不会留下占位；
- 没有任何按「按钮个数」计算的宽度 / 固定 spacer，`Picker` 上的 `.frame(width: 116)` 只约束它自己；
- 实测（v1.5.6 窗口截图）：分段控件与「更多」菜单之间是一个正常 item 间距，
  菜单到窗口右边缘的留白与改动前一致，没有空洞或错位。

## 代价

粘贴的可发现性下降：新用户可能不知道 <kbd>⌘V</kbd> 或右键能粘。可接受——
粘贴在没有剪贴板内容时本来就是禁用态，一个常年发灰的按钮没有教学价值；
真要看，右键菜单第一段就有。
