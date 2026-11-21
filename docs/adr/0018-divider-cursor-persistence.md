# ADR 0018 · 列分隔线光标「闪一下就消失」

- 状态：已实施（v1.4.14）
- 起因：用户反馈「鼠标悬停在分隔线上时，光标只短暂闪变一下，随后没有保持
  预期的悬停或可拖拽状态」。
- 关联：[ADR 0017](0017-list-style-finder.md)（列表样式与列宽光标）

## 根因

原实现是：

```swift
.onHover { inside in
    hoveredDivider = inside ? column : nil
    if inside { dividerCursor.set() } else { NSCursor.arrow.set() }
}
```

两处独立的问题叠加成「闪一下」：

1. **`NSCursor.set()` 是一次性设置，不是持久状态。**
   它只改变「当前这一刻」的光标。AppKit 在**下一次 `mouseMoved`** 时会根据鼠标
   所在视图的 cursor rect 重新决定光标 —— 而我们的 `Rectangle` 从没注册过
   cursor rect，于是立刻被改回箭头。鼠标动一下，光标就没了。
2. **`onHover` 会在视图重建时丢状态。**
   `FileListView` 观察整个 `BrowserModel`，任何 `@Published` 变化都会重建表头。
   重建出新的 hover 视图时，SwiftUI 不保证补发「鼠标在里面」，`hoveredDivider`
   可能被重置为 `nil` —— 于是高亮也一起消失。

## 决定

光标和悬停态都改由 AppKit 管理，新增 `FileListView.DividerArea`（`NSViewRepresentable`）：

| 职责 | 实现 | 为什么 |
|---|---|---|
| 光标 | `resetCursorRects()` → `addCursorRect(bounds, cursor:)` | cursor rect 是**声明式**的，AppKit 每次鼠标移动都会重新应用，不会掉 |
| 悬停高亮 | `NSTrackingArea(.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect)` | 视图重建时 `updateTrackingAreas()` 会重新注册，状态不丢 |
| 事件穿透 | `hitTest(_:) -> NSView?` 返回 `nil` | 点击、拖拽、双击仍然交给上层 SwiftUI 手势，不抢事件 |

`mouseEntered` 里额外补一次 `cursor.set()`：cursor rect 要等下一次移动才生效，
进入瞬间手动设一次，避免「刚移上去还是箭头」的一帧。

`onChanged` 里保留 `dividerCursor.set()`：拖动过程中鼠标很容易移出 7pt 窄热区，
这时 cursor rect 已不覆盖，需要每帧钉一次。

## 取舍

- **没有用 `NSCursor.push()/pop()`**：视图重建时 push 和 pop 容易失配，
  光标会「卡住」变成别的形状，这是更糟的故障。
- **没有用 `onContinuousHover`**：它只解决坐标回调频率，不解决「`set()` 被重置」
  这个根本问题。

## 验证

- 三个分隔线区域都实际装配（临时探针日志：三条「列分隔光标区域就绪 divider」，
  确认 `cursor` 是自绘的 divider 光标而不是 `.arrow`）。
- 自检 zh / en 全 `SELFTEST OK`——改动在视图层，不影响模型断言。
- 光标本身无法被 `screencapture` 抓到，最终效果需实机确认：鼠标停在
  「大小 / 修改日期 / 类型」之间的竖线上，光标应**持续**保持竖线加两侧箭头，
  同时竖线变粗变蓝；拖到热区外拖动时也应保持。
