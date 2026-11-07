// Launcher/LauncherView.swift
// Draws the launcher from LauncherModel: background, search field, the icon grid (paged or
// vertical), page dots, an open folder, the icon being dragged, dialogs and toasts.
// No gestures live here — InteractionView handles input — except the text fields and
// dialog buttons, which InteractionView lets through.

import AppKit
import SwiftUI

struct LauncherView: View {
    @ObservedObject var model: LauncherModel
    @ObservedObject var prefs: Preferences

    var body: some View {
        let m = model.metrics
        let s = prefs.settings
        ZStack(alignment: .topLeading) {
            BackgroundView(style: s.background, image: model.backgroundImage, dim: s.backgroundDim, compact: model.compact)
                .opacity(model.presented ? 1 : 0)

            ZStack(alignment: .topLeading) {
                GridLayer(model: model, metrics: m)
                    .blur(radius: model.openFolderID != nil ? 22 : 0)
                    .opacity(model.openFolderID != nil ? 0.45 : 1)

                SearchField(model: model)
                    .frame(width: m.searchFieldFrame.width, height: m.searchFieldFrame.height)
                    .position(x: m.searchFieldFrame.midX, y: m.searchFieldFrame.midY)
                    .opacity(model.openFolderID != nil ? 0 : 1)

                if s.showPageDots, !model.isVertical, model.pageCount > 1 {
                    PageDots(count: model.pageCount, current: model.page, offset: model.pageOffset, width: model.size.width)
                        .frame(width: m.pageDotsFrame(count: model.pageCount).width, height: 18)
                        .position(x: m.pageDotsFrame(count: model.pageCount).midX, y: m.pageDotsFrame(count: model.pageCount).midY)
                        .opacity(model.openFolderID != nil ? 0 : 1)
                }

                if model.isSearching, model.results.isEmpty {
                    Text("No Results")
                        .font(.system(size: 22, weight: .medium))
                        .foregroundStyle(.white.opacity(0.75))
                        .position(x: model.size.width / 2, y: m.gridRect.midY)
                }
            }
            .scaleEffect(model.presented ? 1 : 1.1)
            .opacity(model.presented ? 1 : 0)

            if let folder = model.openFolder, let fm = model.folderMetrics {
                FolderOverlay(model: model, folder: folder, fm: fm)
                    .transition(.scale(scale: 0.85).combined(with: .opacity))
            }

            if let drag = model.drag, let item = model.displayItem(id: drag.ids[0]) {
                DraggedIcon(model: model, item: item, count: drag.ids.count)
                    .position(x: drag.location.x - drag.grab.width, y: drag.location.y - drag.grab.height)
                    .allowsHitTesting(false)
            }

            if let toast = model.toast {
                Text(toast)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18).padding(.vertical, 10)
                    .glassEffect(.regular, in: Capsule())
                    .position(x: model.size.width / 2, y: model.size.height - (model.compact ? 70 : 110))
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }

            if let dialog = model.dialog {
                DialogView(model: model, dialog: dialog)
                    .transition(.opacity)
            }
        }
        .frame(width: model.size.width, height: model.size.height)
        .environment(\.colorScheme, .dark)
    }
}

// MARK: - Background

struct BackgroundView: View {
    let style: BackgroundStyle
    let image: CGImage?
    let dim: Double
    let compact: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: compact ? 28 : 0, style: .continuous)
        ZStack {
            switch style {
            case .wallpaper where image != nil:
                Image(decorative: image!, scale: 1).resizable().aspectRatio(contentMode: .fill)
                Color.black.opacity(dim)
            case .dark:
                Color(white: 0.06).opacity(0.94)
            default:
                VisualEffectBackground()
                Color.black.opacity(dim * 0.8)
            }
        }
        .clipShape(shape)
        .overlay(compact ? shape.strokeBorder(.white.opacity(0.18), lineWidth: 1) : nil)
    }
}

struct VisualEffectBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .fullScreenUI
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

// MARK: - Grid

struct GridLayer: View {
    @ObservedObject var model: LauncherModel
    let metrics: GridMetrics

