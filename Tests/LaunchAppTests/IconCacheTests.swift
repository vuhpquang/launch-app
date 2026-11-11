import AppKit
import XCTest
@testable import LaunchApp

/// Rasterised icons must fill their bitmap at any screen scale, not one corner of it.
final class IconCacheTests: XCTestCase {
    func testIconFillsBitmapCentred() throws {
        let image = IconCache.shared.icon(for: URL(fileURLWithPath: "/System/Applications/Notes.app"), points: 96)
        let rep = try XCTUnwrap(image.representations.first as? NSBitmapImageRep)
        XCTAssertEqual(image.size, NSSize(width: 96, height: 96))
        var minX = Int.max, minY = Int.max, maxX = -1, maxY = -1
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.1 {
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        let w = CGFloat(rep.pixelsWide), h = CGFloat(rep.pixelsHigh)
        XCTAssertGreaterThan(CGFloat(maxX - minX) / w, 0.7, "icon covers only part of the bitmap width")
        XCTAssertGreaterThan(CGFloat(maxY - minY) / h, 0.7, "icon covers only part of the bitmap height")
        XCTAssertEqual(CGFloat(minX + maxX) / 2 / w, 0.5, accuracy: 0.05)
        XCTAssertEqual(CGFloat(minY + maxY) / 2 / h, 0.5, accuracy: 0.05)
    }
}
