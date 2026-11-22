# ADR 0024 · 子树读取失败被当成空目录（树形懒加载不自愈）

- 状态：已实施（v1.5.5）
- 起因：上报「展开过的文件夹过一会儿自己变空，怎么刷新都不回来」，复核确认成立。
- 关联：[ADR 0019](0019-tree-folder-management.md)（树形与子项缓存）、
  [ADR 0020](0020-tree-refresh-blanking.md)（刷新不清缓存）、
  [ADR 0021](0021-stale-tree-cache-after-move.md)（展开即重读）、
  [ADR 0013](0013-async-directory-load.md)（主目录读取的看门狗）

## 现象

`ensureChildrenLoaded` 原来的失败分支是这样写的：

```swift
case .failure(let error):
    // 记为「读过但没有」：免得每次重建都再发起一次必然失败的读取
    self.treeChildren[key] = []
```

三件事同时发生：

1. **瞬时失败被永久降级成「空目录」**。`treeChildren[key] = []` 与「真的读了、里面没有」完全同构，
   `appendRows` 里 `!children.isEmpty` 一挡，两者在界面上长得一模一样。
2. **它还会覆盖上次读成功的内容**。网络卷抖一下、TCC 权限被收走一次，重读失败就把之前
   好好的 3 行子项换成 0 行——这正好把 ADR 0020「刷新期间不能塌」的承诺又破了一次。
3. **没有任何自愈路径**。失败后不重试；本次读失败也不会改当前目录的 signature，
   所以 `applyRefresh` 早在签名比对那一步就 return 了，`reloadExpandedSubtrees` 根本不会跑。
   唯一的触发器是「当前目录出现别的改动」，与失败的子树毫无因果关系。

同一个函数里还有两个隐患：

- `guard !loadingTreePaths.contains(key) else { return }` 把 **force 请求直接丢掉**。
  展开目标文件夹的同时往里面新建 / 拖入，`finishMutation` 的强制重读被这条 guard 吞掉，
  随后落地的还是「建目录之前」那次读的结果。ADR 0021 修过同一类症状，但漏了这条时序。
- 子树读取**没有超时兜底**。主目录读取有 5s 看门狗（ADR 0013），子树没有：
  `contents(of:)` 在掉线的 SMB / 卡住的 FUSE 上永不返回时，`loadingTreePaths` 里这个 key
  永远摘不掉，行上一直转圈，之后所有 force 请求继续被吞。这不是内存泄漏，是**锁悬挂**。

## 修法

### 1. 失败与空目录分成两种状态

`treeChildren` 只放**读成功**的结果（真空调目录是空数组），失败的路径记在
`treeFailures[key] = TreeLoadFailure(message:attempts:)`。失败时**不碰** `treeChildren`：
旧内容继续显示，只是状态标成「这次没读到」。行上由 `treeLoadError(_:)` 给一个警告三角，
悬停写明原因——不再让空目录背锅。

### 2. 每个路径一个代次，迟到结果整包丢弃

`treeLoadGeneration[key]` 自增。完成回调先比代次，不符就 `note` 一条日志后返回。
超时、退避重试、换目录都会推高代次，因此「超时之后原请求才回来」不会写脏缓存，
也不需要额外的取消机制。

### 3. force 请求排队，不再丢弃

读取进行中又收到 force → 记进 `pendingForcedKeys`，本次读完后补读一次。
`finishMutation` / `revealAncestors` / `reloadExpandedSubtrees` 因此不会再有「请求消失在 guard 里」的情况。

### 4. 超时兜底 + 补偿重扫

- 5s 看门狗（与主目录一致）：到点推高代次、摘掉 `loadingTreePaths`、按失败处理；
- 失败后按 `0.5s / 1.5s / 4s` 退避重扫，最多三次，且只在文件夹仍然展开时才重扫；
- 放弃时写一条明确的日志，用户再去折叠-展开（force）仍可手动重试。

### 5. 顺手补的两处

- `resetTreeCache()`：换目录 / 全部收起时连 `loadingTreePaths`、看门狗、重试任务一起清。
  **必须清 `loadingTreePaths`**：在途读取回来后代次对不上会整包丢弃，没人再来摘锁，转圈会一直转。
- `pruneTreeCacheIfNeeded()`：`treeChildren` 超过 300 条时丢掉折叠着的那些
  （再展开本来就会 force 重读）。
- 运行日志：失败带次数、错误描述与「保留了几条旧内容」；排队 / 补读 / 放弃都有日志；
  `diagnosticsSummary` 增加 `failed=`。

## 没有做的事

- **没有**在子文件夹读取失败时弹授权浮层。被拒的子文件夹在列表里本来就是
  「变淡 + 锁」的占位项，浮层是给「当前目录整个打不开」用的；子层弹浮层会打断浏览。
- **没有**给成功结果加 LRU 之外的过期时间。展开即 force 重读（ADR 0021）已经覆盖了正确性，
  时间过期只会让慢目录反复重读。

## 验证

自检里新增三条用例（`Sources/WinExplorer/Services/SelfTest.swift`，紧跟原有树形用例之后）：

| 用例 | 断言 |
|---|---|
| 读失败不会把已读成功的子项抹掉 | chmod 000 后触发刷新，`rows` 仍含 `a.txt` |
| 读失败被单独记下来 | `treeLoadError(sub) != nil`，且 `isTreeLoading == false` |
| 失败子树会自己重扫恢复 | 恢复权限后不做任何操作，6s 内错误清空且子项回来 |
| 进行中收到的 force 会补读 | 首次读在飞时新建文件夹，最终树里能看到它 |

**回退验证**（把 `BrowserModel.swift` / `FileListView.swift` 退回修复前，只保留新测试）：
四条全部 FAIL，说明这些用例确实抓得住这个 bug，而不是摆设。

```
FAIL 树形：读失败不会把已读成功的子项抹掉  rows=["sub", "trigger.txt"]
FAIL 树形：读失败被单独记下来，不再伪装成空目录  error=nil
FAIL 树形：失败子树会自己重扫恢复  rows=["sub", "trigger.txt"]
FAIL 树形：读取进行中收到的 force 请求会补读，不会丢  loading=true rows=["target"]
```

修复后全量自检 `SELFTEST OK`（含原有 32 项树形场景，无回归）。
