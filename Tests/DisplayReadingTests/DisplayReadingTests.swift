import CoreGraphics
import DisplayReading
import ScreenSpace
import Testing

/// The window server's two lists, as a test gives them.
@Suite struct DisplayReadingTests {
    /// A list that answers `ids` as the window server does: as many as there is room for, and
    /// how many it gave.
    private func listing(_ ids: [CGDirectDisplayID]) -> OnlineDisplay.DisplayList {
        { room, into, count in
            count?.pointee = min(room, UInt32(ids.count))
            for (index, id) in ids.prefix(Int(room)).enumerated() { into?[index] = id }
            return .success
        }
    }

    /// A list that fills the room it is given is asked again with more, so a layout of more
    /// displays than the first room is read whole.
    @Test func aListThatFillsItsRoomIsReadWhole() throws {
        let many = (1...40).map(CGDirectDisplayID.init)
        #expect(try OnlineDisplay.read(online: listing(many), active: listing([])).map(\.id) == many)
    }

    /// Active is what the active list holds: a display online and not listed active - asleep,
    /// or a hardware mirror past its primary - is in the layout and is not captured.
    @Test func activeIsWhatTheActiveListHolds() throws {
        let read = try OnlineDisplay.read(online: listing([3, 4]), active: listing([4]))
        #expect(read.map(\.id) == [3, 4])
        #expect(read.map(\.isActive) == [false, true])
    }

    /// A list the window server would not give is said, either list, and never read as no
    /// display.
    @Test func aRefusedListIsSaid() {
        let refused: OnlineDisplay.DisplayList = { _, _, _ in .cannotComplete }
        #expect(throws: LayoutUnreadable.list(.cannotComplete)) { try OnlineDisplay.read(online: refused, active: listing([])) }
        #expect(throws: LayoutUnreadable.list(.cannotComplete)) { try OnlineDisplay.read(online: listing([1]), active: refused) }
    }
}
