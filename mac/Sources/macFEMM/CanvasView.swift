// CanvasView.swift — SwiftUI Canvas for the geometry editor.
//
// Phase B: CoreGraphics-based rendering is plenty for wireframe geometry.
// Metal arrives in Phase D for density/contour/vector plots.

import SwiftUI
import AppKit

struct ScrollZoomCatcher: NSViewRepresentable {
    var onZoom: (CGFloat) -> Void
    var onPan: (CGFloat, CGFloat) -> Void
    func makeNSView(context: Context) -> ScrollCatchView {
        let v = ScrollCatchView()
        v.onZoom = onZoom
        v.onPan = onPan
        v.install()
        return v
    }
    func updateNSView(_ v: ScrollCatchView, context: Context) {
        v.onZoom = onZoom
        v.onPan = onPan
    }
    static func dismantleNSView(_ v: ScrollCatchView, coordinator: ()) { v.uninstall() }
}

final class ScrollCatchView: NSView {
    var onZoom: ((CGFloat) -> Void)?
    var onPan: ((CGFloat, CGFloat) -> Void)?
    private var monitor: Any?

    func install() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self = self, let win = self.window, event.window === win else { return event }
            let locInWin = event.locationInWindow
            let locInView = self.convert(locInWin, from: nil)
            guard self.bounds.contains(locInView) else { return event }
            if event.hasPreciseScrollingDeltas {
                if event.modifierFlags.contains(.command) {
                    let dy = event.scrollingDeltaY
                    if dy != 0 { self.onZoom?(dy) }
                } else {
                    let dx = event.scrollingDeltaX
                    let dy = event.scrollingDeltaY
                    if dx != 0 || dy != 0 { self.onPan?(dx, dy) }
                }
            } else {
                let dy = event.deltaY * 8
                if dy != 0 { self.onZoom?(dy) } else { return event }
            }
            return nil
        }
    }

    func uninstall() {
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
    }

    deinit { uninstall() }
}


enum Tool: String, CaseIterable, Identifiable {
    case select = "Select"
    case addNode = "Add Node"
    case addSegment = "Add Segment"
    case addLabel = "Add Label"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .select: return "cursorarrow"
        case .addNode: return "plus.circle"
        case .addSegment: return "line.diagonal"
        case .addLabel: return "tag"
        }
    }
}

struct Viewport: Equatable {
    var center: CGPoint = .zero      // world coordinates shown at canvas center
    var scale: Double = 20.0         // pixels per world-unit
    var showGrid: Bool = true
    var snapToGrid: Bool = true
}

// Current grid step in world units, matched to the draw logic (~50 px).
func gridStep(for scale: Double) -> Double {
    let target = 50.0
    var step = 1.0
    while step * scale < target { step *= 10 }
    while step * scale > target * 2.5 { step /= 10 }
    return step
}

struct CanvasView: View {
    @ObservedObject var doc: FemmDocument
    @Binding var viewport: Viewport
    @Binding var tool: Tool
    @Binding var pendingSegmentStart: Int32?
    @State private var hoverPoint: CGPoint? = nil
    @State private var panLast: CGSize = .zero
    @State private var pinchLast: CGFloat = 1.0
    @State private var draggingNode: Int? = nil
    @State private var dragStartedAt: CGPoint? = nil

    var body: some View {
        GeometryReader { proxy in
            Canvas { ctx, size in
                draw(ctx: ctx, size: size)
            }
            .background(Color(nsColor: .textBackgroundColor))
            .contentShape(Rectangle())
            .gesture(panGesture(size: proxy.size))
            .gesture(MagnificationGesture()
                .onChanged { v in
                    let delta = v / pinchLast
                    pinchLast = v
                    zoom(by: delta, around: hoverPoint, size: proxy.size)
                }
                .onEnded { _ in pinchLast = 1.0 })
            .background(ScrollZoomCatcher(
                onZoom: { dy in
                    zoom(by: pow(1.0015, dy), around: hoverPoint, size: proxy.size)
                },
                onPan: { dx, dy in
                    viewport.center.x -= dx / viewport.scale
                    viewport.center.y += dy / viewport.scale
                }))
            .onTapGesture { loc in
                handleTap(at: loc, size: proxy.size)
            }
            .onContinuousHover { phase in
                switch phase {
                case .active(let loc): hoverPoint = loc
                case .ended: hoverPoint = nil
                }
            }
            .overlay(alignment: .topTrailing) {
                ZoomControls(viewport: $viewport, doc: doc)
                    .padding(8)
            }
        }
    }

