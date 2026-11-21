# ADR 0006 · 标签栏常驻工具栏与传文件三通道

- 状态：已实施（v1.4.0）；**决定 1 的布局部分已被
  [ADR 0008](0008-toolbar-tabs-left-aligned-no-title.md) 修订**
  （标签栏居中 → 最左对齐，窗口标题隐藏，导航按钮移除），传文件三通道语义不变。
- 起因：用户想「像 Windows 一样点 + 再开一个文件夹页面，相互独立、可以相互传文件」。
  标签页 v0.8.0 就有（`⌘T`），但**标签栏在只有一个标签时整条隐藏**，
  UI 上根本没有 `+` 入口；且剪贴板是每个标签私有的，跨标签 `⌘C → ⌘V` 不可用。

## 决定 1 · 标签栏并入窗口工具栏，常驻显示

- `TabBarView` 移入 `ToolbarItem(placement: .principal)`，`navigationTitle` 移除
  （标题栏只留「WinExplorer」），一条工具栏 = 导航按钮 | 标签 chips + `+` | 视图按钮，
  正是 Windows 11 的形态；`+` 与标签 chip 从此永远可见。
- 单标签也显示 chip（Windows 11 相同），`showsClose` 仍按 `count > 1`。
- 副作用：`SnapshotSupport` 的窗口截图（contentView）**从来不含工具栏** ——
  本次排查中发现此前「工具栏消失」是截图盲区误判。新增
  `WINEXPLORER_SNAPSHOT_FULL=1` 抓 `contentView.superview`（含标题栏与工具栏）；
  该路径渲染后直接 `exit(0)`（`NSApp.terminate` 会卡在绘制事务里被杀，exit 137）。

## 决定 2 · 剪贴板全局共享

`ClipboardStore`（单例 ObservableObject）取代每个 `BrowserModel` 私有的
`clipboard` 属性；`BrowserModel.clipboard` 变为转发计算属性，并在 init 里订阅
store 的 `objectWillChange` 转发成自己的 ——「剪切中变淡」在所有标签和窗口
同步刷新。语义与 Windows 一致：`⌘C / ⌘X` 在标签 A（或窗口 A），
切到标签 B 直接 `⌘V`。

## 决定 3 · 拖文件到标签栏也是传文件

chip 的 `onDrop` 同时接受 `.text`（拖 chip 排序）与 `.fileURL`（拖文件），
用 provider 类型区分：

- **拖文件悬停在某个 chip 上**：点亮该标签（强调色描边），0.6 秒后
  `TabsModel.scheduleAutoSwitch` 自动切过去（Chrome / Windows 11 行为），
  松手即落入那个标签的当前目录（`TabsModel.receiveDrop`）
- **拖文件到 `+` 号**：新建一个标签（沿用当前目录）并直接放入
  （`TabsModel.receiveDropOnPlus`）
- 悬停切换必须在主线程调度（dropEntered 回调本来就在主线程），
  dropExited 时取消

## 取舍

- 「拖文件到 chip」没有提供「移动 vs 复制」的选项覆盖层，修饰键沿用
  列表拖拽同一套（⌥ = 复制，默认同卷移动）
- 标签栏宽度上限 520pt，超出靠横向滚动；chip 最宽 168pt + 中间截断
- 没有做「拖文件到已激活 chip 的子文件夹」等花式落点 —— 列表区的落点
  已经覆盖，标签栏只做「换页面」这一件事

## 验证

- SelfTest 312 → 319 项，zh / en 各一遍全 PASS：剪贴板全局共享（跨模型
  可粘贴、剪切标记跨模型可见）、`receiveDrop` 切换并落入、
  `receiveDropOnPlus` 新建并放入
- 截图（`WINEXPLORER_SNAPSHOT_FULL=1`）：双标签 + 高亮 `+` 的工具栏
- 悬停 0.6s 自动切换与真实拖放需要用户手动确认
