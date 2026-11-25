// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ICloudPhotos",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ICloudKit", targets: ["ICloudKit"]),
        .executable(name: "ICloudPhotos", targets: ["ICloudPhotosApp"]),
    ],
    targets: [
        // Native Swift port of the parts of icloudpd / pyicloud_ipd the app needs.
        // No third-party dependencies: CryptoKit on Apple platforms, a small
        // built-in SHA-256 elsewhere (only used so the tests run on Linux CI).
        .target(name: "ICloudKit"),
        .executableTarget(name: "ICloudPhotosApp", dependencies: ["ICloudKit"]),
        .testTarget(
            name: "ICloudKitTests",
            dependencies: ["ICloudKit"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
