import CoreGraphics
import DisplayReading
import ScreenSpace
import Testing

/// The window server's two lists, as a test gives them.
@Suite struct DisplayReadingTests {
    /// A list that answers `ids`, as the window server's two asks do: first how many, then them.
    private func listing(_ ids: [CGDirectDisplayID]) -> OnlineDisplay.DisplayList {
        { room, into, count in
            count?.pointee = room == 0 ? UInt32(ids.count) : min(room, UInt32(ids.count))
            for (index, id) in ids.prefix(Int(room)).enumerated() { into?[index] = id }
            return .success
        }
    }

    /// Active is what the active list holds: a display online and not listed active - asleep,
    /// or a hardware mirror past its primary - is in the layout and is not captured.
    @Test func activeIsWhatTheActiveListHolds() throws {
        let read = try OnlineDisplay.read(online: listing([3, 4]), active: listing([4]))
        #expect(read.map(\.id) == [3, 4])
        #expect(read.map(\.isActive) == [false, true])
    }

    /// A list the window server would not give is said, either list at either of its two asks,
    /// and never read as no display.
    @Test func aRefusedListIsSaid() {
        for failing in [0, 1] {
            var asks = 0
            let refused: OnlineDisplay.DisplayList = { _, _, count in
                defer { asks += 1 }
                count?.pointee = 0
                return asks == failing ? .cannotComplete : .success
            }
            #expect(throws: LayoutUnreadable.list(.cannotComplete)) { try OnlineDisplay.read(online: refused, active: listing([])) }
            asks = 0
            #expect(throws: LayoutUnreadable.list(.cannotComplete)) { try OnlineDisplay.read(online: listing([1]), active: refused) }
        }
    }
}
