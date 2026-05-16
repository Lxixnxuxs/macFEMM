// PostProcessor.swift — Phase D: post-processor rendering + inspector.
//
// Provides plot settings, a colormap LUT, density/contour/vector/mesh
// rendering helpers, and the inspector panel (point query + plot controls).

import SwiftUI

enum ViewMode: String, CaseIterable, Identifiable {
    case preprocessor = "Geometry"
    case postprocessor = "Result"
    var id: String { rawValue }
}

enum PlotField: String, CaseIterable, Identifiable {
    case scalar   = "Scalar"    // A / V / T / V
    case vectorMag = "Vector |⋅|" // |B| / |E| / |F| / |E|
    var id: String { rawValue }
}

enum PostTool: String, CaseIterable, Identifiable {
    case query   = "Query"
    case contour = "Contour"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .query:   return "hand.tap"
        case .contour: return "scribble.variable"
        }
    }
}

struct PlotSettings: Equatable {
    var field: PlotField = .vectorMag
    var showDensity: Bool = true
    var showContour: Bool = true
    var contourLevels: Int = 19
    var showVector: Bool = false
    var vectorGrid: Int = 24
    var showMesh: Bool = false
    var smoothShading: Bool = true
    var autoRange: Bool = true
    var showGeometry: Bool = false
    var manualMin: Double = 0
    var manualMax: Double = 1
}

struct PointQuery: Equatable {
    var x: Double
    var y: Double
    var scalar: Double
    var vx: Double
    var vy: Double
    var vmag: Double { (vx*vx + vy*vy).squareRoot() }
}

struct WorldBounds {
    var minX: Double
    var minY: Double
    var maxX: Double
    var maxY: Double

    func intersects(_ other: WorldBounds) -> Bool {
        maxX >= other.minX && minX <= other.maxX &&
        maxY >= other.minY && minY <= other.maxY
    }
}

struct DensityBandPolygon {
    var points: [CGPoint]
    var bounds: WorldBounds
    var bin: Int
}

struct ContourSegment {
    var a: CGPoint
    var b: CGPoint
    var bounds: WorldBounds
}

struct PostRenderData {
    var isEmpty = true
    var field: PlotField = .vectorMag
    var smooth: Bool = true
    var contourLevels: Int = 19
    var plotMin: Double = 0
    var plotMax: Double = 1
    var elementBounds: [WorldBounds] = []
    var scalarElementValues: [Double] = []
    var vectorElementMagnitudes: [Double] = []
    var nodeVectorMagnitudes: [Double] = []
    var smoothDensityPolygons: [DensityBandPolygon] = []
    var contourSegments: [ContourSegment] = []

    static let empty = PostRenderData()
}

func makePostRenderData(result r: ResultSnapshot,
                        labels: [DocSnapshot.Label],
                        field: PlotField,
                        settings: PlotSettings,
                        includeSmoothDensityPolygons: Bool = false) -> PostRenderData {
    guard !r.isEmpty else { return .empty }
    let m = r.elementLabels.count
    var data = PostRenderData(isEmpty: false,
                              field: field,
                              smooth: settings.smoothShading,
                              contourLevels: settings.contourLevels)
    data.elementBounds.reserveCapacity(m)
    data.scalarElementValues.reserveCapacity(m)
    data.vectorElementMagnitudes.reserveCapacity(m)

    for e in 0..<m {
        let a = Int(r.elements[3*e])
        let b = Int(r.elements[3*e + 1])
        let c = Int(r.elements[3*e + 2])
        let xs = [r.nodeX[a], r.nodeX[b], r.nodeX[c]]
        let ys = [r.nodeY[a], r.nodeY[b], r.nodeY[c]]
        data.elementBounds.append(WorldBounds(minX: xs.min() ?? 0,
                                              minY: ys.min() ?? 0,
                                              maxX: xs.max() ?? 0,
                                              maxY: ys.max() ?? 0))
        data.scalarElementValues.append((r.nodeScalar[a] + r.nodeScalar[b] + r.nodeScalar[c]) / 3.0)
        let vx = r.elementVx[e], vy = r.elementVy[e]
        data.vectorElementMagnitudes.append((vx*vx + vy*vy).squareRoot())
    }

    let range = cachedPlotRange(result: r, field: field, settings: settings,
                                labels: labels, scalarValues: data.scalarElementValues,
                                vectorMagnitudes: data.vectorElementMagnitudes)
    data.plotMin = range.0
    data.plotMax = range.1
    data.nodeVectorMagnitudes = nodeMagnitudesFromElements(r)

    if settings.smoothShading && includeSmoothDensityPolygons {
        let nodeVals = (field == .scalar) ? r.nodeScalar : data.nodeVectorMagnitudes
        data.smoothDensityPolygons = makeSmoothDensityPolygons(result: r, nodeVals: nodeVals,
                                                               vmin: data.plotMin, vmax: data.plotMax)
    }
    data.contourSegments = makeContourSegments(result: r, levels: settings.contourLevels,
                                               vmin: r.scalarMin, vmax: r.scalarMax)
    return data
}