    var body: some View {
        let pages = model.displayPages
        let width = model.size.width
        let dragged = Set(model.drag?.ids ?? [])
        let keyboardID = model.keyboardItemID
        let selected = Set(model.selection)
        if model.isVertical {
            let flat = pages.flatMap { $0 }
            ZStack(alignment: .topLeading) {
                ForEach(Array(flat.enumerated()), id: \.element.id) { index, item in
                    tile(item, dragged: dragged, keyboardID: keyboardID, selected: selected)
                        .position(metrics.verticalIconCenter(flat: index, scrollY: 0))
                }
            }
            .frame(width: width, height: model.size.height, alignment: .topLeading)
            .offset(y: -model.scrollY)
            .mask(
                LinearGradient(stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .black, location: (metrics.gridRect.minY - 4) / model.size.height),
                    .init(color: .black, location: (metrics.gridRect.maxY - 10) / model.size.height),
                    .init(color: .clear, location: (metrics.gridRect.maxY + 30) / model.size.height),
                ], startPoint: .top, endPoint: .bottom)
            )
        } else {
            // Two pages each side, so the pages a slide passes through are already there;
            // pages entering/leaving the window appear without a transition (off screen),
            // only the strip as a whole moves.
            let visible = max(0, model.page - 2)...max(0, min(pages.count - 1, model.page + 2))
            ZStack(alignment: .topLeading) {
                ForEach(visible, id: \.self) { p in
                    if p < pages.count {
                        ForEach(Array(pages[p].enumerated()), id: \.element.id) { index, item in
                            let c = metrics.iconCenter(slot: index)
                            tile(item, dragged: dragged, keyboardID: keyboardID, selected: selected)
                                .position(x: c.x + CGFloat(p) * width, y: c.y)
                                .transition(.identity)
                        }
                    }
                }
            }
            .frame(width: width, height: model.size.height, alignment: .topLeading)
            .offset(x: -CGFloat(model.page) * width + model.pageOffset)
        }
    }

    @ViewBuilder
    private func tile(_ item: LayoutItem, dragged: Set<String>, keyboardID: String?, selected: Set<String>) -> some View {
        IconTile(model: model, item: item, metrics: metrics,
                 highlighted: keyboardID == item.id,
                 selected: selected.contains(item.id),
                 mergeTarget: model.mergeTargetID == item.id,
                 showDelete: model.isEditing && model.canUninstall(item))
            .opacity(dragged.contains(item.id) ? 0 : 1)
    }
}

// MARK: - Icon tile

struct IconTile: View {
    @ObservedObject var model: LauncherModel
    let item: LayoutItem
    let metrics: GridMetrics
    var highlighted = false
    var selected = false
    var mergeTarget = false
    var showDelete = false
    var cellWidth: CGFloat? = nil
    var tilt: CGSize = .zero

