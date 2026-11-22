import Testing
@testable import ScreenSpace

/// Where the one pressing rule presses, on layouts a test writes: no window server.
///
/// [LAW:behavior-not-structure] These assert the point pressed and the part it is pressed
/// in, which is what a click lands on, never how the parts were searched.
@Suite struct PlacementTests {
    static func box(_ x: Double, _ y: Double, _ width: Double, _ height: Double) throws -> ScreenRect {
        try ScreenRect(x: x, y: y, width: width, height: height)
    }

    /// A main display at the origin and one to its right, the second asleep unless told.
    static func layout(secondActive: Bool = true) throws -> DisplayLayout {
        try DisplayLayout([OnlineDisplay(id: 1, frame: box(0, 0, 1600, 900), active: true),
                           OnlineDisplay(id: 2, frame: box(1600, 0, 1000, 900), active: secondActive)])
    }

    @Test func aPointIsPressedWhereItIsWhenADisplayHoldsIt() throws {
        let point = try ScreenPoint(x: 10.5, y: 20.25)
        #expect(try Self.layout().online.place(point).value == point)
    }

    @Test func aPointOnNoDisplayIsRefusedSayingSo() throws {
        let refused = #expect(throws: Unplaced.self) { try Self.layout().online.place(ScreenPoint(x: -5, y: 10)) }
        #expect(refused?.description.contains("on no display") == true)
    }

    /// Half-open, as `contains` is: the right edge of the main display is the second's.
    @Test func aPointOnTheSeamIsTheDisplayToItsRight() throws {
        let layout = try Self.layout(secondActive: false)
        #expect(throws: Unplaced.self) { try layout.active.place(ScreenPoint(x: 1600, y: 10)) }
        #expect(try layout.online.place(ScreenPoint(x: 1600, y: 10)).value.x == 1600)
    }

    @Test func aBoxHangingOffADisplayIsPressedInThePartItShows() throws {
        let shown = try Self.layout().online.place(Self.box(-100, 100, 200, 50)).value
        #expect(shown.part == (try Self.box(0, 100, 100, 50)))
        #expect(shown.press == (try ScreenPoint(x: 50, y: 125)))
    }

    @Test func aBoxAcrossTwoDisplaysIsPressedOnTheOneShowingMoreOfIt() throws {
        let shown = try Self.layout().online.place(Self.box(1500, 0, 400, 40)).value
        #expect(shown.part == (try Self.box(1600, 0, 300, 40)))
        #expect(shown.part.contains(shown.press))
    }

    /// The readers place on the active displays, so a box mostly on a sleeping one is
    /// pressed in the part the awake one shows.
    @Test func aSleepingDisplayShowsNothingToTheReaders() throws {
        let shown = try Self.layout(secondActive: false).active.place(Self.box(1500, 0, 400, 40)).value
        #expect(shown.part == (try Self.box(1500, 0, 100, 40)))
    }

    @Test func aBoxUnderAPointASideIsRefused() throws {
        #expect(throws: Unplaced.self) { try Self.layout().online.place(Self.box(10, 10, 0.5, 30)) }
        // And so is a box whose only part on a display is under a point wide.
        #expect(throws: Unplaced.self) { try Self.layout().online.place(Self.box(-99.5, 10, 100, 30)) }
    }

    /// An app's claimed frame is kept as given and pressed in what the display shows.
    @Test func aFrameAWorldWideIsPressedOnTheDisplay() throws {
        let frame = try Self.box(-1e20, 0, 2e20, 1e20)
        let shown = try Self.layout().online.place(frame).value
        #expect(shown.bound == frame)
        #expect(shown.part == (try Self.box(0, 0, 1600, 900)))
        #expect(shown.press == (try ScreenPoint(x: 800, y: 450)))
    }

    @Test func aBoxHalfOutsideItsBoundIsPressedInThePartInside() throws {
        let row = try Self.box(100, 380, 200, 40)
        let list = try Self.box(0, 0, 800, 400)
        let shown = try Self.layout().online.place(row, within: list).value
        #expect(shown.part == (try Self.box(100, 380, 200, 20)))
        #expect(shown.press == (try ScreenPoint(x: 200, y: 390)))
        #expect(shown.bound == list)
    }

    @Test func aBoxWhollyOutsideItsBoundIsRefused() throws {
        #expect(throws: Unplaced.self) { try Self.layout().online.place(Self.box(100, 500, 200, 40), within: Self.box(0, 0, 800, 400)) }
    }