func cachedPlotRange(result r: ResultSnapshot,
                     field: PlotField,
                     settings: PlotSettings,
                     labels: [DocSnapshot.Label],
                     scalarValues: [Double],
                     vectorMagnitudes: [Double]) -> (Double, Double) {
    if !settings.autoRange { return (settings.manualMin, settings.manualMax) }
    var extLabel = [Bool](repeating: false, count: labels.count)
    for (i, l) in labels.enumerated() { extLabel[i] = l.isExternal }
    let values = (field == .scalar) ? scalarValues : vectorMagnitudes
    var vmin = Double.infinity
    var vmax = -Double.infinity
    var kept = 0
    for e in 0..<r.elementLabels.count {
        let li = Int(r.elementLabels[e])
        if li >= 0 && li < extLabel.count && extLabel[li] { continue }
        let v = values[e]
        if v < vmin { vmin = v }
        if v > vmax { vmax = v }
        kept += 1
    }
    if kept > 0 && vmax > vmin { return (vmin, vmax) }
    switch field {
    case .scalar:    return (r.scalarMin, r.scalarMax)
    case .vectorMag: return (r.vectorMagMin, r.vectorMagMax)
    }
}

// MARK: - BELA colormap (FEMM Windows parity)
//
// Hard-coded 20-level magenta→cyan palette from femm/StdAfx.h. Windows indexes
// via `lav = 19 - (int)b` after normalising to [0, 20]. We expose the same
// discrete lookup so density plots match Windows exactly.

let belaPalette: [(Double, Double, Double)] = [
    (  0/255.0, 255/255.0, 255/255.0),  // low  → cyan
    ( 37/255.0, 255/255.0, 195/255.0),
    ( 69/255.0, 255/255.0, 147/255.0),
    ( 98/255.0, 255/255.0, 108/255.0),
    (123/255.0, 255/255.0,  76/255.0),
    (148/255.0, 255/255.0,  51/255.0),
    (171/255.0, 255/255.0,  31/255.0),
    (194/255.0, 255/255.0,  16/255.0),
    (217/255.0, 255/255.0,   6/255.0),
    (242/255.0, 255/255.0,   1/255.0),
    (255/255.0, 242/255.0,   1/255.0),
    (255/255.0, 217/255.0,   6/255.0),
    (255/255.0, 194/255.0,  16/255.0),
    (255/255.0, 171/255.0,  31/255.0),
    (255/255.0, 148/255.0,  51/255.0),
    (255/255.0, 123/255.0,  76/255.0),
    (255/255.0,  98/255.0, 108/255.0),
    (255/255.0,  69/255.0, 147/255.0),
    (255/255.0,  37/255.0, 195/255.0),
    (255/255.0,   0/255.0, 255/255.0),  // high → magenta
]

func viridis(_ t: Double) -> Color {
    // Name kept for call-site compatibility; now returns the BELA discrete bin.
    let u = max(0.0, min(1.0, t))
    var bin = Int(u * 20.0)
    if bin > 19 { bin = 19 }
    return belaColor(bin)
}

func belaColor(_ bin: Int) -> Color {
    let c = belaPalette[max(0, min(19, bin))]
    return Color(red: c.0, green: c.1, blue: c.2)
}

// MARK: - Color-bar legend

struct ColorBarLegend: View {
    let vmin: Double
    let vmax: Double
    let label: String
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption).bold().foregroundStyle(.secondary)
            HStack(alignment: .top, spacing: 6) {
                LinearGradient(
                    colors: (0..<20).map {
                        let c = belaPalette[$0]
                        return Color(red: c.0, green: c.1, blue: c.2)
                    },
                    startPoint: .bottom, endPoint: .top
                )
                .frame(width: 18, height: 140)
                .clipShape(RoundedRectangle(cornerRadius: 3))
                .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color.secondary.opacity(0.4)))

                VStack(alignment: .leading) {
                    Text(String(format: "%.3g", vmax)).font(.caption2)
                    Spacer(minLength: 0)
                    Text(String(format: "%.3g", 0.5 * (vmin + vmax))).font(.caption2)
                    Spacer(minLength: 0)
                    Text(String(format: "%.3g", vmin)).font(.caption2)
                }
                .frame(height: 140)
            }
        }
        .padding(6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
    }
}

