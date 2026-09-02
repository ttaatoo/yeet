#if os(macOS)
    import XCTest
    @testable import STTextViewAppKit

    @MainActor
    class TextViewTests: XCTestCase {

        func testInitialSelection() {
            let nstv = NSTextView()
            let sttv = STTextView()

            XCTAssertEqual(nstv.selectedRange(), sttv.textSelection)
        }

    }

#endif
