# ADR 0003 · 后台递归统计不得进入 macOS 隐私保护位置

- 状态：已实施（v1.2.1）
- 起因：用户反馈「一直弹框」，截图为系统框
  `“WinExplorer.app” 想访问 Apple Music、你的音乐与视频活动以及你的媒体资料库`
  （`不允许` / `允许`），背景是个人文件夹 `~/`，大小列正在逐个算出数值。

## 根因

不是 1.2.0 那套「未授权项淡显」逻辑的问题，而是**我们自己在后台递归读了受保护目录**：

1. v1.0.0 加了「计算文件夹大小」，开关持久化在 `UserDefaults`。
2. 我用 `WINEXPLORER_KEYS='sizes:on'` 拍验收截图时，钩子的 didSet 把 `true`
   **写进了用户真实偏好，且截图退出后没有恢复**。
3. 用户重启 App，`showsFolderSizes` 变成默认开启。
4. 用户浏览 `~/`，`refreshFolderSizes()` 对 `~/音乐`、`~/影片`、`~/图片`、
   `~/下载` … 逐个 `FileManager.enumerator` 递归。
5. 枚举到 `~/Music/Music`（Apple Music 媒体资料库）触发
   `kTCCServiceMediaLibrary` 授权框；每次刷新 / 切目录 / 自动刷新都会再问一次，
   观感就是「一直弹框」。

`FileInfoService.folderStats`（属性面板「显示简介」）有同样的递归，是第二个隐藏触发点。

## 决定

### 1. 止血

把 `showsFolderSizes` 重置为 `false`，停掉运行中的旧进程（旧进程内存里仍是 true，
改 defaults 不会影响它）。

### 2. 截图/调试永不写用户偏好

`SnapshotSupport.scheduleIfNeeded` 开头设 `Preferences.enabled = false`。
`WINEXPLORER_SNAPSHOT` 是一次性的开发态，钩子（`sizes:on`、`cmd+3`…）改的视图偏好
只在内存里生效，退出即消失。**验收动作不许改变用户真实设置**。

### 3. 单一规则：后台自动递归绝不进 TCC 区域

新增 `Services/ProtectedPaths.swift`，集中判定，纯字符串比较、零文件系统访问：

| 位置 | 例子 |
|---|---|
| 家目录第一层的 TCC 保护目录 | `Desktop/Documents/Downloads/Music/Movies/Pictures/Library` |
| 媒体 / 照片资料库包（任意位置） | `*.photoslibrary`、`*.musiclibrary`、`*.ituneslibrary` |
| 其他用户目录 | `/Users/someone-else/…`、`/Users/Shared` |
| 外置与网络卷 | `/Volumes/…` |

**两层语义严格区分**：

- 用户**主动进入**某目录 → 照常列出这一层，不拦（这是用户预期内的行为）。
- 应用**后台自动递归**（文件夹大小、`显示简介` 统计）→ 一律不进，直接返回 `skipped`。

`FolderSizeService.measure` 与 `FileInfoService.folderStats` 共用这条规则；
`PermissionService.needsSystemSettings` 也改为复用，避免三处规则漂移。

### 4. 跳过要有可见解释，不能假装是 0 B

- 大小列显示 `—`（不是 `0 B`，也不显示「计算中…」卡住）
- 状态栏：`N 项受保护，跳过统计`，悬停给出完整原因
- 属性面板：新增「访问」字段写原因，`大小 / 包含` 显示 `—`，底部说明
  「你仍可以正常打开并浏览」
- 多选属性：被跳过的目录不计入总大小，总值前加 `≥` 并注明
- 跳过结果**不进缓存**：规则或系统授权状态变了，下次重新判

### 5. 图标规则比统计规则窄

`shouldAvoidSystemIcon` 只覆盖真正会被当成媒体资料库的项
（`*.photoslibrary`、`~/音乐/Music` 及其内部子项），其余受保护目录
（桌面 / 文稿 / 下载 …）**保持系统真实图标**。

理由：这些目录是**可读的**，只是不参与统计；若画成灰色会与 v1.2.0 的
「未授权项淡显 + 锁」混淆，违反「已授权的保持正常样式」。
`NSWorkspace.icon(forFile:)` 对普通目录不读内容，风险可忽略。

## 取舍

- **代价**：在家目录 / iCloud 云盘里，受保护子目录看不到文件夹大小。
  这是有意的：一个数字不值得换一个反复弹出的系统授权框。用户主动双击进去
  仍可完整浏览、复制、重命名。
- **没有做**：按窗口实际宽度动态判断要不要折叠、给受保护目录提供
  「手动点一次去统计」的按钮。前者与统计无关；后者会重新引入系统弹框，
  与本次目标冲突。
- **没改**：TCC 首次访问桌面 / 文稿 / 下载时系统自己弹的那一次框。
  那是用户主动进入目录时系统行为，应用无法预先知道授权结果，也无法阻止。
- **没启用沙盒**：本 App 要浏览任意路径，沙盒会把所有路径都变成需要授权，
  与产品目标相反。

## 验证

- `SELFTEST` 255 → **281** 项，zh / en 各一遍全 PASS。新增断言覆盖：
  7 个家目录保护位置、媒体资料库 / 照片图库包 / 外置卷 / 其他用户目录、
  家目录本身与临时目录不被误判、`measure` 与 `folderStats` 直接跳过、
  跳过结果不进缓存、普通目录仍正常统计、图标规则的窄边界、文案双语。
  断言故意用**不存在的受保护路径**，避免规则写错时真的去枚举 `~/Music`。
- 真实窗口截图：`docs/screenshot-1.2.1-protected-home.png`、
  `docs/screenshot-1.2.1-protected-info.png`。
- 截图后复查 `defaults read com.eric.winexplorer showsFolderSizes` 仍为 `0`，
  确认验收动作没有再污染偏好。

> 注：本机 `log show` 读不到统一日志（无权限），所以「系统框不再出现」这一点
> 由逻辑断言 + 窗口截图间接保证，最终仍需用户在真实操作中确认。
