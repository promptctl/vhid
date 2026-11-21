import CoreGraphics
import Testing
@testable import ScreenSpace

/// A box made by the one door, for the cases the door is not what is asked about.
func box(_ x: Double, _ y: Double, _ width: Double, _ height: Double) throws -> ScreenRect {
    try ScreenRect(x: x, y: y, width: width, height: height)
}

func point(_ x: Double, _ y: Double) throws -> ScreenPoint { try ScreenPoint.at(x, y) }

/// The conversion from what a recogniser reports to what a caller clicks, and the geometry
/// of boxes, asked without a display, a capture or a grant.
///
/// [LAW:behavior-not-structure] These assert where a box lands, which is the contract, and
/// never how the arithmetic got there. The failure they exist to catch does not announce
/// itself: a reader that flips the wrong way still returns four plausible Doubles in the
/// right order of magnitude, and the click just goes somewhere else.
@Suite struct ScreenRectTests {
    /// Measured on the owner's Mac from the window list: the main display, in points.
    static let main = try! box(0, 0, 1512, 982)

    private func expect(_ got: Double, _ want: Double, _ what: String) {
        #expect(abs(got - want) < 0.001, "\(what): got \(got), wanted \(want)")
    }

    private func placed(_ normalized: CGRect, on display: ScreenRect = Self.main) throws -> ScreenRect {
        try #require(ScreenRect.fromImageSpace(normalized: normalized, on: display))
    }

    /// The flip, stated as the thing a reader gets backwards. Vision measures a box's
    /// origin UP from the bottom of the image; the screen measures DOWN from the top.
    @Test func aBoxLowInTheImageLandsLowOnTheScreen() throws {
        // A button 10% up from the bottom of the image, 5% tall.
        let rect = try placed(CGRect(x: 0.8, y: 0.1, width: 0.15, height: 0.05))

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
    @Test func aBoxAtTheTopOfTheImageLandsAtTheTopOfTheScreen() throws {
        expect(try placed(CGRect(x: 0, y: 0.95, width: 0.2, height: 0.05)).y, 0, "a box flush with the image top is flush with the screen top")
    }

    /// A box filling the image fills the display, which pins both edges at once.
    @Test func theWholeImageIsTheWholeDisplay() throws {
        #expect(try placed(CGRect(x: 0, y: 0, width: 1, height: 1)) == Self.main)
    }

    /// Retina changes nothing, and that is a fact about the signature rather than about
    /// the arithmetic: a normalized box is a fraction of the image and the same fraction
    /// of the display's point size, so the capture's pixel count divides out before
    /// anything runs.
    @Test func theCaptureScaleCannotChangeTheAnswer() throws {
        let rect = try placed(CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5))
        expect(rect.x, 378, "left edge")
        expect(rect.y, 245.5, "top edge")
        expect(rect.width, 756, "width")
        expect(rect.height, 491, "height")
    }

    /// A display left of the main one sits at a negative origin, and a reader that
    /// ignored the origin would return coordinates on the wrong monitor - which, unlike a
    /// flip, still looks entirely reasonable.
    @Test func aDisplayAtANegativeOriginPutsFindingsAtNegativeCoordinates() throws {
        let secondary = try box(-1512, 0, 1512, 982)
        let normalized = CGRect(x: 0.8, y: 0.1, width: 0.15, height: 0.05)
        let rect = try placed(normalized, on: secondary)

        expect(rect.x, -1512 + 0.8 * 1512, "left edge on the secondary display")
        #expect(rect.x < 0)
        // The vertical answer does not change with the horizontal origin.
        expect(rect.y, try placed(normalized).y, "top edge is the same on both displays")
    }

    /// A box Vision gives that lands on no place is none, for the reader to count.
    @Test func aVisionBoxThatIsNoPlaceIsNoBox() {
        #expect(ScreenRect.fromImageSpace(normalized: CGRect(x: Double.nan, y: 0, width: 0.1, height: 0.1), on: Self.main) == nil)
        #expect(ScreenRect.fromImageSpace(normalized: CGRect(x: 0, y: 0, width: -0.1, height: 0.1), on: Self.main) == nil)
    }

    /// A piece of a display, taken to Vision's space and back, is the same piece - on a
    /// display at a negative origin, where a missed offset shows. And the top of the screen
    /// is the top of the image, so its normalized box sits high.
    @Test func aPieceOfTheDisplayRoundTripsThroughImageSpace() throws {
        let display = try box(-2400, -300, 2400, 1600)
        let piece = try box(-2000, -300, 800, 400)
        let normalized = piece.normalized(in: display)
        expect(normalized.maxY, 1, "a piece at the top of the display sits at the top of the image")
        let back = try placed(normalized, on: display)
        expect(back.x, piece.x, "x")
        expect(back.y, piece.y, "y")
        expect(back.width, piece.width, "width")
        expect(back.height, piece.height, "height")
    }

