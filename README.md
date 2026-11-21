# WinExplorer

macOS 上的「Windows 资源管理器」式文件浏览器，SwiftUI + Swift 原生实现，无 Xcode 工程、无第三方依赖。

当前版本：**0.4.0（剪贴板 + 空白区右键菜单）**，窗口尺寸 1060×680，启动后默认打开个人文件夹。
本阶段的重点是把「文件夹操作」做扎实，应用包（`.app`）一律按普通文件处理，不做应用专属逻辑。

## 已实现

| 能力 | 说明 |
|---|---|
| 侧边栏 | 个人文件夹 / 桌面 / 文稿 / 下载 / 应用程序 + 本机卷 |
| 面包屑地址栏 | 点任意一级直接跳转，末级高亮 |
| 详细信息列表 | 名称 / 大小 / 修改日期 / 类型 四列，点表头排序，升降序切换 |
| 文件夹优先 | 任何排序方式下文件夹都在最前，和 Windows 一致 |
| 双击打开 | 文件夹进入、文件用默认程序打开（`.app` 也按文件处理，直接交给系统） |
| 前进 / 后退 / 上一级 | 完整历史栈，按钮与菜单快捷键同步禁用状态 |
| **多选** | ⌘ 点击加选/取消、Shift 连选、⌘A 全选、点空白清空 |
| **键盘导航** | ↑↓ 移动、PgUp/PgDn 翻页、Home/End 首末，选中项自动滚进视口 |
| **选中汇总** | 状态栏显示「已选 N 项 · 共 X」，文件夹不计入大小 |
| **行内重命名** | F2 或右键/菜单进入，默认只选中主文件名，Enter 提交、Esc 取消、点击别处提交；重名、含 `/`、空名就地提示且不覆盖原文件 |
| **移到废纸篓** | ⌘⌫ 直接移入废纸篓（可恢复），完成后状态栏提示 |
| **彻底删除** | ⇧⌘⌫ 弹出窗口内确认层，**只有鼠标点「彻底删除」才执行**；不会进废纸篓，不可恢复 |
| **复制 / 剪切 / 粘贴** | ⌘C / ⌘X / ⌘V；同卷剪切粘贴用 `moveItem` 瞬时完成；复制与跨卷移动后台执行，底部进度卡可取消 |
| **剪切标记** | 剪切后的行整体变淡（Windows 的「待移动」观感），粘贴成功后自动清除 |
| **重名不覆盖** | 复制时生成「报告 副本.pdf」「报告 副本 2.pdf」；剪切遇到同名整批拒绝并提示 |
| **粘贴校验** | 禁止把文件夹粘进它自己或子目录；目标不是文件夹时直接拒绝；粘贴后自动选中新生成的项目 |
| **系统剪贴板互通** | 复制时把文件 URL 写进系统剪贴板，可以直接粘到 Finder；也能粘进来从 Finder 复制的文件 |
| **空白区右键菜单** | 新建文件夹 / 粘贴 / 全选 / 刷新 / 在 Finder 中显示 / 复制当前文件夹路径 / 显示隐藏文件 |
| 新建文件夹 | 重名自动编号「新建文件夹 2」，建完自动选中 |
| 隐藏文件开关 | 默认隐藏 `.` 开头的文件和系统隐藏项 |
| 右键菜单 | 打开 / 在 Finder 中显示 / 剪切 / 复制 / 粘贴到此处（文件夹）/ 复制路径 / 重命名 / 删除 / 刷新 |
| 状态栏 | 项目数、选中项名称与大小、当前完整路径 |
| 错误处理 | 无权限或目录消失时顶部黄条提示，不崩溃、不跳走 |
| 表头固定 | 滚动时表头常驻（pinned section header） |

## 快捷键

| 快捷键 | 动作 |
|---|---|
| `↑` `↓` `PgUp` `PgDn` `Home` `End` | 移动选中（自动滚动） |
| `Return` | 打开选中项（多选时逐个打开文件） |
| `Esc` | 清空选择 |
| `⌘A` | 全选（Command 被重映射的键盘下用 `fn`+`A` 或 `⌥`+`A` 同样生效） |
| `⌘C` / `⌘X` / `⌘V` | 复制 / 剪切 / 粘贴（`fn`+`C`、`fn`+`X`、`fn`+`V` 同样生效） |
| `⌘⌥C` | 复制选中项路径 |
| `F2` | 重命名选中项 |
| `⌘⌫` | 移到废纸篓 |
| `⇧⌘⌫` | 彻底删除（需在确认层点按钮） |
| `⌘[` / `⌘]` | 后退 / 前进 |
| `⌘↑` | 上一级 |
| `⇧⌘N` | 新建文件夹 |
| `⌘O` | 打开选中项 |
| `⌘R` | 刷新 |
| `⇧⌘.` | 显示/隐藏隐藏文件 |
| `⇧⌘H` | 回到个人文件夹 |

## 构建与运行

```bash
./scripts/build_app.sh          # release 构建，产物 build/WinExplorer.app
open build/WinExplorer.app
```

脚本会自动处理本机两个坑：

1. `xcode-select` 指向 CommandLineTools 时，SwiftPM 的 PackageDescription 与 swiftpm 不匹配，直接 `swift build` 会报链接错误 —— 脚本切到 `/Applications/Xcode*.app` 的完整工具链。
2. 受限环境下 SwiftPM 的 `sandbox-exec` 会 `Operation not permitted` —— 脚本传 `--disable-sandbox`。

