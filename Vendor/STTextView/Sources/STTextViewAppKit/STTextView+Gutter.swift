//  Created by Marcin Krzyzanowski
//  https://github.com/krzyzanowskim/STTextView/blob/main/LICENSE.md

import AppKit
import STTextKitPlus
import CoreTextSwift
import STTextViewCommon

extension STTextView {

    /// This action method shows or hides the ruler, if the receiver is enclosed in a scroll view.
    @objc public func toggleRuler(_ sender: Any?) {
        isGutterVisible.toggle()
    }

    /// A Boolean value that controls whether the scroll view enclosing text views sharing the receiver’s layout manager displays the ruler.
    var isGutterVisible: Bool {
        set {
            if gutterView == nil, newValue == true {
                let gutterView = STGutterView()
                // estimate max gutter width
                gutterView.frame.origin = .zero
                gutterView.frame.size.width = max(gutterView.minimumThickness, CGFloat(textContentManager.length) / (1024 * 100))
                gutterView.frame.size.height = contentView.bounds.height
                gutterView.textColor = textColor.withAlphaComponent(0.45)
                gutterView.selectedLineTextColor = textColor
                gutterView.highlightSelectedLine = highlightSelectedLine
                gutterView.selectedLineHighlightColor = selectedLineHighlightColor
                gutterView.backgroundColor = backgroundColor
                if let enclosingScrollView {
                    enclosingScrollView.addFloatingSubview(gutterView, for: .horizontal)
                } else {
                    self.addSubview(gutterView)
                }
                self.gutterView = gutterView
                needsLayout = true
                layoutGutter()
            } else if newValue == false, let gutterView {
                gutterView.removeFromSuperview()
                self.gutterView = nil
                needsLayout = true
                layoutGutter()
            }
        }
        get {
            gutterView != nil
        }
    }

    func layoutGutter() {
        guard let gutterView, textLayoutManager.textViewportLayoutController.viewportRange != nil else {
            return
        }

        gutterView.frame.size.height = contentView.bounds.height

        layoutGutterLineNumbers()
        layoutGutterMarkers()
    }


    /// Paragraphs strictly before `location`, using the last measurement as
    /// an anchor so a small viewport move does not rescan the document head.
    private func paragraphCount(before location: NSTextLocation) -> Int {
        let documentStart = textLayoutManager.documentRange.location
        if location.compare(documentStart) != .orderedDescending {
            gutterParagraphsBeforeViewport = (location, 0)
            return 0
        }
        if let anchor = gutterParagraphsBeforeViewport {
            let order = anchor.location.compare(location)
            if order == .orderedSame {
                return anchor.count
            }
            if order == .orderedAscending,
               let range = NSTextRange(location: anchor.location, end: location) {
                let count = anchor.count + textContentManager.textElements(for: range).count
                gutterParagraphsBeforeViewport = (location, count)
                return count
            }
            if order == .orderedDescending,
               let range = NSTextRange(location: location, end: anchor.location) {
                let count = max(0, anchor.count - textContentManager.textElements(for: range).count)
                gutterParagraphsBeforeViewport = (location, count)
                return count
            }
        }
        guard let range = NSTextRange(location: documentStart, end: location) else {
            return 0
        }
        let count = textContentManager.textElements(for: range).count
        gutterParagraphsBeforeViewport = (location, count)
        return count
    }

