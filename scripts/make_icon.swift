#!/usr/bin/env swift
// 生成 App 图标：1024×1024 的 PNG，交给 scripts/make_icon.sh 转成 .icns
// 用法: swift scripts/make_icon.swift /tmp/icon-1024.png

import AppKit

let canvas = CGFloat(1024)
let argument = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "/tmp/icon-1024.png"

let image = NSImage(size: NSSize(width: canvas, height: canvas))
image.lockFocus()

guard let context = NSGraphicsContext.current else {
    FileHandle.standardError.write(Data("无法获取绘图上下文\n".utf8))
    exit(1)
}
context.imageInterpolation = .high
context.shouldAntialias = true

// 背景：圆角 + 蓝色渐变（macOS 图标的标准留白：四周各 40pt）
let bounds = NSRect(x: 40, y: 40, width: canvas - 80, height: canvas - 80)
let background = NSBezierPath(roundedRect: bounds, xRadius: 210, yRadius: 210)
NSGradient(colors: [
    NSColor(srgbRed: 0.35, green: 0.62, blue: 0.98, alpha: 1),
    NSColor(srgbRed: 0.10, green: 0.31, blue: 0.76, alpha: 1)
])?.draw(in: background, angle: -90)

// 顶部一层很淡的高光，避免整块纯色
let highlight = NSBezierPath(roundedRect: NSRect(x: 40, y: canvas / 2, width: canvas - 80, height: canvas / 2 - 40),
                             xRadius: 200, yRadius: 200)
NSColor.white.withAlphaComponent(0.08).setFill()
highlight.fill()

// 文件夹：标签 + 主体
let folderColor = NSColor.white.withAlphaComponent(0.96)
let tab = NSBezierPath(
    roundedRect: NSRect(x: 168, y: 596, width: 330, height: 132),
    xRadius: 54,
    yRadius: 54
)
folderColor.setFill()
tab.fill()

let body = NSBezierPath(
    roundedRect: NSRect(x: 168, y: 214, width: 688, height: 430),
    xRadius: 62,
    yRadius: 62
)
folderColor.setFill()
body.fill()

// 文件夹里的三行「列表」，暗示这是个文件浏览器
let lineColor = NSColor(srgbRed: 0.16, green: 0.38, blue: 0.82, alpha: 0.55)
lineColor.setFill()
let lines: [(CGFloat, CGFloat)] = [(300, 560), (300, 478), (300, 396)]
let widths: [CGFloat] = [430, 340, 390]
for (index, origin) in lines.enumerated() {
    let rect = NSRect(x: origin.0, y: origin.1, width: widths[index], height: 34)
    NSBezierPath(roundedRect: rect, xRadius: 17, yRadius: 17).fill()
}

image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write(Data("图标编码失败\n".utf8))
    exit(1)
}

do {
    try png.write(to: URL(fileURLWithPath: argument))
    print("已生成 \(argument)")
} catch {
    FileHandle.standardError.write(Data("写文件失败：\(error.localizedDescription)\n".utf8))
    exit(1)
}
