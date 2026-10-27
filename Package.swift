// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Wakeful",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "Wakeful",
            path: "Sources/Wakeful",
            linkerSettings: [.linkedFramework("IOKit"), .linkedFramework("ServiceManagement"),
                             .linkedFramework("DiskArbitration"), .linkedFramework("CoreAudio")]
        ),
        .testTarget(
            name: "WakefulTests",
            dependencies: ["Wakeful"],
            path: "Tests/WakefulTests"
        ),
    ]
)
