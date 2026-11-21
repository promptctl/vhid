import Foundation
import Testing
@testable import ScreenSpace

/// Where a point or a box is pressed on a layout a test wrote: the one rule both halves use.
/// [LAW:behavior-not-structure] Each asserts the part and the point, the contract, never how
/// they were worked out.
@Suite struct PlacementTests {
    static func box(_ x: Double, _ y: Double, _ width: Double, _ height: Double) -> ScreenRect {
        try! ScreenRect(x: x, y: y, width: width, height: height)
    }

    static func point(_ x: Double, _ y: Double) -> ScreenPoint { try! ScreenPoint(x: x, y: y) }

    static func layout(_ bounds: ScreenRect..., active: Set<Int> = []) -> DisplayLayout {
        try! DisplayLayout(bounds.enumerated().map { OnlineDisplay(id: UInt32($0.offset + 1), bounds: $0.element, active: active.isEmpty || active.contains($0.offset)) })
    }

    static let main = box(0, 0, 1600, 900)
    /// Left of the main one, at a negative origin.
    static let left = box(-1280, 100, 1280, 800)

    @Test func aBoxWhollyOnADisplayIsPressedAtTheWholePointNearestItsMiddle() throws {
        let shown = try Self.layout(Self.main).online.place(Self.box(10.25, 20.25, 31, 11)).value
        #expect(shown.part == Self.box(10.25, 20.25, 31, 11))
        #expect(shown.press == Self.point(26, 26))
    }

    @Test func aBoxHangingOffADisplayIsPressedInsideTheShownPart() throws {
        let shown = try Self.layout(Self.main).online.place(Self.box(1500, 800, 400, 300)).value
        #expect(shown.part == Self.box(1500, 800, 100, 100))
        #expect(shown.press == Self.point(1550, 850))
        #expect(shown.part.contains(shown.press))
    }

    @Test func aBoxAcrossTwoDisplaysIsPressedOnTheOneShowingMoreOfIt() throws {
        let shown = try Self.layout(Self.main, Self.left).online.place(Self.box(-300, 400, 400, 20)).value
        #expect(shown.part == Self.box(-300, 400, 300, 20))
        #expect(shown.press == Self.point(-150, 410))
    }

    @Test func aBoxUnderAPointASideIsOnNoDisplay() {
        #expect(throws: Unplaced.box(Self.box(10, 10, 0.5, 30))) { try Self.layout(Self.main).online.place(Self.box(10, 10, 0.5, 30)) }
        // A point a side shown only in a sliver at the edge is no part to press either.
        #expect(throws: Unplaced.box(Self.box(1599.5, 10, 30, 30))) { try Self.layout(Self.main).online.place(Self.box(1599.5, 10, 30, 30)) }
    }

    @Test func aPointASideIsPressedAtTheWholePointItHolds() throws {
        let shown = try Self.layout(Self.main).online.place(Self.box(10.5, 10.5, 1, 1)).value
        #expect(shown.press == Self.point(11, 11))
        #expect(shown.part.contains(shown.press))
    }

    @Test func aDocumentFrameFarWiderThanAnyDisplayIsPressedOnTheDisplay() throws {
        let frame = Self.box(-1e20, 100, 2e20, 40)
        let shown = try Self.layout(Self.main).online.place(frame).value
        #expect(shown.box == frame)
        #expect(shown.part == Self.box(0, 100, 1600, 40))
        #expect(shown.press == Self.point(800, 120))
    }

    @Test func aDisplayAtAFractionalOriginHoldsThePressPoint() throws {
        let display = Self.box(0.5, 0.5, 100, 100)
        let shown = try Self.layout(display).online.place(Self.box(0, 0, 3, 3)).value
        #expect(shown.part == Self.box(0.5, 0.5, 2.5, 2.5))
        #expect(shown.part.contains(shown.press))
        #expect(display.contains(shown.press))
    }

    @Test func aPointIsPressedWhereItIsAndOnlyOnADisplay() throws {
        #expect(try Self.layout(Self.main).online.place(Self.point(0, 899.5)).value == Self.point(0, 899.5))
        // Half-open: the far edge is the next display's, or no display's.
        #expect(throws: Unplaced.point(Self.point(1600, 10))) { try Self.layout(Self.main).online.place(Self.point(1600, 10)) }
    }

    @Test func aSleepingDisplayIsOnlineAndNotActive() throws {
        let layout = Self.layout(Self.main, Self.left, active: [1])
        _ = try layout.online.place(Self.point(10, 10))
        #expect(throws: Unplaced.point(Self.point(10, 10))) { try layout.active.place(Self.point(10, 10)) }
        #expect(try layout.active.place(Self.point(-10, 110)).value == Self.point(-10, 110))
    }
}

@Suite struct LayoutTests {
    @Test func aLayoutCrossesTheWireAsItsFieldsAndComesBackTheSame() throws {
        let layout = PlacementTests.layout(PlacementTests.main, PlacementTests.left, active: [0])
        #expect(try DisplayLayout(fields: layout.fields) == layout)
    }

    @Test func aListWithNoDisplayOrADisplayWithNoAreaIsNoLayout() {
        #expect(throws: LayoutUnreadable.noDisplay) { try DisplayLayout([]) }
        let flat = OnlineDisplay(id: 1, bounds: PlacementTests.box(0, 0, 1600, 0), active: true)
        #expect(throws: LayoutUnreadable.arealess(flat)) { try DisplayLayout([flat]) }
    }

