import Pointing
import Testing
@testable import Input
import ScreenSpace
import ScreenSpaceTesting

/// The table between clicks: what it predicts, and the reports it asks for.
@Suite struct SteeringTests {
    private let curve = try! Steering([
        Steering.Sample(counts: 1, perCount: 1),
        Steering.Sample(counts: 10, perCount: 1),
        Steering.Sample(counts: 20, perCount: 3),
    ])

    /// Straight lines between samples, and the nearest sample beyond them.
    @Test func gainIsInterpolatedBetweenSamples() throws {
        #expect(curve.perCount(0.5) == 1)
        #expect(curve.perCount(15) == 2)
        #expect(curve.perCount(100) == 3)
    }

    /// One report covers a step it can, and the point it lands on is the prediction.
    @Test func aStepIsTheReportThatComesNearest() throws {
        let (reports, lands) = try curve.reports(from: try! ScreenPoint(x: 0, y: 0), to: Displays.vast.at(try! ScreenPoint(x: 8, y: 0)))
        #expect(reports == [Move(x: Count(clamping: 8), y: .zero)])
        #expect(lands == (try! ScreenPoint(x: 8, y: 0)))
    }

    /// A step longer than one report carries goes out as full reports and a last one.
    @Test func aLongStepIsSplitIntoFullReports() throws {
        let (reports, lands) = try curve.reports(from: try! ScreenPoint(x: 0, y: 0), to: Displays.vast.at(try! ScreenPoint(x: 500, y: 0)))
        #expect(reports.dropLast().allSatisfy { $0.x.value == Count.limit })
        #expect(reports.count == 2)
        #expect(abs(lands.x - 500) <= 3)
    }

    /// A diagonal step past one report's reach is split too: the cap is the report's
    /// length, which a diagonal reaches with neither axis at 127.
    @Test func aLongDiagonalStepIsSplitToo() throws {
        let (reports, lands) = try curve.reports(from: try! ScreenPoint(x: 0, y: 0), to: Displays.vast.at(try! ScreenPoint(x: 500, y: 500)))
        #expect(reports.count > 1)
        #expect(abs(lands.x - 500) <= 3 && abs(lands.y - 500) <= 3, "\(lands)")
    }

    /// What no whole count covers is left in the prediction, where the next step makes it up.
    @Test func lessThanACountIsLeftForTheNextStep() throws {
        let (reports, lands) = try curve.reports(from: try! ScreenPoint(x: 0, y: 0), to: Displays.vast.at(try! ScreenPoint(x: 0.4, y: 0)))
        #expect(reports.isEmpty)
        #expect(lands == (try! ScreenPoint(x: 0, y: 0)))
    }

    /// A table in which nothing moved is refused by name.
    @Test func aTableOfNoMotionIsRefused() throws {
        #expect(throws: Steering.Unmoved.self) { try Steering([Steering.Sample(counts: 1, perCount: 0)]) }
    }
}
