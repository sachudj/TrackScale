// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TrackScale",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "TrackScale", targets: ["TrackScale"])
    ],
    dependencies: [
        .package(url: "https://github.com/krishkrosh/OpenMultitouchSupport.git", from: "1.0.0")
    ],
    targets: [
        .executableTarget(
            name: "TrackScale",
            dependencies: [
                .product(name: "OpenMultitouchSupport", package: "OpenMultitouchSupport")
            ]
        )
    ]
)
