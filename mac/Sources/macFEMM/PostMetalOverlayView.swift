// PostMetalOverlayView.swift — GPU-backed line/fill overlays for results.

import AppKit
import Metal
import MetalKit
import SwiftUI

struct PostOverlayMarker: Hashable {
    var x: Double
    var y: Double
    var isPinned: Bool
}

private struct OverlayVertex {
    var x: Float
    var y: Float
    var r: Float
    var g: Float
    var b: Float
    var a: Float
}

private struct OverlayUniforms {
    var centerX: Float
    var centerY: Float
    var scale: Float
    var width: Float
    var height: Float
}

private struct MetalRegionEdge: Hashable {
    let a: Int
    let b: Int

    init(_ i: Int, _ j: Int) {
        a = min(i, j)
        b = max(i, j)
    }
}

struct PostMetalOverlayView: NSViewRepresentable {
    let doc: FemmDocument
    let result: ResultSnapshot
    let snapshot: DocSnapshot
    let data: PostRenderData
    let viewport: Viewport
    let settings: PlotSettings
    let postTool: PostTool
    let selectedLabels: Set<Int>
    let contour: [CGPoint]
    let queryMarkers: [PostOverlayMarker]

    func makeCoordinator() -> Renderer {
        Renderer()
    }

    func makeNSView(context: Context) -> MTKView {
        let view = MTKView()
        view.device = context.coordinator.device
        view.delegate = context.coordinator
        view.isPaused = true
        view.enableSetNeedsDisplay = true
        view.framebufferOnly = true
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        view.layer?.isOpaque = false
        return view
    }

    func updateNSView(_ view: MTKView, context: Context) {
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        context.coordinator.update(doc: doc,
                                   result: result,
                                   snapshot: snapshot,
                                   data: data,
                                   viewport: viewport,
                                   settings: settings,
                                   postTool: postTool,
                                   selectedLabels: selectedLabels,
                                   contour: contour,
                                   queryMarkers: queryMarkers,
                                   viewSize: view.bounds.size)
        view.setNeedsDisplay(view.bounds)
    }

    final class Renderer: NSObject, MTKViewDelegate {
        let device: MTLDevice?
        private let queue: MTLCommandQueue?
        private let pipeline: MTLRenderPipelineState?
        private var lineBuffer: MTLBuffer?
        private var fillBuffer: MTLBuffer?
        private var lineCount = 0
        private var fillCount = 0
        private var signature = ""
        private var viewport = Viewport()

        override init() {
            let device = MTLCreateSystemDefaultDevice()
            self.device = device
            self.queue = device?.makeCommandQueue()
            if let device {
                self.pipeline = Renderer.makePipeline(device: device)
            } else {
                self.pipeline = nil
            }
            super.init()
        }

        func update(doc: FemmDocument,
                    result: ResultSnapshot,
                    snapshot: DocSnapshot,
                    data: PostRenderData,
                    viewport: Viewport,
                    settings: PlotSettings,
                    postTool: PostTool,
                    selectedLabels: Set<Int>,
                    contour: [CGPoint],
                    queryMarkers: [PostOverlayMarker],
                    viewSize: CGSize) {
            self.viewport = viewport
            let vectorViewport = settings.showVector ? "\(viewport.center.x):\(viewport.center.y):\(viewport.scale):\(viewSize.width):\(viewSize.height)" : ""
            let markerScale = "\(viewport.scale)"
            let nextSignature = [
                "\(result.nodeX.count):\(result.elementLabels.count):\(data.contourSegments.count)",
                "\(snapshot.nodes.count):\(snapshot.segments.count):\(snapshot.arcs.count):\(snapshot.labels.count)",
                "\(settings.showContour):\(settings.showMesh):\(settings.showVector):\(settings.showGeometry)",
                "\(postTool.rawValue):\(selectedLabels.sorted().map(String.init).joined(separator: ","))",
                contour.map { "\($0.x):\($0.y)" }.joined(separator: "|"),
                queryMarkers.map { "\($0.x):\($0.y):\($0.isPinned)" }.joined(separator: "|"),
                vectorViewport,
                markerScale
            ].joined(separator: "#")
            guard nextSignature != signature else { return }
            signature = nextSignature
            rebuildBuffers(doc: doc,
                           result: result,
                           snapshot: snapshot,
                           data: data,
                           viewport: viewport,
                           settings: settings,
                           postTool: postTool,
                           selectedLabels: selectedLabels,
                           contour: contour,
                           queryMarkers: queryMarkers,
                           viewSize: viewSize)
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
            signature = ""
            view.setNeedsDisplay(view.bounds)
        }

