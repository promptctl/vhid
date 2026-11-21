import Testing
import ScreenSpace

/// The one screen space both halves speak: what is a place in it, and how a place is
/// printed and read back.
@Suite struct ScreenSpaceTests {
    /// A coordinate that is not finite is no place: no report brings the cursor nearer one.
    @Test func aCoordinateThatIsNotFiniteIsNoPoint() {
        for bad in [Double.nan, .infinity, -.infinity] {
            #expect(ScreenPoint(x: bad, y: 0) == nil)
            #expect(ScreenPoint(x: 0, y: bad) == nil)
        }
        #expect(ScreenPoint(x: -1512, y: 0.25) != nil)
    }

    /// A box is finite to its far corners and has no side under zero, and an empty one is a
    /// box: a window or a Vision box can have no size.
    @Test func aBoxIsFiniteToItsFarCornersAndHasNoNegativeSide() {
        #expect(ScreenRect(x: .nan, y: 0, width: 1, height: 1) == nil)
        #expect(ScreenRect(x: 0, y: 0, width: .infinity, height: 1) == nil)
        #expect(ScreenRect(x: 1e308, y: 0, width: 1e308, height: 1) == nil)
        #expect(ScreenRect(x: 0, y: 0, width: -1, height: 1) == nil)
        #expect(ScreenRect(x: 0, y: 0, width: 10, height: 0)?.isEmpty == true)
        #expect(ScreenRect(x: 0, y: 0, width: 10, height: 1)?.isEmpty == false)
    }

    /// A point prints every digit it has, so the point printed is the point passed on.
    @Test func aPointIsPrintedAsItIsPassedOn() {
        #expect(ScreenPoint(x: 1234.5678, y: -3)!.description == "1234.5678,-3")
    }

    /// Rounded outward, so the whole points printed still cover what was found, and a
    /// negative coordinate is not moved toward zero as truncation would move it.
    @Test func aBoxIsSpelledInWholePointsRoundedOutward() {
        #expect(ScreenRect(x: -0.6, y: 10.5, width: 99.6, height: 20)!.description == "-1,10,100,21")
    }

    /// What is printed reads back as the box it names, and anything else reads as none.
    @Test func theSpellingReadsBack() {
        let r = ScreenRect(x: -1920, y: -98, width: 1920, height: 1080)!
        #expect(ScreenRect(spelled: r.description) == r)
        #expect(ScreenRect(spelled: " 1.5, 2 ,3,4") == ScreenRect(x: 1.5, y: 2, width: 3, height: 4))
        for refused in ["1,2,3", "1,2,3,4,5", "1,2,3,4,", "1,,3,4", "1,2,0,4", "1,2,3,-4", "1,2,inf,4", "2000000,0,1,1", "0,0 10x10", ""] {
            #expect(ScreenRect(spelled: refused) == nil, "\(refused)")
        }
    }
}
