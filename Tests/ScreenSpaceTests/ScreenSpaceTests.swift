import CoreGraphics
import Testing
import ScreenSpace

/// The one screen space both halves speak: what is a place in it, how a place is printed
/// and read back, and the geometry of boxes in it.
@Suite struct ScreenSpaceTests {
    /// A coordinate that is not finite is no place: no report brings the cursor nearer one.
    /// Nor is one past where a Double holds every whole point.
    @Test func aCoordinateThatIsNotFiniteOrPastTheSpaceIsNoPoint() {
        for bad in [Double.nan, .infinity, -.infinity, ScreenPoint.farthest * 2] {
            #expect(ScreenPoint(x: bad, y: 0) == nil)
            #expect(ScreenPoint(x: 0, y: bad) == nil)
        }
        #expect(ScreenPoint(x: -1512, y: 0.25) != nil)
        #expect(ScreenPoint(x: -ScreenPoint.farthest, y: ScreenPoint.farthest) != nil)
    }

    /// Every door refuses a pair in the same words, a whole number without its `.0`.
    @Test func aPairThatIsNoPlaceIsRefusedInOneSpelling() throws {
        let refusal = #expect(throws: NotAPlace.self) { try ScreenPoint.at(.infinity, 2) }
        #expect(refusal?.description == "(inf, 2) is not a place on the screen")
        #expect(try ScreenPoint.at(-5, 10) == ScreenPoint(x: -5, y: 10))
    }

    /// A box lies within the space to its far edges and has no side under zero, and an
    /// empty one is a box: a window or a Vision box can have no size.
    @Test func aBoxLiesWithinTheSpaceAndHasNoNegativeSide() {
        #expect(ScreenRect(x: .nan, y: 0, width: 1, height: 1) == nil)
        #expect(ScreenRect(x: 0, y: 0, width: .infinity, height: 1) == nil)
        #expect(ScreenRect(x: ScreenPoint.farthest, y: 0, width: 1e10, height: 1) == nil)
        #expect(ScreenRect(x: 0, y: 0, width: -1, height: 1) == nil)
        #expect(ScreenRect(x: 0, y: 0, width: 10, height: 0)?.isEmpty == true)
        #expect(ScreenRect(x: 0, y: 0, width: 10, height: 1)?.isEmpty == false)
    }

    /// CoreGraphics reports a negative size as its magnitude; the box is read as given, so a
    /// frame an app claims with a size under zero is refused, not mirrored about its origin.
    @Test func aCoreGraphicsRectWithANegativeSizeIsNoBox() {
        #expect(ScreenRect(CGRect(x: 100, y: 100, width: -50, height: 20)) == nil)
        #expect(ScreenRect(CGRect.null) == nil)
        #expect(ScreenRect(CGRect(x: -10, y: 5, width: 50, height: 20)) == ScreenRect(x: -10, y: 5, width: 50, height: 20))
    }

    /// A point prints every digit it has, so the point printed is the point passed on, in
    /// the figures a box beside it prints, however large, and with no sign on a zero.
    @Test func aPointIsPrintedAsItIsPassedOn() {
        #expect(ScreenPoint(x: 1234.5678, y: -3)!.description == "1234.5678,-3")
        #expect(ScreenPoint(x: -0.0, y: 0)!.description == "0,0")
        #expect(ScreenPoint(x: ScreenPoint.farthest, y: 0)!.description == "9007199254740992,0")
        #expect(ScreenRect(x: ScreenPoint.farthest - 4, y: 0, width: 4, height: 1)!.description == "9007199254740988,0,4,1")
    }

    /// Rounded outward, so the whole points printed still cover what was found, and a
    /// negative coordinate is not moved toward zero as truncation would move it.
    @Test func aBoxIsSpelledInWholePointsRoundedOutward() {
        #expect(ScreenRect(x: -0.6, y: 10.5, width: 99.6, height: 20)!.description == "-1,10,100,21")
    }

    /// What is printed reads back as the box it names, empty ones too, and anything else,
    /// or a box reaching past the limit, reads as none.
    @Test func theSpellingReadsBack() {
        for r in [ScreenRect(x: -1920, y: -98, width: 1920, height: 1080)!, ScreenRect(x: 3, y: 4, width: 0, height: 0)!] {
            #expect(ScreenRect(spelled: r.description) == r)
        }
        #expect(ScreenRect(spelled: " 1.5, 2 ,3,4") == ScreenRect(x: 1.5, y: 2, width: 3, height: 4))
        for refused in ["1,2,3", "1,2,3,4,5", "1,2,3,4,", "1,,3,4", "1,2,3,-4", "1,2,inf,4", "2000000,0,1,1", "999999,0,999999,1", "0,0 10x10", ""] {
            #expect(ScreenRect(spelled: refused) == nil, "\(refused)")
        }
    }

    /// Two boxes meet where they share area, and only there: touching at an edge is not
    /// meeting, so a merged reading takes two things side by side as two. What the part they
    /// share, whether they meet and how much they share say agree, as one rule.
    @Test func boxesMeetOnlyWhereTheyShareArea() {
        let left = ScreenRect(x: 0, y: 0, width: 10, height: 10)!
        let touching = ScreenRect(x: 10, y: 0, width: 10, height: 10)!
        let over = ScreenRect(x: 9, y: 2, width: 10, height: 10)!
        #expect(left.intersection(touching) == nil)
        #expect(!left.intersects(touching))
        #expect(left.overlap(touching) == 0)
        #expect(left.intersection(over) == ScreenRect(x: 9, y: 2, width: 1, height: 8))
        #expect(left.intersects(over))
        #expect(left.overlap(over) == 8)
        #expect(left.intersection(ScreenRect(x: 5, y: 5, width: 0, height: 0)!) == nil)
    }

    /// Boxes as far apart as the space allows hold a box between them, so the box holding
    /// both, rounding out and the point nearest a place are boxes and points again.
    @Test func theGeometryOfBoxesStaysInTheSpace() {
        let far = ScreenPoint.farthest
        let a = ScreenRect(x: -far, y: -far, width: 1, height: 1)!
        let b = ScreenRect(x: far - 1, y: far - 1, width: 1, height: 1)!
        #expect(a.union(b) == ScreenRect(x: -far, y: -far, width: 2 * far, height: 2 * far))
        #expect(ScreenRect(x: -0.5, y: 0.5, width: 1, height: 1)!.integral == ScreenRect(x: -1, y: 0, width: 2, height: 2))
        let box = ScreenRect(x: 10, y: 20, width: 30, height: 40)!
        #expect(box.nearest(x: 1e300, y: -1e300) == ScreenPoint(x: 40, y: 20))
        #expect(box.nearest(x: 15, y: 25) == ScreenPoint(x: 15, y: 25))
        #expect(ScreenRect.spanning(ScreenPoint(x: 5, y: 1)!, ScreenPoint(x: 1, y: 9)!) == ScreenRect(x: 1, y: 1, width: 4, height: 8))
        #expect(box.contains(ScreenRect(x: 10, y: 20, width: 30, height: 40)!))
        #expect(!box.contains(ScreenRect(x: 9, y: 20, width: 2, height: 2)!))
    }
}