        func draw(in view: MTKView) {
            guard let pipeline,
                  let queue,
                  let drawable = view.currentDrawable,
                  let descriptor = view.currentRenderPassDescriptor else { return }

            descriptor.colorAttachments[0].clearColor = view.clearColor
            guard let command = queue.makeCommandBuffer(),
                  let encoder = command.makeRenderCommandEncoder(descriptor: descriptor) else { return }

            let size = view.bounds.size
            var u = OverlayUniforms(centerX: Float(viewport.center.x),
                                    centerY: Float(viewport.center.y),
                                    scale: Float(viewport.scale),
                                    width: max(1, Float(size.width)),
                                    height: max(1, Float(size.height)))
            encoder.setRenderPipelineState(pipeline)
            encoder.setVertexBytes(&u, length: MemoryLayout<OverlayUniforms>.stride, index: 1)

            if fillCount > 0, let fillBuffer {
                encoder.setVertexBuffer(fillBuffer, offset: 0, index: 0)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: fillCount)
            }
            if lineCount > 0, let lineBuffer {
                encoder.setVertexBuffer(lineBuffer, offset: 0, index: 0)
                encoder.drawPrimitives(type: .line, vertexStart: 0, vertexCount: lineCount)
            }

            encoder.endEncoding()
            command.present(drawable)
            command.commit()
        }