// MARK: - Post-processor inspector panel

struct PostProcessorPanel: View {
    @ObservedObject var doc: FemmDocument
    @Binding var settings: PlotSettings
    @Binding var query: PointQuery?
    @Binding var postTool: PostTool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Label("Post-processor", systemImage: "waveform.path.ecg").font(.headline)

                if doc.result.isEmpty {
                    Text("No solution loaded. Run Analyze.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    stats
                    Divider()
                    plotControls
                    Divider()
                    toolPicker
                    if postTool == .contour {
                        contourControls
                    } else {
                        pointQuery
                    }
                }
                Spacer()
            }
            .padding(12)
        }
    }

    private var toolPicker: some View {
        Picker("Tool", selection: $postTool) {
            ForEach(PostTool.allCases) { t in
                Label(t.rawValue, systemImage: t.symbol).tag(t)
            }
        }
        .pickerStyle(.segmented)
    }

    private var contourControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Contour", systemImage: "scribble.variable").font(.subheadline).bold()
            Text("Click in canvas to add points.")
                .font(.caption).foregroundStyle(.secondary)
            LabeledContent("Points", value: "\(doc.contour.count)")
            HStack {
                Button("Undo Last") { doc.contourRemoveLast() }
                    .disabled(doc.contour.isEmpty)
                Button("Clear", role: .destructive) { doc.contourClear() }
                    .disabled(doc.contour.isEmpty)
            }
            BendArcControls(doc: doc)
            Divider()
            IntegralPanel(doc: doc)
            Divider()
            XYPlotPanel(doc: doc)
        }.font(.caption)
    }

    private var stats: some View {
        VStack(alignment: .leading, spacing: 4) {
            LabeledContent("Physics", value: doc.result.physics.displayName)
            LabeledContent("Nodes",    value: "\(doc.result.nodeX.count)")
            LabeledContent("Elements", value: "\(doc.result.elementLabels.count)")
            if doc.result.frequency > 0 {
                LabeledContent("Frequency", value: String(format: "%.6g Hz", doc.result.frequency))
            }
            LabeledContent("\(doc.result.physics.scalarName) range",
                           value: String(format: "%.3g … %.3g", doc.result.scalarMin, doc.result.scalarMax))
            LabeledContent("|\(doc.result.physics.vectorName)| range",
                           value: String(format: "%.3g … %.3g", doc.result.vectorMagMin, doc.result.vectorMagMax))
        }.font(.caption)
    }

    private var plotControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Plot", systemImage: "paintpalette").font(.subheadline).bold()
            Picker("Field", selection: $settings.field) {
                ForEach(PlotField.allCases) { f in
                    Text(fieldLabel(f)).tag(f)
                }
            }
            Toggle("Density", isOn: $settings.showDensity)
            Toggle("Contour", isOn: $settings.showContour)
            if settings.showContour {
                Stepper("Levels: \(settings.contourLevels)",
                        value: $settings.contourLevels, in: 3...60)
            }
            Toggle("Vectors", isOn: $settings.showVector)
            if settings.showVector {
                Stepper("Grid: \(settings.vectorGrid)",
                        value: $settings.vectorGrid, in: 6...80)
            }
            Toggle("Mesh", isOn: $settings.showMesh)
            Toggle("Smooth shading", isOn: $settings.smoothShading)
            Toggle("Auto range", isOn: $settings.autoRange)
            Toggle("Geometry", isOn: $settings.showGeometry)
            if !settings.autoRange {
                HStack {
                    TextField("min", value: $settings.manualMin, format: .number)
                        .textFieldStyle(.roundedBorder).frame(maxWidth: 90)
                    TextField("max", value: $settings.manualMax, format: .number)
                        .textFieldStyle(.roundedBorder).frame(maxWidth: 90)
                }
            }
        }.font(.caption)
    }

    private var pointQuery: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Point Query", systemImage: "hand.tap").font(.subheadline).bold()
            if let q = query {
                LabeledContent("x", value: String(format: "%.6g", q.x))
                LabeledContent("y", value: String(format: "%.6g", q.y))
                LabeledContent(doc.result.physics.scalarName,
                               value: String(format: "%.6g", q.scalar))
                LabeledContent("\(doc.result.physics.vectorName)x",
                               value: String(format: "%.6g", q.vx))
                LabeledContent("\(doc.result.physics.vectorName)y",
                               value: String(format: "%.6g", q.vy))
                LabeledContent("|\(doc.result.physics.vectorName)|",
                               value: String(format: "%.6g", q.vmag))
            } else {
                Text("Click in the canvas to query.").foregroundStyle(.secondary)
            }
        }.font(.caption)
    }

    private func fieldLabel(_ f: PlotField) -> String {
        switch f {
        case .scalar:    return doc.result.physics.scalarName
        case .vectorMag: return "|\(doc.result.physics.vectorName)|"
        }
    }
}

