import Foundation
import Testing
import ScreenSpaceTesting
@testable import ScreenSpace

/// Where a point or a box is pressed on a layout a test wrote: the one rule both halves use.
/// [LAW:behavior-not-structure] Each asserts the part and the point, the contract, never how
/// they were worked out.
@Suite struct PlacementTests {
    static func box(_ x: Double, _ y: Double, _ width: Double, _ height: Double) -> ScreenRect {
        try! ScreenRect(x: x, y: y, width: width, height: height)
    }

    static func point(_ x: Double, _ y: Double) -> ScreenPoint { try! ScreenPoint(x: x, y: y) }

    static let main = box(0, 0, 1600, 900)
    /// Left of the main one, at a negative origin.
    static let left = box(-1280, 100, 1280, 800)

    @Test func aBoxWhollyOnADisplayIsPressedAtTheWholePointNearestItsMiddle() throws {
        let shown = try DisplayLayout.at(Self.main).online.place(Self.box(10.25, 20.25, 31, 11)).value
        #expect(shown.part == Self.box(10.25, 20.25, 31, 11))
        #expect(shown.press == Self.point(26, 26))
    }

    @Test func aBoxHangingOffADisplayIsPressedInsideTheShownPart() throws {
        let shown = try DisplayLayout.at(Self.main).online.place(Self.box(1500, 800, 400, 300)).value
        #expect(shown.part == Self.box(1500, 800, 100, 100))
        #expect(shown.press == Self.point(1550, 850))
        #expect(shown.part.contains(shown.press))
    }

    @Test func aBoxAcrossTwoDisplaysIsPressedOnTheOneShowingMoreOfIt() throws {
        let shown = try DisplayLayout.at(Self.main, Self.left).online.place(Self.box(-300, 400, 400, 20)).value
        #expect(shown.part == Self.box(-300, 400, 300, 20))
        #expect(shown.press == Self.point(-150, 410))
    }

    @Test func aBoxUnderAPointASideIsOnNoDisplay() {
        #expect(throws: Unplaced.box(Self.box(10, 10, 0.5, 30))) { try DisplayLayout.at(Self.main).online.place(Self.box(10, 10, 0.5, 30)) }
        // A point a side shown only in a sliver at the edge is no part to press either.
        #expect(throws: Unplaced.box(Self.box(1599.5, 10, 30, 30))) { try DisplayLayout.at(Self.main).online.place(Self.box(1599.5, 10, 30, 30)) }
    }

    @Test func aPointASideIsPressedAtTheWholePointItHolds() throws {
        let shown = try DisplayLayout.at(Self.main).online.place(Self.box(10.5, 10.5, 1, 1)).value
        #expect(shown.press == Self.point(11, 11))
        #expect(shown.part.contains(shown.press))
    }

    @Test func aDocumentFrameFarWiderThanAnyDisplayIsPressedOnTheDisplay() throws {
        let frame = Self.box(-1e20, 100, 2e20, 40)
        let shown = try DisplayLayout.at(Self.main).online.place(frame).value
        #expect(shown.box == frame)
        #expect(shown.part == Self.box(0, 100, 1600, 40))
        #expect(shown.press == Self.point(800, 120))
    }

    @Test func aDisplayAtAFractionalOriginHoldsThePressPoint() throws {
        let display = Self.box(0.5, 0.5, 100, 100)
        let shown = try DisplayLayout.at(display).online.place(Self.box(0, 0, 3, 3)).value
        #expect(shown.part == Self.box(0.5, 0.5, 2.5, 2.5))
        #expect(shown.part.contains(shown.press))
        #expect(display.contains(shown.press))
    }

    @Test func aPointIsPressedWhereItIsAndOnlyOnADisplay() throws {
        #expect(try DisplayLayout.at(Self.main).online.place(Self.point(0, 899.5)).value == Self.point(0, 899.5))
        // Half-open: the far edge is the next display's, or no display's.
        #expect(throws: Unplaced.point(Self.point(1600, 10))) { try DisplayLayout.at(Self.main).online.place(Self.point(1600, 10)) }
    }

    @Test func aSleepingDisplayIsOnlineAndNotActive() throws {
        let layout = DisplayLayout.at(Self.main, Self.left, asleep: [1])
        _ = try layout.online.place(Self.point(10, 10))
        #expect(throws: Unplaced.point(Self.point(10, 10))) { try layout.active.place(Self.point(10, 10)) }
        #expect(try layout.active.place(Self.point(-10, 110)).value == Self.point(-10, 110))
    }
}

