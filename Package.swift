// swift-tools-version:5.9
import PackageDescription

// Vox is a macOS product, but the platform-independent half of the core
// (`VoxKit`) builds and tests anywhere so logic can be exercised in CI without
// a Mac. The macOS-only targets (`VoxCore`, `VoxCLI`, `VoxApp`) are added only
// when building on macOS.
#if os(macOS)
// Every target that imports `CWhisper` — directly, or transitively through
// `VoxCore` — has to be able to find whisper.h, or Swift fails to build the
// module whenever it is compiled without `VoxCore` in the same invocation
// (e.g. `make app` right after `make whisper` rewrote the headers).
// Relative paths resolve against the working directory of `swift build`, so
// all builds must be driven from the repo root (the Makefile always is).
let whisperHeaderSearchPath: [SwiftSetting] = [
    .unsafeFlags(["-Xcc", "-Ivendor/whisper.cpp/install/include"])
]

let macOSTargets: [Target] = [
    .systemLibrary(name: "CWhisper", path: "Sources/CWhisper"),
    .target(
        name: "VoxCore",
        dependencies: ["VoxKit", "CWhisper"],
        swiftSettings: whisperHeaderSearchPath,
        linkerSettings: [
            // `make whisper` (scripts/build-whisper.sh) installs a single
            // merged static archive here so this flag list never has to track
            // whisper.cpp's internal library split.
            .unsafeFlags(["-Lvendor/whisper.cpp/install/lib"]),
            .linkedLibrary("vox-whisper"),
            .linkedLibrary("c++"),
            .linkedFramework("Accelerate"),
            .linkedFramework("Metal"),
            .linkedFramework("MetalKit"),
            .linkedFramework("Foundation"),
        ]
    ),
    .executableTarget(
        name: "VoxCLI",
        dependencies: [
            "VoxCore",
            "VoxKit",
            .product(name: "ArgumentParser", package: "swift-argument-parser"),
        ],
        swiftSettings: whisperHeaderSearchPath
    ),
    .executableTarget(
        name: "VoxApp",
        dependencies: ["VoxCore", "VoxKit"],
        swiftSettings: whisperHeaderSearchPath
    ),
]
let macOSProducts: [Product] = [
    .executable(name: "vox", targets: ["VoxCLI"]),
    .executable(name: "VoxApp", targets: ["VoxApp"]),
]
#else
let macOSTargets: [Target] = []
let macOSProducts: [Product] = []
#endif

let package = Package(
    name: "Vox",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "VoxKit", targets: ["VoxKit"])
    ] + macOSProducts,
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0")
    ],
    targets: [
        .target(name: "VoxKit"),
        .testTarget(name: "VoxKitTests", dependencies: ["VoxKit"]),
    ] + macOSTargets
)
