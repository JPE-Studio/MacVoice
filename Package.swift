// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MacVoice",
    targets: [
        .systemLibrary(name: "Ccactus", path: "Sources/Ccactus"),
        .executableTarget(
            name: "MacVoice",
            dependencies: ["Ccactus"],
            path: "Sources/MacVoice",
            linkerSettings: [
                .unsafeFlags(["-Lmacos-arm64"]),
                .linkedLibrary("c++")
            ]
        )
    ]
)
