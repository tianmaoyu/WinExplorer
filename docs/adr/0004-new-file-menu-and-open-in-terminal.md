# ADR 0004 · 右键新建常用文件与「在终端中打开」

- 状态：已实施（v1.3.0）
- 需求：右键空白处可以新建**文本文件和一些常用的办公文件**；右键可以**用命令行打开当前文件夹**。

## 决定 1 · 新建文件走「内嵌最小模板」

### 类型清单

`NewFileKind`：文本文档（txt）、Markdown（md）、CSV（csv）、RTF（rtf）、
Word 文档（docx）、Excel 工作表（xlsx）、PowerPoint 演示文稿（pptx）。

- txt / md / csv 初始为**空文件**（Windows 的「新建文本文档」就是空的）
- rtf 用 `NSAttributedString.rtf(from:documentAttributes:)` 由 AppKit 现生成，纯代码
- docx / xlsx / pptx 用 **ECMA-376 最小空白包**，以 base64 内嵌在
  `Services/DocumentTemplates.swift`（合计约 5 KB）

### 为什么内嵌而不是放 Bundle 资源

- 自检直接跑 `swift build` 的裸二进制，`Bundle.main` 没有 Resources；
  内嵌后自检可以断言魔数（`PK`）、大小、模板齐全，无环境差异
- 不依赖 `build_app.sh` 的拷贝步骤，少一个可能漏的环节

### 为什么能保证 Office 能打开

模板是手工构造的标准 OOXML 最小集（docx 三件套 / xlsx 五件套 / pptx 六件套），
验证链：

1. `file` → 识别为 Microsoft Word/Excel/PowerPoint 2007+
2. `unzip -t` → zip 结构完整
3. `textutil -convert txt t.docx` → macOS 自带 OOXML 解析器读取成功
4. 真实窗口截图 → 系统给三个文件显示**真正的 Word/Excel/PowerPoint 图标**、
   类型列为「Office Open XML」—— LaunchServices 已按文档类型解析

### 行为对齐 Windows

- 重名自动编号：`新建文本文档.txt` → `新建文本文档 2.txt`
- 创建后**立即进行内重命名**，且只选中主文件名（扩展名不动）
- 整条创建记录可 ⌘Z 撤销、⌘⇧Z 重做；
  **undo 前比较文件大小**：和创建时一致才删，用户已经写过内容就提示
  「已经被编辑过，没有撤销」—— 绝不因为撤销丢用户内容

## 决定 2 · 「在终端中打开」走 LaunchServices 转交

`TerminalService` 列出本机可用终端（iTerm / Warp 装了就排前，
系统 Terminal 永远兜底），用
`NSWorkspace.open([folder], withApplicationAt:, configuration:)` 转交。

**刻意不用 AppleScript**：`tell application "Terminal" to do script "cd …"`
会触发「想控制 Terminal」的 TCC 自动化授权弹框 —— 用户刚在 ADR 0003
被系统弹框困扰过，这里必须零弹框。LaunchServices 转交不请求任何权限，
Terminal / iTerm / Warp 收到文件夹 URL 都会自己开新窗口并 `cd`。

菜单形态：空白处右键「在终端中打开」子菜单列出各终端；
文件夹项右键同名子菜单，打开的是那个文件夹。

## 取舍

- 没做 Pages / Numbers / Keynote 模板：Apple 私有格式无法程序化生成最小文件
- 没做「新建时选择模板样式」（如带表头的 Excel）：保持 Windows 的
  「新建 = 空白文档」心智；Word/Excel 打开后内容就是一张空页/空表
- 终端列表写死三个（Terminal / iTerm / Warp）：覆盖绝大多数用户；
  其他终端（kitty、Alacritty…）暂不探测，列表做成数据驱动，后续好加
- 自检不真实启动终端（会弹真窗口打扰人），只断言可用终端列表、
  转交命令描述与 `dryRun` 路径；真实体验由用户确认

## 验证

- SelfTest 281 → **306** 项，zh / en 各一遍全 PASS：
  模板齐全与魔数、默认名与重名编号、创建后自动重命名、undo/redo、
  「编辑过的文件不撤销删除」、终端可用列表与转交命令
- 截图 `docs/screenshot-1.3.0-newfile.png`：六种文件 + 系统真实图标 + 状态栏提示
- 右键菜单本身是系统上下文菜单，窗口截图抓不到，需要用户手动确认两项
  子菜单内容与点击行为
