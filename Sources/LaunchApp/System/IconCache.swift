// System/IconCache.swift
// App icons, rendered once into bitmaps at the size the grid needs, so scrolling and
// dragging draw a plain image instead of resolving an NSImage icon family every frame.

import AppKit

final class IconCache {
    static let shared = IconCache()

    private var cache: [String: NSImage] = [:]
    private let lock = NSLock()

    /// Icon for the app at `url`, rasterised at `points` × the main screen's scale.
    func icon(for url: URL, points: CGFloat) -> NSImage {
        let bucket = max(16, (points / 8).rounded(.up) * 8)   // reuse across tiny size changes
        let key = "\(url.path)#\(Int(bucket))"
        lock.lock()
        if let img = cache[key] { lock.unlock(); return img }
        lock.unlock()

        let source = NSWorkspace.shared.icon(forFile: url.path)
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let px = Int(bucket * scale)
        let image: NSImage
        if let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                                      samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                      colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
           let ctx = NSGraphicsContext(bitmapImageRep: rep) {
            rep.size = NSSize(width: bucket, height: bucket)
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

    /// Warms the cache off the main thread.
    func preload(_ urls: [URL], points: CGFloat) {
        DispatchQueue.global(qos: .userInitiated).async {
            for url in urls { _ = self.icon(for: url, points: points) }
        }
    }
}
