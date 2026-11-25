// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Squeaky",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "SqueakyCore", targets: ["SqueakyCore"]),
        .library(name: "SqueakyUI", targets: ["SqueakyUI"]),
        .executable(name: "SelfTest", targets: ["SelfTest"]),
    ],
    targets: [
        .target(name: "SqueakyCore"),
        .target(name: "SqueakyUI", dependencies: ["SqueakyCore"]),
        .executableTarget(name: "SelfTest", dependencies: ["SqueakyCore"]),
    ]
)
