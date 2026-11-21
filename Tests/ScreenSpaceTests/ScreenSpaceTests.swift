import CoreGraphics
import Testing
@testable import ScreenSpace

/// The one screen space, asked with no display: what is a place, what is a box, how each is
/// written, and what boxes share. [LAW:behavior-not-structure] Each test states what a
/// caller relies on - a frame an app claimed is kept, a printed box reads back - never how
/// the arithmetic got there.
@Suite struct ScreenSpaceTests {
    @Test func aCoordinateIsWrittenInPositionalNotation() {
        #expect((-0.0).positional == "0")
        #expect((0.0).positional == "0")
        #expect((1e-5).positional == "0.00001")
        #expect((1e20).positional == "100000000000000000000")
        #expect((1.5e20).positional == "150000000000000000000")
        #expect((-1e-7).positional == "-0.0000001")
        #expect((300.0).positional == "300")
        #expect((-12.25).positional == "-12.25")
        #expect((0.1).positional == "0.1")
        #expect((9007199254740993.0).positional == "9007199254740992")
        #expect(Double.nan.positional == "nan")
        #expect((-Double.infinity).positional == "-inf")
    }

    /// The shortest digits that read back: nothing a caller is shown names a number other
    /// than the one held.
    @Test func everyCoordinateWrittenReadsBackAsItself() {
        for value: Double in [0.1, 1 / 3, -2.5e-300, 1.7976931348623157e308, 5e-324, 123456.789, -1e15, 4.35] {
            #expect(Double(value.positional) == value, "\(value)")
        }
    }

    @Test func aPointIsTwoFiniteNumbersAndTheRefusalNamesThem() {
        #expect(ScreenPoint(x: -1920, y: 0.5)?.description == "-1920,0.5")
        for (x, y) in [(Double.nan, 0.0), (0, .infinity), (-.infinity, .nan)] {
            #expect(ScreenPoint(x: x, y: y) == nil)
        }
        #expect(throws: NotAPlace.self) { try ScreenPoint.at(.nan, 3) }
        do {
            _ = try ScreenPoint.at(.nan, 3)
        } catch {
            #expect(error.description == "nan,3 is not a place on the screen")
        }
    }

    /// A place a caller or the window server gives is one a display could show: a point
    /// past where any display can be is refused as the non-finite one is, and one at the
    /// near edge of that space is a place.
    @Test func aPlaceIsInsideTheSpaceADisplayCanBeIn() throws {
        #expect(try ScreenPoint.at(-1_000_000, 999_999.5) == ScreenPoint(x: -1_000_000, y: 999_999.5))
        for (x, y) in [(1_000_000.0, 0.0), (0, -1_000_000.5), (1e20, 1e20)] {
            #expect(throws: NotAPlace.self, "\(x),\(y)") { try ScreenPoint.at(x, y) }
        }
    }

    /// A display's bounds are a box a display can be at: a box past that space, or one that
    /// is no box, is no display; one with no area is a display showing nothing, kept.
    @Test func aDisplaysBoundsAreABoxInsideTheDisplaySpace() {
        #expect(ScreenRect(displayBounds: CGRect(x: -1920, y: -98, width: 1920, height: 1080)) == ScreenRect(x: -1920, y: -98, width: 1920, height: 1080))
        #expect(ScreenRect(displayBounds: CGRect(x: 5, y: 5, width: 0, height: 0))?.isEmpty == true)
        for refused in [CGRect(x: CGFloat.nan, y: 0, width: 10, height: 10), CGRect(x: 999_000, y: 0, width: 1920, height: 1080),
                        CGRect(x: 0, y: 0, width: -10, height: 10)] {
            #expect(ScreenRect(displayBounds: refused) == nil, "\(refused)")
        }
    }

    /// The strongest theorem true of every frame a reader is handed: finite numbers, finite
    /// far edges, no side under zero. A frame with no area is one, and one 1e20 wide is one.
    @Test func aBoxIsAnyFrameTheScreenReportsAndNothingElse() {
        #expect(ScreenRect(x: 0, y: 0, width: 0, height: 0)?.isEmpty == true)
        #expect(ScreenRect(x: -400, y: 22, width: 1e20, height: 30)?.width == 1e20)
        let refused: [(Double, Double, Double, Double)] = [
            (.nan, 0, 1, 1), (0, .infinity, 1, 1), (0, 0, .nan, 1), (0, 0, 1, -.infinity),
            (0, 0, -1, 1), (0, 0, 1, -0.5),
            (1.7e308, 0, 1.7e308, 1), (0, 1e308, 1, 1e308),
        ]
        for (x, y, w, h) in refused {
            #expect(ScreenRect(x: x, y: y, width: w, height: h) == nil, "\(x),\(y),\(w),\(h)")
        }
    }