        private func rebuildBuffers(doc: FemmDocument,
                                    result: ResultSnapshot,
                                    snapshot: DocSnapshot,
                                    data: PostRenderData,
                                    viewport: Viewport,
                                    settings: PlotSettings,
                                    postTool: PostTool,
                                    selectedLabels: Set<Int>,
                                    contour: [CGPoint],
                                    queryMarkers: [PostOverlayMarker],
                                    viewSize: CGSize) {
            guard let device, !result.isEmpty else {
                lineBuffer = nil; fillBuffer = nil
                lineCount = 0; fillCount = 0
                return
            }

            var lines: [OverlayVertex] = []
            var fills: [OverlayVertex] = []
            lines.reserveCapacity(8192)

            let gray = rgba(0.55, 0.55, 0.55, 0.35)
            let contourColor = rgba(0.02, 0.02, 0.02, 0.42)
            let labelColor = rgba(NSColor.labelColor, alpha: 0.82)
            let selectedColor = rgba(1.0, 0.55, 0.0, 0.86)
            let unselectedLabelColor = rgba(0.55, 0.24, 0.74, 0.78)
            let red = rgba(1.0, 0.05, 0.03, 0.95)

            if settings.showContour {
                for seg in data.contourSegments {
                    appendLine(&lines, seg.a, seg.b, contourColor)
                }
            }

            if settings.showMesh {
                for e in 0..<result.elementLabels.count {
                    let a = Int(result.elements[3*e])
                    let b = Int(result.elements[3*e + 1])
                    let c = Int(result.elements[3*e + 2])
                    let pa = point(result, a), pb = point(result, b), pc = point(result, c)
                    appendLine(&lines, pa, pb, gray)
                    appendLine(&lines, pb, pc, gray)
                    appendLine(&lines, pc, pa, gray)
                }
            }

            if settings.showVector {
                appendVectors(&lines, doc: doc, result: result, viewport: viewport,
                              viewSize: viewSize, grid: settings.vectorGrid)
            }

            if settings.showGeometry {
                appendGeometry(&lines, snapshot: snapshot, viewport: viewport,
                               labelColor: labelColor,
                               selectedColor: selectedColor,
                               unselectedLabelColor: unselectedLabelColor,
                               selectedLabels: selectedLabels,
                               includeLabels: postTool != .region)
            }

            if postTool == .region {
                appendSelectedRegion(fill: &fills, lines: &lines, result: result,
                                     selectedLabels: selectedLabels,
                                     fillColor: rgba(0.45, 0.45, 0.45, 0.22),
                                     outlineColor: rgba(0.34, 0.34, 0.34, 0.82))
                appendRegionLabels(fill: &fills, lines: &lines,
                                   snapshot: snapshot,
                                   viewport: viewport,
                                   selectedLabels: selectedLabels,
                                   color: rgba(0.02, 0.02, 0.02, 0.92))
            }

            appendUserContour(&lines, contour: contour, viewport: viewport, color: red)
            appendQueryMarkers(&lines, markers: queryMarkers, viewport: viewport, color: red)

            lineCount = lines.count
            fillCount = fills.count
            lineBuffer = lines.isEmpty ? nil : lines.withUnsafeBytes {
                device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared)
            }
            fillBuffer = fills.isEmpty ? nil : fills.withUnsafeBytes {
                device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared)
            }
        }

        private func appendGeometry(_ lines: inout [OverlayVertex],
                                    snapshot: DocSnapshot,
                                    viewport: Viewport,
                                    labelColor: SIMD4<Float>,
                                    selectedColor: SIMD4<Float>,
                                    unselectedLabelColor: SIMD4<Float>,
                                    selectedLabels: Set<Int>,
                                    includeLabels: Bool = true) {
            let nodes = snapshot.nodes
            for seg in snapshot.segments {
                guard seg.n0 >= 0, Int(seg.n0) < nodes.count,
                      seg.n1 >= 0, Int(seg.n1) < nodes.count else { continue }
                appendLine(&lines, nodePoint(nodes[Int(seg.n0)]), nodePoint(nodes[Int(seg.n1)]), labelColor)
            }
            for arc in snapshot.arcs {
                appendArc(&lines, arc: arc, nodes: nodes, color: labelColor)
            }

            let nodeRadius = CGFloat(2.8 / max(viewport.scale, 1e-9))
            for n in nodes {
                appendCross(&lines, center: nodePoint(n), radius: nodeRadius, color: labelColor)
            }

            guard includeLabels else { return }
            for (i, label) in snapshot.labels.enumerated() {
                let selected = selectedLabels.contains(i)
                let radius = CGFloat((selected ? 6.0 : 5.0) / max(viewport.scale, 1e-9))
                appendCross(&lines,
                            center: CGPoint(x: label.x, y: label.y),
                            radius: radius,
                            color: selected ? selectedColor : unselectedLabelColor)
            }
        }

        private func appendRegionLabels(fill fills: inout [OverlayVertex],
                                        lines: inout [OverlayVertex],
                                        snapshot: DocSnapshot,
                                        viewport: Viewport,
                                        selectedLabels: Set<Int>,
                                        color: SIMD4<Float>) {
            let scale = max(viewport.scale, 1e-9)
            for (i, label) in snapshot.labels.enumerated() {
                let selected = selectedLabels.contains(i)
                let center = CGPoint(x: label.x, y: label.y)
                let radius = CGFloat((selected ? 8.0 : 6.5) / scale)
                appendDiamond(&fills,
                              center: center,
                              radius: radius,
                              color: color)
            }
        }

        private func appendSelectedRegion(fill fills: inout [OverlayVertex],
                                          lines: inout [OverlayVertex],
                                          result: ResultSnapshot,
                                          selectedLabels: Set<Int>,
                                          fillColor: SIMD4<Float>,
                                          outlineColor: SIMD4<Float>) {
            guard !selectedLabels.isEmpty else { return }
            var edges: [MetalRegionEdge: Int] = [:]
            for e in 0..<result.elementLabels.count where selectedLabels.contains(Int(result.elementLabels[e])) {
                let a = Int(result.elements[3*e])
                let b = Int(result.elements[3*e + 1])
                let c = Int(result.elements[3*e + 2])
                let pa = point(result, a), pb = point(result, b), pc = point(result, c)
                appendTriangle(&fills, pa, pb, pc, fillColor)
                edges[MetalRegionEdge(a, b), default: 0] += 1
                edges[MetalRegionEdge(b, c), default: 0] += 1
                edges[MetalRegionEdge(c, a), default: 0] += 1
            }
            for (edge, count) in edges where count == 1 {
                appendLine(&lines, point(result, edge.a), point(result, edge.b), outlineColor)
            }
        }

        private func appendUserContour(_ lines: inout [OverlayVertex],
                                       contour: [CGPoint],
                                       viewport: Viewport,
                                       color: SIMD4<Float>) {
            guard !contour.isEmpty else { return }
            for i in 1..<contour.count {
                appendLine(&lines, contour[i - 1], contour[i], color)
            }
            let radius = CGFloat(4.0 / max(viewport.scale, 1e-9))
            for p in contour {
                appendCross(&lines, center: p, radius: radius, color: color)
            }
        }

        private func appendQueryMarkers(_ lines: inout [OverlayVertex],
                                        markers: [PostOverlayMarker],
                                        viewport: Viewport,
                                        color: SIMD4<Float>) {
            let radius = CGFloat(8.0 / max(viewport.scale, 1e-9))
            for marker in markers {
                let center = CGPoint(x: marker.x, y: marker.y)
                appendCross(&lines, center: center, radius: radius, color: color)
                if marker.isPinned {
                    appendBox(&lines, center: center, radius: radius * 0.72, color: color)
                }
            }
        }

        private func appendVectors(_ lines: inout [OverlayVertex],
                                   doc: FemmDocument,
                                   result: ResultSnapshot,
                                   viewport: Viewport,
                                   viewSize: CGSize,
                                   grid: Int) {
            guard let b = result.bounds, grid > 0 else { return }
            let span = max(1e-30, result.vectorMagMax - result.vectorMagMin)
            let stepPx = min(viewSize.width, viewSize.height) / CGFloat(grid)
            var yy = stepPx / 2
            while yy < viewSize.height {
                var xx = stepPx / 2
                while xx < viewSize.width {
                    let world = viewToWorld(CGPoint(x: xx, y: yy), size: viewSize, viewport: viewport)
                    if world.x >= b.min.x && world.x <= b.max.x &&
                       world.y >= b.min.y && world.y <= b.max.y,
                       let q = doc.samplePoint(x: Double(world.x), y: Double(world.y)) {
                        let mag = (q.vx*q.vx + q.vy*q.vy).squareRoot()
                        if mag > 0 {
                            let t = (mag - result.vectorMagMin) / span
                            let color = rgba(viridis(t))
                            let length = 0.45 * stepPx
                            let ux = q.vx / mag
                            let uy = q.vy / mag
                            let p0s = CGPoint(x: xx - ux * length / 2, y: yy + uy * length / 2)
                            let p1s = CGPoint(x: xx + ux * length / 2, y: yy - uy * length / 2)
                            let p0 = viewToWorld(p0s, size: viewSize, viewport: viewport)
                            let p1 = viewToWorld(p1s, size: viewSize, viewport: viewport)
                            appendLine(&lines, p0, p1, color)
                            let hx = ux * length * 0.25
                            let hy = uy * length * 0.25
                            let left = CGPoint(x: p1s.x - hx - uy * length * 0.15,
                                               y: p1s.y + hy - ux * length * 0.15)
                            let right = CGPoint(x: p1s.x - hx + uy * length * 0.15,
                                                y: p1s.y + hy + ux * length * 0.15)
                            appendLine(&lines, p1, viewToWorld(left, size: viewSize, viewport: viewport), color)
                            appendLine(&lines, p1, viewToWorld(right, size: viewSize, viewport: viewport), color)
                        }
                    }
                    xx += stepPx
                }
                yy += stepPx
            }
        }

        private func appendArc(_ lines: inout [OverlayVertex],
                               arc: DocSnapshot.Arc,
                               nodes: [DocSnapshot.Node],
                               color: SIMD4<Float>) {
            guard arc.n0 >= 0, Int(arc.n0) < nodes.count,
                  arc.n1 >= 0, Int(arc.n1) < nodes.count else { return }
            let n0 = nodes[Int(arc.n0)]
            let n1 = nodes[Int(arc.n1)]
            let dx = n1.x - n0.x
            let dy = n1.y - n0.y
            let chord = hypot(dx, dy)
            guard chord > 0 else { return }
            let half = arc.arcDeg * .pi / 360.0
            guard sin(half) != 0 else { return }
            let radius = chord / (2 * sin(half))
            let mx = 0.5 * (n0.x + n1.x)
            let my = 0.5 * (n0.y + n1.y)
            let nx = -dy / chord
            let ny = dx / chord
            let d = radius * cos(half)
            let cx = mx + nx * d
            let cy = my + ny * d
            let steps = max(8, Int(abs(arc.arcDeg) / 2.0))
            var previous: CGPoint?
            let ang0 = atan2(n0.y - cy, n0.x - cx)
            for k in 0...steps {
                let t = Double(k) / Double(steps)
                let ang = ang0 + t * (arc.arcDeg * .pi / 180.0)
                let p = CGPoint(x: cx + radius * cos(ang), y: cy + radius * sin(ang))
                if let previous {
                    appendLine(&lines, previous, p, color)
                }
                previous = p
            }
        }

        private static func makePipeline(device: MTLDevice) -> MTLRenderPipelineState? {
            do {
                let library = try device.makeLibrary(source: overlayShaderSource, options: nil)
                let descriptor = MTLRenderPipelineDescriptor()
                descriptor.vertexFunction = library.makeFunction(name: "overlay_vertex")
                descriptor.fragmentFunction = library.makeFunction(name: "overlay_fragment")
                descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
                descriptor.colorAttachments[0].isBlendingEnabled = true
                descriptor.colorAttachments[0].rgbBlendOperation = .add
                descriptor.colorAttachments[0].alphaBlendOperation = .add
                descriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
                descriptor.colorAttachments[0].sourceAlphaBlendFactor = .sourceAlpha
                descriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
                descriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
                return try device.makeRenderPipelineState(descriptor: descriptor)
            } catch {
                NSLog("macFEMM Metal overlay pipeline failed: \(error)")
                return nil
            }
        }
    }
}

