// swift-tools-version:5.9
import PackageDescription
let package = Package(
    name: "Mandarina",
    platforms: [.macOS(.v14)],
    targets: [.executableTarget(name: "Mandarina", path: "Sources")]
)