/// Turn the last contour segment into an arc. Mirrors Windows FEMM's
/// "Bend Contour" dialog: takes a subtended angle (deg, ±180) and a step
/// (deg, 1 by default). Disabled when the contour has fewer than 2 points.
struct BendArcControls: View {
    @ObservedObject var doc: FemmDocument
    @State private var angle: Double = 90
    @State private var step: Double = 5

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Bend last segment to arc").font(.caption).foregroundStyle(.secondary)
            HStack {
                TextField("angle°", value: $angle, format: .number)
                    .textFieldStyle(.roundedBorder).frame(maxWidth: 70)
                TextField("step°", value: $step, format: .number)
                    .textFieldStyle(.roundedBorder).frame(maxWidth: 60)
                Button("Bend") { doc.contourBendLast(angleDeg: angle, stepDeg: step) }
                    .disabled(doc.contour.count < 2)
            }
        }
    }
}

// MARK: - Rendering helpers (CoreGraphics via SwiftUI Canvas)

func elementValue(_ r: ResultSnapshot, element e: Int, field: PlotField) -> Double {
    switch field {
    case .scalar:
        let a = Int(r.elements[3*e])
        let b = Int(r.elements[3*e + 1])
        let c = Int(r.elements[3*e + 2])
        return (r.nodeScalar[a] + r.nodeScalar[b] + r.nodeScalar[c]) / 3.0
    case .vectorMag:
        let vx = r.elementVx[e], vy = r.elementVy[e]
        return (vx*vx + vy*vy).squareRoot()
    }
}

func plotRange(_ r: ResultSnapshot, field: PlotField,
               settings: PlotSettings,
               doc: FemmDocument? = nil) -> (Double, Double) {
    if !settings.autoRange { return (settings.manualMin, settings.manualMax) }
    // Windows parity: exclude external-region elements from the auto range
    // (see femm/belaviewDoc.cpp lines 755–800). Extreme values in large air
    // boxes otherwise compress the plot into the dim end of the palette.
    if let doc = doc {
        let labels = doc.snapshot.labels
        // Build per-label "external" mask.
        var extLabel = [Bool](repeating: false, count: labels.count)
        for (i, l) in labels.enumerated() { extLabel[i] = l.isExternal }
        let m = r.elementLabels.count
        var vmin = Double.infinity
        var vmax = -Double.infinity
        var kept = 0
        for e in 0..<m {
            let li = Int(r.elementLabels[e])
            if li >= 0 && li < extLabel.count && extLabel[li] { continue }
            let v = elementValue(r, element: e, field: field)
            if v < vmin { vmin = v }
            if v > vmax { vmax = v }
            kept += 1
        }
        // Special case: every element flagged external — fall back to global.
        if kept > 0 && vmax > vmin { return (vmin, vmax) }
    }
    switch field {
    case .scalar:    return (r.scalarMin, r.scalarMax)
    case .vectorMag: return (r.vectorMagMin, r.vectorMagMax)
    }
}

/// Density plot. When `smooth` is true, each triangle is sliced into the 20
/// BELA colour bands using interpolated nodal values (Gouraud-like banded
/// shading — matches Windows FEMM). Otherwise each triangle is filled with a
/// single element-average colour.
func drawDensity(ctx: GraphicsContext, result: ResultSnapshot,
                 field: PlotField, vmin: Double, vmax: Double,
                 smooth: Bool = false,
                 w2v: (CGPoint) -> CGPoint) {
    if smooth {
        let nodeVals: [Double]
        switch field {
        case .scalar:
            nodeVals = result.nodeScalar
        case .vectorMag:
            nodeVals = nodeMagnitudesFromElements(result)
        }
        drawDensitySmoothNodal(ctx: ctx, result: result, nodeVals: nodeVals,
                               vmin: vmin, vmax: vmax, w2v: w2v)
        return
    }
    let m = result.elementLabels.count
    let span = max(1e-30, vmax - vmin)
    for e in 0..<m {
        let a = Int(result.elements[3*e])
        let b = Int(result.elements[3*e + 1])
        let c = Int(result.elements[3*e + 2])
        let pa = w2v(CGPoint(x: result.nodeX[a], y: result.nodeY[a]))
        let pb = w2v(CGPoint(x: result.nodeX[b], y: result.nodeY[b]))
        let pc = w2v(CGPoint(x: result.nodeX[c], y: result.nodeY[c]))
        var path = Path()
        path.move(to: pa); path.addLine(to: pb); path.addLine(to: pc); path.closeSubpath()
        let v = elementValue(result, element: e, field: field)
        let t = (v - vmin) / span
        let color = viridis(t)
        ctx.fill(path, with: .color(color))
        // Stroke in the same color to cover anti-aliasing seams between
        // adjacent triangles (otherwise the mesh appears even with the
        // mesh overlay off).
        ctx.stroke(path, with: .color(color), lineWidth: 0.6)
    }
}

