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

struct GeometryKeyboardCatcher: NSViewRepresentable {
    var onKey: (NSEvent) -> Bool
    var onModifierStateChanged: (Bool, Bool, Bool) -> Void

    func makeNSView(context: Context) -> GeometryKeyCatchView {
        let v = GeometryKeyCatchView()
        v.onKey = onKey
        v.onModifierStateChanged = onModifierStateChanged
        v.install()
        return v
    }

    func updateNSView(_ v: GeometryKeyCatchView, context: Context) {
        v.onKey = onKey
        v.onModifierStateChanged = onModifierStateChanged
    }

    static func dismantleNSView(_ v: GeometryKeyCatchView, coordinator: ()) {
        v.uninstall()
    }
}

final class GeometryKeyCatchView: NSView {
    var onKey: ((NSEvent) -> Bool)?
    var onModifierStateChanged: ((Bool, Bool, Bool) -> Void)?
    private var monitor: Any?
    private var spaceDown = false
    private var optionDown = false
    private var shiftDown = false
    private var commandDown = false

    func install() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { [weak self] event in
            guard let self, let win = self.window, event.window === win else { return event }
            if event.type == .flagsChanged {
                self.updateModifierFlags(event.modifierFlags)
                return event
            }
            guard !Self.firstResponderIsTextInput(in: win) else {
                self.spaceDown = false
                self.publishModifierState()
                return event
            }
            if event.keyCode == 49 {
                self.spaceDown = event.type == .keyDown
                self.publishModifierState()
                return nil
            }
            guard event.type == .keyDown else { return event }
            return self.onKey?(event) == true ? nil : event
        }
    }

    func uninstall() {
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
    }

    private static func firstResponderIsTextInput(in window: NSWindow) -> Bool {
        guard let responder = window.firstResponder else { return false }
        if responder is NSTextView { return true }
        if responder is NSTextField { return true }
        let name = String(describing: type(of: responder))
        return name.contains("Text") || name.contains("FieldEditor")
    }

    private func updateModifierFlags(_ flags: NSEvent.ModifierFlags) {
        let deviceFlags = flags.intersection(.deviceIndependentFlagsMask)
        optionDown = deviceFlags.contains(.option)
        shiftDown = deviceFlags.contains(.shift)
        commandDown = deviceFlags.contains(.command)
        publishModifierState()
    }

    private func publishModifierState() {
        onModifierStateChanged?(spaceDown || optionDown, shiftDown, commandDown)
    }

    deinit { uninstall() }
}

enum CanvasCursorStyle {
    case arrow
    case openHand
    case closedHand
    case crosshair

    var cursor: NSCursor {
        switch self {
        case .arrow: return .arrow
        case .openHand: return .openHand
        case .closedHand: return .closedHand
        case .crosshair: return .crosshair
        }
    }
}

struct CanvasCursorRegion: NSViewRepresentable {
    var style: CanvasCursorStyle

    func makeNSView(context: Context) -> CanvasCursorNSView {
        let v = CanvasCursorNSView()
        v.style = style
        return v
    }

    func updateNSView(_ v: CanvasCursorNSView, context: Context) {
        v.style = style
    }
}

final class CanvasCursorNSView: NSView {
    var style: CanvasCursorStyle = .arrow {
        didSet {
            window?.invalidateCursorRects(for: self)
            if bounds.contains(convert(window?.mouseLocationOutsideOfEventStream ?? .zero, from: nil)) {
                style.cursor.set()
            }
        }
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: style.cursor)
    }
}


enum Tool: String, CaseIterable, Identifiable {
    case select = "Select"
    case addNode = "Add Node"
    case addSegment = "Add Segment"
    case addArc = "Add Arc"
    case addLabel = "Add Label"
    case polyline = "Polyline"
    case rectangle = "Rectangle"
    case circle = "Circle"
    case groupSelect = "Group Select"
    case move = "Move"
    case copy = "Copy"
    case rotate = "Rotate"
    case mirror = "Mirror"
    case scale = "Scale"

    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .select: return "cursorarrow"
        case .addNode: return "smallcircle.filled.circle"
        case .addSegment: return "line.diagonal"
        case .addArc: return "point.topleft.down.curvedto.point.bottomright.up"
        case .addLabel: return "tag"
        case .polyline: return "point.3.connected.trianglepath.dotted"
        case .rectangle: return "rectangle"
        case .circle: return "circle"
        case .groupSelect: return "square.3.layers.3d"
        case .move: return "arrow.up.and.down.and.arrow.left.and.right"
        case .copy: return "plus.square.on.square"
        case .rotate: return "rotate.right"
        case .mirror: return "arrow.left.and.right.righttriangle.left.righttriangle.right"
        case .scale: return "arrow.up.left.and.arrow.down.right"
        }
    }
}

final class GeometryEditorState: ObservableObject {
    @Published var pendingSegmentStart: Int32?
    @Published var pendingArcStart: Int32?
    @Published var pendingPolylineLast: Int32?
    @Published var pendingRectangleCorner: CGPoint?
    @Published var pendingCircleCenter: CGPoint?
    @Published var pendingMirrorStart: CGPoint?
    @Published var arcAngleDeg: Double = 90
    @Published var arcMaxSideDeg: Double = 1
    @Published var rotateAngleDeg: Double = 15
    @Published var scaleFactor: Double = 1.25
    @Published var navigationDragActive = false
    @Published var extendSelection = false
    @Published var toggleSelection = false

