// swift-tools-version:5.7
import PackageDescription

let package = Package(
    name: "CalendarMirrorMenuBar",
    platforms: [.macOS(.v12)],
    targets: [
        .executableTarget(
            name: "CalendarMirrorMenuBar",
            path: "Sources/CalendarMirrorMenuBar"
        )
    ]
)