App 用 ad-hoc 签名（`codesign -s -`）。首次访问桌面/文稿会弹一次 TCC 授权；因为 cdhash 随每次重建变化，重装后可能再弹一次，这是 ad-hoc 签名的固有行为。

## 开发钩子

| 环境变量 | 作用 |
|---|---|
| `WINEXPLORER_SELFTEST=1` | 在临时目录跑 71 项逻辑自检（读取、排序、多选、键盘焦点、导航、新建、重命名、删除、剪贴板、错误处理），打印 PASS/FAIL 后退出 |
| `WINEXPLORER_START=/path` | 启动即打开指定目录，便于截图验收 |
| `WINEXPLORER_SNAPSHOT=/tmp/x.png` | 窗口渲染完成后自截图再退出（用于无「屏幕录制」权限的环境） |
| `WINEXPLORER_SNAPSHOT_DELAY=0.5` | 覆盖截图前的等待秒数，用来抓复制进度这类瞬时状态 |
| `WINEXPLORER_KEYS=down,down,cmd+a` | 截图前先向窗口发按键，走真实响应链验证键盘；`menu:cmd+a` 走菜单派发，`fn+a` 复现 Command 被重映射的情况，`nav:/某个/路径` 直接跳目录 |

```bash
WINEXPLORER_SELFTEST=1 ./build/WinExplorer.app/Contents/MacOS/WinExplorer
```

最近一次自检结果：71/71 PASS（剪贴板用例全部在临时目录内，且自检期间不写系统剪贴板）。

## 代码结构

```
Sources/WinExplorer/
├── WinExplorerApp.swift        # @main，单窗口 Window 场景 + AppDelegate
├── ExplorerCommands.swift      # 菜单栏与快捷键
├── Models/
│   ├── FileItem.swift          # 行数据模型、列定义、面包屑、侧边栏位置
│   └── Clipboard.swift         # 文件剪贴板（复制/剪切两种语义）
├── Services/
│   ├── FileSystemService.swift # 目录读取 + 排序（文件夹优先、自然排序）
│   ├── TransferService.swift   # 递归复制/移动、同卷判定、副本命名、进度与取消
│   ├── IconProvider.swift      # 系统图标缓存
│   ├── SelfTest.swift          # 无界面逻辑自检
│   └── SnapshotSupport.swift   # 无权限环境下的自截图 + 按键注入
├── ViewModels/BrowserModel.swift  # 导航栈、排序、选择、剪贴板、文件操作
└── Views/
    ├── BrowserView.swift       # NavigationSplitView + 工具栏 + 错误条 + 进度卡
    ├── SidebarView.swift
    ├── PathBar.swift
    ├── FileListView.swift      # 共用列骨架 FileListLayout（表头/行严格对齐）+ 右键菜单
    ├── TransferProgressView.swift  # 复制/移动进度卡片
    ├── RenameField.swift       # 行内重命名输入框
    ├── DeleteConfirmView.swift # 彻底删除确认浮层
    └── StatusBar.swift
```

## 已知限制（当前阶段）

- 还不能拖拽（下一版）；没有撤销栈，删除/移动不可回滚
- 复制大目录时如果强退 App，目标目录会留下已完成的部分文件（进度卡上的「取消」会清理干净）
- 列宽不可拖动、没有视图模式切换（图标/列表）、没有搜索框
- 图标同步加载，超大目录（数千项）会有可感知的打开延迟
- 未做目录大小统计（文件夹大小显示 `—`，和 Windows 默认行为一致）
- 「应用程序」目录里的 `.app` 按普通文件对待，没有应用专属信息（版本、签名等）

## 路线图

> 完整的分级待办（26 项）、每项验收标准与迭代计划见 **[ROADMAP.md](ROADMAP.md)**，做完一项勾一项。

### Phase 2 · 基本操作闭环
1. ✅ 多选：⌘ 点选、Shift 连选、⌘A；选中项在状态栏汇总大小
2. ✅ 键盘导航：↑↓ 移动选中、Return 打开、PgUp/PgDn、Home/End
3. ✅ 行内重命名：F2 / Return，扩展名默认不被选中
4. ✅ 剪贴板：⌘C / ⌘X / ⌘V，同卷 `moveItem` 瞬时移动，复制与跨卷带进度、可取消
5. ✅ 空白区右键菜单：新建文件夹 / 粘贴 / 全选 / 刷新 / 显示隐藏文件
6. 拖拽：行拖到侧边栏/面包屑/另一个窗口；同卷移动、跨卷复制、⌥ 强制复制、⌘ 强制移动
7. 撤销栈（⌘Z）：重命名、移动、复制、删除可回滚

### Phase 3 · 浏览体验对齐 Explorer
- 列宽拖拽并记住；视图切换（详细信息 / 列表 / 图标）
- 地址栏可编辑（⌘L 手输路径 + 自动补全）
- 搜索框：当前目录即时过滤，回车转 Spotlight 全盘
- 后退/前进历史下拉；标签页；双窗格
- UserDefaults 记住排序方式、隐藏文件开关、窗口尺寸、上次目录
- 状态栏显示磁盘剩余空间

### Phase 4 · 系统集成
- QuickLook（QLPreviewPanel）、⌘I 属性面板、打开方式菜单
- Finder 标签、共享、压缩/解压
- 侧边栏收藏夹自定义（拖入即收藏）
- 全局快捷键唤出；菜单栏常驻模式（LSUIElement + NSPanel）
- 打包 `.pkg` / DMG、开机自启（LaunchAgent）

### Phase 5 · 进阶
- 批量重命名、目录大小异步统计、网络位置与挂载卷、Total Commander 式双栏
