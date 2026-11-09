import Testing
import CoreGraphics
@testable import ClipHistory

/// The four directions, from the geometry measured on device: the panel must fit
/// on screen and must never overlap the caret.
@Suite("Popup placement")
struct PopupPlacementTests {
    private let size = CGSize(width: 360, height: 420)
    private let screen = CGRect(x: 0, y: 0, width: 1440, height: 860)

    private func visible() -> CGRect { screen.insetBy(dx: 8, dy: 8) }

    private func side(_ frame: CGRect, of anchor: CGRect) -> String {
        let gap = PopupPlacement.gap
        if abs(frame.minY - (anchor.maxY + gap)) < 0.01 { return "above" }
        if abs(frame.maxY - (anchor.minY - gap)) < 0.01 { return "below" }
        if abs(frame.minX - (anchor.maxX + gap)) < 0.01 { return "right" }
        if abs(frame.maxX - (anchor.minX - gap)) < 0.01 { return "left" }
        return "clamped"
    }

    @Test("mid-screen caret opens above without covering it")
    func midScreenCaretOpensAbove() {
        let anchor = CGRect(x: 700, y: 400, width: 2, height: 17)
        let frame = PopupPlacement.frame(for: anchor, size: size, within: visible())
        XCTAssertEqual(side(frame, of: anchor), "above")
        #expect(!frame.intersects(anchor))
        #expect(visible().contains(frame))
    }

    @Test("caret near the top opens below")
    func caretNearTopOpensBelow() {
        let anchor = CGRect(x: 700, y: 820, width: 2, height: 17)
        let frame = PopupPlacement.frame(for: anchor, size: size, within: visible())
        XCTAssertEqual(side(frame, of: anchor), "below")
        #expect(!frame.intersects(anchor))
        #expect(visible().contains(frame))
    }

    @Test("short screen falls back to the right")
    func shortScreenFallsBackToRight() {
        let short = CGRect(x: 0, y: 0, width: 1440, height: 600).insetBy(dx: 8, dy: 8)
        let anchor = CGRect(x: 400, y: 300, width: 2, height: 17)
        let frame = PopupPlacement.frame(for: anchor, size: size, within: short)
        XCTAssertEqual(side(frame, of: anchor), "right")
        #expect(!frame.intersects(anchor))
    }

    @Test("short screen at the right edge falls back to the left")
    func shortScreenFallsBackToLeft() {
        let short = CGRect(x: 0, y: 0, width: 1440, height: 600).insetBy(dx: 8, dy: 8)
        let anchor = CGRect(x: 1300, y: 300, width: 2, height: 17)
        let frame = PopupPlacement.frame(for: anchor, size: size, within: short)
        XCTAssertEqual(side(frame, of: anchor), "left")
        #expect(!frame.intersects(anchor))
    }

    @Test("a zero-size anchor still places the panel")
    func zeroSizeAnchorPlacesPanel() {
        let anchor = CGRect(x: 700, y: 300, width: 0, height: 0)
        let frame = PopupPlacement.frame(for: anchor, size: size, within: visible())
        #expect(visible().contains(frame))
        #expect(!frame.intersects(anchor))
    }
}
