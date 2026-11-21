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
        #expect(throws: LayoutUnreadable.bounds(display: 7, CGRect(x: 0, y: 0, width: -5, height: 900))) {
            try DisplayLayout([online(1, 0, 0, 1600, 900), online(7, 0, 0, -5, 900)])
        }
        #expect(LayoutUnreadable.bounds(display: 7, CGRect(x: 0, y: 0, width: Double.nan, height: 900)).description
            == "display 7 has bounds 0,0,nan,900, which are no box on the screen")
        #expect(throws: LayoutUnreadable.noDisplay) { try DisplayLayout([]) }
        let far = Double.greatestFiniteMagnitude
        #expect(throws: LayoutUnreadable.self) { try DisplayLayout([online(1, -far, 0, 10, 10), online(2, far / 2, 0, 10, 10)]) }
        // Its sides each a Double, its diagonal past one: two points inside lie further apart
        // than a Double says.
        #expect(throws: LayoutUnreadable.self) { try DisplayLayout([online(1, -far / 2, -far / 2, 10, 10), online(2, far / 2 - 10, far / 2 - 10, 10, 10)]) }
    }

    /// A list the window server would not give is said, at either of the two asks, and
    /// never read as no display online.
    @Test func aRefusedListIsSaid() {
        for failing in [0, 1] {
            var asks = 0
            let refused: DisplayLayout.DisplayList = { _, _, count in
                defer { asks += 1 }
                count?.pointee = 0
                return asks == failing ? .cannotComplete : .success
            }
            #expect(throws: LayoutUnreadable.list(.cannotComplete)) { try DisplayLayout.online(list: refused) }
        }
    }
}
