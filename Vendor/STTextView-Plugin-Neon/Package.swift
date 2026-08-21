// swift-tools-version: 5.10
//
// Local wrapper around STTextView-Plugin-Neon 0.8.1 (commit 5a30db4).
// Sources live in the `upstream` git submodule. See KERO.md.
//
// kero change vs upstream Package.swift:
// - Drop the remote STTextView dependency. kero already vendors a patched
//   STTextView at Vendor/STTextView; a second copy from
//   github.com/krzyzanowskim/STTextView shares the SwiftPM identity
//   `sttextview` and Xcode 27 crashes while resolving the graph.
// - Exclude the stock NeonPlugin / Coordinator / SystemInterface sources
//   (they are the only files that import STTextView). kero ships its own
//   highlighter in SyntaxHighlightPlugin.swift and only needs Theme plus
//   TreeSitterResource from this package.
// - Point every target at upstream/Sources/<name>.

import PackageDescription

let package = Package(
    name: "STTextView-Plugin-Neon",
    platforms: [.macOS(.v14), .iOS(.v16), .macCatalyst(.v16)],
    products: [
        .library(
            name: "STTextView-Plugin-Neon",
            targets: ["STPluginNeon"]),
    ],
    dependencies: [
        .package(url: "https://github.com/kylemacomber/Neon", revision: "ce8d252"),
        .package(url: "https://github.com/ChimeHQ/SwiftTreeSitter", from: "0.9.0")
    ],
    targets: [
        .target(
            name: "STPluginNeon",
            dependencies: [
                .target(name: "STPluginNeonAppKit", condition: .when(platforms: [.macOS])),
                .target(name: "STPluginNeonUIKit", condition: .when(platforms: [.iOS, .macCatalyst]))
            ],
            path: "upstream/Sources/STPluginNeon"
        ),
        .target(
            name: "STPluginNeonAppKit",
            dependencies: [
                .product(name: "Neon", package: "Neon"),
                .target(name: "TreeSitterResource")
            ],
            path: "upstream/Sources/STPluginNeonAppKit",
            exclude: [
                "Coordinator.swift",
                "NeonPlugin.swift",
                "STTextViewSystemInterface.swift"
            ],
            resources: [.process("Themes.xcassets")]
        ),
        .target(
            name: "STPluginNeonUIKit",
            dependencies: [
                .product(name: "Neon", package: "Neon"),
                .target(name: "TreeSitterResource")
            ],
            path: "upstream/Sources/STPluginNeonUIKit",
            exclude: [
                "Coordinator.swift",
                "NeonPlugin.swift",
                "STTextViewSystemInterface.swift"
            ],
            resources: [.process("Themes.xcassets")]
        ),
        .target(
            name: "TreeSitterResource",
            dependencies: [
                .product(name: "SwiftTreeSitter", package: "SwiftTreeSitter"),
                .target(name: "TreeSitterBash"),
                .target(name: "TreeSitterBashQueries"),
                .target(name: "TreeSitterC"),
                .target(name: "TreeSitterCQueries"),
                .target(name: "TreeSitterCPP"),
                .target(name: "TreeSitterCPPQueries"),
                .target(name: "TreeSitterCSharp"),
                .target(name: "TreeSitterCSharpQueries"),
                .target(name: "TreeSitterCSS"),
                .target(name: "TreeSitterCSSQueries"),
                .target(name: "TreeSitterGo"),
                .target(name: "TreeSitterGoQueries"),
                .target(name: "TreeSitterHTML"),
                .target(name: "TreeSitterHTMLQueries"),
                .target(name: "TreeSitterJava"),
                .target(name: "TreeSitterJavaQueries"),
                .target(name: "TreeSitterJavaScript"),
                .target(name: "TreeSitterJavaScriptQueries"),
                .target(name: "TreeSitterJSON"),
                .target(name: "TreeSitterJSONQueries"),
                .target(name: "TreeSitterMarkdown"),
                .target(name: "TreeSitterMarkdownQueries"),
                .target(name: "TreeSitterPHP"),
                .target(name: "TreeSitterPHPQueries"),
                .target(name: "TreeSitterPython"),
                .target(name: "TreeSitterPythonQueries"),
                .target(name: "TreeSitterRuby"),
                .target(name: "TreeSitterRubyQueries"),
                .target(name: "TreeSitterRust"),
                .target(name: "TreeSitterRustQueries"),
                .target(name: "TreeSitterSwift"),
                .target(name: "TreeSitterSwiftQueries"),
                .target(name: "TreeSitterSQL"),
                .target(name: "TreeSitterSQLQueries"),
                .target(name: "TreeSitterTOML"),
                .target(name: "TreeSitterTOMLQueries"),
                .target(name: "TreeSitterTypeScript"),
                .target(name: "TreeSitterTypeScriptQueries"),
                .target(name: "TreeSitterYAML"),
                .target(name: "TreeSitterYAMLQueries")
            ],
            path: "upstream/Sources/TreeSitterResource"
        ),
        .target(name: "TreeSitterBash", path: "upstream/Sources/TreeSitterBash", cSettings: [.headerSearchPath("src")]),
        .target(name: "TreeSitterBashQueries", path: "upstream/Sources/TreeSitterBashQueries", resources: [.copy("highlights.scm")]),
        .target(name: "TreeSitterC", path: "upstream/Sources/TreeSitterC", cSettings: [.headerSearchPath("src")]),
        .target(name: "TreeSitterCQueries", path: "upstream/Sources/TreeSitterCQueries", resources: [.copy("highlights.scm")]),
        .target(name: "TreeSitterCSharp", path: "upstream/Sources/TreeSitterCSharp", cSettings: [.headerSearchPath("src")]),
        .target(name: "TreeSitterCSharpQueries", path: "upstream/Sources/TreeSitterCSharpQueries", resources: [.copy("highlights.scm"), .copy("tags.scm")]),
        .target(name: "TreeSitterCPP", path: "upstream/Sources/TreeSitterCPP", cSettings: [.headerSearchPath("src")]),
        .target(name: "TreeSitterCPPQueries", path: "upstream/Sources/TreeSitterCPPQueries", resources: [.copy("highlights.scm")]),
        .target(name: "TreeSitterCSS", path: "upstream/Sources/TreeSitterCSS", cSettings: [.headerSearchPath("src")]),
        .target(name: "TreeSitterCSSQueries", path: "upstream/Sources/TreeSitterCSSQueries", resources: [.copy("highlights.scm")]),
        .target(name: "TreeSitterGo", path: "upstream/Sources/TreeSitterGo", cSettings: [.headerSearchPath("src")]),
        .target(name: "TreeSitterGoQueries", path: "upstream/Sources/TreeSitterGoQueries", resources: [.copy("highlights.scm"), .copy("tags.scm")]),
        .target(name: "TreeSitterHTML", path: "upstream/Sources/TreeSitterHTML", cSettings: [.headerSearchPath("src")]),
        .target(name: "TreeSitterHTMLQueries", path: "upstream/Sources/TreeSitterHTMLQueries", resources: [.copy("highlights.scm"), .copy("injections.scm")]),
        .target(name: "TreeSitterJava", path: "upstream/Sources/TreeSitterJava", cSettings: [.headerSearchPath("src")]),
        .target(name: "TreeSitterJavaQueries", path: "upstream/Sources/TreeSitterJavaQueries", resources: [.copy("highlights.scm"), .copy("tags.scm")]),
        .target(name: "TreeSitterJavaScript", path: "upstream/Sources/TreeSitterJavaScript", cSettings: [.headerSearchPath("src")]),
        .target(name: "TreeSitterJavaScriptQueries", path: "upstream/Sources/TreeSitterJavaScriptQueries", resources: [.copy("highlights-jsx.scm"), .copy("highlights-params.scm"), .copy("highlights.scm"), .copy("injections.scm"), .copy("locals.scm"), .copy("tags.scm")]),
        .target(name: "TreeSitterJSON", path: "upstream/Sources/TreeSitterJSON", cSettings: [.headerSearchPath("src")]),
        .target(name: "TreeSitterJSONQueries", path: "upstream/Sources/TreeSitterJSONQueries", resources: [.copy("highlights.scm")]),
        .target(name: "TreeSitterMarkdown", path: "upstream/Sources/TreeSitterMarkdown", cSettings: [.headerSearchPath("src")]),
        .target(name: "TreeSitterMarkdownQueries", path: "upstream/Sources/TreeSitterMarkdownQueries", resources: [.copy("highlights.scm"), .copy("injections.scm")]),
        .target(name: "TreeSitterPHP", path: "upstream/Sources/TreeSitterPHP", cSettings: [.headerSearchPath("src")]),
        .target(name: "TreeSitterPHPQueries", path: "upstream/Sources/TreeSitterPHPQueries", resources: [.copy("highlights.scm"), .copy("injections.scm"), .copy("tags.scm")]),
        .target(name: "TreeSitterPython", path: "upstream/Sources/TreeSitterPython", cSettings: [.headerSearchPath("src")]),
        .target(name: "TreeSitterPythonQueries", path: "upstream/Sources/TreeSitterPythonQueries", resources: [.copy("highlights.scm"), .copy("tags.scm")]),
        .target(name: "TreeSitterRuby", path: "upstream/Sources/TreeSitterRuby", cSettings: [.headerSearchPath("src")]),
        .target(name: "TreeSitterRubyQueries", path: "upstream/Sources/TreeSitterRubyQueries", resources: [.copy("highlights.scm"), .copy("locals.scm"), .copy("tags.scm")]),
        .target(name: "TreeSitterRust", path: "upstream/Sources/TreeSitterRust", cSettings: [.headerSearchPath("src")]),
        .target(name: "TreeSitterRustQueries", path: "upstream/Sources/TreeSitterRustQueries", resources: [.copy("highlights.scm"), .copy("injections.scm")]),
        .target(name: "TreeSitterSQL", path: "upstream/Sources/TreeSitterSQL", cSettings: [.headerSearchPath("src")]),
        .target(name: "TreeSitterSQLQueries", path: "upstream/Sources/TreeSitterSQLQueries", resources: [.copy("highlights.scm")]),
        .target(name: "TreeSitterSwift", path: "upstream/Sources/TreeSitterSwift", cSettings: [.headerSearchPath("src")]),
        .target(name: "TreeSitterSwiftQueries", path: "upstream/Sources/TreeSitterSwiftQueries", resources: [.copy("highlights.scm"), .copy("locals.scm")]),
        .target(name: "TreeSitterTOML", path: "upstream/Sources/TreeSitterTOML", cSettings: [.headerSearchPath("src")]),
        .target(name: "TreeSitterTOMLQueries", path: "upstream/Sources/TreeSitterTOMLQueries", resources: [.copy("highlights.scm")]),
        .target(name: "TreeSitterTypeScript", path: "upstream/Sources/TreeSitterTypeScript", cSettings: [.headerSearchPath("src")]),
        .target(name: "TreeSitterTypeScriptQueries", path: "upstream/Sources/TreeSitterTypeScriptQueries", resources: [.copy("highlights.scm"), .copy("locals.scm"), .copy("tags.scm")]),
        .target(name: "TreeSitterYAML", path: "upstream/Sources/TreeSitterYAML", exclude: ["src/schema.generated.cc"], cSettings: [.headerSearchPath("src")]),
        .target(name: "TreeSitterYAMLQueries", path: "upstream/Sources/TreeSitterYAMLQueries", resources: [.copy("highlights.scm")]),
    ]
)