    var body: some View {
        let s = metrics.iconSize
        let settings = model.settings
        VStack(spacing: 8) {
            ZStack {
                if highlighted || selected {
                    RoundedRectangle(cornerRadius: s * 0.26, style: .continuous)
                        .fill(.white.opacity(selected ? 0.32 : 0.22))
                        .frame(width: s * 1.22, height: s * 1.22)
                }
                if mergeTarget {
                    RoundedRectangle(cornerRadius: s * 0.24, style: .continuous)
                        .fill(.white.opacity(0.3))
                        .frame(width: s * 1.25, height: s * 1.25)
                }
                iconImage(size: s)
                    .scaleEffect(mergeTarget ? 0.82 : 1)
                if showDelete {
                    DeleteBadge()
                        .offset(x: -s * 0.40, y: -s * 0.40)
                        .transition(.scale.combined(with: .opacity))
                }
                if selected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 20, weight: .semibold))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, Color.accentColor)
                        .offset(x: s * 0.42, y: -s * 0.42)
                }
            }
            .frame(width: s, height: s)
            .modifier(Wiggle(active: model.isEditing, seed: item.id.hashValue))

            if settings.showLabels {
                Text(model.name(of: item))
                    .font(.system(size: settings.labelSize, weight: .medium))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.45), radius: 2, y: 1)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(width: max(s, (cellWidth ?? metrics.cellSize.width) - 10))
                    .frame(height: metrics.labelHeight)
            }
        }
        // Keep the icon centre where GridMetrics expects it: shift down by half the label block.
        .offset(y: settings.showLabels ? (8 + metrics.labelHeight) / 2 : 0)
    }

    @ViewBuilder
    private func iconImage(size s: CGFloat) -> some View {
        switch item {
        case .app(let id):
            if let app = model.apps[id] {
                Image(nsImage: IconCache.shared.icon(for: app.url, points: s))
                    .resizable()
                    .interpolation(.high)
                    .frame(width: s, height: s)
                    .overlay {
                        // A moving glint while the icon is carried around.
                        if tilt != .zero {
                            GlassGlint(screen: model.size, tilt: tilt, strength: 0.5)
                                .clipShape(RoundedRectangle(cornerRadius: s * 0.2, style: .continuous))
                                .frame(width: s * 0.82, height: s * 0.82)
                        }
                    }
            } else {
                RoundedRectangle(cornerRadius: s * 0.22).fill(.white.opacity(0.15)).frame(width: s * 0.8, height: s * 0.8)
            }
        case .folder(let f):
            FolderIcon(model: model, folder: f, size: s, tilt: tilt)
        }
    }
}

struct DeleteBadge: View {
    var body: some View {
        Image(systemName: "xmark")
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(.black.opacity(0.75))
            .frame(width: 22, height: 22)
            .background(Circle().fill(Color(white: 0.88)))
            .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
    }
}

struct Wiggle: ViewModifier {
    let active: Bool
    let seed: Int

    func body(content: Content) -> some View {
        if active {
            TimelineView(.animation) { context in
                let t = context.date.timeIntervalSinceReferenceDate
                let r = Double(abs(seed % 997)) / 997
                let phase = r * .pi * 2
                let rate = 2 * .pi * (2.1 + r * 0.5)     // ~2.1–2.6 Hz, each icon its own
                content
                    .rotationEffect(.degrees(sin(t * rate + phase) * 1.1))
                    .offset(y: cos(t * rate * 0.5 + phase) * 0.4)
            }
        } else {
            content
        }
    }
}

struct FolderIcon: View {
    @ObservedObject var model: LauncherModel
    let folder: Folder
    let size: CGFloat
    var tilt: CGSize = .zero

    var body: some View {
        let inner = size * 0.232
        let gap = size * 0.046
        let shown = Array(folder.apps.prefix(9))
        ZStack {
            LiquidGlassTile(model: model, cornerRadius: size * 0.235 * 0.86, tilt: tilt)
                .frame(width: size * 0.86, height: size * 0.86)
            VStack(spacing: gap) {
                ForEach(0..<3, id: \.self) { row in
                    HStack(spacing: gap) {
                        ForEach(0..<3, id: \.self) { col in
                            let i = row * 3 + col
                            if i < shown.count, let app = model.apps[shown[i]] {
                                Image(nsImage: IconCache.shared.icon(for: app.url, points: inner))
                                    .resizable().frame(width: inner, height: inner)
                            } else {
                                Color.clear.frame(width: inner, height: inner)
                            }
                        }
                    }
                }
            }
        }
        .frame(width: size, height: size)
    }
}

struct DraggedIcon: View {
    @ObservedObject var model: LauncherModel
    let item: LayoutItem
    let count: Int
    var tilt: CGSize { model.drag.map { $0.velocity == .zero ? CGSize(width: 0.001, height: 0) : $0.velocity } ?? .zero }

    var body: some View {
        let m = model.metrics
        ZStack(alignment: .topTrailing) {
            IconTile(model: model, item: item, metrics: m, tilt: tilt)
                .scaleEffect(1.1)
                .shadow(color: .black.opacity(0.28), radius: 10, y: 5)
            if count > 1 {
                Text("\(count)")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 7).frame(minWidth: 24, minHeight: 24)
                    .background(Capsule().fill(Color.red))
                    .offset(x: -m.cellSize.width / 2 + m.iconSize + 8, y: -4)
            }
        }
    }
}

