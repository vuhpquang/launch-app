// System/Wallpaper.swift
// The blurred desktop picture behind the launcher, like Launchpad. Rendered once per
// (picture, screen size) off the main thread and cached, so opening the launcher is instant.
// Dynamic/aerial wallpapers that NSImage can't read fall back to the Liquid Glass backdrop.

import AppKit
import CoreImage

final class Wallpaper {
    static let shared = Wallpaper()

    private var cacheKey: String?
    private(set) var image: CGImage?
    private let context = CIContext(options: [.useSoftwareRenderer: false])
    private let queue = DispatchQueue(label: "launchapp.wallpaper", qos: .userInitiated)

    /// Returns the cached image for `screen` if it is current; otherwise renders it and
    /// calls `ready` on the main queue.
    func image(for screen: NSScreen, ready: @escaping (CGImage?) -> Void) {
        guard let url = NSWorkspace.shared.desktopImageURL(for: screen) else { ready(nil); return }
        let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)?
            .timeIntervalSince1970 ?? 0
        let size = screen.frame.size
        let key = "\(url.path)#\(mtime)#\(Int(size.width))x\(Int(size.height))"
        if key == cacheKey, let image { ready(image); return }

        queue.async {
            let rendered = self.render(url: url, size: size)
            DispatchQueue.main.async {
                self.cacheKey = key
                self.image = rendered
                ready(rendered)
            }
        }
    }

    private func render(url: URL, size: CGSize) -> CGImage? {
        guard let ns = NSImage(contentsOf: url),
              let cg = ns.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        // Work at ~half the screen size: the result is blurred anyway.
        let target = CGSize(width: size.width / 2, height: size.height / 2)
        var input = CIImage(cgImage: cg)
        // Aspect-fill to the screen.
        let scale = max(target.width / input.extent.width, target.height / input.extent.height)
        input = input.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let ox = (input.extent.width - target.width) / 2
        let oy = (input.extent.height - target.height) / 2
        input = input.cropped(to: CGRect(x: ox, y: oy, width: target.width, height: target.height))
            .transformed(by: CGAffineTransform(translationX: -ox, y: -oy))
        let blurred = input.clampedToExtent()
            .applyingGaussianBlur(sigma: 28)
            .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 1.25, kCIInputBrightnessKey: -0.02])
            .cropped(to: CGRect(origin: .zero, size: target))
        return context.createCGImage(blurred, from: CGRect(origin: .zero, size: target))
    }
}