@Suite struct LayoutTests {
    @Test func aLayoutCrossesTheWireAsItsFieldsAndComesBackTheSame() throws {
        let layout = DisplayLayout.at(PlacementTests.main, PlacementTests.left, asleep: [2])
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

    /// Boxes near the end of what a Double holds intersect and hold points finitely; the
    /// box holding two of them would reach past it, so their union is refused.
    @Test func boxesNearWhatADoubleHoldsStillIntersectFinitely() throws {
        let wide = PlacementTests.box(8e307, 0, 9e307, 10)
        #expect(wide.intersection(PlacementTests.box(8e307, 0, 5e307, 10)) == PlacementTests.box(8e307, 0, 5e307, 10))
        #expect(wide.intersection(PlacementTests.box(-1.7e308, 0, 1, 1)) == nil)
        #expect(throws: NotABox.self) { try wide.union(PlacementTests.box(-1.7e308, 0, 1, 1)) }
        #expect(wide.contains(PlacementTests.point(1.6e308, 5)))
        #expect(wide.contains(wide.centre))
    }

    /// The centre is the only number a caller actually uses, so it is derived from the
    /// rectangle rather than carried beside it.
    @Test func theCentreIsTheMiddleOfTheRectangle() {
        let rect = PlacementTests.box(100, 200, 60, 40)
        #expect(rect.centre == PlacementTests.point(130, 220))
        #expect(rect.contains(rect.centre))
    }

    /// Overlap is how a merged reading tells one thing seen by both readers from two
    /// things seen once each, so touching-but-not-overlapping must read as separate.
    @Test func rectanglesThatOnlyTouchDoNotIntersect() throws {
        let left = PlacementTests.box(0, 0, 10, 10)
        #expect(!left.intersects(PlacementTests.box(10, 0, 10, 10)))
        #expect(left.intersects(PlacementTests.box(9, 0, 10, 10)))
    }

    /// A box prints its four numbers as given, so what a look prints reads back as itself.
    @Test func aBoxIsSpelledExactlyAndReadBackAsItself() throws {
        let box = PlacementTests.box(-10.5, 2.25, 20, 3.5)
        #expect(box.description == "-10.5,2.25,20,3.5")
        #expect(try ScreenRect(spelled: box.description) == box)
        for refused in ["", "1,2,3", "1,2,3,4,5", "1,,3,4", "a,2,3,4", "0,0 10x10"] {
            #expect(throws: Misspelled.form(refused, wanted: ScreenRect.spelling), "\(refused)") { try ScreenRect(spelled: refused) }
        }
        // Four numbers that are no box are refused as that, not as a misspelling.
        for refused in ["1,2,3,-4", "1,2,inf,4"] {
            #expect(performing: { try ScreenRect(spelled: refused) }, throws: { error in
                if case Misspelled.notABox(refused, _) = error { true } else { false }
            })
        }
        #expect(try ScreenRect(spelled: " -5 ,2.5,1,1") == PlacementTests.box(-5, 2.5, 1, 1))
    }

    /// A point prints as the one spelling `x,y`, and reads back as itself.
    @Test func aPointIsSpelledXYAndReadBackAsItself() throws {
        let point = PlacementTests.point(-3, 4.5)
        #expect(point.description == "-3,4.5")
        #expect(try ScreenPoint(spelled: point.description) == point)
        #expect(throws: Misspelled.form("3", wanted: ScreenPoint.spelling)) { try ScreenPoint(spelled: "3") }
        #expect(performing: { try ScreenPoint(spelled: "nan,1") }, throws: { error in
            if case Misspelled.notAPlace("nan,1", _) = error { true } else { false }
        })
    }

    /// A box whose far edge is past what a Double holds is no box, whatever its numbers'
    /// size: the far edge is where its middle and its parts are worked out from.
    @Test func aBoxWhoseFarEdgeIsPastADoubleIsRefused() {
        #expect(throws: NotABox.self) { try ScreenRect(x: .greatestFiniteMagnitude, y: 0, width: .greatestFiniteMagnitude, height: 1) }
        // No constant bound: a frame 1e20 wide is a box.
        #expect(throws: Never.self) { try ScreenRect(x: -1e20, y: 0, width: 2e20, height: 1) }
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