// MARK: - Search

struct SearchField: View {
    @ObservedObject var model: LauncherModel
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.7))
            TextField("", text: $model.query, prompt: Text("Search").foregroundStyle(.white.opacity(0.55)))
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .foregroundStyle(.white)
                .focused($focused)
                .onSubmit {
                    if let item = model.keyboardItem() { model.open(item) }
                }
            if !model.query.isEmpty {
                Button { model.query = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.white.opacity(0.6))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .frame(maxHeight: .infinity)
        .glassEffect(.regular, in: Capsule())
        .onAppear { focused = true }
        .onChange(of: model.focusSearchToken) { _, _ in focused = true }
    }
}

// MARK: - Page dots

struct PageDots: View {
    let count: Int
    let current: Int
    let offset: CGFloat
    let width: CGFloat

    var body: some View {
        HStack(spacing: 10) {
            ForEach(0..<count, id: \.self) { i in
                Circle()
                    .fill(.white.opacity(i == current ? 0.95 : 0.35))
                    .frame(width: 8, height: 8)
            }
        }
    }
}

// MARK: - Folder

struct FolderOverlay: View {
    @ObservedObject var model: LauncherModel
    let folder: Folder
    let fm: FolderMetrics
    @State private var title = ""
    @FocusState private var editingTitle: Bool

    var body: some View {
        let panel = fm.panelRect
        let cap = fm.capacity
        let pages = max(1, Int(ceil(Double(folder.apps.count) / Double(cap))))
        let dragged = Set(model.drag?.ids ?? [])
        ZStack(alignment: .topLeading) {
            Color.black.opacity(0.001)   // keeps the overlay full-size

            TextField("", text: $title)
                .textFieldStyle(.plain)
                .multilineTextAlignment(.center)
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
                .focused($editingTitle)
                .onSubmit { commit() }
                .onChange(of: editingTitle) { _, focused in
                    model.folderTitleEditing = focused
                    if !focused { commit() }
                }
                .frame(width: fm.titleFrame.width, height: fm.titleFrame.height)
                .position(x: fm.titleFrame.midX, y: fm.titleFrame.midY)

            RoundedRectangle(cornerRadius: 36, style: .continuous)
                .fill(.clear)
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 36, style: .continuous))
                .frame(width: panel.width, height: panel.height)
                .position(x: panel.midX, y: panel.midY)

            ZStack(alignment: .topLeading) {
                ForEach(Array(folder.apps.enumerated()), id: \.element) { index, id in
                    let c = fm.iconCenter(slot: index)
                    let pageShift = CGFloat(index / cap - model.folderPage) * panel.width
                    IconTile(model: model, item: .app(id), metrics: model.metrics,
                             highlighted: model.keyboardItemID == id,
                             selected: model.selection.contains(id),
                             showDelete: model.isEditing && model.apps[id].map(AppActions.canUninstall) == true,
                             cellWidth: fm.cell.width)
                        .opacity(dragged.contains(id) ? 0 : 1)
                        .position(x: c.x + pageShift, y: c.y)
                }
            }
            .frame(width: model.size.width, height: model.size.height, alignment: .topLeading)
            .mask(
                RoundedRectangle(cornerRadius: 36, style: .continuous)
                    .frame(width: panel.width, height: panel.height)
                    .position(x: panel.midX, y: panel.midY)
            )

            if pages > 1 {
                PageDots(count: pages, current: model.folderPage, offset: 0, width: panel.width)
                    .position(x: panel.midX, y: panel.maxY + 22)
            }
        }
        .frame(width: model.size.width, height: model.size.height)
        .onAppear { title = folder.name }
        .onDisappear { model.folderTitleEditing = false }
        .onChange(of: folder.id) { _, _ in title = folder.name }
    }

    private func commit() {
        if title != folder.name { model.renameFolder(folder.id, to: title) }
        model.focusSearchToken += 1
    }
}

// MARK: - Dialogs

struct DialogView: View {
    @ObservedObject var model: LauncherModel
    let dialog: Dialog
    @State private var text = ""
    @FocusState private var fieldFocused: Bool

