import Foundation
import FemmCore

struct PropertyLibraryPreset: Codable, Identifiable {
    let id: String
    let physics: String
    let kind: String
    let name: String
    let summary: String
    let values: [String: Double]
}

enum PropertyLibraryStore {
    static func presets(for physics: Physics, category: PropCategory) -> [PropertyLibraryPreset] {
        allPresets.filter { $0.physics == physics.libraryKey && $0.kind == category.libraryKey }
    }

    static let allPresets: [PropertyLibraryPreset] = {
        guard let url = Bundle.module.url(forResource: "default_property_library", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let presets = try? JSONDecoder().decode([PropertyLibraryPreset].self, from: data)
        else { return [] }
        return presets
    }()
}

extension Physics {
    var libraryKey: String {
        switch self {
        case .magnetics: return "magnetics"
        case .electrostatics: return "electrostatics"
        case .heat: return "heat"
        case .current: return "current"
        }
    }
}

extension PropCategory {
    var libraryKey: String {
        switch self {
        case .materials: return "materials"
        case .boundaries: return "boundaries"
        case .pointProps: return "pointProps"
        case .circuits: return "circuits"
        }
    }

    var symbol: String {
        switch self {
        case .materials: return "shippingbox"
        case .boundaries: return "line.3.horizontal"
        case .pointProps: return "smallcircle.filled.circle"
        case .circuits: return "bolt"
        }
    }
}

extension FemmDocument {
    func importPreset(_ preset: PropertyLibraryPreset) {
        guard let h = raw else { return }
        let name = uniqueName(preset.name, for: preset.kind)
        switch (snapshot.physics, preset.kind) {
        case (.magnetics, "materials"):
            name.withCString { cName in
                var s = femm_mag_material_t(
                    name: cName,
                    mu_x: preset.double("muX", 1),
                    mu_y: preset.double("muY", 1),
                    H_c: preset.double("hC", 0),
                    theta_m: preset.double("thetaM", 0),
                    J_src: femm_complex_t(re: preset.double("jRe", 0), im: preset.double("jIm", 0)),
                    c_duct: preset.double("sigma", 0),
                    lam_d: preset.double("lamD", 0),
                    theta_hn: 0,
                    theta_hx: 0,
                    theta_hy: 0,
                    lam_type: Int32(preset.double("lamType", 0)),
                    lam_fill: preset.double("lamFill", 1),
                    n_strands: Int32(preset.double("nStrands", 0)),
                    wire_d: preset.double("wireD", 0))
                _ = femm_mag_add_material(h, &s)
            }
        case (.magnetics, "boundaries"):
            name.withCString { cName in
                var s = femm_mag_boundary_t(
                    name: cName,
                    bdry_format: Int32(preset.double("format", 0)),
                    A0: preset.double("A0", 0),
                    A1: preset.double("A1", 0),
                    A2: preset.double("A2", 0),
                    phi: preset.double("phi", 0),
                    c0: femm_complex_t(re: preset.double("c0Re", 0), im: preset.double("c0Im", 0)),
                    c1: femm_complex_t(re: preset.double("c1Re", 0), im: preset.double("c1Im", 0)),
                    mu: preset.double("mu", 0),
                    sig: preset.double("sig", 0),
                    inner_angle: preset.double("innerAngle", 0),
                    outer_angle: preset.double("outerAngle", 0))
                _ = femm_mag_add_boundary(h, &s)
            }
        case (.electrostatics, "materials"):
            name.withCString { cName in
                var s = femm_es_material_t(
                    name: cName,
                    ex: preset.double("ex", 1),
                    ey: preset.double("ey", 1),
                    qv: preset.double("qv", 0))
                _ = femm_es_add_material(h, &s)
            }
        case (.electrostatics, "boundaries"):
            name.withCString { cName in
                var s = femm_es_boundary_t(
                    name: cName,
                    bdry_format: Int32(preset.double("format", 0)),
                    V: preset.double("V", 0),
                    qs: preset.double("qs", 0),
                    c0: preset.double("c0", 0),
                    c1: preset.double("c1", 0))
                _ = femm_es_add_boundary(h, &s)
            }
        case (.heat, "materials"):
            name.withCString { cName in
                var s = femm_heat_material_t(
                    name: cName,
                    Kx: preset.double("Kx", 1),
                    Ky: preset.double("Ky", 1),
                    Kt: preset.double("Kt", 0),
                    qv: preset.double("qv", 0))
                _ = femm_heat_add_material(h, &s)
            }
        case (.heat, "boundaries"):
            name.withCString { cName in
                var s = femm_heat_boundary_t(
                    name: cName,
                    bdry_format: Int32(preset.double("format", 0)),
                    Tset: preset.double("Tset", 0),
                    qs: preset.double("qs", 0),
                    beta: preset.double("beta", 0),
                    h: preset.double("h", 0),
                    Tinf: preset.double("Tinf", 0),
                    TinfRad: preset.double("TinfRad", 0))
                _ = femm_heat_add_boundary(h, &s)
            }
        case (.current, "materials"):
            name.withCString { cName in
                var s = femm_curr_material_t(
                    name: cName,
                    ox: preset.double("ox", 1),
                    oy: preset.double("oy", 1),
                    ex: preset.double("ex", 1),
                    ey: preset.double("ey", 1),
                    ltx: preset.double("ltx", 0),
                    lty: preset.double("lty", 0))
                _ = femm_curr_add_material(h, &s)
            }
        case (.current, "boundaries"):
            name.withCString { cName in
                var s = femm_curr_boundary_t(
                    name: cName,
                    bdry_format: Int32(preset.double("format", 0)),
                    Vs: femm_complex_t(re: preset.double("vsRe", 0), im: preset.double("vsIm", 0)),
                    qs: femm_complex_t(re: preset.double("qsRe", 0), im: preset.double("qsIm", 0)),
                    c0: femm_complex_t(re: preset.double("c0Re", 0), im: preset.double("c0Im", 0)),
                    c1: femm_complex_t(re: preset.double("c1Re", 0), im: preset.double("c1Im", 0)))
                _ = femm_curr_add_boundary(h, &s)
            }
        default:
            return
        }
        markDirtyAndReload()
    }

    private func uniqueName(_ base: String, for kind: String) -> String {
        let existing: Set<String>
        switch kind {
        case "materials": existing = Set(snapshot.materials.map(\.name))
        case "boundaries": existing = Set(snapshot.boundaries.map(\.name))
        case "pointProps": existing = Set(snapshot.pointProps.map(\.name))
        case "circuits": existing = Set(snapshot.circuits.map(\.name))
        default: existing = []
        }
        guard existing.contains(base) else { return base }
        var n = 2
        while existing.contains("\(base) \(n)") { n += 1 }
        return "\(base) \(n)"
    }
}

private extension PropertyLibraryPreset {
    func double(_ key: String, _ fallback: Double) -> Double {
        values[key] ?? fallback
    }
}
