// Launcher/LauncherModel+Input.swift
// Mouse, trackpad and keyboard handling: hit-testing, clicks, long-press to edit, dragging
// icons (reorder, make folders, flip pages at the screen edges, pull apps out of folders,
// drop on the Dock), page swipes and keyboard navigation.

import AppKit
import SwiftUI

enum Hit: Equatable {
    case item(id: String, slot: Int, inFolder: Bool)
    case deleteBadge(AppID)
    case pageDot(Int)
    case folderBackground
    case outsideFolder
    case empty
}

/// Per-gesture bookkeeping that the views never see.
final class InputState {
    struct Press {
        var start: CGPoint
        var hit: Hit
        var time: Date
        var modifiers: NSEvent.ModifierFlags
        var longPressed = false
        var mode: Mode = .none
        var startScrollY: CGFloat = 0
        var lastX: CGFloat = 0
        var velocity: CGFloat = 0
        enum Mode { case none, item, swipe, scroll }
    }
    var press: Press?
    var longPress: DispatchWorkItem?
    var swiping = false
    var swipeVelocity: CGFloat = 0
    var wheelAccum: CGFloat = 0
    var lastWheelFlip = Date.distantPast
    var lastWheelEvent = Date.distantPast
    var velocityReset: DispatchWorkItem?
    var ignoreMomentum = false
}

extension LauncherModel {

    // MARK: - Placement helpers

    /// Centre of the item at `slot` on the current page (or flat slot in vertical mode), in
    /// view coordinates.
    func onScreenCenter(slot: Int) -> CGPoint {
        if isVertical { return metrics.verticalIconCenter(flat: slot, scrollY: scrollY) }
        return metrics.iconCenter(slot: slot)
    }

    func onScreenHitRect(slot: Int) -> CGRect {
        if isVertical {
            let c = onScreenCenter(slot: slot)
            let r = metrics.hitRect(slot: slot % metrics.columns)
            let base = metrics.iconCenter(slot: slot % metrics.columns)
            return r.offsetBy(dx: c.x - base.x, dy: c.y - base.y)
        }
        return metrics.hitRect(slot: slot)
    }

    /// Items visible right now with their slot numbers.
    var visibleSlots: [(item: LayoutItem, slot: Int)] {
        let pages = displayPages
        if isVertical {
            return pages.flatMap { $0 }.enumerated().map { ($0.element, $0.offset) }
        }
        guard page < pages.count else { return [] }
        return pages[page].enumerated().map { ($0.element, $0.offset) }
    }

    func canUninstall(_ item: LayoutItem) -> Bool {
        guard case .app(let id) = item, let app = apps[id] else { return false }
        return AppActions.canUninstall(app)
    }

    // MARK: - Hit testing

    func hit(at p: CGPoint) -> Hit {
        if let fm = folderMetrics, let folder = openFolder {
            let cap = fm.capacity
            let start = folderPage * cap
            for (i, id) in folder.apps.enumerated() where i >= start && i < start + cap {
                if isEditing, let app = apps[id], AppActions.canUninstall(app),
                   deleteBadgeRect(center: fm.iconCenter(slot: i)).contains(p) {
                    return .deleteBadge(id)
                }
                if fm.hitRect(slot: i).contains(p) { return .item(id: id, slot: i, inFolder: true) }
            }
            if fm.panelRect.contains(p) { return .folderBackground }
            return .outsideFolder
        }
        if settings.showPageDots, !isVertical, let dot = metrics.pageDot(at: p, count: pageCount) { return .pageDot(dot) }
        // In the vertical view, rows scrolled under the fades can't be clicked.
        let g = metrics.gridRect
        if isVertical, p.y < g.minY - 4 || p.y > g.maxY + 10 { return .empty }
        for (item, slot) in visibleSlots {
            if isEditing, canUninstall(item), deleteBadgeRect(center: onScreenCenter(slot: slot)).contains(p) {
                return .deleteBadge(item.id)
            }
            if onScreenHitRect(slot: slot).contains(p) { return .item(id: item.id, slot: slot, inFolder: false) }
        }
        return .empty
    }

