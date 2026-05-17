// PostCanvasView.swift — Post-processor canvas: density + contour + vector + mesh.

import SwiftUI

struct PostCanvasView: View {
    @ObservedObject var doc: FemmDocument
    @Binding var viewport: Viewport
    @Binding var settings: PlotSettings
    @Binding var query: PointQuery?
    @Binding var postTool: PostTool
    @ObservedObject var integralAnalysis: ResultIntegralAnalysisModel
    var openLineIntegrals: () -> Void = {}
    var openBlockIntegrals: () -> Void = {}
    @State private var panLast: CGSize = .zero
    @State private var pinchLast: CGFloat = 1.0
    @State private var hoverPoint: CGPoint? = nil
    @State private var renderData = PostRenderData.empty
    @State private var queryCallouts: [ResultQueryCallout] = []
    @State private var queryCalloutDragActive = false
    @State private var extendRegionSelection = false
    @State private var toggleRegionSelection = false

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                if settings.showDensity && metalDensityReady {
                    PostMetalDensityView(result: doc.result,
                                         data: renderData,
                                         viewport: viewport,
                                         settings: settings)
                }
                Canvas { ctx, size in
                    draw(ctx: ctx, size: size, viewport: viewport, data: renderData)
                }
                queryCalloutLayer(size: proxy.size)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .clipped()
            .background(Color(nsColor: .textBackgroundColor))
            .contentShape(Rectangle())
            .gesture(panGesture())
            .gesture(MagnificationGesture()
                .onChanged { v in
                    let delta = v / pinchLast
                    pinchLast = v
                    zoom(by: delta, around: hoverPoint, size: proxy.size)
                }
                .onEnded { _ in
                    pinchLast = 1.0
                })
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
                    handleKey(event)
                },
                onModifierStateChanged: { _, extend, toggle in
                    extendRegionSelection = extend
                    toggleRegionSelection = toggle
                }
            ))
            .onContinuousHover { phase in
                switch phase {
                case .active(let loc): hoverPoint = loc
                case .ended: hoverPoint = nil
                }
            }
            .onTapGesture { loc in
                handleTap(at: loc, size: proxy.size)
            }
            .overlay(alignment: .leading) {
                ResultToolPalette(doc: doc,
                                  viewport: $viewport,
                                  settings: $settings,
                                  query: $query,
                                  postTool: $postTool,
                                  openLineIntegrals: openLineIntegrals,
                                  openBlockIntegrals: openBlockIntegrals)
                    .padding(10)
            }
            .overlay(alignment: .trailing) {
                if !doc.result.isEmpty {
                    ColorBarLegend(vmin: renderData.plotMin, vmax: renderData.plotMax, label: fieldLabel())
                        .padding(.trailing, 10)
                }
            }
            .overlay(alignment: .bottom) {
                ResultIntegralToolbar(doc: doc,
                                      analysis: integralAnalysis,
                                      postTool: postTool,
                                      openResults: { kind in
                                          switch kind {
                                          case .line: openLineIntegrals()
                                          case .block: openBlockIntegrals()
                                          }
                                      })
                    .padding(.horizontal, 84)
                    .padding(.bottom, 12)
            }
            .onAppear { rebuildRenderData() }
            .onChange(of: resultSignature) { _, _ in rebuildRenderData() }
            .onChange(of: labelsSignature) { _, _ in rebuildRenderData() }
            .onChange(of: settings) { _, _ in rebuildRenderData() }
        }
    }

    @ViewBuilder private func queryCalloutLayer(size: CGSize) -> some View {
        ForEach($queryCallouts) { $callout in
            let anchor = worldToView(CGPoint(x: callout.query.x, y: callout.query.y),
                                     size: size,
                                     viewport: viewport)
            let position = queryCalloutPosition(anchor: anchor,
                                                offset: callout.offset,
                                                size: size)
            ResultQueryCalloutView(callout: $callout,
                                   physics: doc.result.physics,
                                   onDragActive: { queryCalloutDragActive = $0 },
                                   onClose: {
                                       queryCallouts.removeAll { $0.id == callout.id }
                                   })
                .position(position)
        }
    }

    private func fieldLabel() -> String {
        switch settings.field {
        case .scalar:    return doc.result.physics.scalarName
        case .vectorMag: return "|\(doc.result.physics.vectorName)|"
        }
    }

    private var resultSignature: String {
        let r = doc.result
        return "\(r.nodeX.count):\(r.elementLabels.count):\(r.scalarMin):\(r.scalarMax):\(r.vectorMagMin):\(r.vectorMagMax):\(r.frequency)"
    }

    private var labelsSignature: String {
        doc.snapshot.labels.map { $0.isExternal ? "1" : "0" }.joined()
    }

    private var metalDensityReady: Bool {
        let r = doc.result
        let m = r.elementLabels.count
        return !r.isEmpty &&
               !renderData.isEmpty &&
               renderData.scalarElementValues.count >= m &&
               renderData.vectorElementMagnitudes.count >= m &&
               renderData.nodeVectorMagnitudes.count >= r.nodeX.count
    }

    private func worldToView(_ p: CGPoint, size: CGSize, viewport vp: Viewport) -> CGPoint {
        CGPoint(
            x: size.width / 2 + (p.x - vp.center.x) * vp.scale,
            y: size.height / 2 - (p.y - vp.center.y) * vp.scale
        )
    }
    private func viewToWorld(_ p: CGPoint, size: CGSize, viewport vp: Viewport) -> CGPoint {
        CGPoint(
            x: vp.center.x + (p.x - size.width / 2) / vp.scale,
            y: vp.center.y - (p.y - size.height / 2) / vp.scale
        )
    }

    private func draw(ctx: GraphicsContext, size: CGSize, viewport vp: Viewport, data: PostRenderData) {
        let r = doc.result
        guard !r.isEmpty else {
            let msg = Text("No solution loaded. Run Analyze.").foregroundStyle(.secondary)
            ctx.draw(msg, at: CGPoint(x: size.width/2, y: size.height/2), anchor: .center)
            return
        }
        let w2v: (CGPoint) -> CGPoint = { p in self.worldToView(p, size: size, viewport: vp) }
        let v2w: (CGPoint) -> CGPoint = { p in self.viewToWorld(p, size: size, viewport: vp) }
        let visible = visibleWorldBounds(size: size, viewport: vp)
        if settings.showContour {
            drawContoursPrepared(ctx: ctx, data: data, visible: visible, w2v: w2v)
        }
        if settings.showMesh {
            drawMeshPrepared(ctx: ctx, result: r, data: data, visible: visible, w2v: w2v)
        }
        if settings.showVector {
            let (vmin2, vmax2) = (r.vectorMagMin, r.vectorMagMax)
            drawVectors(ctx: ctx, doc: doc, result: r, grid: settings.vectorGrid,
                        vmin: vmin2, vmax: vmax2,
                        viewSize: size, w2v: w2v, v2w: v2w)
        }
        if settings.showGeometry {
            drawGeometryOverlay(ctx: ctx, size: size, viewport: vp)
        }
        if postTool == .region {
            drawRegionSelectionOverlay(ctx: ctx, result: r, size: size, viewport: vp, w2v: w2v)
        }
        drawQueryMarkers(ctx: ctx, w2v: w2v)
        drawContour(ctx: ctx, w2v: w2v)
    }

    private func drawQueryMarkers(ctx: GraphicsContext, w2v: (CGPoint) -> CGPoint) {
        for callout in queryCallouts {
            let p = w2v(CGPoint(x: callout.query.x, y: callout.query.y))
            var ring = Path(ellipseIn: CGRect(x: p.x - 5, y: p.y - 5, width: 10, height: 10))
            ctx.stroke(ring, with: .color(.red), lineWidth: callout.isPinned ? 2.0 : 1.5)
            ring = Path()
            ring.move(to: CGPoint(x: p.x - 8, y: p.y))
            ring.addLine(to: CGPoint(x: p.x + 8, y: p.y))
            ring.move(to: CGPoint(x: p.x, y: p.y - 8))
            ring.addLine(to: CGPoint(x: p.x, y: p.y + 8))
            ctx.stroke(ring, with: .color(.red), lineWidth: 1.0)
            if callout.isPinned {
                let pin = Text(Image(systemName: "pin.fill"))
                    .font(.caption2)
                    .foregroundStyle(.red)
                ctx.draw(pin, at: CGPoint(x: p.x + 10, y: p.y - 10), anchor: .center)
            }
        }
    }

    private func drawGeometryOverlay(ctx: GraphicsContext, size: CGSize, viewport vp: Viewport) {
        let nodes = doc.snapshot.nodes
        var outlines = Path()
        for seg in doc.snapshot.segments {
            guard seg.n0 >= 0, Int(seg.n0) < nodes.count,
                  seg.n1 >= 0, Int(seg.n1) < nodes.count else { continue }
            let a = nodes[Int(seg.n0)]
            let b = nodes[Int(seg.n1)]
            outlines.move(to: worldToView(CGPoint(x: a.x, y: a.y), size: size, viewport: vp))
            outlines.addLine(to: worldToView(CGPoint(x: b.x, y: b.y), size: size, viewport: vp))
        }
        for arc in doc.snapshot.arcs {
            guard arc.n0 >= 0, Int(arc.n0) < nodes.count,
                  arc.n1 >= 0, Int(arc.n1) < nodes.count else { continue }
            appendArc(arc, nodes: nodes, to: &outlines, size: size, viewport: vp)
        }
        ctx.stroke(outlines, with: .color(Color(nsColor: .labelColor).opacity(0.8)), lineWidth: 1.1)

        for n in nodes {
            let p = worldToView(CGPoint(x: n.x, y: n.y), size: size, viewport: vp)
            let r: CGFloat = 2.5
            ctx.fill(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r)),
                     with: .color(Color(nsColor: .labelColor).opacity(0.85)))
        }

        for (i, label) in doc.snapshot.labels.enumerated() {
            let p = worldToView(CGPoint(x: label.x, y: label.y), size: size, viewport: vp)
            let r: CGFloat = 4
            var mark = Path()
            mark.move(to: CGPoint(x: p.x - r, y: p.y))
            mark.addLine(to: CGPoint(x: p.x + r, y: p.y))
            mark.move(to: CGPoint(x: p.x, y: p.y - r))
            mark.addLine(to: CGPoint(x: p.x, y: p.y + r))
            let selected = doc.selectedLabels.contains(i)
            ctx.stroke(mark, with: .color(selected ? .orange : .purple.opacity(0.65)),
                       lineWidth: selected ? 2.2 : 1.0)
        }
    }

    private func drawRegionSelectionOverlay(ctx: GraphicsContext,
                                            result r: ResultSnapshot,
                                            size: CGSize,
                                            viewport vp: Viewport,
                                            w2v: (CGPoint) -> CGPoint) {
        let selected = doc.selectedLabels
        if !selected.isEmpty {
            for e in 0..<r.elementLabels.count where selected.contains(Int(r.elementLabels[e])) {
                let a = Int(r.elements[3*e])
                let b = Int(r.elements[3*e + 1])
                let c = Int(r.elements[3*e + 2])
                let pa = w2v(CGPoint(x: r.nodeX[a], y: r.nodeY[a]))
                let pb = w2v(CGPoint(x: r.nodeX[b], y: r.nodeY[b]))
                let pc = w2v(CGPoint(x: r.nodeX[c], y: r.nodeY[c]))
                var path = Path()
                path.move(to: pa)
                path.addLine(to: pb)
                path.addLine(to: pc)
                path.closeSubpath()
                ctx.fill(path, with: .color(.orange.opacity(0.16)))
                ctx.stroke(path, with: .color(.orange.opacity(0.34)), lineWidth: 0.8)
            }
        }

        for (i, label) in doc.snapshot.labels.enumerated() {
            let p = worldToView(CGPoint(x: label.x, y: label.y), size: size, viewport: vp)
            let isSelected = selected.contains(i)
            let r: CGFloat = isSelected ? 6 : 5
            var mark = Path()
            mark.move(to: CGPoint(x: p.x - r, y: p.y))
            mark.addLine(to: CGPoint(x: p.x + r, y: p.y))
            mark.move(to: CGPoint(x: p.x, y: p.y - r))
            mark.addLine(to: CGPoint(x: p.x, y: p.y + r))
            ctx.stroke(mark, with: .color(isSelected ? .orange : .purple.opacity(0.8)),
                       lineWidth: isSelected ? 2.5 : 1.4)
            let halo = CGRect(x: p.x - r - 3, y: p.y - r - 3, width: 2 * r + 6, height: 2 * r + 6)
            ctx.stroke(Path(ellipseIn: halo),
                       with: .color(isSelected ? .orange.opacity(0.8) : .purple.opacity(0.35)),
                       lineWidth: isSelected ? 1.4 : 0.8)
        }
    }

    private func appendArc(_ arc: DocSnapshot.Arc,
                           nodes: [DocSnapshot.Node],
                           to path: inout Path,
                           size: CGSize,
                           viewport vp: Viewport) {
        let n0 = nodes[Int(arc.n0)]
        let n1 = nodes[Int(arc.n1)]
        let dx = n1.x - n0.x
        let dy = n1.y - n0.y
        let chord = hypot(dx, dy)
        guard chord > 0 else { return }
        let half = arc.arcDeg * .pi / 360.0
        guard sin(half) != 0 else { return }
        let r = chord / (2 * sin(half))
        let mx = 0.5 * (n0.x + n1.x)
        let my = 0.5 * (n0.y + n1.y)
        let nx = -dy / chord
        let ny = dx / chord
        let d = r * cos(half)
        let cx = mx + nx * d
        let cy = my + ny * d
        let steps = max(8, Int(arc.arcDeg / 2.0))
        let ang0 = atan2(n0.y - cy, n0.x - cx)
        for k in 0...steps {
            let t = Double(k) / Double(steps)
            let ang = ang0 + t * (arc.arcDeg * .pi / 180.0)
            let p = worldToView(CGPoint(x: cx + r * cos(ang), y: cy + r * sin(ang)),
                                size: size,
                                viewport: vp)
            if k == 0 { path.move(to: p) } else { path.addLine(to: p) }
        }
    }

    private func visibleWorldBounds(size: CGSize, viewport vp: Viewport) -> WorldBounds {
        let a = viewToWorld(.zero, size: size, viewport: vp)
        let b = viewToWorld(CGPoint(x: size.width, y: size.height), size: size, viewport: vp)
        return WorldBounds(minX: min(Double(a.x), Double(b.x)),
                           minY: min(Double(a.y), Double(b.y)),
                           maxX: max(Double(a.x), Double(b.x)),
                           maxY: max(Double(a.y), Double(b.y)))
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
                guard !queryCalloutDragActive else {
                    panLast = .zero
                    return
                }
                let dx = (g.translation.width - panLast.width) / viewport.scale
                let dy = (g.translation.height - panLast.height) / viewport.scale
                panLast = g.translation
                viewport.center.x -= dx
                viewport.center.y += dy
            }
            .onEnded { _ in
                panLast = .zero
            }
    }

    private func zoom(by factor: CGFloat, around anchor: CGPoint?, size: CGSize) {
        let f = max(0.2, min(5.0, Double(factor)))
        let anchorView = anchor ?? CGPoint(x: size.width / 2, y: size.height / 2)
        let worldBefore = viewToWorld(anchorView, size: size, viewport: viewport)
        viewport.scale = max(0.01, min(1e8, viewport.scale * f))
        let worldAfter = viewToWorld(anchorView, size: size, viewport: viewport)
        viewport.center.x += worldBefore.x - worldAfter.x
        viewport.center.y += worldBefore.y - worldAfter.y
    }

    private func handleTap(at p: CGPoint, size: CGSize) {
        let w = viewToWorld(p, size: size, viewport: viewport)
        switch postTool {
        case .contour:
            doc.contourAppend(w)
        case .region:
            handleRegionTap(at: p, size: size)
        case .query:
            if let r = doc.samplePoint(x: Double(w.x), y: Double(w.y)) {
                let next = PointQuery(x: Double(w.x), y: Double(w.y),
                                      scalar: r.scalar, vx: r.vx, vy: r.vy)
                query = next
                queryCallouts.removeAll { !$0.isPinned }
                queryCallouts.append(ResultQueryCallout(query: next))
            } else {
                query = nil
                queryCallouts.removeAll { !$0.isPinned }
            }
        }
    }

    private func handleRegionTap(at p: CGPoint, size: CGSize) {
        guard let idx = closestLabel(to: p, size: size, maxDist: 12) else {
            if !extendRegionSelection && !toggleRegionSelection {
                doc.selectedLabels = []
            }
            return
        }

        if toggleRegionSelection {
            var selection = doc.selectedLabels
            if selection.contains(idx) { selection.remove(idx) }
            else { selection.insert(idx) }
            doc.selectedLabels = selection
        } else if extendRegionSelection {
            var selection = doc.selectedLabels
            selection.insert(idx)
            doc.selectedLabels = selection
        } else {
            doc.selectedLabels = [idx]
        }
    }

    private func closestLabel(to p: CGPoint, size: CGSize, maxDist: CGFloat) -> Int? {
        var best: (idx: Int, dist: CGFloat)?
        for (i, label) in doc.snapshot.labels.enumerated() {
            let v = worldToView(CGPoint(x: label.x, y: label.y), size: size, viewport: viewport)
            let d = hypot(v.x - p.x, v.y - p.y)
            if d <= maxDist && (best == nil || d < best!.dist) {
                best = (i, d)
            }
        }
        return best?.idx
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags == .command, event.keyCode == 6, postTool == .contour {
            doc.contourRemoveLast()
            return true
        }
        if flags.contains(.command) || flags.contains(.control) || flags.contains(.option) {
            return false
        }
        if event.keyCode == 53 {
            switch postTool {
            case .query:
                query = nil
                queryCallouts.removeAll { !$0.isPinned }
                return true
            case .region:
                doc.selectedLabels = []
                return true
            case .contour:
                return false
            }
        }
        return false
    }

    private func queryCalloutPosition(anchor: CGPoint, offset: CGSize, size: CGSize) -> CGPoint {
        let width: CGFloat = 218
        let height: CGFloat = 142
        let x = min(max(anchor.x + offset.width, width / 2 + 8), size.width - width / 2 - 8)
        let y = min(max(anchor.y + offset.height, height / 2 + 8), size.height - height / 2 - 8)
        return CGPoint(x: x, y: y)
    }

    private func rebuildRenderData() {
        renderData = makePostRenderData(result: doc.result,
                                        labels: doc.snapshot.labels,
                                        field: settings.field,
                                        settings: settings)
    }
}

