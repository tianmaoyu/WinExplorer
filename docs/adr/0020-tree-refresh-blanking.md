# ADR 0020 · 刷新时树形行数塌陷（「文件突然消失」）

- 状态：已实施（v1.5.1）
- 起因：用户报「运行一会儿，文件夹、文件突然看不到了」，并提供了运行日志。
- 关联：[ADR 0019](0019-tree-folder-management.md)（树形文件夹管理）、
  [ADR 0016](0016-context-menu-hang-and-runlog.md)（运行日志）

## 日志里读到了什么

先排除三个「看起来像 bug 但其实正常」的现象：

| 现象 | 结论 |
|---|---|
| 路径出现 `/Users/<user>/Users/<user>/code/demo-project/…` | **不是拼错的路径**。`/Users/<user>/Users` 是真实存在的目录，里面有一份旧的用户目录副本，用户确实在浏览它 |
| `[load] items=144` 但采样显示 `items=50` | 正常。`items` 是**过滤隐藏项之后**的可见列表；用户主目录下有 94 个 `.` 开头的隐藏文件 |
| `menuBuilds=4589` | 视图重建强度偏高但不算异常（树形展开时行数从 50 涨到 93，每次重建都要重建每行的右键菜单） |

日志里也没有崩溃、没有主线程卡顿（`[perf]` 一条都没有）、`fd` 稳定在 7–11、内存 233→244MB 缓慢爬升后回落。

## 真正的问题：刷新期间把行清空了

日志里这一串数字暴露了问题：

```
20:08:51 [user] 树形展开变更 count=4  rows=99
20:08:52 [user] 树形展开变更 count=3  rows=104
20:08:54 [user] 树形展开变更 count=4  rows=99
20:09:02 [user] 树形展开变更 count=0  rows=104
```

`count`（展开了几个文件夹）没有大改，`rows` 却从 99 跳到 104 再掉回 99。

原因是 `refreshFromDisk` / `applyLoad` 的这条链：

```swift
invalidateTreeCache(keepingExpansion: true)
    → treeChildren.removeAll()        // ← 所有子项缓存瞬间清空
applySortAndFilter()
    → rebuildTreeRows()               // ← 展开的节点查不到子项，rows 只剩顶层
reloadExpandedSubtrees()              // ← 27 个目录排队重读（异步）
```

也就是说：**每次目录监听触发自动刷新，展开的子树会先整个消失，几秒后陆续回来。**
用户正在深层浏览（比如脚手架第 8 层）时，看到的正是「文件突然全没了」。

`~/code/demo-project` 这类带 `target/` 的 Maven 项目会持续产生文件变动，
自动刷新频繁触发，这个塌陷就会反复出现——和「运行一会儿就看不到」完全吻合。

## 修法

**刷新时不清缓存，改成原地重读覆盖。**

- `invalidateTreeCache(keepingExpansion: true)` 不再 `treeChildren.removeAll()`，
  只把磁盘上已不存在的路径从 `expandedPaths` 里剔掉；
- `ensureChildrenLoaded(_:force:)` 加 `force` 参数：强制重读，但**读的过程中旧缓存继续有效**；
- `reloadExpandedSubtrees()` 用 `force: true`；
- `finishMutation` / `revealAncestors` 同样改成 `force` 重读，不再先 `treeChildren[key] = nil`。

效果：刷新期间界面保持旧内容，新数据到了原地替换，行数不再塌。

## 补上的诊断（这次的根本教训）

原来的 `[sys]` 采样只记了 `items=`（数据侧），**没有记界面上有多少行**。
所以用户报「看不到」时，无法区分两种情况：

- 数据真的空了（`items=0`）
- 数据在但没画出来（`items=50` 而 `rows=0`）

现在采样里加了：

```
[sys] fd=11 threads=5 rss=147MB menuBuilds=156 content=1069x918
      items=50 rows=50 expanded=0 loading=0 search=0 hidden=0
```

`items` 与 `rows` 对不上就是直接证据。另外 `rebuildTreeRows` 里加了一条不变式检查：
**`items` 非空却算出 0 行**时记一条 `⚠️` 日志——那意味着界面一定空白。

## 验证

- 自检新增 3 条：刷新前是展开状态、**刷新不会把已展开的行清空**、刷新后子项仍在。
- 端到端：启动到用户主目录，外部写入文件触发监听刷新，`自动刷新完成 49ms / 43ms`，
  没有 `[perf]` 卡顿记录，`fd` 恒定 11。
- 全部自检 zh / en `SELFTEST OK`。

## 取舍

- **重读期间显示旧内容**，如果目录真被删空，会有一小段延迟才反映（最多几百毫秒）。
  相比「每次刷新都把界面清空」，这个方向明显更符合直觉。
- **没有做「刷新代次」**：多个目录并发重读，各自回来各自替换，最后一次结果为准。
  逐个目录的内容是独立的，不存在互相覆盖的问题。