    func deleteBadgeRect(center: CGPoint) -> CGRect {
        let s = metrics.iconSize
        let c = CGPoint(x: center.x - s * 0.40, y: center.y - s * 0.40)
        return CGRect(x: c.x - 14, y: c.y - 14, width: 28, height: 28)
    }

    func displayItem(id: String) -> LayoutItem? {
        if let item = layout.item(id: id) { return item }
        if apps[id] != nil { return .app(id) }
        return nil
    }

    // MARK: - Mouse

    func mouseDown(at p: CGPoint, modifiers: NSEvent.ModifierFlags, clickCount: Int) {
        guard dialog == nil else { return }
        let h = hit(at: p)
        input.press = InputState.Press(start: p, hit: h, time: Date(), modifiers: modifiers, startScrollY: scrollY, lastX: p.x)
        input.longPress?.cancel()
        if case .item = h, !isSearching {
            let work = DispatchWorkItem { [weak self] in
                guard let self, var press = self.input.press, press.mode == .none else { return }
                press.longPressed = true
                self.input.press = press
                withAnimation(self.anim(0.3)) { self.editing = true }
            }
            input.longPress = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
        }
    }

    func mouseDragged(to p: CGPoint) {
        guard var press = input.press else { return }
        let dx = p.x - press.start.x, dy = p.y - press.start.y
        if press.mode == .none {
            guard hypot(dx, dy) > 5 else { return }
            input.longPress?.cancel()
            switch press.hit {
            case .item(let id, let slot, let inFolder) where !isSearching && !press.modifiers.contains(.command):
                press.mode = .item
                input.press = press
                // Grab offset from where the press began, so the icon stays under the finger.
                beginItemDrag(id: id, slot: slot, inFolder: inFolder, at: press.start)
                updateItemDrag(to: p)
                return
            case .item(let id, _, _) where isSearching:
                // Search results can still go to the Dock.
                if let app = apps[id] { host?.beginDockDrag(app: app) }
                press.mode = .item
                input.press = press
                return
            case .empty, .pageDot, .item:
                press.mode = isVertical ? .scroll : .swipe
            default:
                return
            }
        }
        switch press.mode {
        case .item:
            updateItemDrag(to: p)
        case .swipe:
            press.velocity = p.x - press.lastX
            press.lastX = p.x
            pageOffset = rubberBand(dx)
        case .scroll:
            let count = displayPages.flatMap { $0 }.count
            scrollY = min(max(0, press.startScrollY - dy), metrics.maxScrollY(count: count))
        case .none:
            break
        }
        input.press = press
    }

    func mouseUp(at p: CGPoint, modifiers: NSEvent.ModifierFlags) {
        input.longPress?.cancel()
        guard let press = input.press else { return }
        input.press = nil
        switch press.mode {
        case .item:
            if drag != nil { endItemDrag() }
            return
        case .swipe:
            finishSwipe(velocity: press.velocity * 4)
            return
        case .scroll:
            return
        case .none:
            break
        }
        if press.longPressed { return }
        tap(press.hit, modifiers: modifiers)
    }

    private func tap(_ h: Hit, modifiers: NSEvent.ModifierFlags) {
        switch h {
        case .item(let id, _, _):
            if modifiers.contains(.command) || modifiers.contains(.shift) {
                withAnimation(.easeOut(duration: 0.15)) { toggleSelection(id) }
                return
            }
            if !selection.isEmpty {
                withAnimation(.easeOut(duration: 0.15)) { selection.removeAll() }
            }
            guard let item = displayItem(id: id) else { return }
            if isEditing, !item.isFolder { return }
            open(item)
        case .deleteBadge(let id):
            requestUninstall([id])
        case .pageDot(let i):
            goToPage(i)
        case .folderBackground:
            break
        case .outsideFolder:
            closeFolder()
        case .empty:
            if editing { withAnimation(anim(0.3)) { editing = false } }
            else if !selection.isEmpty { withAnimation(.easeOut(duration: 0.15)) { selection.removeAll() } }
            else { host?.dismissLauncher(launching: false) }
        }
    }

    func rightMouseDown(at p: CGPoint) {
        guard dialog == nil, drag == nil else { return }
        host?.showMenu(menu(for: hit(at: p)), at: p)
    }

    // MARK: - Swiping pages