    private func layoutGutterLineNumbers() {
        guard let gutterView else {
            return
        }

        let lineTextAttributes: [NSAttributedString.Key: Any] = [
            .font: gutterView.font,
            .foregroundColor: gutterView.textColor
        ]

        let selectedLineTextAttributes: [NSAttributedString.Key: Any] = [
            .foregroundColor: (gutterView.selectedLineTextColor ?? gutterView.textColor).cgColor
        ]

        // if empty document
        if textLayoutManager.documentRange.isEmpty {
            gutterView.containerView.subviews.compactMap {
                $0 as? STGutterLineNumberCell
            }.forEach {
                $0.removeFromSuperviewWithoutNeedingDisplay()
            }
            if let selectionFrame = textLayoutManager.textSegmentFrame(at: textLayoutManager.documentRange.location, type: .standard) {
                let lineNumber = 1

                // Use typingAttributes to calculate baseline position for empty document.
                // The cell is sized for typingLineHeight, so baseline calculation should use typing font metrics
                // to match where text baseline would be. Line number is still drawn with gutter font.
                let ctNumberLine = CTLineCreateWithAttributedString(NSAttributedString(string: "\(lineNumber)", attributes: typingAttributes))
                let baselineParagraphStyle = typingAttributes[.paragraphStyle] as? NSParagraphStyle ?? defaultParagraphStyle
                let baselineOffset = -(ctNumberLine.typographicHeight() * (baselineParagraphStyle.stLineHeightMultiple - 1.0) / 2)

                var effectiveLineTextAttributes = lineTextAttributes
                if gutterView.highlightSelectedLine /* , isLineSelected */, !selectedLineTextAttributes.isEmpty {
                    effectiveLineTextAttributes.merge(selectedLineTextAttributes, uniquingKeysWith: { (_, new) in new })
                }

                let numberCell = STGutterLineNumberCell(
                    firstBaseline: ctNumberLine.typographicBounds().ascent - baselineOffset,
                    attributes: effectiveLineTextAttributes,
                    number: lineNumber
                )

                numberCell.insets = gutterView.insets

                if gutterView.highlightSelectedLine, textLayoutManager.textSelectionsRanges(.withoutInsertionPoints).isEmpty, !textLayoutManager.insertionPointSelections.isEmpty {
                    numberCell.layer?.backgroundColor = gutterView.selectedLineHighlightColor.cgColor
                }

                // For empty documents, ignore bounce scrolling by treating scroll offset as 0
                // Empty document fits in viewport, so any scroll is just bounce effect
                numberCell.frame = CGRect(
                    origin: CGPoint(
                        x: 0,
                        y: selectionFrame.origin.y
                    ),
                    size: CGSize(
                        width: gutterView.containerView.frame.width,
                        height: selectionFrame.height
                    )
                ).pixelAligned

                gutterView.containerView.addSubview(numberCell)
            }
        } else if let viewportRange = textLayoutManager.textViewportLayoutController.viewportRange {
            // Get visible fragment views from the map and sort by document order
            // kero patch: after an attribute change (font/color) invalidates layout,
            // fragmentViewMap briefly holds both the old and new NSTextLayoutFragment
            // for the same range (the old one is kept alive by its detached fragment
            // view until the weak map purges). Numbering those stale entries shifts
            // every line number. Detached views are never visible, so drop them.
            let visibleFragmentViews = STGutterCalculations.visibleFragmentViewsInViewport(
                fragmentViewMap: fragmentViewMap,
                viewportRange: viewportRange
            ).filter { $0.1.superview != nil }

            guard !visibleFragmentViews.isEmpty else {
                return
            }

            var existingCells: [Int: STGutterLineNumberCell] = [:]
            for case let cell as STGutterLineNumberCell in gutterView.containerView.subviews {
                existingCells[cell.lineNumber] = cell
            }
            var usedCells: Set<ObjectIdentifier> = []

            var requiredWidthFitText = gutterView.minimumThickness
            let startLineIndex = paragraphCount(before: viewportRange.location)
            var linesCount = 0

            for (layoutFragment, fragmentView) in visibleFragmentViews {
                let contentRangeInElement = (layoutFragment.textElement as? NSTextParagraph)?.paragraphContentRange ?? layoutFragment.rangeInElement

                // Only show line numbers for the first line fragment or extra line fragments
                for textLineFragment in layoutFragment.textLineFragments where (textLineFragment.isExtraLineFragment || layoutFragment.textLineFragments.first == textLineFragment) {
                    let lineNumber = startLineIndex + linesCount + 1

                    // Determine if this line is selected
                    let isLineSelected = STGutterCalculations.isLineSelected(
                        textLineFragment: textLineFragment,
                        layoutFragment: layoutFragment,
                        contentRangeInElement: contentRangeInElement,
                        textLayoutManager: textLayoutManager
                    )

                    // Calculate positioning metrics
                    // Get the actual fragment view frame for pixel-perfect alignment
                    let (baselineYOffset, locationForFirstCharacter, cellFrame) = STGutterCalculations.calculateLineNumberMetrics(
                        for: textLineFragment,
                        in: layoutFragment,
                        fragmentViewFrame: fragmentView.frame
                    )

                    let cellFrameAligned = CGRect(
                        origin: CGPoint(
                            x: 0,
                            y: cellFrame.origin.y
                        ),
                        size: CGSize(
                            width: gutterView.containerView.frame.width,
                            height: cellFrame.size.height
                        )
                    ).pixelAligned

                    let highlightSelection = gutterView.highlightSelectedLine && isLineSelected
                        && textLayoutManager.textSelectionsRanges(.withoutInsertionPoints).isEmpty
                        && !textLayoutManager.insertionPointSelections.isEmpty

                    var effectiveLineTextAttributes = lineTextAttributes
                    if gutterView.highlightSelectedLine, isLineSelected, !selectedLineTextAttributes.isEmpty {
                        effectiveLineTextAttributes.merge(selectedLineTextAttributes, uniquingKeysWith: { (_, new) in new })
                    }
                    if let paragraphStyle = textLineFragment.attributedString.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle {
                        effectiveLineTextAttributes[.paragraphStyle] = paragraphStyle
                    }

                    let numberCell: STGutterLineNumberCell
                    if let reused = existingCells[lineNumber] {
                        numberCell = reused
                        reused.frame = cellFrameAligned
                        reused.applyAppearance(
                            firstBaseline: locationForFirstCharacter.y + baselineYOffset,
                            attributes: effectiveLineTextAttributes
                        )
                        reused.insets = gutterView.insets
                    } else {
                        numberCell = STGutterLineNumberCell(
                            firstBaseline: locationForFirstCharacter.y + baselineYOffset,
                            attributes: effectiveLineTextAttributes,
                            number: lineNumber
                        )
                        numberCell.insets = gutterView.insets
                        numberCell.frame = cellFrameAligned
                        gutterView.containerView.addSubview(numberCell)
                    }

                    numberCell.layer?.backgroundColor = highlightSelection
                        ? gutterView.selectedLineHighlightColor.cgColor
                        : nil
                    usedCells.insert(ObjectIdentifier(numberCell))
                    requiredWidthFitText = max(requiredWidthFitText, numberCell.intrinsicContentSize.width)
                    linesCount += 1
                }
            }

            for case let cell as STGutterLineNumberCell in gutterView.containerView.subviews {
                if !usedCells.contains(ObjectIdentifier(cell)) {
                    cell.removeFromSuperviewWithoutNeedingDisplay()
                }
            }

            // adjust ruleThickness to fit the text based on last numberView
            if textLayoutManager.textViewportLayoutController.viewportRange != nil {
                let newGutterWidth = max(requiredWidthFitText, gutterView.minimumThickness)
                if !newGutterWidth.isAlmostEqual(to: gutterView.frame.size.width, tolerance: .ulpOfOne), newGutterWidth > gutterView.frame.size.width {
                    gutterView.frame.size.width = newGutterWidth
                }
            }
        }
    }

    private func layoutGutterMarkers() {
        guard let gutterView else {
            return
        }

        gutterView.layoutMarkers()
    }
}