private func nodePoint(_ node: DocSnapshot.Node) -> CGPoint {
    CGPoint(x: node.x, y: node.y)
}

private func point(_ result: ResultSnapshot, _ idx: Int) -> CGPoint {
    CGPoint(x: result.nodeX[idx], y: result.nodeY[idx])
}

private func viewToWorld(_ p: CGPoint, size: CGSize, viewport vp: Viewport) -> CGPoint {
    CGPoint(
        x: vp.center.x + (p.x - size.width / 2) / vp.scale,
        y: vp.center.y - (p.y - size.height / 2) / vp.scale
    )
}

private func appendLine(_ vertices: inout [OverlayVertex],
                        _ a: CGPoint,
                        _ b: CGPoint,
                        _ color: SIMD4<Float>) {
    vertices.append(vertex(a, color))
    vertices.append(vertex(b, color))
}

private func appendTriangle(_ vertices: inout [OverlayVertex],
                            _ a: CGPoint,
                            _ b: CGPoint,
                            _ c: CGPoint,
                            _ color: SIMD4<Float>) {
    vertices.append(vertex(a, color))
    vertices.append(vertex(b, color))
    vertices.append(vertex(c, color))
}

private func appendDiamond(_ vertices: inout [OverlayVertex],
                           center: CGPoint,
                           radius: CGFloat,
                           color: SIMD4<Float>) {
    let top = CGPoint(x: center.x, y: center.y + radius)
    let right = CGPoint(x: center.x + radius, y: center.y)
    let bottom = CGPoint(x: center.x, y: center.y - radius)
    let left = CGPoint(x: center.x - radius, y: center.y)
    appendTriangle(&vertices, top, right, bottom, color)
    appendTriangle(&vertices, top, bottom, left, color)
}

