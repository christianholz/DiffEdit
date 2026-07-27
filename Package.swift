// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "DiffEdit",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "DiffEdit", targets: ["DiffEdit"])
    ],
    targets: [
        .executableTarget(name: "DiffEdit"),
        .testTarget(name: "DiffEditTests", dependencies: ["DiffEdit"])
    ]
)
