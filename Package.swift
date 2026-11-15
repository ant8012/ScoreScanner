// swift-tools-version: 6.0
import PackageDescription

// ScannerCore reads a score image or PDF into MusicXML: the notes on the device with copisteria (copista-2m, ONNX),
// chord names on the device too (a chord finder and a fine-tuned PP-OCRv6 recogniser, ONNX), and the title,
// composer, tempo and staff text on the device with the standard PP-OCRv6 recogniser (or with Apple's model on
// Private Cloud Compute, when asked). The ScoreScanner app in this repository and Aria both use it.
let package = Package(
    name: "ScoreScanner",
    platforms: [.iOS(.v16), .macOS(.v14)],
    products: [
        .library(name: "ScannerCore", targets: ["ScannerCore"])
    ],
    targets: [
        // Official Microsoft binary and Objective-C bindings, pinned in Vendor/onnxruntime/UPSTREAM.json.
        .binaryTarget(
            name: "onnxruntime",
            url: "https://download.onnxruntime.ai/pod-archive-onnxruntime-c-1.27.0.zip",
            checksum: "8c74edd600eafc3055de9e8f7a9602afee44ed516913cb5e132bca02cc34622c"),
        .target(
            name: "OnnxRuntimeBindings", dependencies: ["onnxruntime"],
            cxxSettings: [.define("SPM_BUILD")]),
        .target(
            name: "ScannerCore", dependencies: ["OnnxRuntimeBindings"],
            resources: [.copy("Resources/Models")]),
        // Command-line reads on the Mac: `swift run -c release ScannerCheck --scan-pdf <pdf> <models> <output>`.
        .executableTarget(name: "ScannerCheck", dependencies: ["ScannerCore"]),
        .testTarget(name: "ScannerCoreTests", dependencies: ["ScannerCore"]),
    ],
    cxxLanguageStandard: .cxx17
)
