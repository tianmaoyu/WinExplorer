import AppKit
import Darwin
import Foundation

/// 开发期自检：WINEXPLORER_SELFTEST=1 启动时，在临时目录里跑一遍
/// 目录读取 / 排序 / 后退前进 / 新建文件夹 / 错误处理，不弹窗、不碰用户数据。
enum SelfTest {
    static func runAll() -> Never {
        var failures = 0

        func check(_ name: String, _ condition: Bool, _ detail: String = "") {
            if condition {
                print("PASS  \(name)")
            } else {
                failures += 1
                print("FAIL  \(name) \(detail)")
            }
        }

        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("winexplorer-selftest-\(UUID().uuidString)")
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        // 造测试数据：2 个文件夹 + 2 个不同大小的文件 + 1 个隐藏文件
        let folderA = root.appendingPathComponent("alpha")
        let folderB = root.appendingPathComponent("beta")
        try? fm.createDirectory(at: folderA, withIntermediateDirectories: false)
        try? fm.createDirectory(at: folderB, withIntermediateDirectories: false)
        fm.createFile(atPath: root.appendingPathComponent("small.txt").path,
                      contents: Data(repeating: 0, count: 10))
        fm.createFile(atPath: root.appendingPathComponent("big.bin").path,
                      contents: Data(repeating: 0, count: 5_000))
        fm.createFile(atPath: root.appendingPathComponent(".secret").path,
                      contents: Data(repeating: 0, count: 1))

        let model = BrowserModel(startAt: root)

        check("读取目录并过滤隐藏文件", model.items.count == 4, "实际 \(model.items.count) 项")
        check("文件夹优先", model.items.prefix(2).allSatisfy { $0.isDirectory })
        check("名称自然排序",
              Array(model.items.map(\.name).suffix(2)) == ["big.bin", "small.txt"],
              "实际 \(model.items.map(\.name))")
        check("文件夹不显示大小", model.items.prefix(2).allSatisfy { $0.sizeText == "—" })
        check("文件类型不是文件夹", model.items.first { $0.name == "small.txt" }?.kind != "文件夹")

        model.showHidden = true
        check("显示隐藏文件", model.items.contains { $0.name == ".secret" })
        model.showHidden = false

        model.sortColumn = .size
        model.sortAscending = false
        check("按大小降序",
              model.items.first(where: { !$0.isDirectory })?.name == "big.bin")
        model.sortColumn = .name
        model.sortAscending = true

        model.navigate(to: folderA)
        check("进入子目录",
              model.currentURL == folderA.standardizedFileURL && model.items.isEmpty,
              "currentURL=\(model.currentURL.path)")
        check("记录后退栈", model.canGoBack)

        model.goBack()
        check("后退回根目录",
              model.currentURL == root.standardizedFileURL && model.canGoForward)
        model.goForward()
        check("前进到子目录", model.currentURL == folderA.standardizedFileURL)
        model.goUp()
        check("上一级", model.currentURL == root.standardizedFileURL)

        model.createFolder()
        check("新建文件夹", fm.fileExists(atPath: root.appendingPathComponent("新建文件夹").path))
        model.createFolder()
        check("重名自动编号", fm.fileExists(atPath: root.appendingPathComponent("新建文件夹 2").path))
        check("新建后选中", model.selection?.lastPathComponent == "新建文件夹 2")

        let before = model.currentURL
        model.navigate(to: root.appendingPathComponent("no-such-dir"))
        check("打不开的目录给出提示而不是崩溃",
              model.errorMessage != nil && model.currentURL == before)

        print(failures == 0 ? "SELFTEST OK" : "SELFTEST FAILED (\(failures) 项)")
        exit(failures == 0 ? 0 : 1)
    }
}
