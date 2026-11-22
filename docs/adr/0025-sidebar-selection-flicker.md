# ADR 0025 · 侧边栏切换目录时选中态闪回（b → a → b）

- 状态：已实施（v1.5.6）
- 起因：从收藏夹点「下载」切到另一个收藏位置时，选中高亮先落在新位置，随即跳回原位置，
  几百毫秒后又跳回新位置。界面看起来闪两下，像点了两次。
- 关联：[ADR 0013](0013-async-directory-load.md)（目录异步读取与代次校验）

## 根因：选中态的「写」和「读」不是同一个时刻

侧边栏的选中态是直接绑到 `currentURL` 上的：

```swift
List(selection: selectionBinding) { ... .tag(place.url) }

private var selectionBinding: Binding<URL?> {
    Binding(
        get: { model.currentURL },
        set: { newValue in if let url = newValue { model.navigate(to: url) } }
    )
}
```

而 `currentURL` **只在目录读成功后才落地**（`applyLoad` 里 `currentURL = url`），
这是 ADR 0013 的刻意设计：读失败时不能把界面挪到一个打不开的目录。

于是点「下载」这一下，实际发生了三步：

| 时刻 | 发生了什么 | 界面 |
|---|---|---|
| t0 | 用户点击，`List` 把 selection 写成 b，触发 `navigate(to: b)` | 高亮 b |
| t0+ε | 视图更新，重新执行 `get` → 仍是 `currentURL == a` | **高亮弹回 a** |
| t0+几十~几百 ms | 后台读完，`applyLoad` 落地 `currentURL = b`，再次触发更新 | 高亮回到 b |

所以现象不是「导航发生了两次」——`navigate` 只被调了一次，`loadGeneration` 也只加了一次。
是**同一次导航被回读了两次**：先读到旧的已落地值，再读到新的。

## 修法：给「正在前往」一个独立的乐观值

新增 `pendingURL`（正在读、还没落地的目录），侧边栏的选中态读 `selectionURL`：

```swift
@Published private(set) var pendingURL: URL?
var selectionURL: URL { pendingURL ?? currentURL }
```

- `load()` 一开始就 `pendingURL = standardized`——点击的那一帧选中态就跟着走；
- `applyLoad` 成功：先 `currentURL = url`，再 `pendingURL = nil`（同一帧里不会出现
  「两者都不是这个目录」的瞬间）；
- `applyLoad` 失败、看门狗判定超时：`pendingURL = nil`，选中态退回真实所在目录
  ——没去成就不该把侧边栏留在那儿。

**没有**改成「`currentURL` 提前更新」。`currentURL` 同时被目录监听（`watchDirectory`）、
历史栈、`applyRefresh` 的 url 比对、面包屑和状态栏使用，提前改会把这些语义一起搅动；
而侧边栏需要的只是「显示哪个高亮」，用独立字段代价最小。

## 连续快速切换

这条链上已经有了两把保险，本次不需要新增：

1. `loadGeneration`：只有最后一次读的结果能落地，中间那次回来会被整包丢弃（ADR 0013）；
2. `pendingURL` 每次点击都覆盖成最后一次的目标，所以选中态始终指着最后一次点的位置，
   不会出现「跟着先返回的那次结果跳」的情况。

自检里连点 a → b → a → b，断言点击瞬间与读完之后都停在 b。

## 验证

自检新增 6 条断言（异步读取那一段）：

| 用例 | 断言 |
|---|---|
| 点击后选中态立刻指向 b | `selectionURL == b`，此时 `currentURL` 还是 a |
| 读取期间 currentURL 仍是 a | 记录「回读会闪回」的真实来源 |
| 读完稳定停在 b | `selectionURL == currentURL == b` |
| 连续快速切换只跟最后一次 | 四次连点后 `selectionURL == b` |
| 快速切换结束后一致 | 读完后两者都还是 b |

**回退验证**：把 `BrowserModel.swift` / `SidebarView.swift` 退回修复前、只补一个
`var selectionURL: URL { currentURL }` 的等价桩，第一条断言立刻失败：

```
FAIL 侧边栏：点击后选中态立刻指向 b，不等读取完成（adr/0025）  selection=sela
```

可复现地证明了「点了 b，回读到的是 a」。修复后全量自检 `SELFTEST OK`。