    /// A `CGRect` is read as given, never standardized: a claimed negative size is no box,
    /// not the box that size would reach back over.
    @Test func aCGRectIsReadAsGiven() {
        #expect(ScreenRect(CGRect(x: 10, y: 20, width: 30, height: 40)) == ScreenRect(x: 10, y: 20, width: 30, height: 40))
        #expect(ScreenRect(CGRect(x: 10, y: 20, width: -30, height: 40)) == nil)
        #expect(ScreenRect(CGRect.null) == nil)
    }

    @Test func pointsOfABoxAreHalfOpen() {
        let box = ScreenRect(x: 10, y: 10, width: 10, height: 10)!
        #expect(box.contains(ScreenPoint(x: 10, y: 10)!))
        #expect(box.contains(ScreenPoint(x: 19.99, y: 19.99)!))
        #expect(!box.contains(ScreenPoint(x: 20, y: 15)!))
        #expect(box.contains(box.centre))
    }

    /// The point of a box nearest any two numbers is a point of it, by the half-open rule
    /// every point of a box is held to, whatever the numbers - a NaN goes to the near edge
    /// - and however large the box; a box with no area, holding none, gives its origin.
    @Test func everyNumberHeldToABoxIsAPointOfIt() {
        let box = ScreenRect(x: 10, y: 10, width: 10, height: 10)!
        #expect(box.clamping(x: 100, y: -100) == ScreenPoint(x: 20.0.nextDown, y: 10))
        #expect(box.clamping(x: 15, y: 12) == ScreenPoint(x: 15, y: 12))
        #expect(box.clamping(x: .nan, y: .infinity) == ScreenPoint(x: 10, y: 20.0.nextDown))
        let vast = ScreenRect(x: -5e307, y: -5e307, width: 1e308, height: 1e308)!
        #expect(vast.contains(vast.clamping(x: -.infinity, y: 1e308)))
        #expect(ScreenRect(x: 5, y: 5, width: 0, height: 3)!.clamping(x: 9, y: 9) == ScreenPoint(x: 5, y: 8.0.nextDown))
    }

    /// The part of a box between two places is a box inside it, in either order, however
    /// far past it the places are, and never rebuilt larger than what is left of it.
    @Test func thePartOfABoxBetweenTwoPlacesLiesInsideIt() {
        let box = ScreenRect(x: 0, y: 0, width: 100, height: 50)!
        #expect(box.part(from: (90, 40), to: (10, 5)) == ScreenRect(x: 10, y: 5, width: 80, height: 35))
        #expect(box.part(from: (-1e300, .nan), to: (1e300, 1e300)) == ScreenRect(x: 0, y: 0, width: 100, height: 50))
        #expect(box.part(from: (20, 20), to: (20, 20)) == ScreenRect(x: 20, y: 20, width: 0, height: 0))
        let vast = ScreenRect(x: -8e307, y: 0, width: 1.6e308, height: 1)!
        #expect(vast.contains(vast.part(from: (-.infinity, 0), to: (.infinity, 1))))
    }

    /// Boxes that touch at an edge share no area, which is how one thing seen twice is told
    /// from two things side by side.
    @Test func boxesThatOnlyTouchDoNotMeet() {
        let left = ScreenRect(x: 0, y: 0, width: 10, height: 10)!
        let beside = ScreenRect(x: 10, y: 0, width: 10, height: 10)!
        #expect(left.intersection(beside) == nil)
        #expect(!left.intersects(beside))
        #expect(left.overlap(beside) == 0)
        let over = ScreenRect(x: 9, y: 0, width: 10, height: 10)!
        #expect(left.intersects(over))
        #expect(left.overlap(over) == 10)
        #expect(!ScreenRect(x: 2, y: 2, width: 0, height: 5)!.intersects(left))
    }

