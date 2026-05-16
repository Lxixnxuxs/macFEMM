// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "macFEMM",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "macFEMM", targets: ["macFEMM"])
    ],
    targets: [
        .target(
            name: "FemmCore",
            path: "Sources/FemmCore",
            publicHeadersPath: "include",
            linkerSettings: [
                .unsafeFlags([
                    "-L../build/libfemm_core",
                    "-lfemm_core",
                    "-lc++",
                ])
            ]
        ),
        .executableTarget(
            name: "macFEMM",
            dependencies: ["FemmCore"],
            path: "Sources/macFEMM",
            resources: [
                .process("Resources")
            ]
        ),
    ],
    cxxLanguageStandard: .cxx17
)
