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
