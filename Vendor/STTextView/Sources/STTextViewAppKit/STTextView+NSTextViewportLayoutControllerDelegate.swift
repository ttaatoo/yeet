//  Created by Marcin Krzyzanowski
//  https://github.com/krzyzanowskim/STTextView/blob/main/LICENSE.md

import AppKit
import STTextKitPlus

extension STTextView: NSTextViewportLayoutControllerDelegate {

    public func textViewportLayoutControllerWillLayout(_ textViewportLayoutController: NSTextViewportLayoutController) {
        lastUsedFragmentViews = Set(fragmentViewMap.objectEnumerator()?.allObjects as? [STTextLayoutFragmentView] ?? [])

        if ProcessInfo().environment["ST_LAYOUT_DEBUG"] == "YES" {
            let viewportDebugView = NSView(frame: viewportBounds(for: textViewportLayoutController))
            viewportDebugView.clipsToBounds = true
            viewportDebugView.wantsLayer = true
            viewportDebugView.layer?.borderColor = NSColor.magenta.cgColor
            viewportDebugView.layer?.borderWidth = 4
            contentViewportView.addSubview(viewportDebugView)
        }
    }

    public func viewportBounds(for textViewportLayoutController: NSTextViewportLayoutController) -> CGRect {
        // visibleRect is already in contentView coords (contentView.origin.x = gutterWidth)
        var visible = contentView.visibleRect

        // Clamp negative origins to 0 (handles overscroll bounce)
        if visible.minX < 0 {
            visible.size.width += visible.minX
            visible.origin.x = 0
        }
        if visible.minY < 0 {
            visible.size.height += visible.minY
            visible.origin.y = 0
        }

        // kero patch: do not union the full preparedContentRect. That made
        // layoutViewport grow with the prepare band (3× viewport → 50–90 ms).
        // Overdraw a fraction of the visible height so a small clip move stays
        // filled without laying out the whole prepared region.
        let pad = visible.height * 0.35
        let minY = max(0, visible.minY - pad)
        let maxY = visible.maxY + pad * 2
        return CGRect(x: 0, y: minY, width: contentView.bounds.width, height: maxY - minY)
    }

    public func textViewportLayoutController(_ textViewportLayoutController: NSTextViewportLayoutController, configureRenderingSurfaceFor textLayoutFragment: NSTextLayoutFragment) {
        var needsDisplay = false
        if let textLayoutFragment = textLayoutFragment as? STTextLayoutFragment,
           textLayoutFragment.showsInvisibleCharacters != showsInvisibleCharacters {
            textLayoutFragment.showsInvisibleCharacters = showsInvisibleCharacters
            needsDisplay = true
        }

        // textLayoutFragment.layoutFragmentFrame is calculated in `self` coordinates,
        // but we use it in contentViewportView coordinates. contentViewportView frame is offset by gutterWidth
        let layoutFragmentFrame = textLayoutFragment.layoutFragmentFrame
        let fragmentView: STTextLayoutFragmentView
        if let cachedFragmentView = fragmentViewMap.object(forKey: textLayoutFragment) {
            cachedFragmentView.layoutFragment = textLayoutFragment
            fragmentView = cachedFragmentView
            lastUsedFragmentViews.remove(cachedFragmentView)
        } else {
            fragmentView = STTextLayoutFragmentView(layoutFragment: textLayoutFragment, frame: layoutFragmentFrame.pixelAligned)
            fragmentViewMap.setObject(fragmentView, forKey: textLayoutFragment)
        }

        // Adjust fragment view frame
        if !fragmentView.frame.isAlmostEqual(to: layoutFragmentFrame.pixelAligned) {
            fragmentView.frame = textLayoutFragment.layoutFragmentFrame.pixelAligned
            fragmentView.needsLayout = true
            needsDisplay = true
        }

        if needsDisplay {
            fragmentView.needsDisplay = true
        }

        if fragmentView.superview != contentViewportView {
            contentViewportView.addSubview(fragmentView)
        }
    }

    public func textViewportLayoutControllerDidLayout(_ textViewportLayoutController: NSTextViewportLayoutController) {
        for staleView in lastUsedFragmentViews {
            staleView.removeFromSuperview()
        }
        lastUsedFragmentViews.removeAll()

        // kero patch: layoutViewport already laid out the viewport. Calling
        // ensureLayout here walked it again on every scroll frame.

        updateContentSizeIfNeeded()

        // When scrolled to the end of the document, relocate viewport to ensure proper layout.
        // kero patch: the document frame is only as tall as laid-out usage
        // bounds. Clip maxY hitting that frame is not "at the last line" —
        // it used to relocateViewport on every scroll frame while lazily
        // growing the document.
        if let viewportRange = textViewportLayoutController.viewportRange,
           let textRange = NSTextRange(location: viewportRange.endLocation, end: textLayoutManager.documentRange.endLocation),
           !textRange.isEmpty {
            let remaining = textContentManager.offset(
                from: viewportRange.endLocation,
                to: textLayoutManager.documentRange.endLocation
            )
            if remaining < 256 {
                relocateViewport(to: textLayoutManager.documentRange.endLocation)
            }
        }

        updateSelectedRangeHighlight()
        updateSelectedLineHighlight()
        layoutGutter()

        if let viewportRange = textViewportLayoutController.viewportRange {
            for events in plugins.events {
                events.didLayoutViewportHandler?(viewportRange)
            }
        }
    }
}
