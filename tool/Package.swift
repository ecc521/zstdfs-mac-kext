// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "zstdfs",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0"),
    ],
    targets: [
        .systemLibrary(
            name: "CZstd",
            path: "Sources/CZstd",
            pkgConfig: "libzstd",
            providers: [.brew(["zstd"])]
        ),
        .executableTarget(
            name: "zstdfs",
            dependencies: [
                "CZstd",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Sources/zstdfs"
        ),
    ]
)
