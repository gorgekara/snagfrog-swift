// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "StareGlareReporter",
    platforms: [.macOS(.v12), .iOS(.v15)],
    products: [
        .library(name: "StareGlareReporter", targets: ["StareGlareReporter"]),
        // Deprecated: the name before the StareGlare rename. Re-exports StareGlareReporter.
        .library(name: "SnagReporter", targets: ["SnagReporter"])
    ],
    targets: [
        .target(
            name: "StareGlareReporter",
            resources: [.process("Resources")]
        ),
        .target(
            name: "SnagReporter",
            dependencies: ["StareGlareReporter"]
        ),
        .testTarget(
            name: "StareGlareReporterTests",
            dependencies: ["StareGlareReporter", "SnagReporter"]
        )
    ]
)
