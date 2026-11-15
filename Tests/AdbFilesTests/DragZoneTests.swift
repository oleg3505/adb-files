import CoreGraphics
import Testing
@testable import AdbFiles

@Suite struct DragZoneTests {
    // A Name cell: 16 pt icon at x 2…18, text field from x 24 to the cell's end (300), name drawn 80 pt wide.
    let icon = CGRect(x: 2, y: 3, width: 16, height: 16)
    let text = CGRect(x: 24, y: 3, width: 276, height: 16)
    let drawn: CGFloat = 80

    @Test func iconAndNameStartADrag() {
        #expect(DragZone.allowsDrag(at: CGPoint(x: 10, y: 10), iconFrame: icon, textFrame: text, textWidth: drawn))
        #expect(DragZone.allowsDrag(at: CGPoint(x: 60, y: 10), iconFrame: icon, textFrame: text, textWidth: drawn))
        #expect(DragZone.allowsDrag(at: CGPoint(x: 24 + 83, y: 10), iconFrame: icon, textFrame: text, textWidth: drawn), "end of the name")
    }

    @Test func emptySpaceRightOfTheNameSelectsInstead() {
        #expect(!DragZone.allowsDrag(at: CGPoint(x: 200, y: 10), iconFrame: icon, textFrame: text, textWidth: drawn))
    }

    @Test func aboveOrBelowTheTextInATallRowSelects() {
        // Large rows: 48 pt high, the text sits in the middle.
        let tallText = CGRect(x: 48, y: 16, width: 250, height: 16)
        #expect(!DragZone.allowsDrag(at: CGPoint(x: 60, y: 40), iconFrame: .zero, textFrame: tallText, textWidth: drawn))
    }

    @Test func longNameIsClippedToItsField() {
        #expect(!DragZone.allowsDrag(at: CGPoint(x: 310, y: 10), iconFrame: icon, textFrame: text, textWidth: 1_000))
        #expect(DragZone.allowsDrag(at: CGPoint(x: 290, y: 10), iconFrame: icon, textFrame: text, textWidth: 1_000))
    }
}
