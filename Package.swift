// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ExtraMagicMouse",
    platforms: [.macOS(.v13)],
    targets: [
        // Thin C shim over Apple's private MultitouchSupport.framework
        // (loaded at runtime with dlopen, so nothing private is linked).
        .target(
            name: "CMultitouch",
            linkerSettings: [.linkedFramework("CoreFoundation"), .linkedFramework("CoreGraphics")]
        ),
        .executableTarget(
            name: "ExtraMagicMouse",
            dependencies: ["CMultitouch"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("Carbon"),
                .linkedFramework("ServiceManagement"),
            ]
        ),
    ]
)
