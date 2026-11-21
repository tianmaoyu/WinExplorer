# ADR 0023 · 树形功能全面测试与 Shift 范围选择崩溃

- 状态：已实施（v1.5.4）
- 起因：用户要求用真实文件系统数据全面测试树形功能，并重点排查
  「先选 a、再 Shift 选 d」时的范围选择。
- 关联：[ADR 0019](0019-tree-folder-management.md)（树形）、
  [ADR 0022](0022-selection-only-current-level.md)（选中项查询）

## 问题：Shift 范围选择用了两个不同的数组

```swift
if shift, let anchor = anchorURL,
   let from = index(of: anchor),      // ← 查的是 visibleItems
   let to = index(of: item.url) {
    selection = Set(items[lower...upper].map(\.url))   // ← 切片用的是 items
}
```

`index(of:)` 在 v1.5.3 改成查 `visibleItems`（树形展开后的完整可见行），
但这一行的切片仍然用 `items`（当前目录的直接子项）。两者长度不同：

- `items` 更短 → 下标越界，**进程直接崩溃**（SIGTRAP / Index out of range）
- 长度恰好够 → 选中的是**另一批项**，范围完全错位

实测：恢复旧代码后，自检在「Shift 正向跨层级连续选中」这一步崩溃退出（exit=133）。

### 修法

```swift
guard upper < visibleItems.count else { return }
selection = Set(visibleItems[lower...upper].map(\.url))
```

下标与取值必须来自**同一个数组**。锚点 `anchorURL` 保持不变，
所以连续按 Shift 点更远的项时，范围始终从最初那个锚点算起（访达行为）。

## 测试覆盖（全部用真实文件/文件夹）

在临时目录里建一棵真实结构，不依赖任何模拟数据：

```
treefull/
  alpha/          ← 展开
    beta/         ← 展开
      gamma/      ← 第 3 层，子项 leaf.txt
      delta.txt
    empty/        ← 空目录
  second/
  third.txt
treebulk/
  f001.txt … f300.txt   ← 300 个文件的扁平目录
```

| 场景 | 断言 |
|---|---|
| 多级嵌套 | 三层展开后共 7 行；第三层有 2 个子项 |
| 同级节点 | `beta` 与 `empty` 缩进一致（同 depth） |
| 展开 / 折叠 | 展开 alpha 5 行、展开 beta 7 行；折叠父级连带后代一起收起并回到 3 行 |
| 空目录 | 展开后行数不变、不崩溃，且被标记为展开 |
| 大量节点 | 300 个文件全部进可见行；全选 300 项；Shift 跨全部行不错位 |
| 新增 | 在子文件夹新建文件 → 磁盘存在 + 可见行出现 |
| 删除 | 删子层文件 → 磁盘消失 + 可见行消失 + 选中集合清空 |
| 重命名 | 子层文件改名 → 可见行显示新名、旧名消失 |
| 移动 | v1.5.2 的用例已覆盖（移入折叠目录后再展开能看到） |
| 点击选择 | 单选只选一项 |
| Shift 正向跨层级 | alpha → third.txt 选中全部 7 行，且包含中间子层节点 |
| Shift 反向 | third.txt → alpha 同样 7 行 |
| Shift 局部范围 | beta → empty 精确等于该切片（5 项） |
| ⌘ 加选 / 减选 | 加选后 2 项；再点一次回到 1 项 |
| 键盘选择 | ↓ 从父级进入子层，↑ 回到父级 |

## 测试基建的两个改进

1. **行缓冲**：`setvbuf(stdout, nil, _IOLBF, 0)`。自检输出重定向到文件时默认是全缓冲，
   一旦中途崩溃，缓冲区里的进度全丢——这次排查就是靠它才看清「崩在哪一步之前」。
2. **不硬编码下标**：断言改成按名字查找（`idx("alpha")`）并配合 `if let`，
   行数一变就不会把「测试自己写错」误判成「产品崩溃」。
   这次第一版就是因为我按 8 行写了下标（实际 7 行）而崩，浪费了一轮。

## 验证

- 自检 **404 项**，zh / en 双向 `SELFTEST OK`
- 修复前后对比：旧代码在跨层级 Shift 选择时 exit=133（数组越界），修复后 32 条树形断言全 PASS

## 取舍

- 没有为 Shift 选择加「跨展开折叠边界」的特殊处理：折叠的目录不产生可见行，
  范围自然跳过它，这符合访达的行为（折叠的节点不参与列表顺序）。
- `selectAll` 仍用 `items`（只选当前层）——⌘A 与 Shift 的语义不同：
  前者是「这个文件夹里的全部」，后者是「列表上这一段」。
