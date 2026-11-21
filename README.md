# WinExplorer

macOS 上的「Windows 资源管理器」式文件浏览器，SwiftUI + Swift 原生实现，无 Xcode 工程、无第三方依赖。

当前版本：**0.1.1（MVP）**，窗口尺寸 1060×680，启动后默认打开个人文件夹。

## 已实现（MVP）

| 能力 | 说明 |
|---|---|
| 侧边栏 | 个人文件夹 / 桌面 / 文稿 / 下载 / 应用程序 + 本机卷 |
| 面包屑地址栏 | 点任意一级直接跳转，末级高亮 |
| 详细信息列表 | 名称 / 大小 / 修改日期 / 类型 四列，点表头排序，升降序切换 |
| 文件夹优先 | 任何排序方式下文件夹都在最前，和 Windows 一致 |
| 双击打开 | 文件夹进入、文件用默认程序打开、`.app` 直接启动（不会钻进去） |
| 前进 / 后退 / 上一级 | 完整历史栈，按钮与菜单快捷键同步禁用状态 |
| 新建文件夹 | 重名自动编号「新建文件夹 2」，建完自动选中 |
| 隐藏文件开关 | 默认隐藏 `.` 开头的文件和系统隐藏项 |
| 右键菜单 | 打开 / 在 Finder 中显示 / 复制路径 / 刷新 |
| 状态栏 | 项目数、选中项名称与大小、当前完整路径 |
| 错误处理 | 无权限或目录消失时顶部黄条提示，不崩溃、不跳走 |
| 表头固定 | 滚动时表头常驻（pinned section header） |

## 快捷键

| 快捷键 | 动作 |
|---|---|
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
| `WINEXPLORER_SELFTEST=1` | 在临时目录跑 16 项逻辑自检（目录读取、排序、导航、新建、错误处理），打印 PASS/FAIL 后退出 |
| `WINEXPLORER_START=/path` | 启动即打开指定目录，便于截图验收 |
| `WINEXPLORER_SNAPSHOT=/tmp/x.png` | 窗口渲染完成后自截图再退出（用于无「屏幕录制」权限的环境） |

```bash
WINEXPLORER_SELFTEST=1 ./build/WinExplorer.app/Contents/MacOS/WinExplorer
```

最近一次自检结果：16/16 PASS。

## 代码结构

```
Sources/WinExplorer/
├── WinExplorerApp.swift        # @main，单窗口 Window 场景 + AppDelegate
├── ExplorerCommands.swift      # 菜单栏与快捷键
├── Models/FileItem.swift       # 行数据模型、列定义、面包屑、侧边栏位置
├── Services/
│   ├── FileSystemService.swift # 目录读取 + 排序（文件夹优先、自然排序）
│   ├── IconProvider.swift      # 系统图标缓存
│   ├── SelfTest.swift          # 无界面逻辑自检
│   └── SnapshotSupport.swift   # 无权限环境下的自截图
├── ViewModels/BrowserModel.swift  # 导航栈、排序、选择、文件操作
└── Views/
    ├── BrowserView.swift       # NavigationSplitView + 工具栏 + 错误条
    ├── SidebarView.swift
    ├── PathBar.swift
    ├── FileListView.swift      # 共用列骨架 FileListLayout（表头/行严格对齐）
    └── StatusBar.swift
```

## 已知限制（MVP 范围）

- 单选：还不支持 ⌘ 点选、Shift 连选、⌘A 全选
- 没有行内重命名、删除、复制/剪切/粘贴、拖拽移动
- 列宽不可拖动、没有视图模式切换（图标/列表）、没有搜索框
- 图标同步加载，超大目录（数千项）会有可感知的打开延迟
- 未做目录大小统计（文件夹大小显示 `—`，和 Windows 默认行为一致）

## 路线图

### Phase 2 · 基本操作闭环（下一步建议）
1. 多选：⌘ 点选、Shift 连选、⌘A；选中项在状态栏汇总大小
2. 键盘导航：↑↓ 移动选中、Return 打开、空格 QuickLook、⌘⌫ 删除到废纸篓（带确认）
3. 行内重命名：Return / F2，扩展名默认不被选中
4. 剪贴板：⌘C / ⌘X / ⌘V，同卷优先 `moveItem`（瞬时），跨卷复制并显示进度
5. 拖拽：行拖到侧边栏/面包屑/另一个窗口；同卷移动、跨卷复制、⌥ 强制复制、⌘ 强制移动
6. 空白区右键菜单：新建文件夹 / 粘贴 / 刷新 / 排序
7. 撤销栈（⌘Z）：重命名、移动、删除可回滚

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
