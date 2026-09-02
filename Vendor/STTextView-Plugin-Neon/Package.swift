// swift-tools-version: 5.10
//
// Local wrapper around STTextView-Plugin-Neon 0.8.1 (commit 5a30db4).
// Sources are copied into Sources/ — there is no nested Package.swift.
// See KERO.md.
//
// kero change vs upstream Package.swift:
// - Drop the remote STTextView dependency. kero already vendors a patched
//   STTextView at Vendor/STTextView; a second copy from
//   github.com/krzyzanowskim/STTextView shares the SwiftPM identity
//   `sttextview` and Xcode 27 crashes while resolving the graph.
// - Do not vendor upstream's own Package.swift. Xcode 27 indexes every
//   Package.swift under the project and then abort-traps in
//   IDESwiftPackageCore (12 file refs vs 11 pins) when a nested
//   manifest is present. A full-repo submodule of Plugin-Neon is the
//   extra manifest that killed Release #3 after the identity fix.
// - Do not copy the stock NeonPlugin / Coordinator / SystemInterface
//   sources (they are the only files that import STTextView). kero ships
//   its own highlighter in SyntaxHighlightPlugin.swift and only needs
//   Theme plus TreeSitterResource from this package. Do not list those
//   missing files in `exclude:` — Xcode warns "Invalid Exclude" when the
//   path is not on disk. If they get re-copied, the build fails because
//   this package has no STTextView dependency.

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
        .package(path: "../Neon"),
        .package(url: "https://github.com/ChimeHQ/SwiftTreeSitter", from: "0.9.0")
    ],
    targets: [
        .target(
            name: "STPluginNeon",
            dependencies: [
                .target(name: "STPluginNeonAppKit", condition: .when(platforms: [.macOS])),
                .target(name: "STPluginNeonUIKit", condition: .when(platforms: [.iOS, .macCatalyst]))
            ],
            path: "Sources/STPluginNeon"
        ),
        .target(
            name: "STPluginNeonAppKit",
            dependencies: [
                .product(name: "Neon", package: "Neon"),
                .target(name: "TreeSitterResource")
            ],
            path: "Sources/STPluginNeonAppKit",
            resources: [.process("Themes.xcassets")]
        ),
        .target(
            name: "STPluginNeonUIKit",
            dependencies: [
                .product(name: "Neon", package: "Neon"),
                .target(name: "TreeSitterResource")
            ],
            path: "Sources/STPluginNeonUIKit",
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
            path: "Sources/TreeSitterResource"
        ),
        .target(name: "TreeSitterBash", path: "Sources/TreeSitterBash", cSettings: [.headerSearchPath("src")]),
        .target(name: "TreeSitterBashQueries", path: "Sources/TreeSitterBashQueries", resources: [.copy("highlights.scm")]),
        .target(name: "TreeSitterC", path: "Sources/TreeSitterC", cSettings: [.headerSearchPath("src")]),
        .target(name: "TreeSitterCQueries", path: "Sources/TreeSitterCQueries", resources: [.copy("highlights.scm")]),
        .target(name: "TreeSitterCSharp", path: "Sources/TreeSitterCSharp", cSettings: [.headerSearchPath("src")]),
        .target(name: "TreeSitterCSharpQueries", path: "Sources/TreeSitterCSharpQueries", resources: [.copy("highlights.scm"), .copy("tags.scm")]),
        .target(name: "TreeSitterCPP", path: "Sources/TreeSitterCPP", cSettings: [.headerSearchPath("src")]),
        .target(name: "TreeSitterCPPQueries", path: "Sources/TreeSitterCPPQueries", resources: [.copy("highlights.scm")]),
        .target(name: "TreeSitterCSS", path: "Sources/TreeSitterCSS", cSettings: [.headerSearchPath("src")]),
        .target(name: "TreeSitterCSSQueries", path: "Sources/TreeSitterCSSQueries", resources: [.copy("highlights.scm")]),
        .target(name: "TreeSitterGo", path: "Sources/TreeSitterGo", cSettings: [.headerSearchPath("src")]),
        .target(name: "TreeSitterGoQueries", path: "Sources/TreeSitterGoQueries", resources: [.copy("highlights.scm"), .copy("tags.scm")]),
        .target(name: "TreeSitterHTML", path: "Sources/TreeSitterHTML", cSettings: [.headerSearchPath("src")]),
        .target(name: "TreeSitterHTMLQueries", path: "Sources/TreeSitterHTMLQueries", resources: [.copy("highlights.scm"), .copy("injections.scm")]),
        .target(name: "TreeSitterJava", path: "Sources/TreeSitterJava", cSettings: [.headerSearchPath("src")]),
        .target(name: "TreeSitterJavaQueries", path: "Sources/TreeSitterJavaQueries", resources: [.copy("highlights.scm"), .copy("tags.scm")]),
        .target(name: "TreeSitterJavaScript", path: "Sources/TreeSitterJavaScript", cSettings: [.headerSearchPath("src")]),
        .target(name: "TreeSitterJavaScriptQueries", path: "Sources/TreeSitterJavaScriptQueries", resources: [.copy("highlights-jsx.scm"), .copy("highlights-params.scm"), .copy("highlights.scm"), .copy("injections.scm"), .copy("locals.scm"), .copy("tags.scm")]),
        .target(name: "TreeSitterJSON", path: "Sources/TreeSitterJSON", cSettings: [.headerSearchPath("src")]),
        .target(name: "TreeSitterJSONQueries", path: "Sources/TreeSitterJSONQueries", resources: [.copy("highlights.scm")]),
        .target(name: "TreeSitterMarkdown", path: "Sources/TreeSitterMarkdown", cSettings: [.headerSearchPath("src")]),
        .target(name: "TreeSitterMarkdownQueries", path: "Sources/TreeSitterMarkdownQueries", resources: [.copy("highlights.scm"), .copy("injections.scm")]),
        .target(name: "TreeSitterPHP", path: "Sources/TreeSitterPHP", cSettings: [.headerSearchPath("src")]),
        .target(name: "TreeSitterPHPQueries", path: "Sources/TreeSitterPHPQueries", resources: [.copy("highlights.scm"), .copy("injections.scm"), .copy("tags.scm")]),
        .target(name: "TreeSitterPython", path: "Sources/TreeSitterPython", cSettings: [.headerSearchPath("src")]),
        .target(name: "TreeSitterPythonQueries", path: "Sources/TreeSitterPythonQueries", resources: [.copy("highlights.scm"), .copy("tags.scm")]),
        .target(name: "TreeSitterRuby", path: "Sources/TreeSitterRuby", cSettings: [.headerSearchPath("src")]),
        .target(name: "TreeSitterRubyQueries", path: "Sources/TreeSitterRubyQueries", resources: [.copy("highlights.scm"), .copy("locals.scm"), .copy("tags.scm")]),
        .target(name: "TreeSitterRust", path: "Sources/TreeSitterRust", cSettings: [.headerSearchPath("src")]),
        .target(name: "TreeSitterRustQueries", path: "Sources/TreeSitterRustQueries", resources: [.copy("highlights.scm"), .copy("injections.scm")]),
        .target(name: "TreeSitterSQL", path: "Sources/TreeSitterSQL", cSettings: [.headerSearchPath("src")]),
        .target(name: "TreeSitterSQLQueries", path: "Sources/TreeSitterSQLQueries", resources: [.copy("highlights.scm")]),
        .target(name: "TreeSitterSwift", path: "Sources/TreeSitterSwift", cSettings: [.headerSearchPath("src")]),
        .target(name: "TreeSitterSwiftQueries", path: "Sources/TreeSitterSwiftQueries", resources: [.copy("highlights.scm"), .copy("locals.scm")]),
        .target(name: "TreeSitterTOML", path: "Sources/TreeSitterTOML", cSettings: [.headerSearchPath("src")]),
        .target(name: "TreeSitterTOMLQueries", path: "Sources/TreeSitterTOMLQueries", resources: [.copy("highlights.scm")]),
        .target(name: "TreeSitterTypeScript", path: "Sources/TreeSitterTypeScript", cSettings: [.headerSearchPath("src")]),
        .target(name: "TreeSitterTypeScriptQueries", path: "Sources/TreeSitterTypeScriptQueries", resources: [.copy("highlights.scm"), .copy("locals.scm"), .copy("tags.scm")]),
        .target(name: "TreeSitterYAML", path: "Sources/TreeSitterYAML", exclude: ["src/schema.generated.cc"], cSettings: [.headerSearchPath("src")]),
        .target(name: "TreeSitterYAMLQueries", path: "Sources/TreeSitterYAMLQueries", resources: [.copy("highlights.scm")]),
    ]
)