func drawDensityPrepared(ctx: GraphicsContext,
                         result: ResultSnapshot,
                         data: PostRenderData,
                         visible: WorldBounds,
                         w2v: (CGPoint) -> CGPoint) {
    guard !data.isEmpty else { return }
    if data.smooth {
        for poly in data.smoothDensityPolygons where poly.bounds.intersects(visible) {
            guard let first = poly.points.first else { continue }
            var path = Path()
            path.move(to: w2v(first))
            for p in poly.points.dropFirst() { path.addLine(to: w2v(p)) }
            path.closeSubpath()
            let color = belaColor(poly.bin)
            ctx.fill(path, with: .color(color))
            ctx.stroke(path, with: .color(color), lineWidth: 0.5)
        }
        return
    }

    let span = max(1e-30, data.plotMax - data.plotMin)
    for e in 0..<result.elementLabels.count where data.elementBounds[e].intersects(visible) {
        let a = Int(result.elements[3*e])
        let b = Int(result.elements[3*e + 1])
        let c = Int(result.elements[3*e + 2])
        let pa = w2v(CGPoint(x: result.nodeX[a], y: result.nodeY[a]))
        let pb = w2v(CGPoint(x: result.nodeX[b], y: result.nodeY[b]))
        let pc = w2v(CGPoint(x: result.nodeX[c], y: result.nodeY[c]))
        var path = Path()
        path.move(to: pa); path.addLine(to: pb); path.addLine(to: pc); path.closeSubpath()
        let values = (data.field == .scalar) ? data.scalarElementValues : data.vectorElementMagnitudes
        let t = (values[e] - data.plotMin) / span
        let color = viridis(t)
        ctx.fill(path, with: .color(color))
        ctx.stroke(path, with: .color(color), lineWidth: 0.6)
    }
}

/// Build per-node scalar values from per-element data by averaging the
/// elements incident on each node (area-weighted would be fancier but equal
/// weighting already matches Windows closely enough).
func nodeMagnitudesFromElements(_ r: ResultSnapshot) -> [Double] {
    var sum = [Double](repeating: 0, count: r.nodeX.count)
    var cnt = [Int](repeating: 0, count: r.nodeX.count)
    let m = r.elementLabels.count
    for e in 0..<m {
        let vx = r.elementVx[e], vy = r.elementVy[e]
        let v = (vx*vx + vy*vy).squareRoot()
        for k in 0..<3 {
            let n = Int(r.elements[3*e + k])
            sum[n] += v
            cnt[n] += 1
        }
    }
    var out = [Double](repeating: 0, count: r.nodeX.count)
    for i in 0..<out.count { out[i] = cnt[i] > 0 ? sum[i] / Double(cnt[i]) : 0 }
    return out
}

func makeSmoothDensityPolygons(result: ResultSnapshot,
                               nodeVals: [Double],
                               vmin: Double,
                               vmax: Double) -> [DensityBandPolygon] {
    let m = result.elementLabels.count
    let span = max(1e-30, vmax - vmin)
    let bins = 20
    var out: [DensityBandPolygon] = []
    out.reserveCapacity(m * 3)
    for e in 0..<m {
        let ia = Int(result.elements[3*e])
        let ib = Int(result.elements[3*e + 1])
        let ic = Int(result.elements[3*e + 2])
        let xa = result.nodeX[ia], ya = result.nodeY[ia], va = nodeVals[ia]
        let xb = result.nodeX[ib], yb = result.nodeY[ib], vb = nodeVals[ib]
        let xc = result.nodeX[ic], yc = result.nodeY[ic], vc = nodeVals[ic]
        let tri: [(x: Double, y: Double, v: Double)] = [
            (xa, ya, va), (xb, yb, vb), (xc, yc, vc)
        ]
        let triMin = min(va, min(vb, vc))
        let triMax = max(va, max(vb, vc))
        var b0 = Int(((triMin - vmin) / span) * Double(bins))
        var b1 = Int(((triMax - vmin) / span) * Double(bins))
        if b0 < 0 { b0 = 0 }
        if b1 > bins - 1 { b1 = bins - 1 }
        if b1 < b0 { continue }
        for b in b0...b1 {
            let lo = vmin + span * Double(b) / Double(bins)
            let hi = vmin + span * Double(b + 1) / Double(bins)
            let poly = clipTriangleByBand(tri, lo: lo, hi: hi)
            guard poly.count >= 3 else { continue }
            let points = poly.map { CGPoint(x: $0.x, y: $0.y) }
            out.append(DensityBandPolygon(points: points,
                                          bounds: boundsFor(points),
                                          bin: b))
        }
    }
    return out
}