    var body: some View {
        ZStack {
            Color.black.opacity(0.35)
                .onTapGesture { close() }
            VStack(spacing: 16) {
                content
            }
            .padding(24)
            .frame(width: 380)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        }
        .frame(width: model.size.width, height: model.size.height)
    }

    @ViewBuilder private var content: some View {
        switch dialog {
        case .rename(let id, let current):
            if let app = model.apps[id] {
                Image(nsImage: IconCache.shared.icon(for: app.url, points: 64)).resizable().frame(width: 64, height: 64)
            }
            Text("Rename App").font(.headline).foregroundStyle(.white)
            TextField("Name", text: $text)
                .textFieldStyle(.roundedBorder)
                .focused($fieldFocused)
                .onSubmit { save(id) }
                .onAppear { text = current; fieldFocused = true }
            HStack {
                if model.settings.renamedApps[id] != nil {
                    Button("Reset") { model.rename(id, to: nil); close() }
                }
                Spacer()
                Button("Cancel") { close() }.keyboardShortcut(.cancelAction)
                Button("Rename") { save(id) }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
            }
        case .uninstall(let ids, let leftovers):
            let names = ids.map { model.name(of: $0) }
            if ids.count == 1, let app = model.apps[ids[0]] {
                Image(nsImage: IconCache.shared.icon(for: app.url, points: 64)).resizable().frame(width: 64, height: 64)
            } else {
                Image(systemName: "trash.circle.fill").font(.system(size: 52)).foregroundStyle(.white.opacity(0.85))
            }
            Text(ids.count == 1 ? "Uninstall “\(names[0])”?" : "Uninstall \(ids.count) apps?")
                .font(.headline).foregroundStyle(.white).multilineTextAlignment(.center)
            Text(leftovers > 0
                 ? "The app\(ids.count == 1 ? "" : "s") and \(leftovers) related file\(leftovers == 1 ? "" : "s") in your Library will be moved to the Trash."
                 : "The app\(ids.count == 1 ? " will" : "s will") be moved to the Trash.")
                .font(.callout).foregroundStyle(.white.opacity(0.75)).multilineTextAlignment(.center)
            HStack {
                Spacer()
                Button("Cancel") { close() }.keyboardShortcut(.cancelAction)
                Button("Uninstall", role: .destructive) { model.confirmUninstall(ids) }
                    .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent).tint(.red)
            }
        case .message(let title, let body):
            Text(title).font(.headline).foregroundStyle(.white)
            Text(body).font(.callout).foregroundStyle(.white.opacity(0.75)).multilineTextAlignment(.center)
            Button("OK") { close() }.keyboardShortcut(.defaultAction)
        }
    }

    private func save(_ id: AppID) {
        model.rename(id, to: text)
        close()
    }

    private func close() {
        withAnimation(model.anim(0.2)) { model.dialog = nil }
        model.focusSearchToken += 1
    }
}


// MARK: - Liquid Glass

/// A folder tile in the style of macOS 26's Liquid Glass folders: a pane that shows the
/// (already blurred) wallpaper right behind it, lifted and brightened, with specular light
/// on the edge facing a light above the screen and a softer one on the opposite edge.
///
/// The "see-through" is drawn from the launcher's own background image, aligned to where
/// the tile is on screen — so it stays correct while the tile is dragged, scaled or
/// wiggling (the system glass material samples badly inside moving layers and turns dark).
struct LiquidGlassTile: View {
    @ObservedObject var model: LauncherModel
    let cornerRadius: CGFloat
    var tilt: CGSize = .zero

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        GeometryReader { geo in
            let frame = geo.frame(in: .global)
            let light = GlassLight(frame: frame, screen: model.size, tilt: tilt)
            ZStack(alignment: .topLeading) {
                backdrop(frame: frame)
                // Lift: glass brightens what is behind it, more toward the light.
                LinearGradient(colors: [.white.opacity(0.36), .white.opacity(0.22)],
                               startPoint: UnitPoint(x: 0.5 + light.direction.dx * 0.5, y: 0.5 + light.direction.dy * 0.5),
                               endPoint: UnitPoint(x: 0.5 - light.direction.dx * 0.5, y: 0.5 - light.direction.dy * 0.5))
                // Specular edges.
                shape.strokeBorder(AngularGradient(stops: light.rimStops, center: .center),
                                   lineWidth: max(1.2, geo.size.width * 0.016))
                shape.inset(by: max(1.5, geo.size.width * 0.02))
                    .stroke(.white.opacity(0.10), lineWidth: 1)
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            .clipShape(shape)
            .shadow(color: .black.opacity(0.18), radius: 4, y: 1.5)
        }
    }

