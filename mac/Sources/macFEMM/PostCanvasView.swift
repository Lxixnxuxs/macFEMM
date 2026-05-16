// PostCanvasView.swift — Post-processor canvas: density + contour + vector + mesh.

import SwiftUI

struct PostCanvasView: View {
    @ObservedObject var doc: FemmDocument
    @Binding var viewport: Viewport
    @Binding var settings: PlotSettings
    @Binding var query: PointQuery?
    @Binding var postTool: PostTool
    @State private var panLast: CGSize = .zero
    @State private var pinchLast: CGFloat = 1.0
    @State private var hoverPoint: CGPoint? = nil

    var body: some View {
        GeometryReader { proxy in
            Canvas { ctx, size in
                draw(ctx: ctx, size: size)
            }
            .background(Color(nsColor: .textBackgroundColor))
            .contentShape(Rectangle())
            .gesture(panGesture())
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
            .onContinuousHover { phase in
                switch phase {
                case .active(let loc): hoverPoint = loc
                case .ended: hoverPoint = nil
                }
            }
            .onTapGesture { loc in
                handleTap(at: loc, size: proxy.size)
            }
            .overlay(alignment: .topTrailing) {
                ZoomControls(viewport: $viewport, doc: doc).padding(8)
            }
            .overlay(alignment: .topLeading) {
                if !doc.result.isEmpty {
                    let (vmin, vmax) = plotRange(doc.result, field: settings.field, settings: settings, doc: doc)
                    ColorBarLegend(vmin: vmin, vmax: vmax, label: fieldLabel())
                        .padding(8)
                }
            }
        }
    }

    private func fieldLabel() -> String {
        switch settings.field {
        case .scalar:    return doc.result.physics.scalarName
        case .vectorMag: return "|\(doc.result.physics.vectorName)|"
        }
    }

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

    private func draw(ctx: GraphicsContext, size: CGSize) {
        let r = doc.result
        guard !r.isEmpty else {
            let msg = Text("No solution loaded. Run Analyze.").foregroundStyle(.secondary)
            ctx.draw(msg, at: CGPoint(x: size.width/2, y: size.height/2), anchor: .center)
            return
        }
        let w2v: (CGPoint) -> CGPoint = { p in self.worldToView(p, size: size) }
        let v2w: (CGPoint) -> CGPoint = { p in self.viewToWorld(p, size: size) }
        let (vmin, vmax) = plotRange(r, field: settings.field, settings: settings, doc: doc)
        if settings.showDensity {
            drawDensity(ctx: ctx, result: r, field: settings.field,
                        vmin: vmin, vmax: vmax,
                        smooth: settings.smoothShading, w2v: w2v)
        }
        if settings.showContour {
            let (smin, smax) = (r.scalarMin, r.scalarMax)
            drawContours(ctx: ctx, result: r, levels: settings.contourLevels,
                         vmin: smin, vmax: smax, w2v: w2v)
        }
        if settings.showMesh {
            drawMesh(ctx: ctx, result: r, w2v: w2v)
        }
        if settings.showVector {
            let (vmin2, vmax2) = (r.vectorMagMin, r.vectorMagMax)
            drawVectors(ctx: ctx, doc: doc, result: r, grid: settings.vectorGrid,
                        vmin: vmin2, vmax: vmax2,
                        viewSize: size, w2v: w2v, v2w: v2w)
        }
        // Point query marker
        if let q = query {
            let p = w2v(CGPoint(x: q.x, y: q.y))
            var ring = Path(ellipseIn: CGRect(x: p.x - 5, y: p.y - 5, width: 10, height: 10))
            ctx.stroke(ring, with: .color(.red), lineWidth: 1.5)
            ring = Path()
            ring.move(to: CGPoint(x: p.x - 8, y: p.y))
            ring.addLine(to: CGPoint(x: p.x + 8, y: p.y))
            ring.move(to: CGPoint(x: p.x, y: p.y - 8))
            ring.addLine(to: CGPoint(x: p.x, y: p.y + 8))
            ctx.stroke(ring, with: .color(.red), lineWidth: 1.0)
        }
        drawContour(ctx: ctx, w2v: w2v)
    }

    private func drawContour(ctx: GraphicsContext, w2v: (CGPoint) -> CGPoint) {
        let pts = doc.contour
        guard !pts.isEmpty else { return }
        if pts.count >= 2 {
            var path = Path()
            path.move(to: w2v(pts[0]))
            for p in pts.dropFirst() { path.addLine(to: w2v(p)) }
            ctx.stroke(path, with: .color(.red), lineWidth: 1.5)
        }
        for (i, p) in pts.enumerated() {
            let v = w2v(p)
            let dot = Path(ellipseIn: CGRect(x: v.x - 3, y: v.y - 3, width: 6, height: 6))
            ctx.fill(dot, with: .color(.red))
            let num = Text("\(i + 1)").font(.caption2).foregroundStyle(.red)
            ctx.draw(num, at: CGPoint(x: v.x + 8, y: v.y - 8))
        }
    }

    private func panGesture() -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { g in
                let dx = (g.translation.width - panLast.width) / viewport.scale
                let dy = (g.translation.height - panLast.height) / viewport.scale
                panLast = g.translation
                viewport.center.x -= dx
                viewport.center.y += dy
            }
            .onEnded { _ in panLast = .zero }
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
        let w = viewToWorld(p, size: size)
        switch postTool {
        case .contour:
            doc.contourAppend(w)
        case .query:
            if let r = doc.samplePoint(x: Double(w.x), y: Double(w.y)) {
                query = PointQuery(x: Double(w.x), y: Double(w.y),
                                   scalar: r.scalar, vx: r.vx, vy: r.vy)
            } else {
                query = nil
            }
        }
    }
}
