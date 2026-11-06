// Launcher/GridMetrics.swift
// Where everything sits on screen. Pure geometry (top-left origin, y down — the same as
// SwiftUI and the flipped interaction view), shared by rendering and hit-testing so the
// two can never disagree.

import CoreGraphics
import Foundation

struct GridMetrics: Equatable {
    let size: CGSize
    let columns: Int
    let rows: Int
    let iconScale: CGFloat
    let showLabels: Bool
    let labelSize: CGFloat
    let compact: Bool   // window mode: tighter margins

    init(size: CGSize, columns: Int, rows: Int, iconScale: CGFloat = 1, showLabels: Bool = true,
         labelSize: CGFloat = 13, compact: Bool = false) {
        self.size = size
        self.columns = max(1, columns)
        self.rows = max(1, rows)
        self.iconScale = iconScale
        self.showLabels = showLabels
        self.labelSize = labelSize
        self.compact = compact
    }

    var searchFieldFrame: CGRect {
        let w = min(260, size.width * 0.5)
        let h: CGFloat = 32
        let top: CGFloat = compact ? 22 : max(34, size.height * 0.045)
        return CGRect(x: (size.width - w) / 2, y: top, width: w, height: h)
    }

    /// The area the icon grid fills on one page.
    var gridRect: CGRect {
        let top = searchFieldFrame.maxY + (compact ? 18 : max(26, size.height * 0.035))
        let bottom: CGFloat = compact ? 46 : max(70, size.height * 0.085)
        let side: CGFloat = compact ? 28 : max(60, size.width * 0.105)
        return CGRect(x: side, y: top, width: max(10, size.width - side * 2), height: max(10, size.height - top - bottom))
    }

    var cellSize: CGSize {
        CGSize(width: gridRect.width / CGFloat(columns), height: gridRect.height / CGFloat(rows))
    }

    var labelHeight: CGFloat { showLabels ? ceil(labelSize * 1.35) : 0 }

    var iconSize: CGFloat {
        let c = cellSize
        let base = min(c.width * 0.66, (c.height - labelHeight - 10) * 0.86)
        return max(24, min(180, base * iconScale))
    }

    /// Centre of the icon image in slot `slot` (row-major), page-local.
    func iconCenter(slot: Int) -> CGPoint {
        let col = slot % columns
        let row = slot / columns
        let c = cellSize
        let blockHeight = iconSize + (showLabels ? 8 + labelHeight : 0)
        let x = gridRect.minX + (CGFloat(col) + 0.5) * c.width
        let y = gridRect.minY + CGFloat(row) * c.height + (c.height - blockHeight) / 2 + iconSize / 2
        return CGPoint(x: x, y: y)
    }

    func iconRect(slot: Int) -> CGRect {
        let c = iconCenter(slot: slot)
        return CGRect(x: c.x - iconSize / 2, y: c.y - iconSize / 2, width: iconSize, height: iconSize)
    }

    /// Icon plus its label — what a click hits.
    func hitRect(slot: Int) -> CGRect {
        let r = iconRect(slot: slot)
        let w = min(cellSize.width - 4, max(r.width + 16, iconSize * 1.3))
        return CGRect(x: r.midX - w / 2, y: r.minY - 4, width: w, height: r.height + 8 + labelHeight + 6)
    }

    /// The slot whose cell contains `p` (page-local), clamped into the grid.
    func nearestSlot(to p: CGPoint) -> Int {
        let c = cellSize
        let col = min(columns - 1, max(0, Int((p.x - gridRect.minX) / c.width)))
        let row = min(rows - 1, max(0, Int((p.y - gridRect.minY) / c.height)))
        return row * columns + col
    }

    var capacity: Int { columns * rows }

    // MARK: - Page dots

    func pageDotsFrame(count: Int) -> CGRect {
        let spacing: CGFloat = 18
        let w = CGFloat(count) * spacing
        let y = size.height - (compact ? 28 : max(40, size.height * 0.05))
        return CGRect(x: (size.width - w) / 2, y: y - 9, width: w, height: 18)
    }