    @Test func displaysFurtherApartThanADoubleHoldsAreNoLayout() {
        let far = [PlacementTests.box(-1.7e308, 0, 10, 10), PlacementTests.box(1.7e308, 0, 10, 10)]
        #expect(throws: LayoutUnreadable.unbounded(far)) {
            try DisplayLayout(far.enumerated().map { OnlineDisplay(id: UInt32($0.offset), bounds: $0.element, active: true) })
        }
    }

    @Test func aWireRecordOfTheWrongShapeIsRefusedByName() {
        #expect(throws: LayoutUnreadable.notARecord([1, 0, 0, 10])) { try DisplayLayout(fields: [1, 0, 0, 10]) }
        #expect(throws: LayoutUnreadable.notARecord([1, 0, 0, 10, 10, 2])) { try DisplayLayout(fields: [1, 0, 0, 10, 10, 2]) }
    }
}

@Suite struct ScreenRectTests {
    @Test func aBoxIsFourFiniteNumbersWithNoSideUnderZero() throws {
        #expect(throws: NotABox.self) { try ScreenRect(x: .nan, y: 0, width: 1, height: 1) }
        #expect(throws: NotABox.self) { try ScreenRect(x: 0, y: 0, width: -1, height: 1) }
        #expect(throws: NotAPlace.self) { try ScreenPoint(x: .infinity, y: 0) }
        // Empty is a box: a window or a Vision box can have no area.
        #expect(try ScreenRect(x: 0, y: 0, width: 0, height: 5).isEmpty)
    }

    @Test func boxesReachingPastWhatADoubleHoldsStillIntersectFinitely() throws {
        let wide = PlacementTests.box(1e308, 0, 1e308, 10)
        #expect(wide.intersection(PlacementTests.box(1e308, 0, 5e307, 10)) == PlacementTests.box(1e308, 0, 5e307, 10))
        #expect(wide.intersection(PlacementTests.box(-1.7e308, 0, 1, 1)) == nil)
        #expect(throws: NotABox.self) { try wide.union(PlacementTests.box(-1.7e308, 0, 1, 1)) }
        #expect(wide.contains(PlacementTests.point(1.7e308, 5)))
    }

    /// The centre is the only number a caller actually uses, so it is derived from the
    /// rectangle rather than carried beside it.
    @Test func theCentreIsTheMiddleOfTheRectangle() throws {
        let rect = PlacementTests.box(100, 200, 60, 40)
        #expect(try rect.centre == PlacementTests.point(130, 220))
        #expect(rect.contains(try rect.centre))
    }

    /// Overlap is how a merged reading tells one thing seen by both readers from two
    /// things seen once each, so touching-but-not-overlapping must read as separate.
    @Test func rectanglesThatOnlyTouchDoNotIntersect() throws {
        let left = PlacementTests.box(0, 0, 10, 10)
        #expect(!left.intersects(PlacementTests.box(10, 0, 10, 10)))
        #expect(left.intersects(PlacementTests.box(9, 0, 10, 10)))
    }

    @Test func aBoxIsSpelledInWholePointsRoundedOutAndReadBack() {
        let box = PlacementTests.box(-10.5, 2.25, 20, 3.5)
        #expect(box.description == "-11,2,21,4")
        #expect(ScreenRect(spelled: box.description) == PlacementTests.box(-11, 2, 21, 4))
        for refused in ["", "1,2,3", "1,2,3,4,5", "1,2,3,-4", "1,,3,4", "a,2,3,4", "1,2,inf,4", "0,0 10x10"] {
            #expect(ScreenRect(spelled: refused) == nil, "\(refused)")
        }
        #expect(ScreenRect(spelled: " -5 ,2.5,1,1") == PlacementTests.box(-5, 2.5, 1, 1))
        #expect(PlacementTests.point(-3, 4.5).description == "-3,4.5")
    }
}

@Suite struct ScreenPointTests {
    /// [LAW:parse-dont-validate] A pair that is not a place is refused where it is made.
    /// The NaN is the one that matters: every comparison against it is false, so it passes
    /// the pointer's arrival test on both axes and the click lands wherever the cursor was.
    @Test(arguments: [(Double.nan, 0.0), (0.0, Double.nan), (.infinity, 0.0), (0.0, -.infinity), (.nan, .nan)])
    func aCoordinateThatIsNotANumberIsNotAPlace(x: Double, y: Double) {
        #expect(throws: NotAPlace.self) { try ScreenPoint(x: x, y: y) }
    }

    /// And refused again on the way in from a script or a request, so nothing decodes into
    /// a point the constructor would not have made. [LAW:single-enforcer]
    @Test func aDecodedCoordinateCrossesTheSameRefusal() throws {
        #expect(throws: (any Error).self) { try JSONDecoder().decode(ScreenPoint.self, from: Data(#"{"x":1e400,"y":1}"#.utf8)) }
        let fine = try JSONDecoder().decode(ScreenPoint.self, from: Data(#"{"x":800,"y":500.5}"#.utf8))
        #expect(fine == (try ScreenPoint(x: 800, y: 500.5)))
    }

}
