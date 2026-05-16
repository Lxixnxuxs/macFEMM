// XYPlotPanel.swift — Line-plot of a field along the active contour.
//
// Samples N points evenly by arc length along doc.contour, calls
// femm_result_point_values per sample, and plots the chosen quantity vs.
// cumulative contour distance in problem units (m at the C ABI boundary —
// we keep the Swift side in problem units to match the user's mental model).

import SwiftUI
import Charts
import FemmCore

enum XYPlotQuantity: String, CaseIterable, Identifiable {
    case scalar = "Scalar"
    case vx     = "Vx"
    case vy     = "Vy"
    case vmag   = "|V|"
    var id: String { rawValue }
}

struct XYSample: Identifiable {
    let id = UUID()
    let s: Double    // arc length from contour start (problem units)
    let v: Double
}

struct XYPlotPanel: View {
    @ObservedObject var doc: FemmDocument
    @State private var quantity: XYPlotQuantity = .scalar
    @State private var samples: Int = 200
    @State private var data: [XYSample] = []
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("XY plot", systemImage: "chart.xyaxis.line").font(.subheadline).bold()
            Picker("Quantity", selection: $quantity) {
                ForEach(XYPlotQuantity.allCases) { q in Text(displayName(q)).tag(q) }
            }
            Stepper("Samples: \(samples)", value: $samples, in: 20...2000, step: 20)
            HStack {
                Button("Plot") { recompute() }
                    .disabled(doc.contour.count < 2)
                Button("Clear") { data.removeAll() }
                    .disabled(data.isEmpty)
                Button("Copy CSV") { copyCSV() }
                    .disabled(data.isEmpty)
            }
            if let msg = errorMessage {
                Text(msg).foregroundStyle(.red).font(.caption)
            }
            if !data.isEmpty {
                Chart(data) { d in
                    LineMark(
                        x: .value("s", d.s),
                        y: .value(displayName(quantity), d.v)
                    )
                }
                .chartXAxisLabel("s")
                .chartYAxisLabel(displayName(quantity))
                .frame(height: 160)
                .padding(.top, 4)
            }
        }
        .font(.caption)
    }

    private func displayName(_ q: XYPlotQuantity) -> String {
        let phys = doc.snapshot.physics
        switch q {
        case .scalar: return phys.scalarName
        case .vx:     return "\(phys.vectorName)x"
        case .vy:     return "\(phys.vectorName)y"
        case .vmag:   return "|\(phys.vectorName)|"
        }
    }

    private func recompute() {
        errorMessage = nil
        let pts = doc.contour
        guard pts.count >= 2, samples >= 2 else {
            errorMessage = "Need contour with 2+ points"
            return
        }
        /* Cumulative arc length in problem units. */
        var cum = [Double](repeating: 0, count: pts.count)
        for i in 1..<pts.count {
            let dx = Double(pts[i].x - pts[i-1].x)
            let dy = Double(pts[i].y - pts[i-1].y)
            cum[i] = cum[i-1] + (dx*dx + dy*dy).squareRoot()
        }
        let total = cum.last ?? 0
        guard total > 0 else {
            errorMessage = "Zero-length contour"
            return
        }

        var out: [XYSample] = []
        out.reserveCapacity(samples)
        var segIdx = 0
        for i in 0..<samples {
            let s = total * Double(i) / Double(samples - 1)
            while segIdx + 1 < cum.count && cum[segIdx + 1] < s { segIdx += 1 }
            let j = min(segIdx + 1, pts.count - 1)
            let segLen = max(1e-30, cum[j] - cum[segIdx])
            let t = (s - cum[segIdx]) / segLen
            let x = Double(pts[segIdx].x) + t * Double(pts[j].x - pts[segIdx].x)
            let y = Double(pts[segIdx].y) + t * Double(pts[j].y - pts[segIdx].y)
            let v: Double
            if let q = doc.samplePoint(x: x, y: y) {
                switch quantity {
                case .scalar: v = q.scalar
                case .vx:     v = q.vx
                case .vy:     v = q.vy
                case .vmag:   v = (q.vx*q.vx + q.vy*q.vy).squareRoot()
                }
            } else {
                v = .nan
            }
            out.append(XYSample(s: s, v: v))
        }
        data = out
    }

    private func copyCSV() {
        var buf = "s,\(displayName(quantity))\n"
        for d in data { buf += "\(d.s),\(d.v)\n" }
        #if canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(buf, forType: .string)
        #endif
    }
}
