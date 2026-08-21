# Why kero vendors STTextView-Plugin-Neon

This directory is a **local Swift package** that wraps upstream
[STTextView-Plugin-Neon](https://github.com/krzyzanowskim/STTextView-Plugin-Neon)
commit `5a30db4` (the revision `kero.xcodeproj` used to pin as a remote
package). Sources live in the `upstream` git submodule. `Package.swift` is
ours.

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

## What changed vs upstream

kero does not use the stock `NeonPlugin`. It has its own highlighter
(`SyntaxHighlightPlugin.swift`) and only imports this package for
`STPluginNeonAppKit.Theme`, `TreeSitterResource` / `TreeSitterLanguage`, and
the bundled grammar + query modules.

So this wrapper:

1. Drops the remote STTextView dependency entirely (no second `sttextview`
   identity).
2. Excludes `Coordinator.swift`, `NeonPlugin.swift`, and
   `STTextViewSystemInterface.swift` — the only sources that `import STTextView`.
3. Keeps Neon + SwiftTreeSitter as remote dependencies, at the same pins
   upstream used.
4. Declares only the grammar targets `TreeSitterResource` actually links.
   Unused upstream grammars (Haskell, Perl, LaTeX, …) stay in the submodule
   but are not package targets.

Theme, query files, and tree-sitter parsers are otherwise verbatim `5a30db4`.

## Identifying the vendored revision

```sh
git -C Vendor/STTextView-Plugin-Neon/upstream rev-parse HEAD
# expect 5a30db4ce7908a5414e7b499e2379bdc49991cd1
```

`Vendor/TreeSitterTSX` is copied from this same commit.

## Re-vendoring / bumping the revision

1. `git -C Vendor/STTextView-Plugin-Neon/upstream fetch`
2. Check out the new upstream commit.
3. Re-read upstream `Package.swift`. Keep the "no remote STTextView" / exclude
   list above. Add any new `TreeSitterResource` grammar targets with
   `path: "upstream/Sources/<name>"`.
4. Confirm `Vendor/TreeSitterTSX` still matches if the TSX grammar moved.
5. Build the `kero` scheme (or `scripts/package.sh`) and open a highlighted
   file.

## Exit path

Delete this directory, remove the `upstream` submodule, and point
`kero.xcodeproj` at a remote Plugin-Neon **only after** one of these is true:

- Upstream Plugin-Neon no longer depends on STTextView (kero does not need
  the stock plugin), or
- kero no longer vendors STTextView (the three patches in
  `Vendor/STTextView` have shipped upstream) and a single remote STTextView
  can satisfy both the app and the plugin.

Until then, a remote Plugin-Neon plus `Vendor/STTextView` is the Xcode 27
crash.
