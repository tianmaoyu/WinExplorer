# 术语表

代码、注释、ADR 与提交信息里统一用这些词，避免同一个东西三种叫法。

## 地址栏

| 词 | 含义 | 对应代码 |
|---|---|---|
| **地址栏** | 列表上方那一整条控件（容器 + 面包屑 + 位置图标），不含搜索框 | `PathBar` |
| **面包屑** | 地址栏里由「卷 › 各级目录」组成的路径段序列 | `BrowserModel.crumbs` |
| **路径段 / 段** | 面包屑里的一级，点击即跳转到该级 | `Crumb` |
| **当前段** | 面包屑最后一段，等于当前目录；只加粗、不加底色 | `Crumb` 的 `isCurrent` |
| **折叠段** | 路径过深时把中段收成 `…`，点开是下拉菜单 | `DisplayCrumb.hidden` |
| **位置图标** | 地址栏最左的当前目录系统图标，仅装饰 | `PathBar.currentIcon` |
| **编辑态** | 地址栏换成路径输入框的状态，`⌘L` 或点空白进入 | `isEditingPath` / `PathField` |
| **提交 / 取消** | 编辑态按 Enter 生效、按 Esc 还原 | `commitPathEditing` / `cancelPathEditing` |
| **补全** | 编辑态按 Tab 把已输入的部分路径补成唯一匹配项 | `completePath` |

## 视觉约定

| 词 | 含义 |
|---|---|
| **容器** | 包裹面包屑的圆角矩形（r=6、高 28、细描边），地址栏与编辑态共用同一个 |
| **悬停底** | 鼠标停在某一段上时出现的浅灰圆角底（`primary @ 7%`） |
| **落点高亮** | 拖拽文件悬停在某一段上时的蓝色描边 + 18% 底，属于功能反馈，不可省略 |
| **焦点环** | 编辑态容器的强调色 1.5pt 描边，路径非法时变红 |

## 权限

| 词 | 含义 | 对应代码 |
|---|---|---|
| **访问状态** | 单项对我们这个进程「能不能读」的结论，只有 `granted` / `denied` 两态 | `AccessState` |
| **未授权项** | `access == .denied` 的行：整行变淡 + 锁徽标，但照常列出 | `FileItem.access` |
| **访问探测** | 只读判断可读性（`isReadableFile` / `resourceValues.isReadable`），不打开文件、不递归 | `PermissionService.isReadable` |
| **授权浮层** | 窗口内的 `AccessRequestView`，只在主动操作未授权项 / 进入被拒目录时出现 | `BrowserModel.accessRequest` |
| **授权入口** | 浮层里的「选择此项目以授权…」（`NSOpenPanel` 预选该项）与「打开系统设置」（TCC） | `PermissionService.pickInPanel` |
| **拦截点** | 所有写操作/打开动作的统一闸门，有未授权目标就弹浮层并中止 | `blockedByUnauthorized` |

## 受保护位置（v1.2.1）

| 词 | 含义 | 对应代码 |
|---|---|---|
| **受保护位置** | macOS 做 TCC 隐私保护的位置：桌面 / 文稿 / 下载 / 音乐 / 影片 / 图片 / 资源库（含 iCloud 云盘）、外置卷、其他用户目录、媒体与照片资料库包 | `ProtectedPaths` |
| **后台递归** | 应用自己发起的、用户没主动点开的深度读取：文件夹大小统计、属性面板「显示简介」的统计 | `FolderSizeService.measure`、`FileInfoService.folderStats` |
| **跳过统计** | 对受保护位置不启动枚举，返回 `skipped`；大小显示 `—`（不是 `0 B`），结果不进缓存 | `Size.skipped` / `FolderStats.skipped` |
| **主动浏览** | 用户双击进入目录、正常列出这一层。**不受保护规则限制**，仍可复制 / 重命名 / 删除 | `BrowserModel.load` |
| **图标规避** | 比「跳过统计」更窄：只对媒体资料库包与 `~/音乐/Music` 内部项避开 `NSWorkspace.icon(forFile:)`；可读的受保护目录保持系统真实图标 | `ProtectedPaths.shouldAvoidSystemIcon` |

## 右键新建与终端（v1.3.0）

| 词 | 含义 | 对应代码 |
|---|---|---|
| **新建模板** | 每种「新建」类型的初始内容：文本类为空、RTF 由 AppKit 生成、Office 三件套是内嵌 base64 的 ECMA-376 最小空白包 | `DocumentTemplates` |
| **新建类型** | `NewFileKind`：txt / md / csv / rtf / docx / xlsx / pptx，带默认名、扩展名与菜单图标 | `NewFileKind` |
| **编号命名** | 重名时 `基名 2.扩展名` 递增，与 Windows 一致 | `BrowserModel.createFile` |
| **终端转交** | 把文件夹 URL 交给终端应用（LaunchServices），终端自己开新窗口并 cd；不用 AppleScript，避免自动化授权弹框 | `TerminalService` |

## 地址栏编辑态（v1.3.1 补充）

