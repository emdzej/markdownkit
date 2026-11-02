// swift-tools-version: 5.9
import PackageDescription

// MarkdownKit — a TextKit 2 Markdown editor for macOS and iOS / iPadOS.
// The modules keep their MarkdownEngine names.
//
// To produce a dynamic `MarkdownEngine` product (needed so consumers'
// binaries don't end up with statically-merged SwiftUI/SwiftUICore symbol
// references that trip Xcode 26's strict allowable_clients validation),
// the implementation lives in target `MarkdownEngineCore` and the
// publicly-imported `MarkdownEngine` target is a thin
// `@_exported import MarkdownEngineCore` wrapper.
//
// Embedders continue to `import MarkdownEngine` exactly as before.
let package = Package(
    name: "MarkdownKit",
    defaultLocalization: "en",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "MarkdownEngine", type: .dynamic, targets: ["MarkdownEngine"]),
        .library(name: "MarkdownEngineCodeBlocks", type: .dynamic, targets: ["MarkdownEngineCodeBlocks"]),
        .library(name: "MarkdownEngineLatex", type: .dynamic, targets: ["MarkdownEngineLatex"]),
    ],
    dependencies: [
        .package(url: "https://github.com/smittytone/HighlighterSwift", from: "3.0.0"),
        .package(url: "https://github.com/mgriebling/SwiftMath", from: "1.7.0"),
    ],
    targets: [
        .target(name: "MarkdownEngineCore", resources: [.process("Resources")]),
        .target(
            name: "MarkdownEngine",
            dependencies: ["MarkdownEngineCore"]
        ),
        .target(
            name: "MarkdownEngineCodeBlocks",
            dependencies: [
                "MarkdownEngineCore",
                .product(name: "Highlighter", package: "HighlighterSwift"),
            ]
        ),
        .target(
            name: "MarkdownEngineLatex",
            dependencies: [
                "MarkdownEngineCore",
                .product(name: "SwiftMath", package: "SwiftMath"),
            ]
        ),
        .testTarget(
            name: "MarkdownEngineTests",
            dependencies: ["MarkdownEngineCore"]
        )
    ]
)