    private func rubberBand(_ dx: CGFloat) -> CGFloat {
        let atStart = page == 0 && dx > 0
        let atEnd = page >= pageCount - 1 && dx < 0
        return (atStart || atEnd) ? dx * 0.3 : dx
    }

    func finishSwipe(velocity: CGFloat) {
        let threshold = size.width * 0.12
        var target = page
        if pageOffset < -threshold || velocity < -12 { target = page + 1 }
        if pageOffset > threshold || velocity > 12 { target = page - 1 }
        target = min(max(0, target), pageCount - 1)
        withAnimation(pageAnimation()) {
            page = target
            pageOffset = 0
        }
        keyboardIndex = nil
    }

    func scrollWheel(dx: CGFloat, dy: CGFloat, precise: Bool, phase: NSEvent.Phase, momentum: NSEvent.Phase) {
        guard dialog == nil, drag == nil else { return }
        if let f = openFolder {
            let pages = Int(ceil(Double(f.apps.count) / Double(settings.folderCapacity)))
            guard pages > 1 else { return }
            discreteFlip(dx: dx, dy: dy, precise: precise, phase: phase, momentum: momentum) { dir in
                let next = min(max(0, self.folderPage + dir), pages - 1)
                withAnimation(self.anim(0.4)) { self.folderPage = next }
            }
            return
        }
        if isVertical {
            let count = displayPages.flatMap { $0 }.count
            let delta = precise ? dy : dy * 12
            scrollY = min(max(0, scrollY - delta), metrics.maxScrollY(count: count))
            return
        }
        // A wheel (or a mouse with smooth scrolling — precise deltas but no gesture phases)
        // flips one page per notch/flick, up/down as well as left/right.
        if !precise || (phase.isEmpty && momentum.isEmpty) {
            discreteFlip(dx: dx, dy: dy, precise: false, phase: phase, momentum: momentum) { dir in self.goToPage(self.page + dir) }
            return
        }
        // Trackpad: follow the fingers, then snap.
        if phase.contains(.began) {
            input.swiping = true
            input.ignoreMomentum = false
            input.swipeVelocity = 0
        }
        if !momentum.isEmpty { return }
        guard input.swiping else { return }
        if phase.contains(.changed) {
            let d = abs(dx) >= abs(dy) ? dx : dy
            input.swipeVelocity = d
            pageOffset += (page == 0 && pageOffset + d > 0) || (page >= pageCount - 1 && pageOffset + d < 0) ? d * 0.3 : d
        }
        if phase.contains(.ended) || phase.contains(.cancelled) {
            input.swiping = false
            finishSwipe(velocity: input.swipeVelocity)
        }
    }

    private func discreteFlip(dx: CGFloat, dy: CGFloat, precise: Bool, phase: NSEvent.Phase, momentum: NSEvent.Phase,
                              flip: (Int) -> Void) {
        if !momentum.isEmpty { return }
        if phase.contains(.began) || Date().timeIntervalSince(input.lastWheelEvent) > 0.3 { input.wheelAccum = 0 }
        input.lastWheelEvent = Date()
        let d = abs(dx) >= abs(dy) ? dx : dy
        input.wheelAccum += d
        let threshold: CGFloat = precise ? 40 : 1
        guard abs(input.wheelAccum) >= threshold, Date().timeIntervalSince(input.lastWheelFlip) > 0.5 else { return }
        flip(input.wheelAccum > 0 ? -1 : 1)
        input.wheelAccum = 0
        input.lastWheelFlip = Date()
    }

    // MARK: - Dragging icons

    func beginItemDrag(id: String, slot: Int, inFolder: Bool, at p: CGPoint) {
        var ids = [id]
        if !inFolder, selection.contains(id), selection.count > 1 {
            ids = [id] + orderedSelection.filter { $0 != id }
        }
        let original = layout
        let center: CGPoint
        if inFolder, let fm = folderMetrics { center = fm.iconCenter(slot: slot) } else { center = onScreenCenter(slot: slot) }
        let grab = CGSize(width: p.x - center.x, height: p.y - center.y)

        if inFolder, let folder = openFolder {
            let index = folder.apps.firstIndex(of: id) ?? 0
            drag = DragState(ids: ids, fromFolder: folder.id, base: original,
                             baseFolderApps: folder.apps.filter { !ids.contains($0) }, original: original,
                             location: p, grab: grab, target: ItemPosition(page: 0, index: index))
            return
        }
        var base = original
        let pos = original.position(of: id) ?? ItemPosition(page: page, index: 0)
        let before = original.pages[pos.page].prefix(pos.index).filter { !ids.contains($0.id) }.count
        base.remove(ids)
        drag = DragState(ids: ids, fromFolder: nil, base: base, original: original, location: p, grab: grab,
                         target: ItemPosition(page: pos.page, index: before))
        applyMainPreview()
    }