    func pageDot(at p: CGPoint, count: Int) -> Int? {
        let f = pageDotsFrame(count: count).insetBy(dx: -4, dy: -6)
        guard count > 1, f.contains(p) else { return nil }
        return min(count - 1, max(0, Int((p.x - f.minX - 4) / 18)))
    }

    // MARK: - Vertical scroll mode

    /// Row height of the continuous grid.
    var rowHeight: CGFloat { cellSize.height }

    func verticalIconCenter(flat: Int, scrollY: CGFloat) -> CGPoint {
        let row = flat / columns
        let base = iconCenter(slot: flat % columns)
        return CGPoint(x: base.x, y: base.y + CGFloat(row) * rowHeight - scrollY)
    }

    func verticalContentHeight(count: Int) -> CGFloat {
        let rowsNeeded = max(1, Int(ceil(Double(count) / Double(columns))))
        return CGFloat(rowsNeeded) * rowHeight
    }

    func maxScrollY(count: Int) -> CGFloat {
        max(0, verticalContentHeight(count: count) - gridRect.height)
    }

    func verticalSlot(at p: CGPoint, scrollY: CGFloat) -> Int {
        let c = cellSize
        let col = min(columns - 1, max(0, Int((p.x - gridRect.minX) / c.width)))
        let row = max(0, Int((p.y - gridRect.minY + scrollY) / c.height))
        return row * columns + col
    }
}

/// Geometry of an open folder: a panel centred on screen with its own small grid.
struct FolderMetrics: Equatable {
    let grid: GridMetrics
    let columns: Int
    let rows: Int
    let count: Int

    var cell: CGSize {
        let c = grid.cellSize
        return CGSize(width: min(c.width, grid.iconSize * 1.75), height: min(c.height, grid.iconSize + grid.labelHeight + 34))
    }

    /// Rows actually shown (fewer when the folder is small).
    var visibleRows: Int { min(rows, max(1, Int(ceil(Double(count) / Double(columns))))) }
    var visibleColumns: Int { count < columns ? max(count, 3) : columns }

    var panelRect: CGRect {
        let w = CGFloat(visibleColumns) * cell.width + 48
        let h = CGFloat(visibleRows) * cell.height + 40
        let x = (grid.size.width - w) / 2
        let y = max(grid.gridRect.minY + 40, (grid.size.height - h) / 2 + 10)
        return CGRect(x: x, y: y, width: w, height: h)
    }

    var titleFrame: CGRect {
        let p = panelRect
        return CGRect(x: p.midX - 200, y: p.minY - 64, width: 400, height: 44)
    }

    var capacity: Int { max(1, columns * rows) }

    func iconCenter(slot: Int) -> CGPoint {
        let local = slot % capacity
        let col = local % columns
        let row = local / columns
        let p = panelRect
        let blockHeight = grid.iconSize + (grid.showLabels ? 8 + grid.labelHeight : 0)
        return CGPoint(x: p.minX + 24 + (CGFloat(col) + 0.5) * cell.width,
                       y: p.minY + 20 + CGFloat(row) * cell.height + (cell.height - blockHeight) / 2 + grid.iconSize / 2)
    }

    func hitRect(slot: Int) -> CGRect {
        let c = iconCenter(slot: slot)
        let s = grid.iconSize
        return CGRect(x: c.x - cell.width / 2 + 4, y: c.y - s / 2 - 4, width: cell.width - 8, height: s + 8 + grid.labelHeight + 6)
    }

    func nearestSlot(to p: CGPoint) -> Int {
        let r = panelRect
        let col = min(columns - 1, max(0, Int((p.x - r.minX - 24) / cell.width)))
        let row = min(rows - 1, max(0, Int((p.y - r.minY - 20) / cell.height)))
        return row * columns + col
    }
}
