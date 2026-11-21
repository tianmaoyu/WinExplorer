# ADR 0013 · 目录读取移出主线程

- 状态：已实施（v1.4.7）
- 起因：性能排查最后一个 P0 —— `BrowserModel.load` 在主线程同步调
  `FileSystemService.contents(of:)`。几万项的大目录、或网络卷（SMB）超时，会直接
  冻住窗口，连"转圈"都画不出来。

## 决定

### 读取放后台 + 代次校验

```
load(directory:)          → loadGeneration += 1，记下本次代次，isLoadingDirectory = true
  └ DispatchQueue.global → FileSystemService.contents(of:)  （唯一的重活）
      └ DispatchQueue.main → applyLoad(..., generation:)
                             guard generation == loadGeneration else { return }  ← 过期结果整包丢弃
```

- **代次校验**解决"连点两个目录，先发的请求后回来把新结果覆盖掉"的经典竞态；
  丢弃时不碰任何状态，只把 `isLoadingDirectory` 留给最新那次去收尾。
- 成功路径的落地逻辑原样搬进 `applyLoad`（历史栈、清选择、清输入态、写偏好、
  排序过滤、统计大小、装监听），语义与同步版逐条对齐。
- 失败路径仍走原来的分流：权限问题 → 授权浮层，其它 → 错误条。

### 配套：加载反馈与"待揭示"

- `isLoadingDirectory` 驱动状态栏左侧的小转圈 + 「正在读取…」；
  异步化之后没有这个反馈，点目录会像"没反应"。
- 压缩/解压完成后要选中新产物（`revealNewItem`），但列表此刻可能还没读完：
  改成记下 `pendingRevealURL`，`applyLoad` 成功后由 `applyPendingReveal()` 补选中
  与滚动，找不到就留着等下一次加载。

### 自检怎么保持"同步断言"

新增静态开关 `loadsDirectorySynchronously`（生产默认 `false`）：

- 自检默认设为 `true`，既有的「navigate 完立刻断言 items」写法全部不用改；
- 另外**专门有 3 条用例走异步路径**：临时切到 `false` → `navigate` →
  泵 runloop 直到 `isLoadingDirectory == false`（3s 超时），断言结果落地；
  再连点两个目录断言"以最后一次为准"；最后切回同步并导航回根目录还原状态。

## 取舍

- **没有真正取消后台读取**：`contentsOfDirectory` 是不可中断的系统调用，
  过期结果只能丢弃，不能中止。代价是快速连点时后台会多跑几次枚举（无副作用）。
- **`refreshFromDisk`（目录监听触发的刷新）仍同步**：它要保留选择与焦点、比对
  目录签名，异步化要再引入一套"刷新代次"与合并逻辑，风险与本批不同量级。
  它只在 0.25s 防抖后触发，先留作后续；ADR 0011/0012 已记录同样的判断。
- **上一份列表在加载期间继续显示**（不做闪空）：换目录时用户看到的还是旧内容 +
  状态栏"正在读取…"，这是资源管理器的常见行为，也避免列表闪烁。

## 验证

- 自检 **340 项**断言 zh / en 双语全 PASS（新增 3 条异步用例：走完加载态、
  结果落地、连点以最后一次为准）。
- 既有 337 条全部通过：导航/后退前进、搜索、排序、剪贴板、传输、压缩、
  打开方式、文件夹大小、图标策略 —— 说明 `applyLoad` 的搬迁没有改变行为。
- 实机冒烟：直接以 `Sources/WinExplorer`（几十个文件）启动并截图，
  图标列 52 个采样行检测到彩色像素 —— 异步读取 + 图标回填在同一次渲染里都完成了。
