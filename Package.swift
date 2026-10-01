// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "SnagReporter",
    platforms: [.macOS(.v12)],
    products: [
        .library(name: "SnagReporter", targets: ["SnagReporter"])
    ],
    targets: [
        .target(
            name: "SnagReporter",
            resources: [.process("Resources")]
        ),
        .testTarget(
            name: "SnagReporterTests",
            dependencies: ["SnagReporter"]
        )
    ]
)
