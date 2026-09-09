// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "FanControl",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "fand", targets: ["fand"]),
        .executable(name: "fanctl", targets: ["fanctl"]),
        .executable(name: "FanMenu", targets: ["FanMenu"]),
    ],
    targets: [
        .target(name: "SMCCore"),
        .executableTarget(name: "fand", dependencies: ["SMCCore"]),
        .executableTarget(name: "fanctl", dependencies: ["SMCCore"]),
        .executableTarget(
            name: "FanMenu",
            dependencies: ["SMCCore"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ServiceManagement"),
            ]
        ),
    ]
)
