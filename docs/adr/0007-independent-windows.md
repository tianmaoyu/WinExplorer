# ADR 0007 · 独立窗口（⌘N）

- 状态：已实施（v1.4.0）
- 起因：标签页共享一个窗口，没法并排看两个文件夹；用户要「像 Windows 一样
  同时开多个文件夹、相互独立」。独立窗口是 Windows 资源管理器的经典形态。

## 决定

- `TabsModel` 从 App 级 `@StateObject` **下沉到窗口层**（`WindowRootView` 内
  `@StateObject`）—— 每个窗口一份完整的标签组、目录、历史、选中，互不影响。
- 菜单命令改用 `@FocusedObject var focusedTabs: TabsModel?`：
  「撤销 / 新建文件夹 / ⌘T…」永远作用于**聚焦窗口**；没有聚焦窗口的极短暂
  间隙里菜单为空（`CommandBuilder` 的 `if let` 支持）。
- `ExplorerCommands` 的 `tabs` 属性改为可选，原有命令组整体搬进
  `groups(_ tabs:_ model:)`，`@CommandsBuilder` 零改动迁移。
- 「新建窗口 ⌘N」放回 `CommandGroup(.newItem)` 首位 —— 系统默认的 New Window
  被 `replacing .newItem` 覆盖，必须自己提供（`@Environment(\.openWindow)`）。

## 窗口间传文件

- **拖拽**：macOS 原生跨窗口拖拽，每个窗口列表的 `onDrop` 已存在，零额外代码
- **剪贴板**：全局 `ClipboardStore`（adr/0006），`⌘C` 在窗口 A、`⌘V` 在窗口 B

## 取舍与已知边界

- 菜单栏常驻模式下的 `openWindow(id: "main")`（`⌥⌘E` / Dock / 菜单栏图标）
  会**开一个新窗口**而不是聚焦已有窗口 —— 多窗口时代语义变宽了，暂不区分；
  关掉窗口不退出（菜单栏常驻）行为不变
- 新窗口的起始目录沿用「上次浏览的目录」（与重启行为一致，比强制回个人
  文件夹少一次点击）
- 自检无法开真实窗口：多窗口独立性由「每实例一份 TabsModel + 全局剪贴板」
  的结构保证，`receiveDrop` / 剪贴板共享有直接断言

## 验证

- SelfTest 319 项 zh / en 全 PASS（含跨模型剪贴板、跨标签落点）
- ⌘N 开窗、窗口间拖拽需要用户手动确认
