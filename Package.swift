// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "keitop",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "keitop", targets: ["MacStatus"])
    ],
    targets: [
        .executableTarget(name: "MacStatus")
    ],
    swiftLanguageModes: [.v5]
)