    /// Four numbers are a box when every one and both far edges are finite and no side is
    /// under zero, and nothing else bounds them: a document's claimed frame is a frame.
    @Test func aBoxIsFourFiniteNumbersWithNoSideUnderZero() throws {
        #expect(try box(0, 0, 1e20, 30).width == 1e20)
        #expect(try box(-1e300, 5, 0, 0).isEmpty)
        let far = Double.greatestFiniteMagnitude
        let refused: [(Double, Double, Double, Double)] = [(.nan, 0, 1, 1), (0, 0, .infinity, 1), (0, 0, 1, -1), (far, 0, far, 1)]
        for (x, y, width, height) in refused {
            #expect(throws: NotABox.self) { try box(x, y, width, height) }
        }
        #expect(NotABox(x: 0, y: 0, width: 1, height: -1).description == "0,0,1,-1 is not a box on the screen")
    }

    /// A CoreGraphics rectangle is read as given: a negative size is refused, not turned
    /// round into the box `standardized` would make of it.
    @Test func aRectangleWithANegativeSizeIsNoBox() {
        #expect(throws: NotABox.self) { try ScreenRect(CGRect(x: 10, y: 10, width: -5, height: 5)) }
    }

    /// The centre is the only number a caller actually uses, so it is derived from the
    /// rectangle rather than carried beside it - and it is inside however large the box.
    @Test func theCentreIsTheMiddleOfTheRectangle() throws {
        let rect = try box(100, 200, 60, 40)
        #expect(rect.centre == (try point(130, 220)))
        #expect(rect.contains(rect.centre))
        let wide = try box(-Double.greatestFiniteMagnitude / 2, 0, Double.greatestFiniteMagnitude, 10)
        #expect(wide.contains(wide.centre))
    }

    /// Overlap is how a merged reading tells one thing seen by both readers from two
    /// things seen once each, so touching-but-not-overlapping must read as separate.
    @Test func rectanglesThatOnlyTouchDoNotIntersect() throws {
        let left = try box(0, 0, 10, 10)
        #expect(left.intersection(try box(10, 0, 10, 10)) == nil)
        #expect(!left.intersects(try box(10, 0, 10, 10)))
        #expect(left.intersection(try box(9, 0, 10, 10)) == (try box(9, 0, 1, 10)))
        #expect(left.overlap(try box(9, 0, 10, 10)) == 10)
    }

    /// A union's span can be past any number, so the union says so instead of answering an
    /// infinity; one that fits holds both.
    @Test func aUnionPastADoubleIsNone() throws {
        let far = Double.greatestFiniteMagnitude
        #expect(try box(-far, 0, 1, 1).union(try box(far - far / 4, 0, 1, 1)) == nil)
        #expect(try box(0, 0, 10, 10).union(try box(20, 5, 5, 10)) == (try box(0, 0, 25, 15)))
    }

    /// The point of a box nearest a place is one the box contains, by the half-open rule:
    /// never its right or bottom edge, which belong to the next box over.
    @Test func theNearestPointIsOneTheBoxContains() throws {
        let rect = try box(10, 10, 1, 1)
        for (x, y) in [(0.0, 0.0), (100, 100), (10.5, 10.5), (.nan, 11), (-.infinity, .infinity)] {
            #expect(rect.contains(rect.nearest(x, y)), "\(x),\(y)")
        }
        #expect(rect.nearest(10.5, 10.25) == (try point(10.5, 10.25)))
        #expect(try box(3, 4, 0, 9).nearest(100, 100) == (try point(3, 4)))
    }

    /// Rounded outward, so the whole points still cover what was found, and a negative
    /// coordinate is not moved toward zero as truncation would move it - at any size.
    @Test func theIntegralBoxHoldsTheBox() throws {
        for rect in [try box(-0.6, 10.5, 99.6, 20), try box(0.25, 0.75, 1, 1), try box(-0.5, 0, 9_007_199_254_740_992, 1), try box(-1e300, -0.5, 1e300 + 1e284, 1)] {
            #expect(rect.integral.contains(rect), "\(rect.x),\(rect.y),\(rect.width),\(rect.height)")
        }
    }

    @Test func aRectangleIsSpelledInWholePointsRoundedOutward() throws {
        #expect(try box(-0.6, 10.5, 99.6, 20).description == "-1,10,100,21")
        #expect(try box(0, 0, 1e20, 30).description == "0,0,100000000000000000000,30")
    }

    /// What is printed reads back as the box it names, and anything else reads as none.
    @Test func theSpellingReadsBack() throws {
        for rect in [try box(-1920, -98, 1920, 1080), try box(0, 0, 1e20, 30), try box(5, 5, 0, 0), try box(-0.6, 10.5, 99.6, 20)] {
            #expect(ScreenRect(spelled: rect.description) == rect.integral)
        }
        #expect(ScreenRect(spelled: " 1, 2 ,3,4") == (try box(1, 2, 3, 4)))
        for refused in ["1,2,3", "1,2,3,4,5", "1,2,3,4,", "1,,3,4", "1,2,3,-4", "1.5,2,3,4", "nan,0,1,1", "0,0 10x10", ""] {
            #expect(ScreenRect(spelled: refused) == nil, "\(refused)")
        }
    }
}