func makeContourSegments(result: ResultSnapshot,
                         levels: Int,
                         vmin: Double,
                         vmax: Double) -> [ContourSegment] {
    guard levels > 0, vmax > vmin else { return [] }
    let m = result.elementLabels.count
    var out: [ContourSegment] = []
    out.reserveCapacity(m * levels / 3)
    for li in 1...levels {
        let level = vmin + (vmax - vmin) * Double(li) / Double(levels + 1)
        for e in 0..<m {
            let ia = Int(result.elements[3*e])
            let ib = Int(result.elements[3*e + 1])
            let ic = Int(result.elements[3*e + 2])
            let pts = triCross(level: level,
                               v: [result.nodeScalar[ia], result.nodeScalar[ib], result.nodeScalar[ic]],
                               p: [(result.nodeX[ia], result.nodeY[ia]),
                                   (result.nodeX[ib], result.nodeY[ib]),
                                   (result.nodeX[ic], result.nodeY[ic])])
            if pts.count == 2 {
                let a = CGPoint(x: pts[0].0, y: pts[0].1)
                let b = CGPoint(x: pts[1].0, y: pts[1].1)
                out.append(ContourSegment(a: a, b: b, bounds: boundsFor([a, b])))
            }
        }
    }
    return out
}

func boundsFor(_ points: [CGPoint]) -> WorldBounds {
    guard let first = points.first else {
        return WorldBounds(minX: 0, minY: 0, maxX: 0, maxY: 0)
    }
    var minX = Double(first.x), maxX = Double(first.x)
    var minY = Double(first.y), maxY = Double(first.y)
    for p in points.dropFirst() {
        minX = min(minX, Double(p.x)); maxX = max(maxX, Double(p.x))
        minY = min(minY, Double(p.y)); maxY = max(maxY, Double(p.y))
    }
    return WorldBounds(minX: minX, minY: minY, maxX: maxX, maxY: maxY)
}

/// Smooth banded density plot using per-node values. For each triangle we
/// clip by the two iso-levels bracketing each of the 20 colour bins and fill
/// the resulting polygon in that bin's colour. Matches Windows FEMM's banded
/// Gouraud rendering.
func drawDensitySmoothNodal(ctx: GraphicsContext, result: ResultSnapshot,
                            nodeVals: [Double],
                            vmin: Double, vmax: Double,
                            w2v: (CGPoint) -> CGPoint) {
    let m = result.elementLabels.count
    let span = max(1e-30, vmax - vmin)
    let bins = 20
    for e in 0..<m {
        let ia = Int(result.elements[3*e])
        let ib = Int(result.elements[3*e + 1])
        let ic = Int(result.elements[3*e + 2])
        let xa = result.nodeX[ia], ya = result.nodeY[ia], va = nodeVals[ia]
        let xb = result.nodeX[ib], yb = result.nodeY[ib], vb = nodeVals[ib]
        let xc = result.nodeX[ic], yc = result.nodeY[ic], vc = nodeVals[ic]
        let tri: [(x: Double, y: Double, v: Double)] = [
            (xa, ya, va), (xb, yb, vb), (xc, yc, vc)
        ]
        let triMin = min(va, min(vb, vc))
        let triMax = max(va, max(vb, vc))
        var b0 = Int(((triMin - vmin) / span) * Double(bins))
        var b1 = Int(((triMax - vmin) / span) * Double(bins))
        if b0 < 0 { b0 = 0 }
        if b1 > bins - 1 { b1 = bins - 1 }
        if b1 < b0 { continue }
        for b in b0...b1 {
            let lo = vmin + span * Double(b) / Double(bins)
            let hi = vmin + span * Double(b + 1) / Double(bins)
            let poly = clipTriangleByBand(tri, lo: lo, hi: hi)
            guard poly.count >= 3 else { continue }
            var path = Path()
            path.move(to: w2v(CGPoint(x: poly[0].x, y: poly[0].y)))
            for p in poly.dropFirst() {
                path.addLine(to: w2v(CGPoint(x: p.x, y: p.y)))
            }
            path.closeSubpath()
            let rgb = belaPalette[b]
            let color = Color(red: rgb.0, green: rgb.1, blue: rgb.2)
            ctx.fill(path, with: .color(color))
            ctx.stroke(path, with: .color(color), lineWidth: 0.5)
        }
    }
}

