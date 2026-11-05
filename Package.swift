// swift-tools-version: 6.1
import PackageDescription

// The engine is built with C++ interop (llama.cpp, marisa); importers must match.
let cxx: [SwiftSetting] = [.interoperabilityMode(.Cxx)]

let package = Package(
    name: "Hayate",
    platforms: [.macOS(.v14)],
    dependencies: [
        // Pinned: engine internals change often.
        .package(
            url: "https://github.com/azooKey/AzooKeyKanaKanjiConverter",
            revision: "25a6346bf76931c1cf2214015b808875ea82f4bf",
            traits: ["Zenzai"]
        ),
    ],
    targets: [
        .target(
            name: "HayateCore",
            dependencies: [.product(name: "KanaKanjiConverterModule", package: "AzooKeyKanaKanjiConverter")],
            swiftSettings: cxx
        ),
        .executableTarget(
            name: "Hayate",
            dependencies: ["HayateCore"],
            swiftSettings: cxx,
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),
        .executableTarget(name: "bench", dependencies: ["HayateCore"], swiftSettings: cxx),
    ],
    swiftLanguageModes: [.v5]
)
