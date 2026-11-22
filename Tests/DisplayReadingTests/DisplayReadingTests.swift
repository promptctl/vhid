import CoreGraphics
import Testing
@testable import DisplayReading
import ScreenSpace

/// The window server's display lists as `DisplayLayout.read` takes them, from lists a test
/// writes: what the window server would not give is said, and what it gives is read whole.
@Suite struct DisplayListTests {
    /// A list the window server would not give is said, at either of the two asks, naming
    /// the list and the code, and never read as no display.
    @Test func aListNotGivenIsSaidAtEitherAsk() {
        for failing in [0, 1] {
            var asks = 0
            let refused: DisplayList = { _, _, count in
                defer { asks += 1 }
                count?.pointee = 0
                return asks == failing ? .cannotComplete : .success
            }
            #expect(throws: LayoutUnreadable.windowServer(list: "online", code: CGError.cannotComplete.rawValue)) {
                try DisplayLayout.list("online", refused)
            }
        }
    }

    /// A display that comes online between the count and the list is read with the rest:
    /// the list is asked again with more room until it fits.
    @Test func aListThatGrowsBetweenAsksIsReadWhole() throws {
        var listed: [CGDirectDisplayID] = [1]
        let growing: DisplayList = { room, ids, count in
            if let ids {
                let given = min(Int(room), listed.count)
                for index in 0 ..< given { ids[index] = listed[index] }
                count?.pointee = UInt32(given)
            } else {
                count?.pointee = UInt32(listed.count)
            }
            // A display comes online after every ask, until there are four.
            if listed.count < 4 { listed.append(CGDirectDisplayID(listed.count + 1)) }
            return .success
        }
        #expect(try DisplayLayout.list("online", growing) == [1, 2, 3, 4])
    }
}