| 词 | 含义 | 对应代码 |
|---|---|---|
| **编辑态** | 地址栏的独占输入状态：白底 + 强调色焦点环，面包屑暂被替换 | `BrowserModel.isEditingPath` |
| **编辑态退出** | 用户把注意力转回列表时必须退出：点空白 / 点文件 / ⌘F 聚焦搜索；Esc / Enter / 导航照旧 | `cancelPathEditing` |
| **搜索容器** | 与地址栏同一套填充 / 描边 / 圆角 / 高度 / 聚焦环的搜索框外观；`NSSearchField` 只保留键盘行为 | `SearchBox` |
| **焦点汇报** | 用 `becomeFirstResponder / resignFirstResponder` 而不是 `controlTextDidBeginEditing` —— 后者在只聚焦未打字时不触发 | `FocusReportingSearchField` |
| **过滤保留** | 点列表空白不清搜索词；Esc 第一次清词、第二次退出搜索 | `SearchBox` |

## 标签栏与独立窗口（v1.4.0）

| 词 | 含义 | 对应代码 |
|---|---|---|
| **常驻标签栏** | 嵌在窗口工具栏最左的标签 chips + `+`，单标签也显示（v1.4.1 起从居中改为贴左） | `TabBarView` |
| **全局剪贴板** | 应用级共享的 `ClipboardStore`：⌘C 在标签 A / 窗口 A，切到 B 直接 ⌘V | `ClipboardStore` |
| **悬停切换** | 拖文件悬停在 chip 上 0.6s 自动切到那个标签，松手落入其当前目录 | `TabsModel.scheduleAutoSwitch` |
| **拖到 + 号** | 新建一个标签（沿用当前目录）并直接放入拖入的文件 | `TabsModel.receiveDropOnPlus` |
| **独立窗口** | 每窗口一份 `TabsModel`（窗口层 `@StateObject`），⌘N 开新窗口 | `WindowRootView` |
| **聚焦窗口菜单** | 菜单命令作用于聚焦窗口的标签组，用 `@FocusedObject` 取 | `ExplorerCommands.tabs: TabsModel?` |
| **全窗口截图** | `WINEXPLORER_SNAPSHOT_FULL=1` 抓含标题栏 / 工具栏的完整窗口（contentView 不含 chrome） | `SnapshotSupport.capture` |
| **弹性空白** | `NSToolbar` 的 `flexibleSpace` item：占住剩余宽度把后面的 item 顶到最右。SwiftUI 不暴露，只能经 AppKit 插入 | `ToolbarRightAlignFix` |
| **工具栏定宽幻觉** | SwiftUI 工具栏 item 只按内容理想尺寸布局，`Spacer` / `maxWidth(.infinity)` 都撑不开 | `ToolbarRightAlignFix` 注释 |
| **标签卡** | Win11 风格的标签视觉：激活=白色圆角卡片+轻投影，未激活=透明，悬停=浅色卡，`×` 激活常显/悬停显示 | `TabChip`（adr/0009） |
| **打开方式** | 右键子菜单：列出系统里能打开该类型文件的应用（默认应用置顶标「（默认）」），可一次性打开或设为默认 | `OpenWithService`（adr/0010） |
| **候选应用** | LaunchServices 认为能打开该文件的 `.app`，按 bundle id 去重、名称排序、上限 8，按扩展名缓存 | `OpenWithService.applications(for:)` |
| **一次性打开** | 用指定应用打开，不改系统默认角色绑定 | `NSWorkspace.open(_:withApplicationAt:)` |
| **默认应用** | 该类文件（按 UTI）在系统里绑定的默认打开应用，双击等同此行为 | `NSWorkspace.setDefaultApplication(at:toOpenFileAt:)` |
| **文件夹大小协调者** | 文件夹大小统计的任务生命周期、缓存命中、后台计算与进度回填（从 BrowserModel 拆出） | `FolderSizeCoordinator`（adr/0011） |
| **排序缓存** | 缓存全量排序结果；过滤不改变相对顺序，敲搜索词时只做线性过滤不重排 | `BrowserModel.sortedCache` |
| **搜索防抖** | 搜索输入停 0.18s 后才过滤，避免每个字符都全量过滤+排序 | `BrowserModel.debouncesSearch` |
| **图标异步化** | 列表行不在 body 里同步问系统要图标：先占位，后台队列生成后回填；同步入口只留给一次画一两个的地方 | `IconProvider.iconAsync(for:)`（adr/0012） |
| **读取代次** | 每次 `load` 自增的序号；结果回到主线程时序号不符就整包丢弃，避免连点目录时旧结果覆盖新结果 | `BrowserModel.loadGeneration`（adr/0013） |
| **待揭示 URL** | 压缩/解压完成后要选中的产物；目录异步读，读完前列表里还没有它，先记下、读完后补选中 | `BrowserModel.pendingRevealURL` |
| **加载态** | 目录正在后台读取时状态栏的小转圈与「正在读取…」 | `BrowserModel.isLoadingDirectory` |
| **降级项** | 属性读不出来（TCC/权限/卷异常）时的占位行：保留文件名、标为未授权、类型显示「无法读取」，绝不让行静默消失 | `FileSystemService.degradedItem`（adr/0014） |
| **读取看门狗** | 每次目录读取起的 5s 定时器：超时自动重试一次，再超时给出错误，避免永远停在空列表+转圈 | `BrowserModel.startLoadWatchdog` |
