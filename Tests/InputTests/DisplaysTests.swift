import CoreGraphics
import Testing
@testable import Input
import ScreenSpace

/// What the pointer places on a layout a test writes: a point a display holds, a box cut to
/// the part a display shows, and nothing else, said by name.
@Suite struct DisplaysTests {
    static func displays(_ online: OnlineDisplay...) throws -> Displays { Displays(try DisplayLayout(online)) }

    /// The main display and one to its left, a little higher.
    static let pair = try! displays(OnlineDisplay(id: 1, bounds: CGRect(x: 0, y: 0, width: 1920, height: 1080), isActive: true),
                                    OnlineDisplay(id: 2, bounds: CGRect(x: -1280, y: -200, width: 1280, height: 800), isActive: true))

    /// A point either display holds is placed as it is, a negative one included; a point on
    /// neither, or on a display's far edge, which belongs to the next, is refused saying so.
    @Test func aPointIsPlacedWhenADisplayHoldsIt() throws {
        #expect(try Self.pair.place(ScreenPoint.at(-1000.5, -150)).value == (try ScreenPoint.at(-1000.5, -150)))
        for off in [(-10.0, 700.0), (1920, 10), (5000, 5000)] {
            let point = try ScreenPoint.at(off.0, off.1)
            #expect(throws: OffDisplays(target: .point(point))) { try Self.pair.place(point) }
        }
        #expect(OffDisplays(target: .point(try ScreenPoint.at(1920, 10))).description == "1920,10 is on no display")
    }

    /// A box is pressed in the part the display showing most of it shows: a document frame
    /// 1e20 wide is cut to the screen it runs across, and one astride two displays to the one
    /// holding more of it.
    @Test func aBoxIsCutToThePartTheDisplayShowingMostOfItShows() throws {
        let document = try #require(Target.Box(ScreenRect(x: 46, y: -1_280_000, width: 1e20, height: 1_300_000)))
        #expect(try Self.pair.place(.box(document)).value == .box(try #require(Target.Box(ScreenRect(x: 46, y: 0, width: 1874, height: 1080)))))
        let astride = try #require(Target.Box(ScreenRect(x: -100, y: 10, width: 400, height: 50)))
        #expect(try Self.pair.place(.box(astride)).value == .box(try #require(Target.Box(ScreenRect(x: 0, y: 10, width: 300, height: 50)))))
    }

    /// The largest part a press can land in wins, not the largest part: a box showing a
    /// display a sliver 1000 points long and another a part 10 by 40 is pressed in the part.
    @Test func aBoxIsPressedInTheLargestPartAPressCanLandIn() throws {
        let rows = try Self.displays(OnlineDisplay(id: 1, bounds: CGRect(x: 0, y: 0, width: 1000, height: 100.5), isActive: true),
                                     OnlineDisplay(id: 2, bounds: CGRect(x: 0, y: 100.5, width: 10, height: 100), isActive: true))
        let box = try #require(Target.Box(ScreenRect(x: 0, y: 100, width: 1000, height: 40.5)))
        #expect(try rows.place(.box(box)).value == .box(try #require(Target.Box(ScreenRect(x: 0, y: 100.5, width: 10, height: 40)))))
    }

    /// A box that shows no display a point a side is refused, however much of it there is: on
    /// none, or meeting one in a sliver a press has no point of its own in.
    @Test func aBoxShowingLessThanAPointASideIsRefused() throws {
        for rect in [try ScreenRect(x: 3000, y: 0, width: 50, height: 50), try ScreenRect(x: 1919.5, y: 0, width: 40, height: 40)] {
            let box = try #require(Target.Box(rect))
            #expect(throws: OffDisplays(target: .box(box))) { try Self.pair.place(.box(box)) }
        }
        let box = try #require(Target.Box(ScreenRect(x: 3000, y: 0, width: 50, height: 50)))
        #expect(OffDisplays(target: .box(box)).description == "the box 3000,0,50,50 is on no display, or shows less than a point a side on each it meets")
    }

    /// A Mac whose only display is asleep still has the cursor on it, so a point there is
    /// placed and its edges are edges.
    @Test func aLayoutWithOnlyASleepingDisplayPlaces() throws {
        let asleep = try Self.displays(OnlineDisplay(id: 1, bounds: CGRect(x: 0, y: 0, width: 1600, height: 900), isActive: false))
        #expect(try asleep.place(ScreenPoint.at(800, 450)).value == (try ScreenPoint.at(800, 450)))
        #expect(asleep.isAtEdge(try ScreenPoint.at(1599.5, 450)))
        #expect(!asleep.isAtEdge(try ScreenPoint.at(800, 450)))
    }

    /// An edge is where the displays end; the seam between two side by side is none, and a
    /// point on no display is at no edge.
    @Test func aSeamIsNoEdge() throws {
        #expect(Self.pair.isAtEdge(try ScreenPoint.at(0, 1079.5)))
        #expect(!Self.pair.isAtEdge(try ScreenPoint.at(0.2, 300)))
        #expect(!Self.pair.isAtEdge(try ScreenPoint.at(-5000, 300)))
    }
}