    /// The press point is a whole point inside the part however the part sits on the grid:
    /// a part one point wide starting on a whole point is pressed at its left edge, the one
    /// whole point it holds, and not at the right edge it rounds to.
    @Test func thePressPointIsAWholePointInsideThePart() throws {
        for (x, width) in [(0.0, 1.0), (0.5, 1.0), (10.25, 1.5), (3, 7), (-2.75, 4.5)] {
            let shown = try Self.layout().online.place(Self.box(x + 100, 100, width, 30)).value
            #expect(shown.part.contains(shown.press), "\(x),\(width): \(shown.press) outside \(shown.part)")
            #expect(shown.press.x == shown.press.x.rounded() && shown.press.y == shown.press.y.rounded())
        }
    }

    /// A box given back as the part a reading printed is pressed at the point printed beside
    /// it: the part is on one display and at least a point a side, so it places as itself.
    @Test func aPrintedPartPlacesAsItself() throws {
        let layout = try Self.layout()
        let shown = try layout.active.place(Self.box(1500, 380, 400, 40), within: Self.box(0, 0, 3000, 400)).value
        let again = try layout.online.place(shown.part).value
        #expect(again.part == shown.part)
        #expect(again.press == shown.press)
    }

    @Test func layoutsPressAlikeWhateverIsAsleep() throws {
        #expect(try Self.layout().online.pressesAlike(Self.layout(secondActive: false).online))
        let moved = try DisplayLayout([OnlineDisplay(id: 1, frame: Self.box(0, 0, 1600, 900), active: true),
                                       OnlineDisplay(id: 2, frame: Self.box(-1000, 0, 1000, 900), active: true)])
        #expect(try !Self.layout().online.pressesAlike(moved.online))
    }

    /// Two displays of one size side by side show a box across their seam equally: it is
    /// pressed on the one listed first, so one box is pressed in one place every time.
    @Test func aBoxSplitEquallyIsPressedOnTheDisplayListedFirst() throws {
        let twins = try DisplayLayout([OnlineDisplay(id: 1, frame: Self.box(0, 0, 1000, 900), active: true),
                                       OnlineDisplay(id: 2, frame: Self.box(1000, 0, 1000, 900), active: true)])
        #expect(try twins.online.place(Self.box(900, 0, 200, 40)).value.part == (try Self.box(900, 0, 100, 40)))
    }

    /// A mirror set's members share one frame, so a box on it is one part, shown once.
    @Test func aMirrorSetShowsABoxOnce() throws {
        let mirrored = try DisplayLayout([OnlineDisplay(id: 1, frame: Self.box(0, 0, 1600, 900), active: true),
                                          OnlineDisplay(id: 2, frame: Self.box(0, 0, 1600, 900), active: true)])
        let parts = mirrored.online.parts(of: try Self.box(10, 10, 100, 40))
        #expect(parts.map(\.display.id) == [1])
        #expect(parts.map(\.part) == [try Self.box(10, 10, 100, 40)])
    }

    /// A box with a side of zero is refused saying so, not as a box on no display.
    @Test func aBoxWithASideOfZeroIsRefusedSayingSo() throws {
        let flat = #expect(throws: Unplaced.self) { try Self.layout().online.place(Self.box(10, 10, 0, 30)) }
        #expect(flat?.description == "the box 10,10,0,30 has a side of zero")
        let outside = #expect(throws: Unplaced.self) { try Self.layout().online.place(Self.box(100, 500, 200, 40), within: Self.box(0, 0, 800, 400)) }
        #expect(outside?.description == "the box 100,500,200,40 is outside 0,0,800,400, which it is drawn within")
    }

    /// A display with a side under a point, or two listed under one id, is no layout: every
    /// place the rule pressed on it would be pressed on a display that cannot show it.
    @Test func aLayoutWithADisplayShowingNothingOrTwiceIsRefused() throws {
        let thin = #expect(throws: LayoutUnreadable.self) {
            try DisplayLayout([OnlineDisplay(id: 1, frame: Self.box(0, 0, 1600, 0.5), active: true)])
        }
        guard case .empty(1, _) = thin else { Issue.record("\(String(describing: thin))"); return }
        let twice = #expect(throws: LayoutUnreadable.self) {
            try DisplayLayout([OnlineDisplay(id: 1, frame: Self.box(0, 0, 1600, 900), active: true),
                               OnlineDisplay(id: 1, frame: Self.box(1600, 0, 1000, 900), active: true)])
        }
        guard case .sameId(1) = twice else { Issue.record("\(String(describing: twice))"); return }
    }
}
