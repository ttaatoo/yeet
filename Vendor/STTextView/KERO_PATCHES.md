# Why kero vendors STTextView

This directory is a **verbatim copy of upstream [STTextView](https://github.com/krzyzanowskim/STTextView) tag `2.3.11`**, with exactly **twelve** local source patches. It is wired into the app as a local Swift package (`XCLocalSwiftPackageReference "Vendor/STTextView"` in `kero.xcodeproj`), not as a remote SPM dependency.

We vendor it for one reason: **to carry source-level fixes that aren't in any upstream release.** SPM has no patch/overlay mechanism for a remote package — the only way to ship changes to a dependency's own source is to check that source into the repo and point the project at the local copy. Once the patches below land upstream, we can delete this directory and go back to a pinned remote dependency (see [Exit path](#exit-path)).

`Package.swift` is byte-identical to upstream 2.3.11; the fixes below are the source delta.

## The patches

### Gutter numbering after an attribute change

**`Sources/STTextViewAppKit/STTextView+Gutter.swift`** — gutter line numbers go off-by-one after a font or text-color change.

```diff
         } else if let viewportRange = textLayoutManager.textViewportLayoutController.viewportRange {
             // Get visible fragment views from the map and sort by document order
+            // kero patch: after an attribute change (font/color) invalidates layout,
+            // fragmentViewMap briefly holds both the old and new NSTextLayoutFragment
+            // for the same range (the old one is kept alive by its detached fragment
+            // view until the weak map purges). Numbering those stale entries shifts
+            // every line number. Detached views are never visible, so drop them.
             let visibleFragmentViews = STGutterCalculations.visibleFragmentViewsInViewport(
                 fragmentViewMap: fragmentViewMap,
                 viewportRange: viewportRange
-            )
+            ).filter { $0.1.superview != nil }
```

**Root cause.** When the font or text color is set after text has already been laid out, the attribute change invalidates layout and TextKit 2 rebuilds the affected `NSTextLayoutFragment`s. STTextView's `fragmentViewMap` is weak-key/weak-value, so for a brief window it holds **both** the old and new fragment for the same character range — the stale old fragment stays alive because its (now detached) fragment view hasn't been released yet. The gutter assigns a line number to *every* entry in that map, so the duplicated range pushes all subsequent line numbers down by one.

**Symptom.** Line numbers drift out of alignment with the text and stay wrong — it does **not** self-heal on relayout, resize, or scroll — so the fix has to happen at the numbering source rather than being papered over in the wrapper.

**Why the fix is safe.** A detached fragment view (`superview == nil`) is by definition not on screen, so it can never be a *visible* fragment. Filtering those out removes only the stale duplicates and leaves the real viewport fragments untouched. Worth upstreaming.

### Horizontal document sizing

**`Sources/STTextViewAppKit/STTextView.swift`** — no-wrap documents cannot scroll horizontally when their last line is shorter than an earlier line.

Both `sizeToFit()` and `updateContentSizeIfNeeded()` ask TextKit for the layout fragment immediately before the end of the document, then use that single fragment's width as the document width. That is the final line's width, not the widest line's width. Kero takes the maximum of that value and `usageBoundsForTextContainer.width`, which tracks the widest laid-out line. The scroll-view estimate also adds one `lineFragmentPadding` because TextKit's usage width stops that far short of the final glyph's trailing typographic edge, plus a 16 px readable gap after the final glyph.

**Symptom.** The editor renders long lines past the viewport but its document view can remain only as wide as the short final line, leaving `NSScrollView` with no horizontal scroll range. Even when a range exists, omitting the trailing padding leaves the last few pixels clipped at the rightmost position.

**Why the fix is safe.** It only increases the estimated width when TextKit has already measured wider content. Wrapped editors still replace the estimate with the viewport width in the existing `!isHorizontallyResizable` branch.

### Gutter cells and line index on scroll

**`Sources/STTextViewAppKit/STTextView+Gutter.swift`** and **`Sources/STTextViewAppKit/STTextView.swift`** — scrolling a file rebuilt every visible line-number cell and walked every text element from the document head to the viewport, every viewport layout.

Reuse cells keyed by line number (move the frame, refresh firstBaseline / font / selected-line text, drop cells that left the viewport). Count paragraphs before the viewport from the last measurement plus the gap, and clear that anchor in `replaceCharacters`.

**Symptom.** File-editor scroll sat around 35 FPS on a 120 Hz display. Opening a 1200-line markdown file and dragging the clip view spent most of each frame in gutter layout.

**Why the fix is safe.** Visible line numbers and their Y positions stay the same as the old full rebuild. Edits drop the paragraph-count anchor so numbering cannot go stale.

### Document size from usage bounds

**`Sources/STTextViewAppKit/STTextView.swift`** — `updateContentSizeIfNeeded()` enumerated layout fragments from the document end with `ensuresLayout` on every viewport pass.

Use `usageBoundsForTextContainer` (already the width source for no-wrap documents) for both axes, keep the trailing padding and “fill the viewport” height rules, and only `setFrameSize` when the aligned size changes.

**Symptom.** Same scroll hitch: TextKit walked the document tail after every `layoutViewport()`.

**Why the fix is safe.** The frame still grows when usage bounds grow, so the scroller range still tracks laid-out content. It no longer forces extra layout to re-read a size TextKit already has.

### Prepared-content band includes scrolling down

**`Sources/STTextViewAppKit/STTextView.swift`** — `prepareContent(in:)` only grew the rect upward by half a viewport. Scrolling down (increasing `minY` on a flipped document view) left that band on the next clip step, so `layoutViewport()` ran almost every frame.

Grow by half a viewport above and half below. Skip expansion on the first prepare so opening a file does not lay out 1.5 viewports during the first highlight pass. Two full viewports below made `layoutViewport()` too heavy when that method still unioned prepared+visible (see viewport-bounds patch below).

**Symptom.** After gutter reuse, median frame time was 8.3 ms but ~20% of scroll frames were ~20 ms (`over16ms` well above 5%). Expanding on first prepare also dropped the cold `open.fps` on `md-fence`.

**Why the fix is safe.** It only prepares more of the document that TextKit would lay out on the next scroll anyway. Visible content is unchanged. The first prepare still covers the visible rect.

### Caret-only skip in selection highlight

**`Sources/STTextViewAppKit/STTextView.swift`** — `updateSelectedRangeHighlight()` ran `enumerateTextSegments` and restarted the insertion-point timer on every viewport layout even when the selection was a zero-length caret.

Return after clearing range-highlight views when every selected range is empty.

**Symptom.** Scroll frames paid TextKit segment enumeration plus timer rescheduling while no range was selected.

**Why the fix is safe.** Range highlights still rebuild when a non-empty selection exists. The caret is drawn by the insertion-point views, not this method.

### No second viewport `ensureLayout` after `layoutViewport`

**`Sources/STTextViewAppKit/STTextView+NSTextViewportLayoutControllerDelegate.swift`** — `textViewportLayoutControllerDidLayout` called `ensureLayout(for: viewportRange)` after the viewport controller had already laid that range out.

**Symptom.** Every `layoutViewport()` paid a second TextKit walk, which showed up as ~20 ms frames (two 120 Hz vsyncs) during scroll.

**Why the fix is safe.** The controller just finished laying out that range. The extra `ensureLayout` did not add fragments the first pass missed; it only repeated the work.

### Viewport bounds are a pad around visible, not the prepared rect

**`Sources/STTextViewAppKit/STTextView+NSTextViewportLayoutControllerDelegate.swift`** — `viewportBounds(for:)` unioned `preparedContentRect` with the visible rect.

`layoutViewport()` then laid out that whole union. After `prepareContent` grew a 1.5-viewport band, every clip step paid 50–90 ms.

Return visible height plus 0.35× above and 0.70× below. Keep X at the content-view origin. Do not union the prepared rect.

**Symptom.** Growing the prepare band to keep scrolling inside prepared content made `layoutViewport()` heavier, not cheaper.

**Why the fix is safe.** Prepared content still exists for AppKit; TextKit only lays out the pad around what is on screen. A small clip move stays filled. Large jumps still call `prepareContent` when visible leaves the prepared rect.

### Relocate viewport only near the document end

**`Sources/STTextViewAppKit/STTextView+NSTextViewportLayoutControllerDelegate.swift`** — `textViewportLayoutControllerDidLayout` called `relocateViewport(to: documentEnd)` whenever the viewport end was not the document end and the clip sat at `maxY` of the (still growing) usage-bounds frame.

Usage bounds lag the full document during lazy layout, so a clip at the current frame bottom is not “at the last line”. Relocate then ran every scroll frame (~66 ms).

Relocate only when fewer than 256 UTF-16 units remain after the viewport.

**Symptom.** Triangle-wave scroll still hitching at the laid-out frame bottom; wrapping y=0 was worse for the same reason.

**Why the fix is safe.** Near the real end of the document, relocate still runs. Mid-document scroll no longer forces a full viewport jump.

### One-pass `layoutViewport`

**`Sources/STTextViewAppKit/STTextView.swift`** — `layoutViewport()` looped up to five times whenever `didLayout` set `needsRelayout` (content-size change or relocate).

One `layoutViewport()` call per clip-origin step. Clear `needsRelayout` first.

**Symptom.** A content-size bump during scroll re-laid the viewport several times in the same vsync.

**Why the fix is safe.** The next display refresh (or the next clip step) lays out again if the frame grew. Clip-origin scrolling does not need intra-frame convergence.

### Skip line highlight when the caret is off-viewport

**`Sources/STTextViewAppKit/STTextView.swift`** — `updateSelectedLineHighlight()` enumerated every fragment in the viewport to find the caret line.

If no insertion-point selection intersects the current viewport, return. Range-highlight already cleared leftover views for a caret-only selection.

**Symptom.** Scroll frames walked viewport fragments for a caret that was not on screen.

**Why the fix is safe.** When the caret is in the viewport, the fragment walk still draws the line highlight. Off-viewport, there is nothing to draw.

### Rendering attributes over empty ranges

**`Sources/STTextViewCommon/STTextLayoutManager.swift`** — applying a rendering (temporary) attribute over an **empty** `NSTextRange` crashes deep inside TextKit.

```swift
override open func addRenderingAttribute(_ attribute: NSAttributedString.Key, value: Any?, for textRange: NSTextRange) {
    guard !textRange.isEmpty else { return }
    super.addRenderingAttribute(attribute, value: value, for: textRange)
}
```

**Root cause.** `NSTextLayoutManager.addRenderingAttribute(_:value:for:)` is the Swift name for `-[NSTextLayoutManager addTemporaryAttribute:value:forTextRange:]`. On macOS 15/26, calling it with a zero-length range walks into `-[_NSTextRunStorage enumerateObjectsFromLocation:options:usingBlock:]`, which builds an `NSArray` from a nil element and raises `NSInvalidArgumentException` (`attempt to insert nil object from objects[0]`).

**Symptom.** The syntax highlighter (kero's `SyntaxHighlightPlugin`, adapted from [STTextView-Plugin-Neon](https://github.com/krzyzanowskim/STTextView-Plugin-Neon)) sets a `.foregroundColor` rendering attribute per tree-sitter token. Several grammars emit **zero-length** highlight tokens — markdown's `punctuation.special` for block continuations and thematic breaks is the reliable repro — so opening the first markdown file crashes the app. `applyStyle(to:)` doesn't guard the range, so the guard goes here on STTextView's own layout-manager subclass (`textView.textLayoutManager` is always an `STTextLayoutManager`, so the override intercepts the call).

**Why the fix is safe.** An empty range has nothing to render, so skipping the call is a no-op — it only suppresses the crash. Worth upstreaming.

## Identifying the vendored version

Don't trust `CHANGELOG.md` in this directory — upstream's own changelog stops at `2.3.8` even on the `2.3.11` tag, so it is not a version marker. To confirm the base, diff `Sources/` against upstream tags and pick the one that differs only by the patches above:

```sh
git clone https://github.com/krzyzanowskim/STTextView.git /tmp/sttv && cd /tmp/sttv
git checkout 2.3.11 -- Sources
diff -ru Sources /path/to/kero/Vendor/STTextView/Sources
# expect: only the five documented source files and hunks differ
```

The patched files are `STTextView.swift`, `STTextView+Gutter.swift`, `STTextView+NSTextViewportLayoutControllerDelegate.swift`, `STGutterLineNumberCell.swift`, and `STTextLayoutManager.swift`.

## Re-vendoring / bumping the version

1. Check out the new upstream tag's tree over this directory (keep the `.md` docs like this one).
2. Re-apply all twelve patches above; grep for `kero patch` to find them, and check whether upstream has since fixed any root cause — if so, drop the corresponding patch.
3. Verify the delta is limited to the documented source files, using the diff recipe above.
4. Build with the project's usual command and confirm gutter numbers stay aligned after changing font/size (settings → editor) with a file open. Run `scripts/bench-file-render.sh` on a 120 Hz display and keep `scroll.fps` ≥ 114 for `md-fence`, `md-lists`, and `swift`.

## What is NOT a patch here

Don't re-add these to the package — they live on the app side, in [`kero/SourceTextEditor.swift`](../../kero/SourceTextEditor.swift), and are configuration of a stock STTextView, not modifications to it:

- `scrollView.clipsToBounds = true` — the gutter is a document-height floating subview; since macOS 14 NSViews don't clip subviews, so scrolled-away numbers would otherwise draw over the header.
- `automaticallyAdjustsContentInsets = false` — the full-size-content-view window would otherwise add a titlebar-height top inset that misaligns the gutter by one line.
- Setting font/colors **before** `textView.text` — avoids the restyle-after-layout path that provokes the gutter bug in the first place (belt-and-suspenders alongside the patch).

## Exit path

These twelve patches are the only things keeping this vendored. Upstream them, and once all ship in a release, delete `Vendor/STTextView`, remove the `XCLocalSwiftPackageReference` from `kero.xcodeproj`, and add STTextView back as a normal remote package dependency pinned to that release. (The empty-range guard could alternatively move upstream into the Neon plugin's `applyStyle`; either home retires the patch.)

Until that happens, Plugin-Neon cannot stay a remote package: its
`https://github.com/krzyzanowskim/STTextView` dependency is the same SwiftPM
identity as this directory and Xcode 27 crashes on the duplicate. See
[`Vendor/STTextView-Plugin-Neon/KERO.md`](../STTextView-Plugin-Neon/KERO.md).