    // MARK: - Coordinate conversion
    private func worldToView(_ p: CGPoint, size: CGSize) -> CGPoint {
        CGPoint(
            x: size.width / 2 + (p.x - viewport.center.x) * viewport.scale,
            y: size.height / 2 - (p.y - viewport.center.y) * viewport.scale
        )
    }
    private func viewToWorld(_ p: CGPoint, size: CGSize) -> CGPoint {
        CGPoint(
            x: viewport.center.x + (p.x - size.width / 2) / viewport.scale,
            y: viewport.center.y - (p.y - size.height / 2) / viewport.scale
        )
    }

    // MARK: - Drawing
    private func draw(ctx: GraphicsContext, size: CGSize) {
        if viewport.showGrid { drawGrid(ctx: ctx, size: size) }
        drawSegments(ctx: ctx, size: size)
        drawArcs(ctx: ctx, size: size)
        drawNodes(ctx: ctx, size: size)
        drawLabels(ctx: ctx, size: size)
        drawPlacementPreview(ctx: ctx, size: size)
    }

    private func drawPlacementPreview(ctx: GraphicsContext, size: CGSize) {
        guard let hp = hoverPoint, tool != .select else { return }
        let world = viewToWorld(hp, size: size)
        let snap = snapped(world)
        let p = worldToView(snap, size: size)
        let color: Color
        switch tool {
        case .addNode:    color = .red
        case .addSegment: color = .green
        case .addLabel:   color = .purple
        case .select:     return
        }
        let r: CGFloat = 4
        let rect = CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r)
        ctx.stroke(Path(ellipseIn: rect), with: .color(color.opacity(0.9)), lineWidth: 1.5)
        var cross = Path()
        cross.move(to: CGPoint(x: p.x - r - 3, y: p.y))
        cross.addLine(to: CGPoint(x: p.x + r + 3, y: p.y))
        cross.move(to: CGPoint(x: p.x, y: p.y - r - 3))
        cross.addLine(to: CGPoint(x: p.x, y: p.y + r + 3))
        ctx.stroke(cross, with: .color(color.opacity(0.5)), lineWidth: 0.8)
        // Coordinate label.
        let label = Text(String(format: "(%g, %g)", snap.x, snap.y))
            .font(.system(size: 10, design: .monospaced))
            .foregroundColor(color)
        ctx.draw(label, at: CGPoint(x: p.x + r + 6, y: p.y - r - 6), anchor: .bottomLeading)
    }

    private func snapped(_ p: CGPoint) -> CGPoint {
        guard viewport.showGrid && viewport.snapToGrid else { return p }
        let major = gridStep(for: viewport.scale)
        let minor = major / 10.0
        // Match draw: snap to minor only when visible; otherwise major.
        let step = (minor * viewport.scale >= 6) ? minor : major
        return CGPoint(x: (p.x / step).rounded() * step,
                       y: (p.y / step).rounded() * step)
    }

    private func drawGrid(ctx: GraphicsContext, size: CGSize) {
        let step = gridStep(for: viewport.scale)
        let topLeft = viewToWorld(.zero, size: size)
        let bottomRight = viewToWorld(CGPoint(x: size.width, y: size.height), size: size)
        let x0 = (topLeft.x / step).rounded(.down) * step
        let x1 = (bottomRight.x / step).rounded(.up) * step
        let y0 = (bottomRight.y / step).rounded(.down) * step
        let y1 = (topLeft.y / step).rounded(.up) * step

        // Minor grid — only if pixel spacing stays legible (>= 6 px).
        let minorStep = step / 10.0
        if minorStep * viewport.scale >= 6 {
            var minor = Path()
            var x = x0
            while x <= x1 {
                let p0 = worldToView(CGPoint(x: x, y: y0), size: size)
                let p1 = worldToView(CGPoint(x: x, y: y1), size: size)
                minor.move(to: p0); minor.addLine(to: p1)
                x += minorStep
            }
            var y = y0
            while y <= y1 {
                let p0 = worldToView(CGPoint(x: x0, y: y), size: size)
                let p1 = worldToView(CGPoint(x: x1, y: y), size: size)
                minor.move(to: p0); minor.addLine(to: p1)
                y += minorStep
            }
            ctx.stroke(minor, with: .color(Color.gray.opacity(0.08)), lineWidth: 0.5)
        }

        var path = Path()
        var x = x0
        while x <= x1 {
            let p0 = worldToView(CGPoint(x: x, y: y0), size: size)
            let p1 = worldToView(CGPoint(x: x, y: y1), size: size)
            path.move(to: p0); path.addLine(to: p1)
            x += step
        }
        var y = y0
        while y <= y1 {
            let p0 = worldToView(CGPoint(x: x0, y: y), size: size)
            let p1 = worldToView(CGPoint(x: x1, y: y), size: size)
            path.move(to: p0); path.addLine(to: p1)
            y += step
        }
        ctx.stroke(path, with: .color(Color.gray.opacity(0.25)), lineWidth: 0.5)

        // Axes.
        let origin = worldToView(.zero, size: size)
        var axes = Path()
        axes.move(to: CGPoint(x: 0, y: origin.y)); axes.addLine(to: CGPoint(x: size.width, y: origin.y))
        axes.move(to: CGPoint(x: origin.x, y: 0)); axes.addLine(to: CGPoint(x: origin.x, y: size.height))
        ctx.stroke(axes, with: .color(Color.gray.opacity(0.4)), lineWidth: 0.5)
    }

    private func drawSegments(ctx: GraphicsContext, size: CGSize) {
        for (i, seg) in doc.snapshot.segments.enumerated() {
            guard seg.n0 >= 0, Int(seg.n0) < doc.snapshot.nodes.count,
                  seg.n1 >= 0, Int(seg.n1) < doc.snapshot.nodes.count else { continue }
            let a = doc.snapshot.nodes[Int(seg.n0)]
            let b = doc.snapshot.nodes[Int(seg.n1)]
            let pa = worldToView(CGPoint(x: a.x, y: a.y), size: size)
            let pb = worldToView(CGPoint(x: b.x, y: b.y), size: size)
            var path = Path(); path.move(to: pa); path.addLine(to: pb)
            let color: Color = doc.selectedSegments.contains(i) ? .orange :
                               (seg.bdryIdx > 0 ? .blue : Color(nsColor: .labelColor))
            ctx.stroke(path, with: .color(color),
                       lineWidth: doc.selectedSegments.contains(i) ? 2.5 : 1.2)
        }
    }

    private func drawArcs(ctx: GraphicsContext, size: CGSize) {
        for a in doc.snapshot.arcs {
            guard a.n0 >= 0, Int(a.n0) < doc.snapshot.nodes.count,
                  a.n1 >= 0, Int(a.n1) < doc.snapshot.nodes.count else { continue }
            let n0 = doc.snapshot.nodes[Int(a.n0)]
            let n1 = doc.snapshot.nodes[Int(a.n1)]
            let dx = n1.x - n0.x, dy = n1.y - n0.y
            let chord = hypot(dx, dy)
            let half = a.arcDeg * .pi / 360.0
            guard sin(half) != 0 else { continue }
            let r = chord / (2 * sin(half))
            let mx = 0.5 * (n0.x + n1.x), my = 0.5 * (n0.y + n1.y)
            let nx = -dy / chord, ny = dx / chord
            let d = r * cos(half)
            let cx = mx + nx * d, cy = my + ny * d
            // Approximate arc with N line segments in world space, then project.
            let steps = max(8, Int(a.arcDeg / 2.0))
            var path = Path()
            let ang0 = atan2(n0.y - cy, n0.x - cx)
            for k in 0...steps {
                let t = Double(k) / Double(steps)
                let ang = ang0 + t * (a.arcDeg * .pi / 180.0)
                let wx = cx + r * cos(ang), wy = cy + r * sin(ang)
                let p = worldToView(CGPoint(x: wx, y: wy), size: size)
                if k == 0 { path.move(to: p) } else { path.addLine(to: p) }
            }
            ctx.stroke(path, with: .color(a.bdryIdx > 0 ? .blue : Color(nsColor: .labelColor)),
                       lineWidth: 1.2)
        }
    }

    private func drawNodes(ctx: GraphicsContext, size: CGSize) {
        for (i, n) in doc.snapshot.nodes.enumerated() {
            let p = worldToView(CGPoint(x: n.x, y: n.y), size: size)
            let selected = doc.selectedNodes.contains(i)
            let r: CGFloat = selected ? 5 : 3
            let rect = CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r)
            ctx.fill(Path(ellipseIn: rect),
                     with: .color(selected ? .orange : .red))
        }
        if let start = pendingSegmentStart, Int(start) < doc.snapshot.nodes.count {
            let n = doc.snapshot.nodes[Int(start)]
            let p = worldToView(CGPoint(x: n.x, y: n.y), size: size)
            let r: CGFloat = 8
            let rect = CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r)
            ctx.stroke(Path(ellipseIn: rect), with: .color(.green), lineWidth: 2)
        }
    }

    private func drawLabels(ctx: GraphicsContext, size: CGSize) {
        for (i, l) in doc.snapshot.labels.enumerated() {
            let p = worldToView(CGPoint(x: l.x, y: l.y), size: size)
            let selected = doc.selectedLabels.contains(i)
            let r: CGFloat = 4
            var crosshair = Path()
            crosshair.move(to: CGPoint(x: p.x - r, y: p.y))
            crosshair.addLine(to: CGPoint(x: p.x + r, y: p.y))
            crosshair.move(to: CGPoint(x: p.x, y: p.y - r))
            crosshair.addLine(to: CGPoint(x: p.x, y: p.y + r))
            ctx.stroke(crosshair, with: .color(selected ? .orange : .purple),
                       lineWidth: selected ? 2.5 : 1.5)
            let rect = CGRect(x: p.x - r - 2, y: p.y - r - 2, width: 2 * r + 4, height: 2 * r + 4)
            ctx.stroke(Path(ellipseIn: rect), with: .color(.purple.opacity(0.5)), lineWidth: 0.8)
        }
    }

    // MARK: - Gestures
    private func panGesture(size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { g in
                // First call in this drag: decide between node-drag and pan.
                if dragStartedAt == nil {
                    dragStartedAt = g.startLocation
                    if tool == .select,
                       let (i, _) = closestNode(to: g.startLocation, size: size, maxDist: 10),
                       doc.selectedNodes.contains(i) {
                        draggingNode = i
                    }
                }
                if let i = draggingNode {
                    let w = viewToWorld(g.location, size: size)
                    let snap = snapped(w)
                    doc.moveNode(idx: i, x: snap.x, y: snap.y)
                } else {
                    let dx = (g.translation.width - panLast.width) / viewport.scale
                    let dy = (g.translation.height - panLast.height) / viewport.scale
                    panLast = g.translation
                    viewport.center.x -= dx
                    viewport.center.y += dy
                }
            }
            .onEnded { _ in
                panLast = .zero
                draggingNode = nil
                dragStartedAt = nil
            }
    }

    private func zoom(by factor: CGFloat, around anchor: CGPoint?, size: CGSize) {
        let f = max(0.2, min(5.0, Double(factor)))
        let anchorView = anchor ?? CGPoint(x: size.width / 2, y: size.height / 2)
        let worldBefore = viewToWorld(anchorView, size: size)
        viewport.scale = max(0.01, min(1e8, viewport.scale * f))
        let worldAfter = viewToWorld(anchorView, size: size)
        viewport.center.x += worldBefore.x - worldAfter.x
        viewport.center.y += worldBefore.y - worldAfter.y
    }

    private func handleTap(at p: CGPoint, size: CGSize) {
        let world = viewToWorld(p, size: size)
        let snap = snapped(world)
        switch tool {
        case .select:
            handleSelectTap(at: p, world: world, size: size)
        case .addNode:
            doc.addNode(x: snap.x, y: snap.y)
        case .addSegment:
            handleAddSegmentTap(at: p, world: snap, size: size)
        case .addLabel:
            doc.addLabel(x: snap.x, y: snap.y)
        }
    }

    private func handleSelectTap(at p: CGPoint, world: CGPoint, size: CGSize) {
        // Prefer the closest node within 10 px; else a segment within 8 px;
        // else a label within 10 px; else clear.
        let hitRadius: CGFloat = 10
        if let (i, _) = closestNode(to: p, size: size, maxDist: hitRadius) {
            toggle(&doc.selectedNodes, i)
            return
        }
        if let (i, _) = closestSegment(to: p, size: size, maxDist: 8) {
            toggle(&doc.selectedSegments, i)
            return
        }
        if let (i, _) = closestLabel(to: p, size: size, maxDist: hitRadius) {
            toggle(&doc.selectedLabels, i)
            return
        }
        doc.selectedNodes.removeAll()
        doc.selectedSegments.removeAll()
        doc.selectedLabels.removeAll()
    }

    private func handleAddSegmentTap(at p: CGPoint, world: CGPoint, size: CGSize) {
        // Snap to existing node within 14 px; else create one.
        let idx: Int32
        if let (i, _) = closestNode(to: p, size: size, maxDist: 14) {
            idx = Int32(i)
        } else {
            idx = doc.addNode(x: world.x, y: world.y)
        }
        if let start = pendingSegmentStart {
            if start != idx { doc.addSegment(n0: start, n1: idx) }
            pendingSegmentStart = nil
        } else {
            pendingSegmentStart = idx
        }
    }

    private func toggle(_ set: inout Set<Int>, _ i: Int) {
        if set.contains(i) { set.remove(i) } else { set.insert(i) }
    }

    private func closestNode(to p: CGPoint, size: CGSize, maxDist: CGFloat) -> (Int, CGFloat)? {
        var best: (Int, CGFloat)?
        for (i, n) in doc.snapshot.nodes.enumerated() {
            let v = worldToView(CGPoint(x: n.x, y: n.y), size: size)
            let d = hypot(v.x - p.x, v.y - p.y)
            if d <= maxDist && (best == nil || d < best!.1) { best = (i, d) }
        }
        return best
    }
    private func closestLabel(to p: CGPoint, size: CGSize, maxDist: CGFloat) -> (Int, CGFloat)? {
        var best: (Int, CGFloat)?
        for (i, n) in doc.snapshot.labels.enumerated() {
            let v = worldToView(CGPoint(x: n.x, y: n.y), size: size)
            let d = hypot(v.x - p.x, v.y - p.y)
            if d <= maxDist && (best == nil || d < best!.1) { best = (i, d) }
        }
        return best
    }
    private func closestSegment(to p: CGPoint, size: CGSize, maxDist: CGFloat) -> (Int, CGFloat)? {
        var best: (Int, CGFloat)?
        for (i, s) in doc.snapshot.segments.enumerated() {
            guard s.n0 >= 0, Int(s.n0) < doc.snapshot.nodes.count,
                  s.n1 >= 0, Int(s.n1) < doc.snapshot.nodes.count else { continue }
            let a = doc.snapshot.nodes[Int(s.n0)]
            let b = doc.snapshot.nodes[Int(s.n1)]
            let pa = worldToView(CGPoint(x: a.x, y: a.y), size: size)
            let pb = worldToView(CGPoint(x: b.x, y: b.y), size: size)
            let d = distancePointToSegment(p, pa, pb)
            if d <= maxDist && (best == nil || d < best!.1) { best = (i, d) }
        }
        return best
    }
}

