// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Geotag",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Geotag", targets: ["GeotagApp"]),
    ],
    targets: [
        .target(name: "GeotagCore"),
        .target(name: "GeotagUI", dependencies: ["GeotagCore"]),
        .executableTarget(name: "GeotagApp", dependencies: ["GeotagCore", "GeotagUI"]),
    ]
)
