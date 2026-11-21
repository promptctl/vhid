import CoreGraphics
import Testing
@testable import ScreenSpace

/// The one layout both halves read, parsed from readings a test writes: no window server.
@Suite struct DisplayLayoutTests {
    private func online(_ id: CGDirectDisplayID, _ x: Double, _ y: Double, _ width: Double, _ height: Double, active: Bool = true) -> OnlineDisplay {
        OnlineDisplay(id: id, bounds: CGRect(x: x, y: y, width: width, height: height), isActive: active)
    }

    /// Two displays side by side, one asleep: both are in the layout, the extent holds both,
    /// and only the awake one is active.
    @Test func aSleepingDisplayIsInTheLayoutAndNotActive() throws {
        let layout = try DisplayLayout([online(1, 0, 0, 1600, 900, active: false), online(2, -1920, -100, 1920, 1080)])
        #expect(layout.displays.map(\.id) == [1, 2])
        #expect(layout.extent == (try box(-1920, -100, 3520, 1080)))
        #expect(layout.active.map(\.id) == [2])
    }

    /// A Mac whose only display is asleep still has a layout.
    @Test func aLoneSleepingDisplayIsALayout() throws {
        let layout = try DisplayLayout([online(1, 0, 0, 1600, 900, active: false)])
        #expect(layout.extent == (try box(0, 0, 1600, 900)))
        #expect(layout.active.isEmpty)
    }

    /// A display with no area is kept, showing nothing.
    @Test func aDisplayWithNoAreaIsKept() throws {
        #expect(try DisplayLayout([online(1, 0, 0, 1600, 900), online(2, 1600, 0, 0, 0)]).displays.count == 2)
    }

    /// Bounds that are no box are refused by the display and the bounds it gave; no display
    /// is no layout; displays further apart than a Double spans are no layout either.
    @Test func whatIsNoLayoutIsRefusedByName() throws {
        #expect(throws: LayoutUnreadable.bounds(display: 7, NotABox(x: 0, y: 0, width: -5, height: 900))) {
            try DisplayLayout([online(1, 0, 0, 1600, 900), online(7, 0, 0, -5, 900)])
        }
        #expect(LayoutUnreadable.bounds(display: 7, NotABox(x: 0, y: 0, width: .nan, height: 900)).description
            == "display 7's bounds: 0,0,nan,900 is not a box on the screen")
        #expect(throws: LayoutUnreadable.noDisplay) { try DisplayLayout([]) }
        let far = Double.greatestFiniteMagnitude
        #expect(throws: LayoutUnreadable.self) { try DisplayLayout([online(1, -far, 0, 10, 10), online(2, far / 2, 0, 10, 10)]) }
        // Its sides each a Double, its diagonal past one: two points inside lie further apart
        // than a Double says.
        #expect(throws: LayoutUnreadable.self) { try DisplayLayout([online(1, -far / 2, -far / 2, 10, 10), online(2, far / 2 - 10, far / 2 - 10, 10, 10)]) }
    }

    /// A display's record is the six numbers either wire carries, read back as the display;
    /// numbers that are not one display's are none.
    @Test func aDisplayCrossesAWireAsItsRecord() {
        let display = online(7, -1920, -100.5, 1920, 1080, active: false)
        #expect(display.record == [7, -1920, -100.5, 1920, 1080, 0])
        #expect(OnlineDisplay(record: display.record) == display)
        for refused: [Double] in [[7, 0, 0, 1, 1], [7.5, 0, 0, 1, 1, 1], [-1, 0, 0, 1, 1, 1], [7, 0, 0, 1, 1, 2]] {
            #expect(OnlineDisplay(record: refused) == nil)
        }
    }
}