    private var draggedItems: [LayoutItem] {
        guard let d = drag else { return [] }
        var scratch = d.original
        return scratch.remove(d.ids)
    }

    private func applyMainPreview() {
        guard let d = drag else { return }
        var l = d.base
        l.insert(draggedItems, page: d.target.page, index: d.target.index)
        l.reflow(capacity: settings.capacity, dropEmptyPages: false)
        withAnimation(anim(0.32)) { layout = l }
    }

    private func applyFolderPreview() {
        guard let d = drag, let folderID = d.fromFolder else { return }
        var appsInFolder = d.baseFolderApps
        appsInFolder.insert(contentsOf: d.ids, at: min(d.target.index, appsInFolder.count))
        var l = d.base
        l.updateFolder(folderID) { $0.apps = appsInFolder }
        withAnimation(anim(0.32)) { layout = l }
    }

    func updateItemDrag(to p: CGPoint) {
        guard var d = drag else { return }
        let dt = max(0.004, Date().timeIntervalSince(d.lastUpdate))
        let v = CGSize(width: (p.x - d.location.x) / dt, height: (p.y - d.location.y) / dt)
        d.velocity = CGSize(width: d.velocity.width * 0.7 + v.width * 0.3, height: d.velocity.height * 0.7 + v.height * 0.3)
        d.lastUpdate = Date()
        d.location = p
        drag = d
        // The glass settles when the pointer stops.
        input.velocityReset?.cancel()
        let reset = DispatchWorkItem { [weak self] in
            guard let self, self.drag != nil else { return }
            withAnimation(.spring(duration: 0.45, bounce: 0.35)) { self.drag?.velocity = .zero }
        }
        input.velocityReset = reset
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.09, execute: reset)

        // Over the Dock (but not in a page-flip zone): hand the app to a real drag session
        // so the Dock can take it.
        let insets = host?.dockSideInsets() ?? (left: 0, right: 0)
        let edge = max(36, size.width * 0.035)
        let inFlipZone = !isVertical && d.fromFolder == nil
            && ((p.x >= insets.left && p.x < insets.left + edge) || (p.x <= size.width - insets.right && p.x > size.width - insets.right - edge))
        if !inFlipZone, d.ids.count == 1, apps[d.ids[0]] != nil, layout.item(id: d.ids[0])?.isFolder != true,
           host?.pointerIsOverDock() == true, let app = apps[d.ids[0]] {
            cancelItemDrag()
            host?.beginDockDrag(app: app)
            return
        }

        if let folderID = d.fromFolder {
            guard let fm = folderMetrics else { return }
            if !fm.panelRect.insetBy(dx: -36, dy: -36).contains(p) {
                // Pulled out of the folder: continue as a drag on the main grid.
                var base = d.original
                base.remove(d.ids)
                d.fromFolder = nil
                d.base = base
                let slot = isVertical ? metrics.verticalSlot(at: p, scrollY: scrollY) : metrics.nearestSlot(to: p)
                d.target = isVertical ? base.position(forFlatIndex: slot)
                    : ItemPosition(page: page, index: min(slot, page < base.pages.count ? base.pages[page].count : 0))
                drag = d
                withAnimation(anim(0.3)) { openFolderID = nil }
                _ = folderID
                applyMainPreview()
                return
            }
            let index = min(fm.nearestSlot(to: p) + folderPage * fm.capacity, d.baseFolderApps.count)
            if index != d.target.index {
                d.target.index = index
                drag = d
                applyFolderPreview()
            }
            return
        }

