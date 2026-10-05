// swift-tools-version:5.9
import Foundation
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
// Paths are absolute, anchored on this manifest: the default (swiftbuild)
// build system runs the compiler from the package's parent directory, so a
// relative `-Ivendor/...` silently misses the headers there.
let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
let whisperInstall = packageRoot + "/vendor/whisper.cpp/install"
let whisperHeaderSearchPath: [SwiftSetting] = [
    .unsafeFlags(["-Xcc", "-I" + whisperInstall + "/include"])
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
            .unsafeFlags(["-L" + whisperInstall + "/lib"]),
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
