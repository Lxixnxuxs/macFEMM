// PostMetalDensityView.swift — GPU-backed density plot for the post-processor.

import AppKit
import Metal
import MetalKit
import SwiftUI

private struct MetalDensityVertex {
    var x: Float
    var y: Float
    var value: Float
    var pad: Float = 0
}

private struct MetalDensityUniforms {
    var centerX: Float
    var centerY: Float
    var scale: Float
    var width: Float
    var height: Float
    var vmin: Float
    var vmax: Float
    var pad: Float = 0
}

struct PostMetalDensityView: NSViewRepresentable {
    let result: ResultSnapshot
    let data: PostRenderData
    let viewport: Viewport
    let settings: PlotSettings

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
        view.clearColor = Renderer.backgroundClearColor()
        return view
    }

    func updateNSView(_ view: MTKView, context: Context) {
        view.clearColor = Renderer.backgroundClearColor()
        context.coordinator.update(result: result,
                                   data: data,
                                   viewport: viewport,
                                   settings: settings)
        view.setNeedsDisplay(view.bounds)
    }

    final class Renderer: NSObject, MTKViewDelegate {
        let device: MTLDevice?
        private let queue: MTLCommandQueue?
        private let pipeline: MTLRenderPipelineState?
        private var vertexBuffer: MTLBuffer?
        private var vertexCount = 0
        private var signature = ""
        private var viewport = Viewport()
        private var vmin: Double = 0
        private var vmax: Double = 1

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

        func update(result: ResultSnapshot,
                    data: PostRenderData,
                    viewport: Viewport,
                    settings: PlotSettings) {
            self.viewport = viewport
            self.vmin = data.plotMin
            self.vmax = data.plotMax

            let nextSignature = "\(result.nodeX.count):\(result.elementLabels.count):\(data.field.rawValue):\(data.plotMin):\(data.plotMax):\(settings.smoothShading)"
            guard nextSignature != signature else { return }
            signature = nextSignature
            rebuildVertices(result: result, data: data)
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
            view.setNeedsDisplay(view.bounds)
        }

        func draw(in view: MTKView) {
            guard vertexCount > 0,
                  let pipeline,
                  let queue,
                  let drawable = view.currentDrawable,
                  let descriptor = view.currentRenderPassDescriptor,
                  let vertexBuffer else { return }

            descriptor.colorAttachments[0].clearColor = view.clearColor
            guard let command = queue.makeCommandBuffer(),
                  let encoder = command.makeRenderCommandEncoder(descriptor: descriptor) else { return }

            let size = view.bounds.size
            var u = MetalDensityUniforms(centerX: Float(viewport.center.x),
                                         centerY: Float(viewport.center.y),
                                         scale: Float(viewport.scale),
                                         width: max(1, Float(size.width)),
                                         height: max(1, Float(size.height)),
                                         vmin: Float(vmin),
                                         vmax: Float(vmax))
            encoder.setRenderPipelineState(pipeline)
            encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
            encoder.setVertexBytes(&u, length: MemoryLayout<MetalDensityUniforms>.stride, index: 1)
            encoder.setFragmentBytes(&u, length: MemoryLayout<MetalDensityUniforms>.stride, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: vertexCount)
            encoder.endEncoding()
            command.present(drawable)
            command.commit()
        }

        private func rebuildVertices(result: ResultSnapshot, data: PostRenderData) {
            let elementCount = result.elementLabels.count
            guard let device, !result.isEmpty, !data.isEmpty,
                  data.scalarElementValues.count >= elementCount,
                  data.vectorElementMagnitudes.count >= elementCount,
                  data.nodeVectorMagnitudes.count >= result.nodeX.count else {
                vertexBuffer = nil
                vertexCount = 0
                return
            }

            let nodeValues: [Double]
            switch data.field {
            case .scalar:
                nodeValues = result.nodeScalar
            case .vectorMag:
                nodeValues = data.nodeVectorMagnitudes
            }

            var vertices: [MetalDensityVertex] = []
            vertices.reserveCapacity(elementCount * 3)
            for e in 0..<elementCount {
                let flatValue: Double
                if data.field == .scalar {
                    flatValue = data.scalarElementValues[e]
                } else {
                    flatValue = data.vectorElementMagnitudes[e]
                }
                for k in 0..<3 {
                    let n = Int(result.elements[3*e + k])
                    let value = data.smooth ? nodeValues[n] : flatValue
                    vertices.append(MetalDensityVertex(x: Float(result.nodeX[n]),
                                                       y: Float(result.nodeY[n]),
                                                       value: Float(value)))
                }
            }
            vertexCount = vertices.count
            vertexBuffer = vertices.withUnsafeBytes { bytes in
                device.makeBuffer(bytes: bytes.baseAddress!,
                                  length: bytes.count,
                                  options: .storageModeShared)
            }
        }

        static func backgroundClearColor() -> MTLClearColor {
            let color = NSColor.textBackgroundColor.usingColorSpace(.deviceRGB) ?? .white
            return MTLClearColor(red: Double(color.redComponent),
                                 green: Double(color.greenComponent),
                                 blue: Double(color.blueComponent),
                                 alpha: 1)
        }

        private static func makePipeline(device: MTLDevice) -> MTLRenderPipelineState? {
            do {
                let library = try device.makeLibrary(source: shaderSource, options: nil)
                let descriptor = MTLRenderPipelineDescriptor()
                descriptor.vertexFunction = library.makeFunction(name: "density_vertex")
                descriptor.fragmentFunction = library.makeFunction(name: "density_fragment")
                descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
                return try device.makeRenderPipelineState(descriptor: descriptor)
            } catch {
                NSLog("macFEMM Metal density pipeline failed: \(error)")
                return nil
            }
        }
    }
}