private func appendCross(_ vertices: inout [OverlayVertex],
                         center: CGPoint,
                         radius: CGFloat,
                         color: SIMD4<Float>) {
    appendLine(&vertices,
               CGPoint(x: center.x - radius, y: center.y),
               CGPoint(x: center.x + radius, y: center.y),
               color)
    appendLine(&vertices,
               CGPoint(x: center.x, y: center.y - radius),
               CGPoint(x: center.x, y: center.y + radius),
               color)
}

private func appendBox(_ vertices: inout [OverlayVertex],
                       center: CGPoint,
                       radius: CGFloat,
                       color: SIMD4<Float>) {
    let a = CGPoint(x: center.x - radius, y: center.y - radius)
    let b = CGPoint(x: center.x + radius, y: center.y - radius)
    let c = CGPoint(x: center.x + radius, y: center.y + radius)
    let d = CGPoint(x: center.x - radius, y: center.y + radius)
    appendLine(&vertices, a, b, color)
    appendLine(&vertices, b, c, color)
    appendLine(&vertices, c, d, color)
    appendLine(&vertices, d, a, color)
}

private func vertex(_ p: CGPoint, _ color: SIMD4<Float>) -> OverlayVertex {
    OverlayVertex(x: Float(p.x), y: Float(p.y),
                  r: color.x, g: color.y, b: color.z, a: color.w)
}