// Distance from point to segment (2D).
fileprivate func distancePointToSegment(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
    let dx = b.x - a.x, dy = b.y - a.y
    let L2 = dx * dx + dy * dy
    if L2 == 0 { return hypot(p.x - a.x, p.y - a.y) }
    var t = ((p.x - a.x) * dx + (p.y - a.y) * dy) / L2
    t = max(0, min(1, t))
    let fx = a.x + t * dx, fy = a.y + t * dy
    return hypot(p.x - fx, p.y - fy)
}

struct ZoomControls: View {
    @Binding var viewport: Viewport
    @ObservedObject var doc: FemmDocument
    var body: some View {
        VStack(spacing: 4) {
            Button(action: zoomIn) { Image(systemName: "plus.magnifyingglass") }
                .help("Zoom in")
            Button(action: zoomOut) { Image(systemName: "minus.magnifyingglass") }
                .help("Zoom out")
            Button(action: fit) { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                .help("Fit to content")
                .keyboardShortcut("f", modifiers: [.command])
            Button {
                viewport.showGrid.toggle()
            } label: {
                Image(systemName: viewport.showGrid ? "grid" : "grid.circle")
            }
            .help(viewport.showGrid ? "Hide grid" : "Show grid")
            Button {
                viewport.snapToGrid.toggle()
            } label: {
                Image(systemName: viewport.snapToGrid ? "dot.squareshape.split.2x2" : "squareshape.split.2x2")
            }
            .disabled(!viewport.showGrid)
            .help(viewport.snapToGrid ? "Disable snap to grid" : "Enable snap to grid")
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }
    private func zoomIn() { viewport.scale *= 1.1 }
    private func zoomOut() { viewport.scale /= 1.1 }
    private func fit() {
        guard let b = doc.bounds else { return }
        let w = max(b.max.x - b.min.x, 1e-6)
        let h = max(b.max.y - b.min.y, 1e-6)
        let pad = 1.1
        viewport.center = CGPoint(x: (b.min.x + b.max.x) / 2, y: (b.min.y + b.max.y) / 2)
        // Caller resizes later if needed; for now assume a square 800-px view.
        viewport.scale = min(800 / (w * pad), 600 / (h * pad))
    }
}