    func cancelTransientTools() {
        pendingSegmentStart = nil
        pendingArcStart = nil
        pendingPolylineLast = nil
        pendingRectangleCorner = nil
        pendingCircleCenter = nil
        pendingMirrorStart = nil
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
    @ObservedObject var editor: GeometryEditorState
    @State private var hoverPoint: CGPoint? = nil
    @State private var panLast: CGSize = .zero
    @State private var pinchLast: CGFloat = 1.0
    @State private var dragStartedAt: CGPoint? = nil
    @State private var dragStartWorld: CGPoint? = nil
    @State private var dragCurrentDelta: CGPoint = .zero
    @State private var dragOperation: GeometryDragOperation? = nil
    @State private var dragPreviewNodes: [Int: CGPoint] = [:]
    @State private var dragPreviewLabels: [Int: CGPoint] = [:]
    @State private var marqueeRect: CGRect? = nil
    @State private var duplicatePreviewDelta: CGPoint? = nil
    @State private var rotatePreviewAngleDeg: Double? = nil
    @State private var rotateStartAngleDeg: Double? = nil
    @State private var rotateCenter: CGPoint? = nil

    private enum GeometryDragOperation: Equatable {
        case move
        case rotate
        case marquee
        case pan
    }

    var body: some View {
        GeometryReader { proxy in
            Canvas { ctx, size in
                draw(ctx: ctx, size: size)
            }
            .background(Color(nsColor: .textBackgroundColor))
            .background(CanvasCursorRegion(style: cursorStyle))
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
            .background(GeometryKeyboardCatcher(
                onKey: { event in
                    handleKey(event, size: proxy.size)
                },
                onModifierStateChanged: { navigation, extend, toggle in
                    editor.navigationDragActive = navigation
                    editor.extendSelection = extend
                    editor.toggleSelection = toggle
                }))
            .onTapGesture { loc in
                handleTap(at: loc, size: proxy.size)
            }
            .onContinuousHover { phase in
                switch phase {
                case .active(let loc):
                    hoverPoint = loc
                    updateDuplicatePreview(at: loc, size: proxy.size)
                case .ended:
                    hoverPoint = nil
                    duplicatePreviewDelta = nil
                }
            }
            .onChange(of: tool) { _, newTool in
                if newTool != .copy {
                    duplicatePreviewDelta = nil
                } else if let hoverPoint {
                    updateDuplicatePreview(at: hoverPoint, size: proxy.size)
                }
                if newTool != .rotate {
                    rotatePreviewAngleDeg = nil
                    rotateStartAngleDeg = nil
                    rotateCenter = nil
                }
            }
            .overlay(alignment: .topLeading) {
                GeometryToolPalette(tool: $tool,
                                    viewport: $viewport,
                                    editor: editor,
                                    hasSelection: doc.hasSelection,
                                    onZoomIn: { zoom(by: 1.15, around: hoverPoint, size: proxy.size) },
                                    onZoomOut: { zoom(by: 1.0 / 1.15, around: hoverPoint, size: proxy.size) },
                                    onFit: { fit(size: proxy.size) },
                                    onDelete: {
                                        doc.deleteSelected()
                                        editor.cancelTransientTools()
                                    })
                    .padding(10)
            }
        }
    }

    private var cursorStyle: CanvasCursorStyle {
        if dragOperation == .move || dragOperation == .rotate { return .closedHand }
        if editor.navigationDragActive || tool == .move || tool == .copy || tool == .rotate { return .openHand }
        switch tool {
        case .select: return .arrow
        default: return .crosshair
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

    private func nodePoint(_ idx: Int) -> CGPoint {
        if let preview = dragPreviewNodes[idx] {
            return preview
        }
        let n = doc.snapshot.nodes[idx]
        return CGPoint(x: n.x, y: n.y)
    }

    private func labelPoint(_ idx: Int) -> CGPoint {
        if let preview = dragPreviewLabels[idx] {
            return preview
        }
        let l = doc.snapshot.labels[idx]
        return CGPoint(x: l.x, y: l.y)
    }

    // MARK: - Drawing
    private func draw(ctx: GraphicsContext, size: CGSize) {
        if viewport.showGrid { drawGrid(ctx: ctx, size: size) }
        drawSegments(ctx: ctx, size: size)
        drawArcs(ctx: ctx, size: size)
        drawNodes(ctx: ctx, size: size)
        drawLabels(ctx: ctx, size: size)
        drawDuplicatePreview(ctx: ctx, size: size)
        drawRotationWheel(ctx: ctx, size: size)
        drawPlacementPreview(ctx: ctx, size: size)
        drawMarquee(ctx: ctx)
    }

    private func drawRotationWheel(ctx: GraphicsContext, size: CGSize) {
        guard tool == .rotate, doc.hasSelection,
              let center = rotateCenter ?? selectedGeometryCenter() else { return }
        let c = worldToView(center, size: size)
        let radius = rotationWheelRadius(size: size, center: center)
        let rect = CGRect(x: c.x - radius, y: c.y - radius,
                          width: radius * 2, height: radius * 2)
        let accent = Color.accentColor
        let neutral = Color(nsColor: .secondaryLabelColor)

        ctx.stroke(Path(ellipseIn: rect),
                   with: .color(accent.opacity(0.28)),
                   style: StrokeStyle(lineWidth: 1.4, dash: [6, 5]))

        for deg in stride(from: 0, through: 315, by: 45) {
            let major = deg % 90 == 0
            let a = Double(deg) * .pi / 180.0
            let outer = CGPoint(x: c.x + cos(a) * radius,
                                y: c.y - sin(a) * radius)
            let innerRadius = radius - (major ? 12 : 7)
            let inner = CGPoint(x: c.x + cos(a) * innerRadius,
                                y: c.y - sin(a) * innerRadius)
            var tick = Path()
            tick.move(to: inner)
            tick.addLine(to: outer)
            ctx.stroke(tick,
                       with: .color((major ? accent : neutral).opacity(major ? 0.65 : 0.35)),
                       lineWidth: major ? 1.5 : 1)
        }

        let angle = rotatePreviewAngleDeg ?? 0
        let snapped = isNearRightAngle(angle)
        let a = angle * .pi / 180.0
        let handle = CGPoint(x: c.x + cos(a) * radius,
                             y: c.y - sin(a) * radius)
        var arm = Path()
        arm.move(to: c)
        arm.addLine(to: handle)
        ctx.stroke(arm,
                   with: .color(accent.opacity(snapped ? 0.95 : 0.72)),
                   lineWidth: snapped ? 2.4 : 1.8)
        ctx.fill(Path(ellipseIn: CGRect(x: handle.x - 5, y: handle.y - 5, width: 10, height: 10)),
                 with: .color(accent.opacity(snapped ? 0.92 : 0.72)))

        let label = Text("\(Int(round(angle)))°")
            .font(.system(size: 11, weight: .medium, design: .monospaced))
            .foregroundColor(accent.opacity(0.9))
        ctx.draw(label, at: CGPoint(x: c.x + radius + 10, y: c.y), anchor: .leading)
    }

    private func drawDuplicatePreview(ctx: GraphicsContext, size: CGSize) {
        guard let delta = duplicateDelta(size: size) else { return }
        let stroke = Color(nsColor: .secondaryLabelColor).opacity(0.72)
        let fill = Color(nsColor: .secondaryLabelColor).opacity(0.48)
        let style = StrokeStyle(lineWidth: 1.4, dash: [5, 4])

        for i in doc.selectedSegments where i >= 0 && i < doc.snapshot.segments.count {
            let seg = doc.snapshot.segments[i]
            guard seg.n0 >= 0, Int(seg.n0) < doc.snapshot.nodes.count,
                  seg.n1 >= 0, Int(seg.n1) < doc.snapshot.nodes.count else { continue }
            var path = Path()
            path.move(to: worldToView(offset(nodeOriginalPoint(Int(seg.n0)), by: delta), size: size))
            path.addLine(to: worldToView(offset(nodeOriginalPoint(Int(seg.n1)), by: delta), size: size))
            ctx.stroke(path, with: .color(stroke), style: style)
        }

        for i in doc.selectedArcs where i >= 0 && i < doc.snapshot.arcs.count {
            let arc = doc.snapshot.arcs[i]
            guard arc.n0 >= 0, Int(arc.n0) < doc.snapshot.nodes.count,
                  arc.n1 >= 0, Int(arc.n1) < doc.snapshot.nodes.count,
                  let path = arcPath(from: offset(nodeOriginalPoint(Int(arc.n0)), by: delta),
                                     to: offset(nodeOriginalPoint(Int(arc.n1)), by: delta),
                                     angleDeg: arc.arcDeg,
                                     size: size) else { continue }
            ctx.stroke(path, with: .color(stroke), style: style)
        }

        for i in selectedNodeIndicesForTransform() where i >= 0 && i < doc.snapshot.nodes.count {
            let p = worldToView(offset(nodeOriginalPoint(i), by: delta), size: size)
            let r: CGFloat = 4
            ctx.stroke(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r)),
                       with: .color(fill), lineWidth: 1.2)
        }

        for i in doc.selectedLabels where i >= 0 && i < doc.snapshot.labels.count {
            let p = worldToView(offset(labelOriginalPoint(i), by: delta), size: size)
            let r: CGFloat = 4
            var crosshair = Path()
            crosshair.move(to: CGPoint(x: p.x - r, y: p.y))
            crosshair.addLine(to: CGPoint(x: p.x + r, y: p.y))
            crosshair.move(to: CGPoint(x: p.x, y: p.y - r))
            crosshair.addLine(to: CGPoint(x: p.x, y: p.y + r))
            ctx.stroke(crosshair, with: .color(stroke), style: style)
        }
    }

    private func drawMarquee(ctx: GraphicsContext) {
        guard let rect = marqueeRect else { return }
        let path = Path(rect)
        ctx.fill(path, with: .color(Color.accentColor.opacity(0.10)))
        ctx.stroke(path, with: .color(Color.accentColor.opacity(0.85)),
                   style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
    }

    private func drawPlacementPreview(ctx: GraphicsContext, size: CGSize) {
        guard let hp = hoverPoint, tool != .select else { return }
        guard tool != .move && tool != .copy && tool != .rotate else { return }
        let world = viewToWorld(hp, size: size)
        let snap = snapped(world)
        let p = worldToView(snap, size: size)
        let color: Color
        switch tool {
        case .addNode: color = .red
        case .addSegment, .polyline: color = .green
        case .addArc: color = .cyan
        case .addLabel: color = .purple
        case .rectangle, .circle: color = .teal
        case .groupSelect: color = .indigo
        case .mirror, .scale: color = .accentColor
        case .move, .copy, .rotate, .select: return
        }

        if let start = editor.pendingSegmentStart, tool == .addSegment,
           Int(start) < doc.snapshot.nodes.count {
            strokePreviewLine(from: nodePoint(Int(start)), to: snap, color: color, ctx: ctx, size: size)
        }
        if let start = editor.pendingPolylineLast, tool == .polyline,
           Int(start) < doc.snapshot.nodes.count {
            strokePreviewLine(from: nodePoint(Int(start)), to: snap, color: color, ctx: ctx, size: size)
        }
        if let start = editor.pendingArcStart, tool == .addArc,
           Int(start) < doc.snapshot.nodes.count {
            strokePreviewArc(from: nodePoint(Int(start)), to: snap,
                             angleDeg: editor.arcAngleDeg,
                             color: color, ctx: ctx, size: size)
        }
        if let corner = editor.pendingRectangleCorner, tool == .rectangle {
            strokePreviewRectangle(from: corner, to: snap, color: color, ctx: ctx, size: size)
        }
        if let center = editor.pendingCircleCenter, tool == .circle {
            strokePreviewCircle(center: center, edge: snap, color: color, ctx: ctx, size: size)
        }
        if let start = editor.pendingMirrorStart, tool == .mirror {
            strokePreviewLine(from: start, to: snap, color: color, ctx: ctx, size: size)
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

    private func strokePreviewLine(from a: CGPoint, to b: CGPoint,
                                   color: Color, ctx: GraphicsContext, size: CGSize) {
        var path = Path()
        path.move(to: worldToView(a, size: size))
        path.addLine(to: worldToView(b, size: size))
        ctx.stroke(path, with: .color(color.opacity(0.75)),
                   style: StrokeStyle(lineWidth: 1.3, dash: [4, 4]))
    }

    private func strokePreviewRectangle(from a: CGPoint, to b: CGPoint,
                                        color: Color, ctx: GraphicsContext, size: CGSize) {
        let corners = [
            CGPoint(x: a.x, y: a.y),
            CGPoint(x: b.x, y: a.y),
            CGPoint(x: b.x, y: b.y),
            CGPoint(x: a.x, y: b.y),
            CGPoint(x: a.x, y: a.y)
        ]
        var path = Path()
        for (i, corner) in corners.enumerated() {
            let p = worldToView(corner, size: size)
            if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
        }
        ctx.stroke(path, with: .color(color.opacity(0.75)),
                   style: StrokeStyle(lineWidth: 1.3, dash: [4, 4]))
    }

    private func strokePreviewCircle(center: CGPoint, edge: CGPoint,
                                     color: Color, ctx: GraphicsContext, size: CGSize) {
        let radius = hypot(edge.x - center.x, edge.y - center.y)
        guard radius > 0 else { return }
        let c = worldToView(center, size: size)
        let r = radius * viewport.scale
        ctx.stroke(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)),
                   with: .color(color.opacity(0.75)),
                   style: StrokeStyle(lineWidth: 1.3, dash: [4, 4]))
    }

    private func strokePreviewArc(from a: CGPoint, to b: CGPoint, angleDeg: Double,
                                  color: Color, ctx: GraphicsContext, size: CGSize) {
        guard let path = arcPath(from: a, to: b, angleDeg: angleDeg, size: size) else { return }
        ctx.stroke(path, with: .color(color.opacity(0.75)),
                   style: StrokeStyle(lineWidth: 1.3, dash: [4, 4]))
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
            let a = nodePoint(Int(seg.n0))
            let b = nodePoint(Int(seg.n1))
            let pa = worldToView(a, size: size)
            let pb = worldToView(b, size: size)
            var path = Path(); path.move(to: pa); path.addLine(to: pb)
            let color: Color = doc.selectedSegments.contains(i) ? .orange :
                               (seg.bdryIdx > 0 ? .blue : Color(nsColor: .labelColor))
            ctx.stroke(path, with: .color(color),
                       lineWidth: doc.selectedSegments.contains(i) ? 2.5 : 1.2)
        }
    }

    private func drawArcs(ctx: GraphicsContext, size: CGSize) {
        for (i, a) in doc.snapshot.arcs.enumerated() {
            guard a.n0 >= 0, Int(a.n0) < doc.snapshot.nodes.count,
                  a.n1 >= 0, Int(a.n1) < doc.snapshot.nodes.count else { continue }
            guard let path = arcPath(from: nodePoint(Int(a.n0)),
                                     to: nodePoint(Int(a.n1)),
                                     angleDeg: a.arcDeg,
                                     size: size) else { continue }
            let selected = doc.selectedArcs.contains(i)
            let color: Color = selected ? .orange :
                               (a.bdryIdx > 0 ? .blue : Color(nsColor: .labelColor))
            ctx.stroke(path, with: .color(color),
                       lineWidth: selected ? 2.5 : 1.2)
        }
    }

    private func drawNodes(ctx: GraphicsContext, size: CGSize) {
        for (i, n) in doc.snapshot.nodes.enumerated() {
            let world = dragPreviewNodes[i] ?? CGPoint(x: n.x, y: n.y)
            let p = worldToView(world, size: size)
            let selected = doc.selectedNodes.contains(i)
            let r: CGFloat = selected ? 5 : 3
            let rect = CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r)
            ctx.fill(Path(ellipseIn: rect),
                     with: .color(selected ? .orange : .red))
        }
        if let start = editor.pendingSegmentStart, Int(start) < doc.snapshot.nodes.count {
            let p = worldToView(nodePoint(Int(start)), size: size)
            let r: CGFloat = 8
            let rect = CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r)
            ctx.stroke(Path(ellipseIn: rect), with: .color(.green), lineWidth: 2)
        }
    }

    private func drawLabels(ctx: GraphicsContext, size: CGSize) {
        for (i, _) in doc.snapshot.labels.enumerated() {
            let p = worldToView(labelPoint(i), size: size)
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
                // First call in this drag: decide between selection, transform, and pan.
        if dragStartedAt == nil {
            dragStartedAt = g.startLocation
            dragStartWorld = snapped(viewToWorld(g.startLocation, size: size))
            if editor.navigationDragActive {
                dragOperation = .pan
            } else if tool == .rotate, doc.hasSelection,
                      let center = selectedGeometryCenter() {
                dragOperation = .rotate
                rotateCenter = center
                rotateStartAngleDeg = angleFrom(center: center, toViewPoint: g.startLocation, size: size)
                rotatePreviewAngleDeg = 0
            } else if tool == .move, doc.hasSelection {
                dragOperation = .move
            } else if tool == .select && hitSelectedGeometry(at: g.startLocation, size: size) {
                        dragOperation = .move
                    } else if tool == .select {
                        dragOperation = .marquee
                        marqueeRect = normalizedRect(from: g.startLocation, to: g.location)
                    } else {
                        dragOperation = .pan
                    }
                }
        if dragOperation == .pan {
            let dx = (g.translation.width - panLast.width) / viewport.scale
            let dy = (g.translation.height - panLast.height) / viewport.scale
            panLast = g.translation
            viewport.center.x -= dx
            viewport.center.y += dy
        } else if dragOperation == .rotate,
                  let center = rotateCenter,
                  let start = rotateStartAngleDeg {
            let current = angleFrom(center: center, toViewPoint: g.location, size: size)
            let angle = softSnappedRightAngle(current - start)
            rotatePreviewAngleDeg = angle
            updateRotatePreview(angleDeg: angle, center: center)
        } else if dragOperation == .marquee {
            marqueeRect = normalizedRect(from: g.startLocation, to: g.location)
        } else if dragOperation != nil, let start = dragStartWorld {
                    let end = snapped(viewToWorld(g.location, size: size))
                    let delta = CGPoint(x: end.x - start.x, y: end.y - start.y)
                    dragCurrentDelta = delta
                    updateDragPreview(delta: delta)
                }
            }
            .onEnded { _ in
                if let operation = dragOperation, dragStartWorld != nil {
                    switch operation {
                    case .move:
                        let delta = dragCurrentDelta
                        if delta != .zero {
                            doc.moveSelectedGeometry(by: delta)
                        }
                    case .rotate:
                        if let center = rotateCenter, let angle = rotatePreviewAngleDeg,
                           abs(angle) > 0.0001 {
                            doc.rotateSelectedGeometry(around: center, angleDeg: angle)
                        }
                    case .marquee:
                        if let rect = marqueeRect {
                            selectGeometry(in: rect, size: size)
                        }
                    case .pan:
                        break
                    }
                }
                panLast = .zero
                dragStartedAt = nil
                dragStartWorld = nil
                dragCurrentDelta = .zero
                dragOperation = nil
                dragPreviewNodes.removeAll()
                dragPreviewLabels.removeAll()
                marqueeRect = nil
                rotatePreviewAngleDeg = nil
                rotateStartAngleDeg = nil
                rotateCenter = nil
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
        case .addArc:
            handleAddArcTap(at: p, world: snap, size: size)
        case .addLabel:
            doc.addLabel(x: snap.x, y: snap.y)
        case .polyline:
            handlePolylineTap(at: p, world: snap, size: size)
        case .rectangle:
            handleRectangleTap(at: snap)
        case .circle:
            handleCircleTap(at: snap)
        case .groupSelect:
            handleGroupSelectTap(at: p, size: size)
        case .move:
            break
        case .copy:
            if let delta = duplicateDelta(size: size) {
                doc.copySelectedGeometry(by: delta)
                duplicatePreviewDelta = delta
            }
        case .rotate:
            break
        case .mirror:
            handleMirrorTap(at: snap)
        case .scale:
            doc.scaleSelectedGeometry(around: snap, factor: editor.scaleFactor)
        }
    }

    private func handleSelectTap(at p: CGPoint, world: CGPoint, size: CGSize) {
        // Prefer the closest node within 10 px; else a segment within 8 px;
        // else a label within 10 px; else clear.
        let hitRadius: CGFloat = 10
        if let (i, _) = closestNode(to: p, size: size, maxDist: hitRadius) {
            applySingleSelection(kind: .node, index: i)
            return
        }
        if let (i, _) = closestSegment(to: p, size: size, maxDist: 8) {
            applySingleSelection(kind: .segment, index: i)
            return
        }
        if let (i, _) = closestArc(to: p, size: size, maxDist: 8) {
            applySingleSelection(kind: .arc, index: i)
            return
        }
        if let (i, _) = closestLabel(to: p, size: size, maxDist: hitRadius) {
            applySingleSelection(kind: .label, index: i)
            return
        }
        if !editor.extendSelection && !editor.toggleSelection {
            doc.clearSelection()
        }
    }

    private func handleAddSegmentTap(at p: CGPoint, world: CGPoint, size: CGSize) {
        // Snap to existing node within 14 px; else create one.
        doc.performUndoGroup {
            let idx = nodeIndexForPlacement(at: p, world: world, size: size)
            if let start = editor.pendingSegmentStart {
                if start != idx { doc.addSegment(n0: start, n1: idx) }
                editor.pendingSegmentStart = nil
            } else {
                editor.pendingSegmentStart = idx
            }
        }
    }

    private func handleAddArcTap(at p: CGPoint, world: CGPoint, size: CGSize) {
        doc.performUndoGroup {
            let idx = nodeIndexForPlacement(at: p, world: world, size: size)
            if let start = editor.pendingArcStart {
                if start != idx {
                    doc.addArc(n0: start, n1: idx,
                               arcDeg: editor.arcAngleDeg,
                               maxSideDeg: editor.arcMaxSideDeg)
                }
                editor.pendingArcStart = nil
            } else {
                editor.pendingArcStart = idx
            }
        }
    }

    private func handlePolylineTap(at p: CGPoint, world: CGPoint, size: CGSize) {
        doc.performUndoGroup {
            let idx = nodeIndexForPlacement(at: p, world: world, size: size)
            if let last = editor.pendingPolylineLast, last != idx {
                doc.addSegment(n0: last, n1: idx)
            }
            editor.pendingPolylineLast = idx
        }
    }

    private func handleRectangleTap(at p: CGPoint) {
        if let a = editor.pendingRectangleCorner {
            guard abs(a.x - p.x) > 0 || abs(a.y - p.y) > 0 else { return }
            doc.performUndoGroup {
                let n0 = doc.addNode(x: a.x, y: a.y)
                let n1 = doc.addNode(x: p.x, y: a.y)
                let n2 = doc.addNode(x: p.x, y: p.y)
                let n3 = doc.addNode(x: a.x, y: p.y)
                doc.addSegment(n0: n0, n1: n1)
                doc.addSegment(n0: n1, n1: n2)
                doc.addSegment(n0: n2, n1: n3)
                doc.addSegment(n0: n3, n1: n0)
                editor.pendingRectangleCorner = nil
            }
        } else {
            editor.pendingRectangleCorner = p
        }
    }

    private func handleCircleTap(at p: CGPoint) {
        if let c = editor.pendingCircleCenter {
            let r = hypot(p.x - c.x, p.y - c.y)
            guard r > 0 else { return }
            doc.performUndoGroup {
                let n0 = doc.addNode(x: c.x + r, y: c.y)
                let n1 = doc.addNode(x: c.x, y: c.y + r)
                let n2 = doc.addNode(x: c.x - r, y: c.y)
                let n3 = doc.addNode(x: c.x, y: c.y - r)
                doc.addArc(n0: n0, n1: n1, arcDeg: 90, maxSideDeg: editor.arcMaxSideDeg)
                doc.addArc(n0: n1, n1: n2, arcDeg: 90, maxSideDeg: editor.arcMaxSideDeg)
                doc.addArc(n0: n2, n1: n3, arcDeg: 90, maxSideDeg: editor.arcMaxSideDeg)
                doc.addArc(n0: n3, n1: n0, arcDeg: 90, maxSideDeg: editor.arcMaxSideDeg)
                editor.pendingCircleCenter = nil
            }
        } else {
            editor.pendingCircleCenter = p
        }
    }

    private func handleGroupSelectTap(at p: CGPoint, size: CGSize) {
        if let group = nearestGroup(at: p, size: size) {
            doc.selectGroup(group)
        } else {
            doc.clearSelection()
        }
    }

    private func handleMirrorTap(at p: CGPoint) {
        if let start = editor.pendingMirrorStart {
            doc.mirrorSelectedGeometry(from: start, to: p)
            editor.pendingMirrorStart = nil
        } else {
            editor.pendingMirrorStart = p
        }
    }

    private func nodeIndexForPlacement(at p: CGPoint, world: CGPoint, size: CGSize) -> Int32 {
        if let (i, _) = closestNode(to: p, size: size, maxDist: 14) {
            return Int32(i)
        }
        return doc.addNode(x: world.x, y: world.y)
    }

    private func handleKey(_ event: NSEvent, size: CGSize) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags == .command,
           event.charactersIgnoringModifiers?.lowercased() == "z" {
            doc.undo()
            editor.cancelTransientTools()
            tool = .select
            return true
        }
        if flags.contains(.command) || flags.contains(.control) || flags.contains(.option) {
            return false
        }

        let fast = flags.contains(.shift) ? 3.0 : 1.0
        let panX = max(size.width, 1) * 0.10 * fast / viewport.scale
        let panY = max(size.height, 1) * 0.10 * fast / viewport.scale

        switch event.keyCode {
        case 51, 117: // delete / forward delete
            doc.deleteSelected()
            editor.cancelTransientTools()
            return true
        case 53: // escape
            doc.clearSelection()
            editor.cancelTransientTools()
            tool = .select
            return true
        case 123: viewport.center.x -= panX; return true // left
        case 124: viewport.center.x += panX; return true // right
        case 125: viewport.center.y -= panY; return true // down
        case 126: viewport.center.y += panY; return true // up
        case 115: fit(size: size); return true // home
        default:
            break
        }

        guard let key = event.charactersIgnoringModifiers?.lowercased() else { return false }
        switch key {
        case "w": viewport.center.y += panY
        case "a": viewport.center.x -= panX
        case "s": viewport.center.y -= panY
        case "d": viewport.center.x += panX
        case "+", "=": zoom(by: 1.15, around: hoverPoint, size: size)
        case "-", "_": zoom(by: 1.0 / 1.15, around: hoverPoint, size: size)
        case "0": fit(size: size)
        case "1": setTool(.select)
        case "2": setTool(.addNode)
        case "3": setTool(.addSegment)
        case "4": setTool(.addArc)
        case "5": setTool(.addLabel)
        case "v": setTool(.select)
        case "n": setTool(.addNode)
        case "l": setTool(.addLabel)
        case "p": setTool(.polyline)
        case "r":
            if let center = selectedGeometryCenter() {
                doc.rotateSelectedGeometry(around: center, angleDeg: 90)
            }
        case "e": setTool(.rectangle)
        case "o": setTool(.circle)
        case "m": setTool(.move)
        case "c": setTool(.copy)
        case "t": setTool(.rotate)
        case "b": setTool(.mirror)
        case "z": setTool(.scale)
        case "g": viewport.showGrid.toggle()
        case "x":
            if viewport.showGrid { viewport.snapToGrid.toggle() }
        default:
            return false
        }
        return true
    }

    private func setTool(_ next: Tool) {
        tool = next
        editor.cancelTransientTools()
    }

    private func fit(size: CGSize) {
        guard let b = doc.bounds else { return }
        let w = max(b.max.x - b.min.x, 1e-6)
        let h = max(b.max.y - b.min.y, 1e-6)
        let pad = 1.15
        viewport.center = CGPoint(x: (b.min.x + b.max.x) / 2,
                                  y: (b.min.y + b.max.y) / 2)
        viewport.scale = min(max(size.width, 1) / (w * pad),
                             max(size.height, 1) / (h * pad))
    }

    private enum SelectionKind {
        case node, segment, arc, label
    }

    private func applySingleSelection(kind: SelectionKind, index: Int) {
        if editor.toggleSelection {
            toggleSelection(kind: kind, index: index)
            return
        }
        if !editor.extendSelection {
            doc.clearSelection()
        }
        addSelection(kind: kind, index: index)
    }

    private func addSelection(kind: SelectionKind, index: Int) {
        switch kind {
        case .node: doc.selectedNodes.insert(index)
        case .segment: doc.selectedSegments.insert(index)
        case .arc: doc.selectedArcs.insert(index)
        case .label: doc.selectedLabels.insert(index)
        }
    }

    private func toggleSelection(kind: SelectionKind, index: Int) {
        switch kind {
        case .node:
            if doc.selectedNodes.contains(index) { doc.selectedNodes.remove(index) }
            else { doc.selectedNodes.insert(index) }
        case .segment:
            if doc.selectedSegments.contains(index) { doc.selectedSegments.remove(index) }
            else { doc.selectedSegments.insert(index) }
        case .arc:
            if doc.selectedArcs.contains(index) { doc.selectedArcs.remove(index) }
            else { doc.selectedArcs.insert(index) }
        case .label:
            if doc.selectedLabels.contains(index) { doc.selectedLabels.remove(index) }
            else { doc.selectedLabels.insert(index) }
        }
    }

    private func selectGeometry(in rect: CGRect, size: CGSize) {
        var nodes = Set<Int>()
        var segments = Set<Int>()
        var arcs = Set<Int>()
        var labels = Set<Int>()

        for (i, n) in doc.snapshot.nodes.enumerated() {
            if rect.contains(worldToView(CGPoint(x: n.x, y: n.y), size: size)) {
                nodes.insert(i)
            }
        }
        for (i, l) in doc.snapshot.labels.enumerated() {
            if rect.contains(worldToView(CGPoint(x: l.x, y: l.y), size: size)) {
                labels.insert(i)
            }
        }
        for (i, s) in doc.snapshot.segments.enumerated() {
            guard s.n0 >= 0, Int(s.n0) < doc.snapshot.nodes.count,
                  s.n1 >= 0, Int(s.n1) < doc.snapshot.nodes.count else { continue }
            let a = nodeOriginalPoint(Int(s.n0))
            let b = nodeOriginalPoint(Int(s.n1))
            if segmentIntersects(rect: rect,
                                 a: worldToView(a, size: size),
                                 b: worldToView(b, size: size)) {
                segments.insert(i)
            }
        }
        for (i, arc) in doc.snapshot.arcs.enumerated() {
            let points = arcPolyline(arc, size: size)
            guard points.count >= 2 else { continue }
            for k in 1..<points.count where segmentIntersects(rect: rect, a: points[k - 1], b: points[k]) {
                arcs.insert(i)
                break
            }
        }

        if editor.toggleSelection {
            toggleSet(&doc.selectedNodes, with: nodes)
            toggleSet(&doc.selectedSegments, with: segments)
            toggleSet(&doc.selectedArcs, with: arcs)
            toggleSet(&doc.selectedLabels, with: labels)
        } else if editor.extendSelection {
            doc.selectedNodes.formUnion(nodes)
            doc.selectedSegments.formUnion(segments)
            doc.selectedArcs.formUnion(arcs)
            doc.selectedLabels.formUnion(labels)
        } else {
            doc.selectedNodes = nodes
            doc.selectedSegments = segments
            doc.selectedArcs = arcs
            doc.selectedLabels = labels
        }
    }

    private func toggleSet(_ target: inout Set<Int>, with values: Set<Int>) {
        for value in values {
            if target.contains(value) { target.remove(value) }
            else { target.insert(value) }
        }
    }

    private func normalizedRect(from a: CGPoint, to b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x),
               y: min(a.y, b.y),
               width: abs(a.x - b.x),
               height: abs(a.y - b.y))
    }

    private func segmentIntersects(rect: CGRect, a: CGPoint, b: CGPoint) -> Bool {
        if rect.contains(a) || rect.contains(b) { return true }
        let corners = [
            CGPoint(x: rect.minX, y: rect.minY),
            CGPoint(x: rect.maxX, y: rect.minY),
            CGPoint(x: rect.maxX, y: rect.maxY),
            CGPoint(x: rect.minX, y: rect.maxY)
        ]
        for i in 0..<4 {
            if segmentsIntersect(a, b, corners[i], corners[(i + 1) % 4]) {
                return true
            }
        }
        return false
    }

    private func segmentsIntersect(_ a: CGPoint, _ b: CGPoint,
                                   _ c: CGPoint, _ d: CGPoint) -> Bool {
        func orient(_ p: CGPoint, _ q: CGPoint, _ r: CGPoint) -> CGFloat {
            (q.x - p.x) * (r.y - p.y) - (q.y - p.y) * (r.x - p.x)
        }
        let o1 = orient(a, b, c)
        let o2 = orient(a, b, d)
        let o3 = orient(c, d, a)
        let o4 = orient(c, d, b)
        return (o1 == 0 || o2 == 0 || (o1 > 0) != (o2 > 0)) &&
               (o3 == 0 || o4 == 0 || (o3 > 0) != (o4 > 0))
    }

    private func hitSelectedGeometry(at p: CGPoint, size: CGSize) -> Bool {
        if let (i, _) = closestNode(to: p, size: size, maxDist: 10),
           selectedNodeIndicesForTransform().contains(i) { return true }
        if let (i, _) = closestSegment(to: p, size: size, maxDist: 8),
           doc.selectedSegments.contains(i) { return true }
        if let (i, _) = closestArc(to: p, size: size, maxDist: 8),
           doc.selectedArcs.contains(i) { return true }
        if let (i, _) = closestLabel(to: p, size: size, maxDist: 10),
           doc.selectedLabels.contains(i) { return true }
        return false
    }

    private func updateDuplicatePreview(at p: CGPoint, size: CGSize) {
        guard tool == .copy, doc.hasSelection, dragOperation == nil,
              let center = selectedGeometryCenter() else {
            duplicatePreviewDelta = nil
            return
        }
        let cursor = snapped(viewToWorld(p, size: size))
        duplicatePreviewDelta = CGPoint(x: cursor.x - center.x, y: cursor.y - center.y)
    }

    private func duplicateDelta(size: CGSize) -> CGPoint? {
        guard tool == .copy, doc.hasSelection else { return nil }
        if let duplicatePreviewDelta { return duplicatePreviewDelta }
        let pxOffset = max(22.0 / max(viewport.scale, 1e-9), gridStep(for: viewport.scale) / 2)
        let fallback = CGPoint(x: pxOffset, y: -pxOffset)
        return snappedDelta(fallback)
    }

    private func selectedGeometryCenter() -> CGPoint? {
        var points: [CGPoint] = []
        for i in selectedNodeIndicesForTransform() where i >= 0 && i < doc.snapshot.nodes.count {
            points.append(nodeOriginalPoint(i))
        }
        for i in doc.selectedLabels where i >= 0 && i < doc.snapshot.labels.count {
            points.append(labelOriginalPoint(i))
        }
        guard !points.isEmpty else { return nil }
        let sum = points.reduce(CGPoint.zero) { acc, p in
            CGPoint(x: acc.x + p.x, y: acc.y + p.y)
        }
        return CGPoint(x: sum.x / Double(points.count),
                       y: sum.y / Double(points.count))
    }

    private func rotationWheelRadius(size: CGSize, center: CGPoint) -> CGFloat {
        let viewCenter = worldToView(center, size: size)
        var maxDistance: CGFloat = 34
        for i in selectedNodeIndicesForTransform() where i >= 0 && i < doc.snapshot.nodes.count {
            let p = worldToView(nodeOriginalPoint(i), size: size)
            maxDistance = max(maxDistance, hypot(p.x - viewCenter.x, p.y - viewCenter.y))
        }
        for i in doc.selectedLabels where i >= 0 && i < doc.snapshot.labels.count {
            let p = worldToView(labelOriginalPoint(i), size: size)
            maxDistance = max(maxDistance, hypot(p.x - viewCenter.x, p.y - viewCenter.y))
        }
        return min(max(maxDistance + 28, 48), 180)
    }

    private func angleFrom(center: CGPoint, toViewPoint p: CGPoint, size: CGSize) -> Double {
        let c = worldToView(center, size: size)
        return atan2(c.y - p.y, p.x - c.x) * 180.0 / .pi
    }

    private func softSnappedRightAngle(_ angle: Double) -> Double {
        let normalized = normalizeAngle(angle)
        let nearest = (normalized / 90.0).rounded() * 90.0
        let diff = normalizeAngle(normalized - nearest)
        return abs(diff) <= 8 ? nearest : normalized
    }

    private func isNearRightAngle(_ angle: Double) -> Bool {
        abs(normalizeAngle(angle - (angle / 90.0).rounded() * 90.0)) <= 8
    }

    private func normalizeAngle(_ angle: Double) -> Double {
        var a = angle.truncatingRemainder(dividingBy: 360)
        if a > 180 { a -= 360 }
        if a <= -180 { a += 360 }
        return a
    }

    private func updateRotatePreview(angleDeg: Double, center: CGPoint) {
        var nodePreview: [Int: CGPoint] = [:]
        for i in selectedNodeIndicesForTransform() where i >= 0 && i < doc.snapshot.nodes.count {
            nodePreview[i] = rotated(nodeOriginalPoint(i), around: center, angleDeg: angleDeg)
        }
        var labelPreview: [Int: CGPoint] = [:]
        for i in doc.selectedLabels where i >= 0 && i < doc.snapshot.labels.count {
            labelPreview[i] = rotated(labelOriginalPoint(i), around: center, angleDeg: angleDeg)
        }
        dragPreviewNodes = nodePreview
        dragPreviewLabels = labelPreview
    }

    private func rotated(_ p: CGPoint, around center: CGPoint, angleDeg: Double) -> CGPoint {
        let a = angleDeg * .pi / 180.0
        let c = cos(a)
        let s = sin(a)
        let dx = p.x - center.x
        let dy = p.y - center.y
        return CGPoint(x: center.x + dx * c - dy * s,
                       y: center.y + dx * s + dy * c)
    }

    private func snappedDelta(_ delta: CGPoint) -> CGPoint {
        guard viewport.showGrid && viewport.snapToGrid else { return delta }
        let origin = snapped(.zero)
        let end = snapped(delta)
        return CGPoint(x: end.x - origin.x, y: end.y - origin.y)
    }

    private func offset(_ p: CGPoint, by delta: CGPoint) -> CGPoint {
        CGPoint(x: p.x + delta.x, y: p.y + delta.y)
    }

    private func updateDragPreview(delta: CGPoint) {
        var nodePreview: [Int: CGPoint] = [:]
        for i in selectedNodeIndicesForTransform() where i >= 0 && i < doc.snapshot.nodes.count {
            let p = nodeOriginalPoint(i)
            nodePreview[i] = CGPoint(x: p.x + delta.x, y: p.y + delta.y)
        }
        var labelPreview: [Int: CGPoint] = [:]
        for i in doc.selectedLabels where i >= 0 && i < doc.snapshot.labels.count {
            let p = labelOriginalPoint(i)
            labelPreview[i] = CGPoint(x: p.x + delta.x, y: p.y + delta.y)
        }
        dragPreviewNodes = nodePreview
        dragPreviewLabels = labelPreview
    }

    private func selectedNodeIndicesForTransform() -> Set<Int> {
        var out = doc.selectedNodes
        for i in doc.selectedSegments where i >= 0 && i < doc.snapshot.segments.count {
            out.insert(Int(doc.snapshot.segments[i].n0))
            out.insert(Int(doc.snapshot.segments[i].n1))
        }
        for i in doc.selectedArcs where i >= 0 && i < doc.snapshot.arcs.count {
            out.insert(Int(doc.snapshot.arcs[i].n0))
            out.insert(Int(doc.snapshot.arcs[i].n1))
        }
        return out
    }

    private func nodeOriginalPoint(_ idx: Int) -> CGPoint {
        let n = doc.snapshot.nodes[idx]
        return CGPoint(x: n.x, y: n.y)
    }

    private func labelOriginalPoint(_ idx: Int) -> CGPoint {
        let l = doc.snapshot.labels[idx]
        return CGPoint(x: l.x, y: l.y)
    }

    private func nearestGroup(at p: CGPoint, size: CGSize) -> Int32? {
        let hitRadius: CGFloat = 10
        if let (i, _) = closestNode(to: p, size: size, maxDist: hitRadius) {
            return doc.snapshot.nodes[i].group
        }
        if let (i, _) = closestSegment(to: p, size: size, maxDist: 8) {
            return doc.snapshot.segments[i].group
        }
        if let (i, _) = closestArc(to: p, size: size, maxDist: 8) {
            return doc.snapshot.arcs[i].group
        }
        if let (i, _) = closestLabel(to: p, size: size, maxDist: hitRadius) {
            return doc.snapshot.labels[i].group
        }
        return nil
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
    private func closestArc(to p: CGPoint, size: CGSize, maxDist: CGFloat) -> (Int, CGFloat)? {
        var best: (Int, CGFloat)?
        for (i, a) in doc.snapshot.arcs.enumerated() {
            let points = arcPolyline(a, size: size)
            guard points.count >= 2 else { continue }
            var localBest = CGFloat.greatestFiniteMagnitude
            for k in 1..<points.count {
                localBest = min(localBest, distancePointToSegment(p, points[k - 1], points[k]))
            }
            if localBest <= maxDist && (best == nil || localBest < best!.1) {
                best = (i, localBest)
            }
        }
        return best
    }

    private func arcPath(from start: CGPoint, to end: CGPoint,
                         angleDeg: Double, size: CGSize) -> Path? {
        let x0 = Double(start.x), y0 = Double(start.y)
        let x1 = Double(end.x), y1 = Double(end.y)
        let dx = x1 - x0, dy = y1 - y0
        let chord = hypot(dx, dy)
        guard chord > 0 else { return nil }
        let half = angleDeg * .pi / 360.0
        guard sin(half) != 0 else { return nil }
        let r = chord / (2 * sin(half))
        let mx = 0.5 * (x0 + x1), my = 0.5 * (y0 + y1)
        let nx = -dy / chord, ny = dx / chord
        let d = r * cos(half)
        let cx = mx + nx * d, cy = my + ny * d
        let steps = max(8, Int(abs(angleDeg) / 2.0))
        let ang0 = atan2(y0 - cy, x0 - cx)
        var path = Path()
        for k in 0...steps {
            let t = Double(k) / Double(steps)
            let ang = ang0 + t * (angleDeg * .pi / 180.0)
            let p = worldToView(CGPoint(x: cx + r * cos(ang),
                                        y: cy + r * sin(ang)),
                                size: size)
            if k == 0 { path.move(to: p) } else { path.addLine(to: p) }
        }
        return path
    }

    private func arcPolyline(_ a: DocSnapshot.Arc, size: CGSize) -> [CGPoint] {
        guard a.n0 >= 0, Int(a.n0) < doc.snapshot.nodes.count,
              a.n1 >= 0, Int(a.n1) < doc.snapshot.nodes.count else { return [] }
        let n0 = nodePoint(Int(a.n0))
        let n1 = nodePoint(Int(a.n1))
        let x0 = Double(n0.x), y0 = Double(n0.y)
        let x1 = Double(n1.x), y1 = Double(n1.y)
        let dx = x1 - x0, dy = y1 - y0
        let chord = hypot(dx, dy)
        guard chord > 0 else { return [] }
        let half = a.arcDeg * .pi / 360.0
        guard sin(half) != 0 else { return [] }
        let r = chord / (2 * sin(half))
        let mx = 0.5 * (x0 + x1), my = 0.5 * (y0 + y1)
        let nx = -dy / chord, ny = dx / chord
        let d = r * cos(half)
        let cx = mx + nx * d, cy = my + ny * d
        let steps = max(8, Int(abs(a.arcDeg) / 2.0))
        let ang0 = atan2(y0 - cy, x0 - cx)
        return (0...steps).map { k in
            let t = Double(k) / Double(steps)
            let ang = ang0 + t * (a.arcDeg * .pi / 180.0)
            let wx = cx + r * cos(ang)
            let wy = cy + r * sin(ang)
            return worldToView(CGPoint(x: wx, y: wy), size: size)
        }
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

struct GeometryToolPalette: View {
    @Binding var tool: Tool
    @Binding var viewport: Viewport
    @ObservedObject var editor: GeometryEditorState
    var hasSelection: Bool
    var onZoomIn: () -> Void
    var onZoomOut: () -> Void
    var onFit: () -> Void
    var onDelete: () -> Void
    @State private var optionsShown = false

    private let drawItems: [Tool] = [.select, .addNode, .addSegment, .addArc, .addLabel]
    private let shapeItems: [Tool] = [.polyline, .rectangle, .circle, .groupSelect]
    private let editItems: [Tool] = [.move, .copy, .rotate, .mirror, .scale]

    var body: some View {
        VStack(spacing: 6) {
            paletteSection(drawItems)
            paletteDivider
            paletteSection(shapeItems)
            paletteDivider
            paletteSection(editItems)
            paletteDivider
            actionButton(symbol: "plus.magnifyingglass", title: "Zoom In", action: onZoomIn)
            actionButton(symbol: "minus.magnifyingglass", title: "Zoom Out", action: onZoomOut)
            actionButton(symbol: "arrow.up.left.and.arrow.down.right", title: "Fit", action: onFit)
            actionButton(symbol: viewport.showGrid ? "grid" : "grid.circle",
                         title: viewport.showGrid ? "Hide Grid" : "Show Grid") {
                viewport.showGrid.toggle()
            }
            actionButton(symbol: viewport.snapToGrid ? "dot.squareshape.split.2x2" : "squareshape.split.2x2",
                         title: viewport.snapToGrid ? "Disable Snap" : "Enable Snap",
                         disabled: !viewport.showGrid) {
                viewport.snapToGrid.toggle()
            }
            actionButton(symbol: "trash", title: "Delete Selected",
                         disabled: !hasSelection, role: .destructive,
                         action: onDelete)
            paletteDivider
            optionsButton
        }
        .padding(6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color(nsColor: .separatorColor).opacity(0.45), lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.12), radius: 10, x: 0, y: 3)
    }

    private func paletteSection(_ items: [Tool]) -> some View {
        VStack(spacing: 4) {
            ForEach(items) { item in
                toolButton(item)
            }
        }
    }

    private var paletteDivider: some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor).opacity(0.55))
            .frame(width: 22, height: 1)
            .padding(.vertical, 1)
    }

    private func toolButton(_ item: Tool) -> some View {
        let active = item == tool
        let disabled = editItems.contains(item) && !hasSelection
        return Button {
            tool = item
            editor.cancelTransientTools()
        } label: {
            Image(systemName: item.symbol)
                .font(.system(size: 14, weight: active ? .semibold : .regular))
                .symbolRenderingMode(.hierarchical)
                .frame(width: 28, height: 28)
                .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .foregroundStyle(active ? Color.accentColor : Color.primary.opacity(disabled ? 0.32 : 0.82))
        .background {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(active ? Color.accentColor.opacity(0.16) : Color.clear)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(active ? Color.accentColor.opacity(0.55) : Color.clear, lineWidth: 1)
        }
        .disabled(disabled)
        .help(item.rawValue)
    }

    private func actionButton(symbol: String,
                              title: String,
                              disabled: Bool = false,
                              role: ButtonRole? = nil,
                              action: @escaping () -> Void) -> some View {
        Button(role: role, action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14))
                .symbolRenderingMode(.hierarchical)
                .frame(width: 28, height: 28)
                .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .foregroundStyle(role == .destructive ? Color.red.opacity(disabled ? 0.32 : 0.9)
                                              : Color.primary.opacity(disabled ? 0.32 : 0.82))
        .disabled(disabled)
        .help(title)
    }

    private var optionsButton: some View {
        Button {
            optionsShown.toggle()
        } label: {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 14))
                .symbolRenderingMode(.hierarchical)
                .frame(width: 28, height: 28)
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.primary.opacity(0.82))
        .help("Tool Options")
        .popover(isPresented: $optionsShown, arrowEdge: .leading) {
            toolOptions
                .padding(14)
                .frame(width: 220)
        }
    }

    @ViewBuilder
    private var toolOptions: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch tool {
            case .addArc, .circle:
                Label("Arc", systemImage: Tool.addArc.symbol).font(.headline)
                LabeledContent("Angle") {
                    TextField("", value: $editor.arcAngleDeg, format: .number)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 72)
                }
                LabeledContent("Max Side") {
                    TextField("", value: $editor.arcMaxSideDeg, format: .number)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 72)
                }
            case .scale:
                Label("Scale", systemImage: tool.symbol).font(.headline)
                LabeledContent("Factor") {
                    TextField("", value: $editor.scaleFactor, format: .number)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 72)
                }
            default:
                Label(tool.rawValue, systemImage: tool.symbol).font(.headline)
            }
        }
    }
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
