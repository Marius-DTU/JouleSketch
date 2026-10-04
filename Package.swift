// swift-tools-version:6.0

import PackageDescription

/// The web (Windows) version of JouleSketch: the shared Swift files of the
/// Mac app, compiled to WebAssembly, plus a small bridge to JavaScript.
///
/// The shared files are listed here and live in `JouleSketch/`, so a fix in
/// one of them reaches both versions. The Mac app itself is built with the
/// Xcode project as before; this package isn't used by it.
///
/// Build with `Web/build.sh` (see `Web/README.md`).
let sharedFiles = [
    "Circuit.swift",
    "CircuitSolver.swift",
    "CircuitEditor.swift",
    "KeyBindings.swift",
    "MapleExporter.swift",
    "MapleMathML.swift",
    "MathLatex.swift",
    "MeshWalkthrough.swift",
    "NodalWalkthrough.swift",
    "SchematicScene.swift",
    "SheetInteraction.swift",
    "UserGuide.swift",
    "Walkthrough.swift",
].map { "JouleSketch/\($0)" }

let package = Package(
    name: "JouleSketchWeb",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/swiftwasm/JavaScriptKit.git", from: "0.59.0"),
    ],
    targets: [
        .executableTarget(
            name: "JouleWeb",
            dependencies: ["JavaScriptKit"],
            path: ".",
            sources: sharedFiles + ["Web/Bridge"],
            swiftSettings: [
                .enableExperimentalFeature("Extern"),
                .enableUpcomingFeature("MemberImportVisibility"),
                .swiftLanguageMode(.v5),
            ],
            plugins: [
                .plugin(name: "BridgeJS", package: "JavaScriptKit"),
            ]
        ),
    ]
)
