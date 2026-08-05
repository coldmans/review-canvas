// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "ReviewCanvasCore",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
    ],
    products: [
        .library(name: "ReviewCanvasCore", targets: ["ReviewCanvasCore"]),
    ],
    targets: [
        .target(name: "ReviewCanvasCore"),
        .testTarget(
            name: "ReviewCanvasCoreTests",
            dependencies: ["ReviewCanvasCore"]
        ),
    ]
)