    /// What two boxes share is built from their own numbers: a box inside another is
    /// shared as given, and far from the origin a size is never rebuilt from edges, where
    /// `(x + w) - x` is not `w`.
    @Test func theSharedPartKeepsTheSizeItWasGiven() {
        let far = ScreenRect(x: 1e17, y: 0.1, width: 3, height: 0.7)!
        let around = ScreenRect(x: 0, y: 0, width: 1e18, height: 10)!
        #expect(far.intersection(around) == far)
        #expect(around.intersection(far) == far)
        let halves = ScreenRect(x: 0, y: 0, width: 10, height: 10)!.intersection(ScreenRect(x: 5, y: 5, width: 10, height: 10)!)
        #expect(halves == ScreenRect(x: 5, y: 5, width: 5, height: 5))
    }

    @Test func aUnionPastWhatADoubleHoldsIsNone() {
        let left = ScreenRect(x: -1.7e308, y: 0, width: 1, height: 1)!
        let right = ScreenRect(x: 1.7e308, y: 0, width: 1, height: 1)!
        #expect(left.union(right) == nil)
        #expect(ScreenRect(x: 0, y: 0, width: 2, height: 2)!.union(ScreenRect(x: 5, y: 1, width: 1, height: 4)!)
            == ScreenRect(x: 0, y: 0, width: 6, height: 5))
        let far = ScreenRect(x: 1e17, y: 0, width: 3, height: 1)!
        #expect(far.union(ScreenRect(x: 1e17, y: 0, width: 1, height: 1)!) == far)
    }

    /// The centre lies between the edges, so it is a place for every box.
    @Test func theCentreOfEveryBoxIsAPlace() {
        let huge = ScreenRect(x: -1.7e308, y: -1.7e308, width: 1.7e308 * 1.05, height: 1.7e308 * 1.05)!
        #expect(huge.centre.x.isFinite && huge.centre.y.isFinite)
        #expect(ScreenRect(x: 100, y: 200, width: 60, height: 40)!.centre == ScreenPoint(x: 130, y: 220))
    }

    /// Rounded outward, so the whole points printed still cover what was found, and a
    /// negative coordinate is not moved toward zero as truncation would move it.
    @Test func aBoxIsPrintedInWholePointsRoundedOutward() {
        #expect(ScreenRect(x: -0.6, y: 10.5, width: 99.6, height: 20)!.description == "-1,10,100,21")
        #expect(ScreenRect(x: 10.5, y: 3, width: 1, height: 1)!.description == "10,3,2,1")
        #expect(ScreenRect(x: 1e20, y: 0, width: 5, height: 1e-5)!.description == "100000000000000000000,0,5,1")
        // Just left of zero: the fraction above the floor rounds to a whole point, and the
        // printed box still reaches past every point of the one found.
        let slip = ScreenRect(x: -1e-17, y: 0, width: 5e-17, height: 1)!
        #expect(slip.integral == ScreenRect(x: -1, y: 0, width: 2, height: 1))
        // Whole far out, with a fraction near the origin: still holding it all.
        let wide = ScreenRect(x: 0.5, y: 0, width: 1e20, height: 1)!
        #expect(wide.integral.contains(wide))
    }

    /// Every printed box reads back as the box printed, and the reading takes that form and
    /// nothing more.
    @Test func everyPrintedBoxReadsBack() {
        let printed = [
            ScreenRect(x: -1920, y: -98, width: 1920, height: 1080)!, ScreenRect(x: -0.6, y: 10.5, width: 99.6, height: 20)!,
            ScreenRect(x: 1e20, y: -3.5, width: 1e-5, height: 7)!, ScreenRect(x: 4, y: 4, width: 0, height: 0)!,
        ]
        for box in printed {
            #expect(ScreenRect(spelled: box.description) == box.integral, "\(box)")
        }
        #expect(ScreenRect(spelled: "1,2,0,4") == ScreenRect(x: 1, y: 2, width: 0, height: 4))
        for refused in ["1,2,3", "1,2,3,4,5", "1,2,3,4,", "1,,3,4", "1,2,3,-4", " 1,2,3,4", "1.5,2,3,4", "1e3,0,1,1", "--1,0,1,1",
                        "+1,0,1,1", "0,0 10x10", "", "nan,0,1,1"] {
            #expect(ScreenRect(spelled: refused) == nil, "\(refused)")
        }
    }

    @Test func aBoxHoldsTheBoxesInsideIt() {
        let window = ScreenRect(x: 0, y: 0, width: 100, height: 100)!
        #expect(window.contains(ScreenRect(x: 0, y: 0, width: 100, height: 100)!))
        #expect(window.contains(ScreenRect(x: 10, y: 10, width: 0, height: 0)!))
        #expect(!window.contains(ScreenRect(x: 90, y: 90, width: 11, height: 5)!))
    }
}
