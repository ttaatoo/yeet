# Why kero vendors STTextView-Plugin-Neon

This directory is a **local Swift package** that wraps upstream
[STTextView-Plugin-Neon](https://github.com/krzyzanowskim/STTextView-Plugin-Neon)
commit `5a30db4` (the revision `yeet.xcodeproj` used to pin as a remote
package). `Sources/` is a copy of the modules kero actually imports.
`Package.swift` is ours. There is no git submodule and no second
`Package.swift` in this tree.

## Why this is local

kero vendors a patched [STTextView](../STTextView/KERO_PATCHES.md) as
`Vendor/STTextView`. SwiftPM's identity for that path is `sttextview`.

Upstream Plugin-Neon depends on `https://github.com/krzyzanowskim/STTextView`,
whose identity is also `sttextview`. Xcode 26 treated the local package as an
override and resolved the graph. Xcode 27 reports a conflicting identity and
then aborts during Resolve Package Graph:

```
Conflicting identity for sttextview: dependency
'github.com/krzyzanowskim/sttextview' and dependency '.../vendor/sttextview'
both point to the same package identity 'sttextview'.

Uncaught Exception: *** -[NSMutableArray insertObjects:atIndexes:]:
count of array (12) differs from count of index set (11)
```

That crash is what killed Release #2 (`scripts/package.sh` / `xcodebuild`
exit 134) on the `xcode-27` runner. There is no SwiftPM overlay that lets a
remote package consume our patched tree, so Plugin-Neon has to be local too.

## Why Sources/ are copied (no submodule)

PR #6 made this a local package and pointed targets at a full-repo git
submodule (`Vendor/STTextView-Plugin-Neon/upstream` @ `5a30db4`). Our
wrapper dropped the remote STTextView dependency, so Resolve Package Graph
finished (Release #3 fetched Neon, FuzzyMatch, Sparkle, STTextKitPlus; no
`Conflicting identity for sttextview`). Then Xcode 27 still abort-trapped
in `IDESwiftPackageCore` `DependencyPackagesGroup.sortedInsert` (12 file
refs vs 11 pins).

That off-by-one happens when Xcode indexes more `Package.swift` manifests
than `Package.resolved` pins. The extra manifest was upstream's own
`upstream/Package.swift`, which still depends on
`https://github.com/krzyzanowskim/STTextView`. Copying only `Sources/`
(and theme assets) means Xcode sees exactly one Plugin-Neon manifest: ours.

Do not re-add a nested `Package.swift` under this directory. The other
intentional Vendor manifests are `Vendor/STTextView/Package.swift` and
`Vendor/TreeSitterTSX/Package.swift`.

## What changed vs upstream

kero does not use the stock `NeonPlugin`. It has its own highlighter
(`SyntaxHighlightPlugin.swift`) and only imports this package for
`STPluginNeonAppKit.Theme`, `TreeSitterResource` / `TreeSitterLanguage`, and
the bundled grammar + query modules.

So this wrapper:

1. Drops the remote STTextView dependency entirely (no second `sttextview`
   identity).
2. Omits `Coordinator.swift`, `NeonPlugin.swift`, and
   `STTextViewSystemInterface.swift` — the only sources that `import STTextView`.
   Do **not** list the omitted files in `Package.swift` `exclude:`. SwiftPM
   `exclude` is for files that exist on disk; Xcode warns `Invalid Exclude`
   (`File not found`) when the path is missing. If a re-copy puts those
   files back, the build fails because this package has no STTextView
   dependency.
3. Uses the Swift 6 compatibility copy of Neon at `Vendor/Neon` and keeps
   SwiftTreeSitter as a remote dependency.
4. Declares only the grammar targets `TreeSitterResource` actually links.
   Unused upstream grammars (Haskell, Perl, LaTeX, …) are not copied.
5. Marks immutable token names as `Sendable` and isolates the AppKit/UIKit
   default theme construction to the main actor.

Query files and tree-sitter parsers are otherwise verbatim `5a30db4`.

## Identifying the vendored revision

The tree is commit `5a30db4ce7908a5414e7b499e2379bdc49991cd1` of
`krzyzanowskim/STTextView-Plugin-Neon`. There is no submodule to
`rev-parse`.

`Vendor/TreeSitterTSX` is copied from this same commit.

## Re-vendoring / bumping the revision

1. Clone or fetch `https://github.com/krzyzanowskim/STTextView-Plugin-Neon`
   and check out the new commit.
2. Copy the `Sources/<name>` directories this `Package.swift` lists into
   `Vendor/STTextView-Plugin-Neon/Sources/`. Do **not** copy upstream
   `Package.swift`, `DemoApp`, or unused grammar directories.
3. Delete `Coordinator.swift`, `NeonPlugin.swift`, and
   `STTextViewSystemInterface.swift` from `STPluginNeonAppKit` and
   `STPluginNeonUIKit`. Do not add them to `exclude:` in our
   `Package.swift` (Xcode `Invalid Exclude` if the files are gone).
4. Re-read upstream `Package.swift`. Keep the "no remote STTextView" /
   no nested manifest rules above. Add any new `TreeSitterResource`
   grammar targets with `path: "Sources/<name>"`.
5. Confirm `Vendor/TreeSitterTSX` still matches if the TSX grammar moved.
6. Build the `kero` scheme (or `scripts/package.sh`) and open a highlighted
   file.

## Exit path

Delete this directory and point `yeet.xcodeproj` at a remote Plugin-Neon
**only after** one of these is true:

- Upstream Plugin-Neon no longer depends on STTextView (kero does not need
  the stock plugin), or
- kero no longer vendors STTextView (the three patches in
  `Vendor/STTextView` have shipped upstream) and a single remote STTextView
  can satisfy both the app and the plugin.

Until then, a remote Plugin-Neon plus `Vendor/STTextView` is the Xcode 27
crash.