private let shaderSource = """
#include <metal_stdlib>
using namespace metal;

struct VertexIn {
    float x;
    float y;
    float value;
    float pad;
};

struct Uniforms {
    float centerX;
    float centerY;
    float scale;
    float width;
    float height;
    float vmin;
    float vmax;
    float pad;
};

struct VertexOut {
    float4 position [[position]];
    float value;
};

vertex VertexOut density_vertex(const device VertexIn *vertices [[buffer(0)]],
                                constant Uniforms &u [[buffer(1)]],
                                uint vid [[vertex_id]]) {
    VertexIn v = vertices[vid];
    float clipX = 2.0 * (v.x - u.centerX) * u.scale / u.width;
    float clipY = 2.0 * (v.y - u.centerY) * u.scale / u.height;
    return { float4(clipX, clipY, 0.0, 1.0), v.value };
}

fragment float4 density_fragment(VertexOut in [[stage_in]],
                                 constant Uniforms &u [[buffer(0)]]) {
    constexpr float3 palette[20] = {
        float3(0.000000, 1.000000, 1.000000),
        float3(0.145098, 1.000000, 0.764706),
        float3(0.270588, 1.000000, 0.576471),
        float3(0.384314, 1.000000, 0.423529),
        float3(0.482353, 1.000000, 0.298039),
        float3(0.580392, 1.000000, 0.200000),
        float3(0.670588, 1.000000, 0.121569),
        float3(0.760784, 1.000000, 0.062745),
        float3(0.850980, 1.000000, 0.023529),
        float3(0.949020, 1.000000, 0.003922),
        float3(1.000000, 0.949020, 0.003922),
        float3(1.000000, 0.850980, 0.023529),
        float3(1.000000, 0.760784, 0.062745),
        float3(1.000000, 0.670588, 0.121569),
        float3(1.000000, 0.580392, 0.200000),
        float3(1.000000, 0.482353, 0.298039),
        float3(1.000000, 0.384314, 0.423529),
        float3(1.000000, 0.270588, 0.576471),
        float3(1.000000, 0.145098, 0.764706),
        float3(1.000000, 0.000000, 1.000000)
    };
    float span = max(1.0e-30, u.vmax - u.vmin);
    float t = clamp((in.value - u.vmin) / span, 0.0, 1.0);
    int bin = min(19, int(t * 20.0));
    return float4(palette[bin], 1.0);
}
"""