        let now = Date()
        // Flip pages at the left/right edges.
        if !isVertical {
            let dir = p.x < insets.left + edge ? -1 : (p.x > size.width - insets.right - edge ? 1 : 0)
            if dir != 0 {
                if d.edgeSince == nil { d.edgeSince = now }
                if let since = d.edgeSince, now.timeIntervalSince(since) > 0.55 {
                    let next = page + dir
                    let pageHasOthers = page < d.base.pages.count && !d.base.pages[page].isEmpty
                    let allowed = next >= 0 && (next < d.base.pages.count || (next == d.base.pages.count && pageHasOthers))
                    if allowed {
                        d.edgeSince = now.addingTimeInterval(0.3)
                        let count = next < d.base.pages.count ? d.base.pages[next].count : 0
                        d.target = ItemPosition(page: next, index: count)
                        drag = d
                        withAnimation(pageAnimation()) { page = next }
                        applyMainPreview()
                        return
                    }
                }
                drag = d
                return
            }
            d.edgeSince = nil
        } else {
            // Auto-scroll near the top and bottom of the grid.
            let g = metrics.gridRect
            let count = displayPages.flatMap { $0 }.count
            if p.y < g.minY + 24 { scrollY = max(0, scrollY - 14) }
            if p.y > g.maxY - 24 { scrollY = min(metrics.maxScrollY(count: count), scrollY + 14) }
        }

        // What the dragged icon (not the pointer) is over. Its body has to actually cover
        // another icon before anything happens there:
        //  - apps dropped on an icon make / join a folder (after a short rest);
        //  - a folder resting on an icon takes its place;
        //  - icons only make room when the dragged icon is in the gap between them.
        let iconCenter = CGPoint(x: p.x - d.grab.width, y: p.y - d.grab.height)
        let draggingOnlyApps = d.ids.allSatisfy { d.original.item(id: $0)?.isFolder != true }
        var over: (id: String, slot: Int)?
        for (item, slot) in visibleSlots where !d.ids.contains(item.id) {
            let c = onScreenCenter(slot: slot)
            if hypot(iconCenter.x - c.x, iconCenter.y - c.y) < metrics.iconSize * 0.5 { over = (item.id, slot); break }
        }
        if let over {
            if d.mergeCandidate != over.id {
                d.mergeCandidate = over.id
                d.mergeSince = now
            }
            let rested = now.timeIntervalSince(d.mergeSince ?? now)
            // An icon that just slid under the pointer isn't a target yet.
            let settled = now.timeIntervalSince(d.lastMove) > 0.3
            if draggingOnlyApps {
                if rested > 0.22, settled, mergeTargetID != over.id {
                    withAnimation(anim(0.25)) { mergeTargetID = over.id }
                }
            } else if rested > 0.45, settled {
                moveDragTarget(&d, slot: over.slot, now: now)
                d.mergeCandidate = nil
            }
            d.pendingTarget = nil
            drag = d
            return
        }
        d.mergeCandidate = nil
        if mergeTargetID != nil { withAnimation(anim(0.25)) { mergeTargetID = nil } }

