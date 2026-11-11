// System/IconCache.swift
// App icons, rendered once into bitmaps at the size the grid needs, so scrolling and
// dragging draw a plain image instead of resolving an NSImage icon family every frame.

import AppKit

final class IconCache {
    static let shared = IconCache()

    private struct Key: Hashable { let url: URL; let bucket: Int; let scale: Int }
    private var cache: [Key: NSImage] = [:]
    private let lock = NSLock()

    /// Icon for the app at `url`, rasterised at `points` × the sharpest attached screen's scale.
    /// The scale is part of the key: plugging in a Retina display re-renders 1× icons sharp.
    func icon(for url: URL, points: CGFloat) -> NSImage {
        let bucket = max(16, (points / 8).rounded(.up) * 8)   // reuse across tiny size changes
        let scale = NSScreen.screens.map(\.backingScaleFactor).max() ?? 2
        let key = Key(url: url, bucket: Int(bucket), scale: Int(scale.rounded()))
        lock.lock()
        if let img = cache[key] { lock.unlock(); return img }
        lock.unlock()

        let source = NSWorkspace.shared.icon(forFile: url.path)
        let px = Int(bucket * scale)
        let image: NSImage
        if let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                                      samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                      colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
           let ctx = { () -> NSGraphicsContext? in
               // The size must be set before the context exists: the context takes its point→pixel
               // transform from it. Set afterwards, a 2× bitmap got the icon in its top-left quarter.
               rep.size = NSSize(width: bucket, height: bucket)
               return NSGraphicsContext(bitmapImageRep: rep)
           }() {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = ctx
            ctx.imageInterpolation = .high
            source.draw(in: NSRect(x: 0, y: 0, width: bucket, height: bucket), from: .zero,
                        operation: .sourceOver, fraction: 1)
            NSGraphicsContext.restoreGraphicsState()
            image = NSImage(size: rep.size)
            image.addRepresentation(rep)
        } else {
            image = source
        }
        lock.lock()
        cache[key] = image
        lock.unlock()
        return image
    }

    func invalidate() {
        lock.lock()
        cache.removeAll()
        lock.unlock()
    }

    /// Warms the cache off the main thread, at every size the launcher draws for an icon of
    /// `points`: the tile, the miniatures inside a folder, and the dragged folder's
    /// refraction. A miss is rasterised on the main thread, which stalled the first folder
    /// open and folder drag.
    func preload(_ urls: [URL], points: CGFloat) {
        let lens = points * 0.72
        let sizes = [points, points * 0.232, lens, lens * 0.23]
        DispatchQueue.global(qos: .userInitiated).async {
            for size in sizes {
                for url in urls { _ = self.icon(for: url, points: size) }
            }
        }
    }
}
