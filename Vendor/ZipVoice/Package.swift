// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ZipVoice",
    platforms: [.iOS(.v15)],
    products: [.library(name: "ZipVoiceBridge", targets: ["ZipVoiceBridge"])],
    targets: [
        // Upstream v2.0.3 iOS shared framework with ONNX Runtime linked statically.
        // SHA-256: 6e35088e42c7ccbacea6377d198cca5e0e05262b11f17c9225af445a5bbb5c5e
        .binaryTarget(name: "SherpaOnnxC", path: "SherpaOnnxC.xcframework.zip"),
        .target(name: "ZipVoiceBridge", dependencies: ["SherpaOnnxC"])
    ]
)
