#!/usr/bin/env swift
// scripts/make-dmg-background.swift
// Draws the Finder background for LaunchApp.dmg (920×400 points) with AppKit.
// Recent Finder versions won't make a window narrower than ~920 points, so the canvas is
// that wide and the 660-point artwork is centred in it.
//
//   swift scripts/make-dmg-background.swift <out-dir>
//
// Writes dmg-background.png (1×) and dmg-background@2x.png (2×) into <out-dir>.
// The icon positions here must match scripts/dmg-settings.py: app at (300, 200),
// Applications at (620, 200) in Finder's top-left coordinates.

import AppKit

let width: CGFloat = 920
let art: CGFloat = 660            // artwork width, centred
let height: CGFloat = 400
let outDir = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

func text(_ s: String, size: CGFloat, weight: NSFont.Weight, color: NSColor, centerX: CGFloat, y: CGFloat) {
    let para = NSMutableParagraphStyle()
    para.alignment = .center
    let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: size, weight: weight),
        .foregroundColor: color,
        .paragraphStyle: para,
    ]
    let str = NSAttributedString(string: s, attributes: attrs)
    let h = str.size().height
    str.draw(in: NSRect(x: centerX - 300, y: y - h / 2, width: 600, height: h))
}

func render(scale: CGFloat, to url: URL) {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(width * scale), pixelsHigh: Int(height * scale),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
          let gctx = NSGraphicsContext(bitmapImageRep: rep) else { fatalError("no context") }
    rep.size = NSSize(width: width, height: height)   // points, so @2x carries 144 dpi
    NSGraphicsContext.current = gctx
    let ctx = gctx.cgContext
    ctx.scaleBy(x: scale, y: scale)
    let full = NSRect(x: 0, y: 0, width: width, height: height)

    // Soft lavender wash — light, so Finder's dark icon labels stay readable.
    NSGradient(colors: [rgb(0xFBFAFF), rgb(0xEEECFF), rgb(0xE2DFFF)],
               atLocations: [0, 0.55, 1], colorSpace: .sRGB)!.draw(in: full, angle: -90)
    ctx.translateBy(x: (width - art) / 2, y: 0)   // below, x is in artwork coordinates

    // Faint panel behind the icons.
    let pad = NSBezierPath(roundedRect: NSRect(x: 60, y: 92, width: 540, height: 200), xRadius: 28, yRadius: 28)
    rgb(0xFFFFFF, 0.55).setFill()
    pad.fill()
    rgb(0x5B57E8, 0.14).setStroke()
    pad.lineWidth = 1.5
    pad.stroke()

    // Header.
    text("LaunchApp", size: 26, weight: .bold, color: rgb(0x2A2780), centerX: art / 2, y: 352)
    text("Drag LaunchApp into Applications to install", size: 13, weight: .regular,
         color: rgb(0x4A4870, 0.85), centerX: art / 2, y: 324)

    // Arrow from the app (x 170) to Applications (x 490); icon centres sit at y = 400 − 200.
    let y: CGFloat = 200
    let arrow = NSBezierPath()
    arrow.move(to: NSPoint(x: 255, y: y))
    arrow.curve(to: NSPoint(x: 400, y: y + 1), controlPoint1: NSPoint(x: 300, y: y + 22),
                controlPoint2: NSPoint(x: 353, y: y + 22))
    arrow.lineWidth = 4
    arrow.lineCapStyle = .round
    arrow.setLineDash([2, 9], count: 2, phase: 0)
    rgb(0x5B57E8).setStroke()
    arrow.stroke()

    let head = NSBezierPath()
    head.move(to: NSPoint(x: 396, y: y + 11))
    head.line(to: NSPoint(x: 409, y: y - 1))
    head.line(to: NSPoint(x: 394, y: y - 10))
    head.lineWidth = 4
    head.lineCapStyle = .round
    head.lineJoinStyle = .round
    head.stroke()

    // Footer hint.
    text("First launch: if macOS blocks it, open System Settings → Privacy & Security → Open Anyway",
         size: 11, weight: .regular, color: rgb(0x4A4870, 0.7), centerX: art / 2, y: 46)

    NSGraphicsContext.current = nil
    guard let png = rep.representation(using: .png, properties: [:]) else { fatalError("png") }
    try! png.write(to: url)
    print("wrote \(url.path)")
}

try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
render(scale: 1, to: outDir.appendingPathComponent("dmg-background.png"))
render(scale: 2, to: outDir.appendingPathComponent("dmg-background@2x.png"))
