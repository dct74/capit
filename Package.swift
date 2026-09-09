// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Capit",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "Capit",
            path: "Sources/Capit"
        )
    ]
)