        // In a gap: make room there once the spot has been held briefly.
        let slot = isVertical ? metrics.verticalSlot(at: iconCenter, scrollY: scrollY) : metrics.nearestSlot(to: iconCenter)
        if d.pendingTarget != slot {
            d.pendingTarget = slot
            d.pendingSince = now
        } else if let since = d.pendingSince, now.timeIntervalSince(since) > 0.08 {
            moveDragTarget(&d, slot: slot, now: now)
        }
        drag = d
    }

    private func moveDragTarget(_ d: inout DragState, slot: Int, now: Date) {
        let target: ItemPosition
        if isVertical {
            target = d.base.position(forFlatIndex: min(slot, d.base.allItems.count))
        } else {
            let count = page < d.base.pages.count ? d.base.pages[page].count : 0
            target = ItemPosition(page: page, index: min(slot, count))
        }
        guard target != d.target else { return }
        d.target = target
        d.lastMove = now
        drag = d
        applyMainPreview()
    }

    func endItemDrag() {
        // Dropped in a gap before the spot settled: still put it there.
        if var pending = drag, pending.fromFolder == nil, mergeTargetID == nil, let slot = pending.pendingTarget {
            moveDragTarget(&pending, slot: slot, now: Date())
        }
        guard let d = drag else { return }
        let primary = d.ids[0]
        withAnimation(anim(0.35)) {
            if d.fromFolder == nil, let target = mergeTargetID {
                var l = layout
                let moving = d.ids.filter { $0 != target }
                let names = ([target] + moving).compactMap { apps[$0] }
                let folderID = l.merge(moving, into: target, newFolderName: AppActions.folderName(for: names))
                l.reflow(capacity: settings.capacity)
                layout = l
                if let folderID, let pos = layout.position(of: folderID) { page = pos.page }
            } else {
                var l = layout
                l.reflow(capacity: settings.capacity)
                layout = l
                if !isVertical, let pos = layout.position(of: primary) { page = pos.page }
            }
            drag = nil
            mergeTargetID = nil
            selection.removeAll()
            clampPage()
        }
        scheduleSave()
    }

    func cancelItemDrag() {
        guard let d = drag else { return }
        withAnimation(anim(0.3)) {
            layout = d.original
            drag = nil
            mergeTargetID = nil
            clampPage()
        }
        input.press = nil
    }

    // MARK: - Keyboard

    /// Returns true when the key was handled (and must not reach the search field).
    func keyDown(keyCode: UInt16, modifiers: NSEvent.ModifierFlags, characters: String?) -> Bool {
        let cmd = modifiers.contains(.command)
        if dialog != nil {
            if keyCode == 53 { withAnimation(anim(0.2)) { dialog = nil }; return true }
            return false
        }
        if cmd {
            switch characters?.lowercased() {
            case ",": host?.openSettings(); return true
            case "w", "q": host?.dismissLauncher(launching: false); return true
            case "f": focusSearchToken += 1; return true
            case "=", "+": adjustIconScale(by: 0.1); return true
            case "-", "_": adjustIconScale(by: -0.1); return true
            case "0": adjustIconScale(by: nil); return true
            case "a" where !isSearching:
                withAnimation(.easeOut(duration: 0.15)) {
                    selection = (openFolder?.apps ?? (page < layout.pages.count ? layout.pages[page].map(\.id) : []))
                }
                return true
            default: break
            }
            if keyCode == 123 { goToPage(page - 1); return true }
            if keyCode == 124 { goToPage(page + 1); return true }
            return false
        }
        switch keyCode {
        case 53: // esc
            if drag != nil { cancelItemDrag() }
            else if openFolderID != nil { closeFolder() }
            else if isSearching { query = "" }
            else if editing { withAnimation(anim(0.3)) { editing = false } }
            else if !selection.isEmpty { selection.removeAll() }
            else { host?.dismissLauncher(launching: false) }
            return true
        case 36, 76: // return
            if let item = keyboardItem() { open(item); return true }
            if editing { withAnimation(anim(0.3)) { editing = false }; return true }
            return false
        case 123: moveKeyboard(-1); return true
        case 124: moveKeyboard(1); return true
        case 125: moveKeyboard(openFolder != nil ? settings.folderColumns : settings.columns); return true
        case 126: moveKeyboard(-(openFolder != nil ? settings.folderColumns : settings.columns)); return true
        case 48: moveKeyboard(modifiers.contains(.shift) ? -1 : 1); return true
        default:
            return false
        }
    }

    /// The list the arrow keys move through, and the index of its first item on screen.
    private var keyboardList: [LayoutItem] {
        if let f = openFolder { return f.apps.map { .app($0) } }
        if isSearching { return results.map { .app($0) } }
        if isVertical { return layout.allItems }
        return page < layout.pages.count ? layout.pages[page] : []
    }

    func keyboardItem() -> LayoutItem? {
        guard let i = keyboardIndex else { return nil }
        let list = keyboardList
        return i < list.count ? list[i] : nil
    }

    /// Id of the item the keyboard highlight is on (for drawing).
    var keyboardItemID: String? { keyboardItem()?.id }

    private func moveKeyboard(_ delta: Int) {
        let list = keyboardList
        guard let current = keyboardIndex else {
            if !list.isEmpty { keyboardIndex = isSearching ? page * settings.capacity : 0 }
            return
        }
        let next = current + delta
        if openFolder == nil, !isSearching, !isVertical {
            // Walk across pages.
            if next < 0, page > 0 {
                goToPage(page - 1)
                keyboardIndex = max(0, layout.pages[page].count - 1)
                return
            }
            if next >= list.count, page < layout.pages.count - 1 {
                goToPage(page + 1)
                keyboardIndex = 0
                return
            }
        }
        guard !list.isEmpty else { return }
        let clamped = min(max(0, next), list.count - 1)
        keyboardIndex = clamped
        if isSearching, !isVertical {
            let p = clamped / settings.capacity
            if p != page { goToPage(p) }
        }
        if let fm = folderMetrics, openFolder != nil {
            let p = clamped / fm.capacity
            if p != folderPage { withAnimation(anim(0.4)) { folderPage = p } }
        }
        if isVertical, openFolder == nil {
            let c = metrics.verticalIconCenter(flat: clamped, scrollY: scrollY)
            let g = metrics.gridRect
            let count = displayPages.flatMap { $0 }.count
            if c.y < g.minY + metrics.iconSize { scrollY = max(0, scrollY - metrics.rowHeight) }
            if c.y > g.maxY - metrics.iconSize { scrollY = min(metrics.maxScrollY(count: count), scrollY + metrics.rowHeight) }
        }
    }

    func flagsChanged(_ flags: NSEvent.ModifierFlags) {
        let onlyOption = flags.intersection([.option, .command, .control, .shift]) == .option
        if onlyOption != optionHeld, !isSearching {
            withAnimation(anim(0.25)) { optionHeld = onlyOption }
        }
    }

    // MARK: - Context menus

    func menu(for h: Hit) -> [MenuEntry] {
        switch h {
        case .item(let id, _, let inFolder):
            if selection.count > 1, selection.contains(id) { return batchMenu() }
            guard let item = displayItem(id: id) else { return [] }
            switch item {
            case .folder(let f): return folderMenu(f)
            case .app(let appID): return appMenu(appID, inFolder: inFolder)
            }
        case .deleteBadge(let id):
            return appMenu(id, inFolder: layout.folderContaining(id) != nil)
        default:
            return backgroundMenu()
        }
    }

    private func appMenu(_ id: AppID, inFolder: Bool) -> [MenuEntry] {
        guard let app = apps[id] else { return [] }
        var m: [MenuEntry] = [
            MenuEntry(title: "Open", symbol: "arrow.up.forward.app") { [weak self] in self?.launch(id) },
            MenuEntry(title: "Show in Finder", symbol: "folder") { [weak self] in
                AppActions.revealInFinder(app)
                self?.host?.dismissLauncher(launching: true)
            },
            .separator,
            MenuEntry(title: "Rename…", symbol: "pencil") { [weak self] in
                guard let self else { return }
                withAnimation(self.anim(0.25)) { self.dialog = .rename(id, self.name(of: id)) }
            },
            MenuEntry(title: "Hide", symbol: "eye.slash") { [weak self] in self?.hide([id]) },
        ]
        if inFolder {
            m.append(MenuEntry(title: "Remove from Folder", symbol: "rectangle.portrait.and.arrow.right") { [weak self] in
                self?.removeFromFolder(id)
            })
        }
        if AppActions.isInDock(app) {
            m.append(MenuEntry(title: "Remove from Dock", symbol: "dock.rectangle") { AppActions.removeFromDock(app) })
        } else {
            m.append(MenuEntry(title: "Add to Dock", symbol: "dock.rectangle") { AppActions.addToDock(app) })
        }
        m.append(.separator)
        m.append(MenuEntry(title: selection.contains(id) ? "Deselect" : "Select", symbol: "checkmark.circle") { [weak self] in
            withAnimation(.easeOut(duration: 0.15)) { self?.toggleSelection(id) }
        })
        m.append(MenuEntry(title: "Uninstall…", symbol: "trash", enabled: AppActions.canUninstall(app)) { [weak self] in
            self?.requestUninstall([id])
        })
        return m
    }

    private func folderMenu(_ f: Folder) -> [MenuEntry] {
        [
            MenuEntry(title: "Open", symbol: "folder") { [weak self] in self?.openFolder(f.id) },
            MenuEntry(title: "Sort by Name", symbol: "textformat") { [weak self] in
                guard let self else { return }
                withAnimation(self.anim(0.35)) {
                    self.layout.updateFolder(f.id) { folder in
                        folder.apps.sort { self.name(of: $0).localizedStandardCompare(self.name(of: $1)) == .orderedAscending }
                    }
                }
                self.scheduleSave()
            },
            MenuEntry(title: "Ungroup Folder", symbol: "square.grid.3x3.square") { [weak self] in self?.disbandFolder(f.id) },
            .separator,
            MenuEntry(title: "Hide All \(f.apps.count) Apps", symbol: "eye.slash") { [weak self] in self?.hide(f.apps) },
        ]
    }

    private func batchMenu() -> [MenuEntry] {
        let ids = orderedSelection
        let appIDs = ids.filter { layout.item(id: $0)?.isFolder != true }
        let n = ids.count
        return [
            MenuEntry(title: "Open \(appIDs.count) Apps", symbol: "arrow.up.forward.app", enabled: !appIDs.isEmpty) { [weak self] in
                guard let self else { return }
                appIDs.compactMap { self.apps[$0] }.forEach { AppActions.open($0) }
                self.host?.dismissLauncher(launching: true)
            },
            MenuEntry(title: "New Folder with \(appIDs.count) Apps", symbol: "folder.badge.plus", enabled: appIDs.count >= 2) { [weak self] in
                self?.makeFolder(from: appIDs)
            },
            MenuEntry(title: "Hide \(appIDs.count) Apps", symbol: "eye.slash", enabled: !appIDs.isEmpty) { [weak self] in
                self?.hide(appIDs)
            },
            MenuEntry(title: "Uninstall \(appIDs.count) Apps…", symbol: "trash", enabled: !appIDs.isEmpty) { [weak self] in
                self?.requestUninstall(appIDs)
            },
            .separator,
            MenuEntry(title: "Deselect All (\(n))", symbol: "xmark.circle") { [weak self] in
                withAnimation(.easeOut(duration: 0.15)) { self?.selection.removeAll() }
            },
        ]
    }

    /// Steps the icon size (nil = default), clamped to the Settings slider's range.
    func adjustIconScale(by step: Double?) {
        let current = prefs.settings.iconScale
        let next = step.map { ((current + $0) * 10).rounded() / 10 } ?? 1.0
        withAnimation(anim(0.25)) { prefs.settings.iconScale = min(1.6, max(0.5, next)) }
    }

    private func backgroundMenu() -> [MenuEntry] {
        [
            MenuEntry(title: editing ? "Done Editing" : "Edit Layout", symbol: "square.grid.3x3") { [weak self] in
                guard let self else { return }
                withAnimation(self.anim(0.3)) { self.editing.toggle() }
            },
            MenuEntry(title: "Sort All Apps by Name", symbol: "textformat") { [weak self] in self?.sortAlphabetically() },
            MenuEntry(title: "Layout", symbol: "rectangle.grid.3x2", children: LayoutPreset.allCases.map { preset in
                MenuEntry(title: preset.title, checked: LayoutPreset.matching(settings) == preset) { [weak self] in
                    if let self { preset.apply(to: &self.prefs.settings) }
                }
            }),
            MenuEntry(title: "Icon Size", symbol: "textformat.size", children: [
                MenuEntry(title: "Larger  (⌘+)") { [weak self] in self?.adjustIconScale(by: 0.1) },
                MenuEntry(title: "Smaller  (⌘−)") { [weak self] in self?.adjustIconScale(by: -0.1) },
                MenuEntry(title: "Default  (⌘0)") { [weak self] in self?.adjustIconScale(by: nil) },
            ]),
            MenuEntry(title: "Import Launchpad Layout", symbol: "square.and.arrow.down", enabled: LaunchpadImporter.isAvailable) { [weak self] in
                self?.importLaunchpadLayout()
            },
            .separator,
            MenuEntry(title: "Settings…", symbol: "gearshape") { [weak self] in self?.host?.openSettings() },
            MenuEntry(title: "Close LaunchApp", symbol: "xmark") { [weak self] in self?.host?.dismissLauncher(launching: false) },
        ]
    }
}
