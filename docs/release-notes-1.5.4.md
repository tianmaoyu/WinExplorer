首个开源版本。macOS 上的「Windows 资源管理器」式文件浏览器 —— 纯 SwiftUI + AppKit，零第三方依赖，SwiftPM 构建（没有 `.xcodeproj`）。

## 下载

| 文件 | 说明 |
|---|---|
| `WinExplorer-1.5.4.dmg` | 打开后把 WinExplorer 拖进「应用程序」。推荐 |
| `WinExplorer-1.5.4.pkg` | 双击安装，适合分发或脚本化部署 |

**系统要求**：macOS 14 (Sonoma) 或更高 · Apple Silicon (arm64)

## ⚠️ 首次打开会被 Gatekeeper 拦下

这个包是 **ad-hoc 签名、未经 Apple 公证**（没有付费开发者账号），所以从网上下载后第一次打开会提示「无法验证开发者」或者「应用已损坏，你应该将它移到废纸篓」。后者是假警报，文件没坏。

两种解法，任选其一：

1. **图形界面**：在「应用程序」里右键点 WinExplorer → 「打开」→ 弹窗里再点「打开」。只需一次。
2. **命令行**（一次即可，之后正常双击）：

```bash
xattr -dr com.apple.quarantine /Applications/WinExplorer.app
```

不想碰签名问题的话，直接按 README 从源码构建，本机编译出来的包不受此限制。

## 这个版本有什么

**像资源管理器的地方**

- 列表里**可展开的树**：点三角就地看子目录，逐层缩进，选中项在状态栏显示完整路径
- 文件夹排在文件前面，<kbd>F2</kbd> 重命名，<kbd>Backspace</kbd> 返回上一级
- 可编辑地址栏（<kbd>⌘L</kbd>）：<kbd>Enter</kbd> 前往、<kbd>Tab</kbd> 补全，路径不合法时红框提示
- 面包屑超过 5 段自动折叠成「首段 › … › 末两段」

**文件操作**

- 复制 / 剪切 / 粘贴与系统剪贴板双向互通，能粘到访达，也能从访达粘进来
- 拖放：拖到文件夹行、空白处、侧边栏、面包屑任一段；同卷移动、跨卷复制，<kbd>⌥</kbd> 强制复制、<kbd>⌘</kbd> 强制移动
- **删除前给级联摘要**：「其中包含 3 个子文件夹、12 个文件」写在确认框里；「彻底删除」是另一个独立的、更重的动作
- **打开方式**：用某个应用打开一次，或直接设为系统默认
- 撤销 / 重做覆盖重命名、移动、复制、新建、移入废纸篓

**外观**

- 详细信息 / 紧凑列表 / 图标网格三种视图
- 列宽可拖、交替条纹、表头列分隔线（悬停变左右箭头光标）、访达比例的选中高亮
- 浅色与深色都是一等公民

**工程**

- 主线程不干重活：目录读取、图标提取、文件夹大小统计全在后台，带代次校验；网络卷卡住也不会冻住窗口
- 内置运行日志 `~/Library/Logs/WinExplorer/`，含主线程卡顿检测和 `fd` / 线程 / 内存采样 —— 「用一会儿就坏了」这种描述没法排查，日志可以
- 404 条自检断言，全部操作真实临时目录里的文件
- 22 篇 ADR（`docs/adr/`）记录每个不显然的决定，包括后来被推翻的那些

## 已知限制

- 仅 Apple Silicon，Intel Mac 跑不了
- 未公证，首次打开需按上文放行
- 没有 Finder 扩展，不接管默认文件浏览行为

---

**English**: First open-source release. A Windows-Explorer-style file browser for macOS, written in SwiftUI + AppKit with zero dependencies. Requires macOS 14+ on Apple Silicon. The build is ad-hoc signed and not notarized — on first launch, right-click → Open, or run `xattr -dr com.apple.quarantine /Applications/WinExplorer.app`. Build from source to avoid this entirely.