    @ViewBuilder
    private func backdrop(frame: CGRect) -> some View {
        if model.settings.background == .wallpaper, let image = model.backgroundImage {
            Image(decorative: image, scale: 1)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: model.size.width, height: model.size.height)
                .offset(x: -frame.minX, y: -frame.minY)
                .frame(width: frame.width, height: frame.height, alignment: .topLeading)
                .saturation(1.15)
        } else {
            Color.white.opacity(0.10)
        }
    }
}

/// A diagonal glint across an app icon while it is dragged.
struct GlassGlint: View {
    let screen: CGSize
    let tilt: CGSize
    var strength: Double = 0.5

    var body: some View {
        GeometryReader { geo in
            let light = GlassLight(frame: geo.frame(in: .global), screen: screen, tilt: tilt)
            LinearGradient(stops: [
                .init(color: .white.opacity(0), location: 0.25),
                .init(color: .white.opacity(strength * light.intensity), location: 0.48),
                .init(color: .white.opacity(0), location: 0.62),
            ], startPoint: UnitPoint(x: 0.5 + light.direction.dx * 0.9, y: 0.5 + light.direction.dy * 0.9),
               endPoint: UnitPoint(x: 0.5 - light.direction.dx * 0.9, y: 0.5 - light.direction.dy * 0.9))
            .blendMode(.plusLighter)
        }
        .allowsHitTesting(false)
    }
}

/// Where the light comes from for a tile at `frame`: a point above the top centre of the
/// screen, nudged by motion (moving fast to the right tips the glass, so the highlight
/// swings left — it trails the motion like a reflection would).
struct GlassLight {
    let direction: CGVector   // unit vector from the tile centre toward the light
    let intensity: Double     // 0.6…1.2

    init(frame: CGRect, screen: CGSize, tilt: CGSize) {
        let w = max(screen.width, 1), h = max(screen.height, 1)
        let source = CGPoint(x: w * 0.5 - tilt.width * 0.9, y: -h * 0.35 - tilt.height * 0.6)
        var dx = source.x - frame.midX, dy = source.y - frame.midY
        let len = max(1, (dx * dx + dy * dy).squareRoot())
        dx /= len; dy /= len
        direction = CGVector(dx: dx, dy: dy)
        let speed = min(1, (tilt.width * tilt.width + tilt.height * tilt.height).squareRoot() / 2500)
        // Tiles nearer the top catch more light.
        intensity = 0.6 + 0.35 * Double(1 - min(1, max(0, frame.midY / h))) + 0.35 * speed
    }

    /// AngularGradient stops (0 = right edge, clockwise in y-down space), sampled from a
    /// bright lobe facing the light and a faint bounce on the opposite edge.
    var rimStops: [Gradient.Stop] {
        var a = atan2(direction.dy, direction.dx) / (2 * .pi)
        if a < 0 { a += 1 }
        func dist(_ x: Double, _ y: Double) -> Double { let d = abs(x - y).truncatingRemainder(dividingBy: 1); return min(d, 1 - d) }
        return (0...48).map { i in
            let t = Double(i) / 48
            let lobe = 0.9 * intensity * exp(-pow(dist(t, a) / 0.11, 2))
            let bounce = 0.5 * intensity * exp(-pow(dist(t, a + 0.5) / 0.1, 2))
            return Gradient.Stop(color: .white.opacity(min(1, 0.14 + lobe + bounce)), location: t)
        }
    }
}
