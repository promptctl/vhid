import CoreGraphics
import Testing
@testable import DisplayReading
import ScreenSpace

/// The read against display lists a test wrote: no window server.
@Suite struct DisplayReadingTests {
    /// A list that answers `ids`, all of them, in the one ask it is given.
    static func list(_ ids: [CGDirectDisplayID]) -> DisplayReading.List {
        { room, into, count in
            for (index, id) in ids.prefix(Int(room)).enumerated() { into?[index] = id }
            count?.pointee = UInt32(min(ids.count, Int(room)))
            return .success
        }
    }

    static func bounds(_ id: CGDirectDisplayID) -> CGRect { CGRect(x: Double(id) * 1000, y: 0, width: 1000, height: 800) }

    @Test func aSleepingDisplayIsReadOnlineAndNotActive() throws {
        let layout = try DisplayReading.layout(online: Self.list([1, 2]), active: Self.list([2]), bounds: Self.bounds)
        #expect(layout.displays.map(\.id) == [1, 2])
        #expect(layout.displays.map(\.active) == [false, true])
    }

    @Test func aMacWhoseOnlyDisplayIsAsleepStillHasALayout() throws {
        let layout = try DisplayReading.layout(online: Self.list([1]), active: Self.list([]), bounds: Self.bounds)
        #expect(layout.active.frames.isEmpty)
        #expect(layout.online.frames.count == 1)
    }

    @Test func aListThatFillsTheRoomIsRefusedRatherThanTakenWhole() {
        let many = (1 ... UInt32(DisplayReading.room)).map { $0 }
        #expect(throws: LayoutUnreadable.self) { try DisplayReading.layout(online: Self.list(many), active: Self.list([]), bounds: Self.bounds) }
    }

    @Test func aRefusedListIsSaidAsTheWindowServers() {
        let refused: DisplayReading.List = { _, _, _ in .illegalArgument }
        #expect(throws: LayoutUnreadable.refused("the window server would not list its online displays (CGError \(CGError.illegalArgument.rawValue))")) {
            try DisplayReading.layout(online: refused, active: Self.list([]), bounds: Self.bounds)
        }
    }
}
