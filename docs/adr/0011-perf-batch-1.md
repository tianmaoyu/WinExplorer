# ADR 0011 · 性能重构第一批：文件夹大小协调者、搜索防抖、读取降本

- 状态：已实施（v1.4.5）
- 起因：用户要求「重构 + 优化」，先做性能卡点排查。排查结论里三条低风险、
  收益明确的先做（P0 中的图标异步与目录读取异步化留到后续单独做，见文末）。

## 背景：排查出来的卡点

| 位置 | 问题 |
|---|---|
| `BrowserModel.refreshFolderSizes` | 主线程对每个候选文件夹调 `cached()` → 每项一次同步 `stat`，200 个文件夹 = 200 次 |
| `FolderSizeService.measure` | 只对**根目录**做受保护路径判断，子目录里的资料库包照样递归 → 慢，且会引出 TCC 授权框 |
| `searchText.didSet` → `applySortAndFilter` | 每敲一个字符就全量过滤 + 重排；排序比较器是 `localizedStandardCompare`，很贵 |
| `FileSystemService.makeItem` | 每项都 `Set(resourceKeys)`（每项一次 Set 分配），每项都 `UTType(filenameExtension:)`（LaunchServices 查询） |

## 决定

### 1. 抽出 `FolderSizeCoordinator`

`folderSizes` / 任务生命周期 / 缓存命中 / 后台计算 / 进度回填整体从
`BrowserModel`（2197 行）搬到一个新类型。`BrowserModel` 只保留：

- `var folderSizes { folderSizeCoordinator.sizes }` —— 视图读法不变
- `folderSizeCoordinator.objectWillChange.sink { objectWillChange.send() }`
  —— 与 `ClipboardStore` 相同的转发方式，视图照常重绘
- `refreshFolderSizes()` 变成三行转发

顺带修掉两个卡点：
- 缓存校验改走 `FolderSizeService.cachedSizes(for:completion:)`，`stat` 在后台队列做；
  缓存字典因此加了 `NSLock`（主线程写结果、后台队列读校验）。
- 递归枚举时对每个子目录判 `shouldSkipRecursiveRead`，命中就 `skipDescendants()`，
  资料库包（`*.photoslibrary` 等）无论嵌多深都不再进入。

### 2. 搜索防抖 + 排序结果缓存

- `searchText` 的过滤延后 0.18s（`SearchDebounce`），连续输入只算最后一次。
- 排序结果缓存到 `sortedCache`：过滤不改变相对顺序，所以「先排序再过滤」与
  「先过滤再排序」结果一致；敲键时只做两趟线性过滤，不再重排。
- `allItems` 的三处赋值（换目录 / 外部刷新 / 权限状态更新）都显式 `invalidateSortCache()`。
- 自检用 `BrowserModel.debouncesSearch = false` 关掉防抖，保持「设完立刻断言」的写法。

### 3. 读取降本

- `Set(resourceKeys)` 提成 `resourceKeySet` 静态常量（每项少一次分配）。
- `kindDescription` 按扩展名走 `NSCache`，同类型的几百个文件只查一次 LaunchServices。
- `contents(of:)` 预分配结果数组容量。

## 取舍

- 没把 `FolderSizeCoordinator` 做成 `@MainActor`：与现有代码风格一致（BrowserModel
  也是「只在主线程调用」的约定），避免在 Swift 5 语言模式下引入并发标注噪音。
- 搜索防抖 0.18s 是手感与开销的折中：更短（0.1s）在慢机器上仍会连排，更长（0.3s）
  会让过滤看起来"迟钝"。
- 排序缓存用「排序参数」做 key，allItems 变化靠显式失效：比每次比较整数组便宜得多，
  代价是新增 `allItems` 赋值点时必须记得失效（已在三处加注释）。

## 未做（下一批）

- 图标异步化（`FileItemIcon` 在 body 里同步取系统图标）
- 目录读取移出主线程（网络卷/超大目录仍会阻塞）
- 这两项都要动视图填充时机与导航竞态，风险高于本批，单独做。

## 验证

- `WINEXPLORER_SELFTEST=1` **335 项**断言 zh / en 双语全 PASS（本次新增 5 条）：
  - 任意层级的资料库包会被剪枝
  - 家目录受保护子目录会被剪枝
  - 普通目录不剪枝
  - 同扩展名的类型描述一致且有内容（缓存正确性）
  - 搜索过滤来回归位后顺序不变（排序缓存正确性）
- 既有用例覆盖：文件夹大小显示、搜索过滤/清空、换目录清空搜索、排序切换 —— 全部仍通过