/// Return the sub-polygon where `lo <= v <= hi`, via two Sutherland–Hodgman
/// passes: first keep `v >= lo`, then keep `v <= hi`. Output vertices carry
/// their interpolated scalar.
fileprivate func clipTriangleByBand(_ tri: [(x: Double, y: Double, v: Double)],
                                    lo: Double, hi: Double)
    -> [(x: Double, y: Double, v: Double)]
{
    let pass1 = clipHalfplane(tri, threshold: lo, keepAbove: true)
    if pass1.count < 3 { return [] }
    let pass2 = clipHalfplane(pass1, threshold: hi, keepAbove: false)
    return pass2
}

fileprivate func clipHalfplane(_ poly: [(x: Double, y: Double, v: Double)],
                               threshold t: Double, keepAbove: Bool)
    -> [(x: Double, y: Double, v: Double)]
{
    guard poly.count >= 2 else { return [] }
    var out: [(x: Double, y: Double, v: Double)] = []
    let inside: (Double) -> Bool = keepAbove ? { $0 >= t } : { $0 <= t }
    for i in 0..<poly.count {
        let p = poly[i]
        let q = poly[(i + 1) % poly.count]
        let pIn = inside(p.v), qIn = inside(q.v)
        if pIn { out.append(p) }
        if pIn != qIn {
            let denom = q.v - p.v
            let s = denom == 0 ? 0 : (t - p.v) / denom
            out.append((x: p.x + s * (q.x - p.x),
                        y: p.y + s * (q.y - p.y),
                        v: t))
        }
    }
    return out
}

/// Extract scalar iso-lines at uniform levels between vmin..vmax.
func drawContours(ctx: GraphicsContext, result: ResultSnapshot,
                  levels: Int, vmin: Double, vmax: Double,
                  w2v: (CGPoint) -> CGPoint) {
    guard levels > 0, vmax > vmin else { return }
    let m = result.elementLabels.count
    var path = Path()
    for li in 1...levels {
        let level = vmin + (vmax - vmin) * Double(li) / Double(levels + 1)
        for e in 0..<m {
            let ia = Int(result.elements[3*e])
            let ib = Int(result.elements[3*e + 1])
            let ic = Int(result.elements[3*e + 2])
            let va = result.nodeScalar[ia]
            let vb = result.nodeScalar[ib]
            let vc = result.nodeScalar[ic]
            let xa = result.nodeX[ia], ya = result.nodeY[ia]
            let xb = result.nodeX[ib], yb = result.nodeY[ib]
            let xc = result.nodeX[ic], yc = result.nodeY[ic]
            // Standard marching-triangles: find which edges cross `level`.
            let pts = triCross(level: level,
                               v: [va, vb, vc],
                               p: [(xa,ya), (xb,yb), (xc,yc)])
            if pts.count == 2 {
                let p0 = w2v(CGPoint(x: pts[0].0, y: pts[0].1))
                let p1 = w2v(CGPoint(x: pts[1].0, y: pts[1].1))
                path.move(to: p0); path.addLine(to: p1)
            }
        }
    }
    ctx.stroke(path, with: .color(.black.opacity(0.4)), lineWidth: 0.6)
}

func drawContoursPrepared(ctx: GraphicsContext,
                          data: PostRenderData,
                          visible: WorldBounds,
                          w2v: (CGPoint) -> CGPoint) {
    var path = Path()
    for seg in data.contourSegments where seg.bounds.intersects(visible) {
        path.move(to: w2v(seg.a))
        path.addLine(to: w2v(seg.b))
    }
    ctx.stroke(path, with: .color(.black.opacity(0.4)), lineWidth: 0.6)
}

