// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Kiosk",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "Kiosk", targets: ["Kiosk"])],
    targets: [
        .target(name: "KioskCore"),
        .executableTarget(name: "Kiosk", dependencies: ["KioskCore"]),
        .testTarget(name: "KioskCoreTests", dependencies: ["KioskCore"])
    ]
)