private struct ResultQueryCallout: Identifiable, Equatable {
    let id = UUID()
    var query: PointQuery
    var offset = CGSize(width: 132, height: -82)
    var isPinned = false
}

private struct ResultQueryCalloutView: View {
    @Binding var callout: ResultQueryCallout
    let physics: Physics
    let onDragActive: (Bool) -> Void
    let onClose: () -> Void
    @State private var dragStart: CGSize?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "scope")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                Text("Point Query")
                    .font(.caption.weight(.semibold))
                Spacer()
                Button {
                    callout.isPinned.toggle()
                } label: {
                    Image(systemName: callout.isPinned ? "pin.fill" : "pin")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(callout.isPinned ? Color.accentColor : Color.secondary)
                .help(callout.isPinned ? "Unpin" : "Pin")

                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Close")
            }

            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 4) {
                valueRow("x", value: callout.query.x)
                valueRow("y", value: callout.query.y)
                Divider()
                    .gridCellColumns(2)
                    .padding(.vertical, 1)
                valueRow(physics.scalarName, value: callout.query.scalar)
                valueRow("\(physics.vectorName)x", value: callout.query.vx)
                valueRow("\(physics.vectorName)y", value: callout.query.vy)
                valueRow("|\(physics.vectorName)|", value: callout.query.vmag)
            }
            .font(.caption2)
        }
        .padding(10)
        .frame(width: 218, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color(nsColor: .separatorColor).opacity(0.55), lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.18), radius: 12, x: 0, y: 4)
        .highPriorityGesture(
            DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { value in
                    if dragStart == nil {
                        dragStart = callout.offset
                        onDragActive(true)
                    }
                    let base = dragStart ?? callout.offset
                    callout.offset = CGSize(width: base.width + value.translation.width,
                                            height: base.height + value.translation.height)
                }
                .onEnded { _ in
                    dragStart = nil
                    onDragActive(false)
                }
        )
        .onDisappear {
            onDragActive(false)
        }
    }

    private func valueRow(_ title: String, value: Double) -> some View {
        GridRow {
            Text(title)
                .foregroundStyle(.secondary)
            Text(String(format: "%.6g", value))
                .font(.system(.caption2, design: .monospaced))
        }
    }
}