fileprivate func triCross(level: Double, v: [Double], p: [(Double, Double)]) -> [(Double, Double)] {
    var out: [(Double, Double)] = []
    for (i, j) in [(0,1), (1,2), (2,0)] {
        let a = v[i], b = v[j]
        if (a - level) * (b - level) < 0 {
            let t = (level - a) / (b - a)
            out.append((p[i].0 + t * (p[j].0 - p[i].0),
                        p[i].1 + t * (p[j].1 - p[i].1)))
        } else if a == level { out.append(p[i]) }
    }
    // Deduplicate (endpoint case)
    if out.count > 2 { out = Array(out.prefix(2)) }
    return out
}

/// Vector plot: sample on an NxN viewport-aligned grid.
func drawVectors(ctx: GraphicsContext, doc: FemmDocument,
                 result: ResultSnapshot,
                 grid: Int, vmin: Double, vmax: Double,
                 viewSize: CGSize, w2v: (CGPoint) -> CGPoint,
                 v2w: (CGPoint) -> CGPoint) {
    guard let b = result.bounds else { return }
    let span = max(1e-30, vmax - vmin)
    let stepPx = min(viewSize.width, viewSize.height) / CGFloat(grid)
    var yy = stepPx / 2
    while yy < viewSize.height {
        var xx = stepPx / 2
        while xx < viewSize.width {
            let world = v2w(CGPoint(x: xx, y: yy))
            // Only sample inside the mesh bounding box
            if world.x >= b.min.x && world.x <= b.max.x &&
               world.y >= b.min.y && world.y <= b.max.y,
               let q = doc.samplePoint(x: Double(world.x), y: Double(world.y)) {
                let mag = (q.vx*q.vx + q.vy*q.vy).squareRoot()
                if mag > 0 {
                    let t = (mag - vmin) / span
                    let L = 0.45 * stepPx
                    let ux = q.vx / mag, uy = q.vy / mag
                    // y-axis flip: screen-down is positive, world-up is positive
                    let p0 = CGPoint(x: xx - ux * L / 2, y: yy + uy * L / 2)
                    let p1 = CGPoint(x: xx + ux * L / 2, y: yy - uy * L / 2)
                    var path = Path(); path.move(to: p0); path.addLine(to: p1)
                    let hx = ux * L * 0.25, hy = uy * L * 0.25
                    let left = CGPoint(x: p1.x - hx - uy * L * 0.15,
                                       y: p1.y + hy - ux * L * 0.15)
                    let right = CGPoint(x: p1.x - hx + uy * L * 0.15,
                                        y: p1.y + hy + ux * L * 0.15)
                    path.move(to: p1); path.addLine(to: left)
                    path.move(to: p1); path.addLine(to: right)
                    ctx.stroke(path, with: .color(viridis(t)), lineWidth: 1.2)
                }
            }
            xx += stepPx
        }
        yy += stepPx
    }
}

/// Mesh overlay: draw element edges.
func drawMesh(ctx: GraphicsContext, result: ResultSnapshot,
              w2v: (CGPoint) -> CGPoint) {
    let m = result.elementLabels.count
    var path = Path()
    for e in 0..<m {
        let a = Int(result.elements[3*e])
        let b = Int(result.elements[3*e + 1])
        let c = Int(result.elements[3*e + 2])
        let pa = w2v(CGPoint(x: result.nodeX[a], y: result.nodeY[a]))
        let pb = w2v(CGPoint(x: result.nodeX[b], y: result.nodeY[b]))
        let pc = w2v(CGPoint(x: result.nodeX[c], y: result.nodeY[c]))
        path.move(to: pa); path.addLine(to: pb)
        path.move(to: pb); path.addLine(to: pc)
        path.move(to: pc); path.addLine(to: pa)
    }
    ctx.stroke(path, with: .color(.gray.opacity(0.35)), lineWidth: 0.4)
}

func drawMeshPrepared(ctx: GraphicsContext,
                      result: ResultSnapshot,
                      data: PostRenderData,
                      visible: WorldBounds,
                      w2v: (CGPoint) -> CGPoint) {
    var path = Path()
    for e in 0..<result.elementLabels.count where data.elementBounds[e].intersects(visible) {
        let a = Int(result.elements[3*e])
        let b = Int(result.elements[3*e + 1])
        let c = Int(result.elements[3*e + 2])
        let pa = w2v(CGPoint(x: result.nodeX[a], y: result.nodeY[a]))
        let pb = w2v(CGPoint(x: result.nodeX[b], y: result.nodeY[b]))
        let pc = w2v(CGPoint(x: result.nodeX[c], y: result.nodeY[c]))
        path.move(to: pa); path.addLine(to: pb)
        path.move(to: pb); path.addLine(to: pc)
        path.move(to: pc); path.addLine(to: pa)
    }
    ctx.stroke(path, with: .color(.gray.opacity(0.35)), lineWidth: 0.4)
}
