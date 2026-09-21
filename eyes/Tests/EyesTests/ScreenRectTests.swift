import CoreGraphics
import Testing
@testable import Eyes

/// The conversion from what a recogniser reports to what a caller clicks, asked without a
/// display, a capture or a grant.
///
/// [LAW:behavior-not-structure] These assert where a box lands, which is the contract, and
/// never how the arithmetic got there. The failure they exist to catch does not announce
/// itself: a reader that flips the wrong way still returns four plausible Doubles in the
/// right order of magnitude, and the click just goes somewhere else.
@Suite struct ScreenRectTests {
    /// Measured on the owner's Mac from the window list: the main display, in points.
    static let main = ScreenRect(x: 0, y: 0, width: 1512, height: 982)

    private func expect(_ got: Double, _ want: Double, _ what: String) {
        #expect(abs(got - want) < 0.001, "\(what): got \(got), wanted \(want)")
    }

    /// The flip, stated as the thing a reader gets backwards. Vision measures a box's
    /// origin UP from the bottom of the image; the screen measures DOWN from the top.
    @Test func aBoxLowInTheImageLandsLowOnTheScreen() {
        // A button 10% up from the bottom of the image, 5% tall.
        let box = CGRect(x: 0.8, y: 0.1, width: 0.15, height: 0.05)
        let rect = ScreenRect.fromImageSpace(normalized: box, on: Self.main)

        // Its top edge is 15% up from the bottom, so 85% down from the top.
        expect(rect.y, 0.85 * 982, "top edge")
        expect(rect.x, 0.8 * 1512, "left edge")
        expect(rect.width, 0.15 * 1512, "width")
        expect(rect.height, 0.05 * 982, "height")
        // And it is in the bottom half of a 982-point screen, which is the whole claim.
        #expect(rect.y > 982 / 2)
    }

    /// The mirror of the above, because a conversion that subtracted the height twice
    /// would pass the first test on a box far from either edge and fail here.
    @Test func aBoxAtTheTopOfTheImageLandsAtTheTopOfTheScreen() {
        let box = CGRect(x: 0, y: 0.95, width: 0.2, height: 0.05)
        let rect = ScreenRect.fromImageSpace(normalized: box, on: Self.main)
        expect(rect.y, 0, "a box flush with the image top is flush with the screen top")
    }

    /// A box filling the image fills the display, which pins both edges at once.
    @Test func theWholeImageIsTheWholeDisplay() {
        let rect = ScreenRect.fromImageSpace(
            normalized: CGRect(x: 0, y: 0, width: 1, height: 1),
            on: Self.main
        )
        #expect(rect == Self.main)
    }

    /// Retina changes nothing, and that is a fact about the signature rather than about
    /// the arithmetic: a normalized box is a fraction of the image and the same fraction
    /// of the display's point size, so the capture's pixel count divides out before
    /// anything runs. A 3024x1964 capture of this display and a 1512x982 one give this
    /// same answer because neither number can be passed in.
    @Test func theCaptureScaleCannotChangeTheAnswer() {
        let box = CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
        let rect = ScreenRect.fromImageSpace(normalized: box, on: Self.main)
        expect(rect.x, 378, "left edge")
        expect(rect.y, 245.5, "top edge")
        expect(rect.width, 756, "width")
        expect(rect.height, 491, "height")
    }

    /// A display left of the main one sits at a negative origin, and a reader that
    /// ignored the origin would return coordinates on the wrong monitor - which, unlike a
    /// flip, still looks entirely reasonable.
    @Test func aDisplayAtANegativeOriginPutsFindingsAtNegativeCoordinates() {
        let secondary = ScreenRect(x: -1512, y: 0, width: 1512, height: 982)
        let box = CGRect(x: 0.8, y: 0.1, width: 0.15, height: 0.05)
        let rect = ScreenRect.fromImageSpace(normalized: box, on: secondary)

        expect(rect.x, -1512 + 0.8 * 1512, "left edge on the secondary display")
        #expect(rect.x < 0)
        // The vertical answer does not change with the horizontal origin.
        let onMain = ScreenRect.fromImageSpace(normalized: box, on: Self.main)
        expect(rect.y, onMain.y, "top edge is the same on both displays")
    }

    /// The centre is the only number a caller actually uses, so it is derived from the
    /// rectangle rather than carried beside it.
    @Test func theCentreIsTheMiddleOfTheRectangle() {
        let rect = ScreenRect(x: 100, y: 200, width: 60, height: 40)
        #expect(rect.centre == ScreenPoint(x: 130, y: 220))
        #expect(rect.contains(rect.centre))
    }

    /// Overlap is how a merged reading tells one thing seen by both readers from two
    /// things seen once each, so touching-but-not-overlapping must read as separate.
    @Test func rectanglesThatOnlyTouchDoNotIntersect() {
        let left = ScreenRect(x: 0, y: 0, width: 10, height: 10)
        #expect(!left.intersects(ScreenRect(x: 10, y: 0, width: 10, height: 10)))
        #expect(left.intersects(ScreenRect(x: 9, y: 0, width: 10, height: 10)))
    }
}