private func rgba(_ r: Double, _ g: Double, _ b: Double, _ a: Double) -> SIMD4<Float> {
    SIMD4<Float>(Float(r), Float(g), Float(b), Float(a))
}

private func rgba(_ color: Color, alpha: Double? = nil) -> SIMD4<Float> {
    let ns = NSColor(color).usingColorSpace(.deviceRGB) ?? .labelColor
    return rgba(ns, alpha: alpha)
}

private func rgba(_ color: NSColor, alpha: Double? = nil) -> SIMD4<Float> {
    let ns = color.usingColorSpace(.deviceRGB) ?? color
    return SIMD4<Float>(Float(ns.redComponent),
                        Float(ns.greenComponent),
                        Float(ns.blueComponent),
                        Float(alpha ?? Double(ns.alphaComponent)))
}

private let overlayShaderSource = """
#include <metal_stdlib>
using namespace metal;

struct VertexIn {
    float x;
    float y;
    float r;
    float g;
    float b;
    float a;
};

struct Uniforms {
    float centerX;
    float centerY;
    float scale;
    float width;
    float height;
};

struct VertexOut {
    float4 position [[position]];
    float4 color;
};

vertex VertexOut overlay_vertex(const device VertexIn *vertices [[buffer(0)]],
                                constant Uniforms &u [[buffer(1)]],
                                uint vid [[vertex_id]]) {
    VertexIn v = vertices[vid];
    float clipX = 2.0 * (v.x - u.centerX) * u.scale / u.width;
    float clipY = 2.0 * (v.y - u.centerY) * u.scale / u.height;
    return { float4(clipX, clipY, 0.0, 1.0), float4(v.r, v.g, v.b, v.a) };
}

fragment float4 overlay_fragment(VertexOut in [[stage_in]]) {
    return in.color;
}
"""
