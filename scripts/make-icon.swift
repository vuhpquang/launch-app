#!/usr/bin/env swift
// scripts/make-icon.swift
// Draws the LaunchApp icon (1024×1024 PNG) with AppKit.
//
//   swift scripts/make-icon.swift Sources/LaunchApp/Resources/AppIcon.png
//
// Motif: a 3×3 grid of glossy app tiles on a deep blue-violet squircle, the top-right tile
// lifting off like a launch. build.sh turns the PNG into AppIcon.icns.

import AppKit

let size: CGFloat = 1024
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.png"

guard let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
      let gctx = NSGraphicsContext(bitmapImageRep: rep) else { fatalError("no context") }
NSGraphicsContext.current = gctx
let ctx = gctx.cgContext

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

// Body: 824pt squircle centred in 1024 (macOS icon grid), soft shadow.
let body = NSRect(x: 100, y: 100, width: 824, height: 824)
let bodyPath = NSBezierPath(roundedRect: body, xRadius: 186, yRadius: 186)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 36, color: NSColor(white: 0, alpha: 0.35).cgColor)
rgb(0x1B1F5E).setFill()
bodyPath.fill()
ctx.restoreGState()

ctx.saveGState()
bodyPath.addClip()
NSGradient(colors: [rgb(0x5B8CFF), rgb(0x4B3FD8), rgb(0x241A66)], atLocations: [0, 0.55, 1], colorSpace: .sRGB)!
    .draw(in: body, angle: -60)
// Soft glow, top left.
NSGradient(starting: NSColor(white: 1, alpha: 0.28), ending: NSColor(white: 1, alpha: 0))!
    .draw(fromCenter: NSPoint(x: 300, y: 820), radius: 0, toCenter: NSPoint(x: 300, y: 820), radius: 560, options: [])
ctx.restoreGState()

// 3×3 tiles.
let tile: CGFloat = 168
let gap: CGFloat = 52
let gridW = tile * 3 + gap * 2
let originX = body.midX - gridW / 2
let originY = body.midY - gridW / 2 - 6
let palette: [(UInt32, UInt32)] = [
    (0xFF7A59, 0xFF3D6E), (0xFFD25A, 0xFF9F1C), (0x55E6A5, 0x14B87A),
    (0x5AD1FF, 0x2A8CFF), (0xFFFFFF, 0xDCE3FF), (0xB18CFF, 0x7A4DFF),
    (0x7CF0FF, 0x2FC6E8), (0xFF8FD2, 0xE0479E), (0xFFFFFF, 0xC9D4FF),
]
for row in 0..<3 {
    for col in 0..<3 {
        let i = row * 3 + col
        var r = NSRect(x: originX + CGFloat(col) * (tile + gap), y: originY + CGFloat(2 - row) * (tile + gap),
                       width: tile, height: tile)
        let launching = (row == 0 && col == 2)
        if launching { r = r.offsetBy(dx: 26, dy: 34) }
        let p = NSBezierPath(roundedRect: r, xRadius: 44, yRadius: 44)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: launching ? -22 : -8), blur: launching ? 34 : 16,
                      color: NSColor(white: 0, alpha: launching ? 0.4 : 0.28).cgColor)
        rgb(palette[i].1).setFill()
        p.fill()
        ctx.restoreGState()
        ctx.saveGState()
        p.addClip()
        NSGradient(starting: rgb(palette[i].0), ending: rgb(palette[i].1))!.draw(in: r, angle: -90)
        NSGradient(starting: NSColor(white: 1, alpha: 0.45), ending: NSColor(white: 1, alpha: 0))!
            .draw(in: NSRect(x: r.minX, y: r.midY, width: r.width, height: r.height / 2), angle: -90)
        ctx.restoreGState()
        NSColor(white: 1, alpha: 0.5).setStroke()
        p.lineWidth = 3
        p.stroke()
    }
}

NSGraphicsContext.current = nil
guard let png = rep.representation(using: .png, properties: [:]) else { fatalError("encode") }
try! png.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
