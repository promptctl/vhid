import ScreenSpace
import ScreenSpaceTesting
import Testing
@testable import Seeing

/// Where a rectangle named as a region is, on layouts a test writes: no window server.
@MainActor @Suite struct RegionTests {
    /// A rectangle a display shows under a point a side of is refused once, by name, as on
    /// no display - the pressing rule's floor - never handed to the readers to be read as a
    /// blank by one and refused by the other.
    @Test func aRectADisplayShowsASliverOfIsOffScreen() throws {
        let sliver = ScreenRect.at(-100, 10, 100.5, 50)
        let refused = #expect(throws: NoSuchPlace.self) { try Region.rect(sliver).bounds(on: .single) }
        guard case .offScreen(sliver) = refused else { Issue.record("\(String(describing: refused))"); return }
        #expect(try Region.rect(.at(-100, 10, 101, 50)).bounds(on: .single) == .at(-100, 10, 101, 50))
    }

    @Test func aRectWithASideOfZeroIsEmpty() throws {
        let flat = ScreenRect.at(10, 10, 0, 50)
        let refused = #expect(throws: NoSuchPlace.self) { try Region.rect(flat).bounds(on: .single) }
        guard case .empty(flat) = refused else { Issue.record("\(String(describing: refused))"); return }
    }
}
