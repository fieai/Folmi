// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Folmi",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "FolmiCore", targets: ["FolmiCore"]),
        .executable(name: "Folmi", targets: ["Folmi"]),
        .executable(name: "folmi-hook", targets: ["FolmiHook"])
    ],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", exact: "1.19.0")
    ],
    targets: [
        .target(name: "FolmiCore"),
        // ReaderAssets: KaTeX and Mermaid for the Markdown reader, served locally (no network at runtime).
        // Fonts: Fusion Pixel (OFL-1.1), used only by the 像素 theme.
        .executableTarget(name: "Folmi", dependencies: ["FolmiCore", .product(name: "SwiftTerm", package: "SwiftTerm")],
                          resources: [.copy("Resources/ReaderAssets"), .copy("Resources/Fonts"), .copy("Resources/Brand")]),
        .executableTarget(name: "FolmiHook", dependencies: ["FolmiCore"]),
        // Tests drive AppKit views and fixtures from synchronous XCTest methods; they stay in Swift 5 mode.
        .testTarget(name: "FolmiCoreTests", dependencies: ["FolmiCore"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "FolmiTests", dependencies: ["Folmi", "FolmiCore"], swiftSettings: [.swiftLanguageMode(.v5)])
    ],
    // The app, Core and the hook build in Swift 6 mode: a possible data race is a compile error, not a warning.
    swiftLanguageModes: [.v6]
)
