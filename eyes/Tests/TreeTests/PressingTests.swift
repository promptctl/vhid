import CoreGraphics
import Testing
import Eyes
import Grants
@testable import Tree

/// How a row's box is checked against where a click lands, asked of trees a test wrote:
/// each element an Int, the hit test a function of the point.
@Suite struct PressingTests {
    static let button = Role(rawValue: "AXButton")
    static let label = Role(rawValue: "AXStaticText")
    static let page = Role(rawValue: "AXWebArea")

    /// Target B of the probe page as Safari answered on studious: the button's frame
    /// 813,620,97,34, the element the page hit-tests 820,625,87,26, its label inside it.
    static let frame = ScreenRect(x: 813, y: 620, width: 97, height: 34)
    static let element = ScreenRect(x: 820, y: 625, width: 87, height: 26)
    static let text = ScreenRect(x: 825, y: 629, width: 78, height: 18)

    static let lineages: [Int: Lineage<Int>] = [
        0: Lineage(role: page, frame: ScreenRect(x: 0, y: 105, width: 1500, height: 795), parent: nil),
        1: Lineage(role: button, frame: frame, parent: 0),
        2: Lineage(role: label, frame: text, parent: 1),
    ]

    static func safari(_ p: ScreenPoint) -> Heard<Int?> {
        func inside(_ r: ScreenRect) -> Bool { r.cgRect.contains(CGPoint(x: p.x, y: p.y)) }
        return .answered(inside(text) ? 2 : inside(element) ? 1 : 0)
    }

    final class Asked { var hits = 0, parents = 0 }

    private func probe(_ asked: Asked = Asked(), hit: @escaping (ScreenPoint) throws -> Heard<Int?> = safari,
                       lineages: [Int: Lineage<Int>] = lineages, spent: @escaping () -> Bool = { false }) -> Probe<Int> {
        Probe(hit: { asked.hits += 1; return try hit($0) },
              lineage: { lineages[$0].map(Heard.answered) ?? .unanswered },
              parent: { asked.parents += 1; return lineages[$0].map { .answered($0.parent) } ?? .unanswered },
              same: ==, spent: spent)
    }

    private func row(_ frame: ScreenRect = frame, source: Source = .tree(role: button)) -> Found {
        Found(text: Text("Target B")!, frame: frame, source: source)
    }

    /// The case measured: a click 4.7 points inside the frame's top pressed the page. The
    /// box comes back within the resolution of the element, never outside it.
    @Test func aFrameWiderThanItsElementIsCutToTheElement() throws {
        guard case .narrowed(let cut) = try probe().press(row()).pressed else { Issue.record("not narrowed"); return }
        let res = Probe<Int>.resolution
        #expect(cut.x >= Self.element.x && cut.x - Self.element.x <= res)
        #expect(cut.y >= Self.element.y && cut.y - Self.element.y <= res)
        #expect(cut.x + cut.width < Self.element.x + Self.element.width && Self.element.x + Self.element.width - (cut.x + cut.width) <= 2 * res)
        #expect(cut.y + cut.height < Self.element.y + Self.element.height && Self.element.y + Self.element.height - (cut.y + cut.height) <= 2 * res)
    }

    /// A row merged from both readers carries the tree's role and frame, and is checked.
    @Test func aMergedRowIsCheckedAsTheTreesRowIs() throws {
        let merged = Source.merged(.tree(role: Self.button), .pixels(confidence: Confidence(0.9)!))
        guard case .narrowed = try probe().press(row(source: merged)).pressed else { Issue.record("not narrowed"); return }
    }

    /// A native control's frame is where it is pressed: the four edges and four corners
    /// each answer at the first try, and the box stands, its hit tests counted.
    @Test func aFramePressedToItsEdgesStandsAfterOneHitAPerEdgeAndCorner() throws {
        let asked = Asked()
        let checked = try probe(asked, hit: { p in .answered(Self.frame.cgRect.contains(CGPoint(x: p.x, y: p.y)) ? 1 : 0) }).press(row())
        #expect(checked == Checked(.kept, hitTests: 9))
        #expect(asked.hits == 9)
    }

    /// A pill-shaped button's corners press the page though its edges press the button: the
    /// box is drawn in until its corners lie on the button, so no point in it presses beside.
    @Test func aRoundedCornerDrawsTheBoxIn() throws {
        let radius = Self.frame.height / 2
        func onPill(_ p: ScreenPoint) -> Bool {
            let f = Self.frame
            guard f.cgRect.contains(CGPoint(x: p.x, y: p.y)) else { return false }
            let cx = min(max(p.x, f.x + radius), f.x + f.width - radius)
            return (p.x - cx) * (p.x - cx) + (p.y - f.centre.y) * (p.y - f.centre.y) <= radius * radius
        }
        guard case .narrowed(let cut) = try probe(hit: { .answered(onPill($0) ? 1 : 0) }).press(row()).pressed else {
            Issue.record("not narrowed"); return
        }
        let corners = [(cut.x, cut.y), (cut.x + cut.width, cut.y), (cut.x, cut.y + cut.height), (cut.x + cut.width, cut.y + cut.height)]
        #expect(corners.allSatisfy { onPill(ScreenPoint(x: $0.0, y: $0.1)) })
        #expect(cut.width > Self.frame.width - 2 * radius && cut.height > radius)
    }

    /// Time spent on earlier rows leaves this one unchecked and says why, and time running
    /// out partway through a row does the same.
    @Test func aRowTheTimeRanOutOnIsUncheckedOverTime() throws {
        let asked = Asked()
        #expect(try probe(asked, spent: { true }).press(row()) == Checked(.unchecked(.overTime), hitTests: 0))
        #expect(asked.hits == 0)
        var asks = 0
        #expect(try probe(spent: { asks += 1; return asks > 4 }).press(row()) == Checked(.unchecked(.overTime), hitTests: 4))
    }

    /// A probe that lands beside the button climbs only until it meets one of the button's
    /// own ancestors - one parent read - never to the top of the tree.
    @Test func aClimbFromBesideStopsAtTheElementsAncestor() throws {
        var lineages = Self.lineages
        lineages[0] = Lineage(role: Self.page, frame: ScreenRect(x: 0, y: 105, width: 1500, height: 795), parent: 10)
        for at in 10..<20 { lineages[at] = Lineage(role: Self.page, frame: nil, parent: at == 19 ? nil : at + 1) }
        lineages[3] = Lineage(role: Self.label, frame: nil, parent: 0)
        var beside = 0
        let hit: (ScreenPoint) -> Heard<Int?> = { p in
            guard Self.element.cgRect.contains(CGPoint(x: p.x, y: p.y)) else { beside += 1; return .answered(3) }
            return .answered(1)
        }
        let asked = Asked()
        guard case .narrowed = try probe(asked, hit: hit, lineages: lineages).press(row()).pressed else { Issue.record("not narrowed"); return }
        // The button's parents once, 0 and 10 through 19 and the top's nil, then one per probe beside.
        #expect(beside > 0)
        #expect(asked.parents == 12 + beside)
    }

    /// The pixels reader placed it, so the tree has nothing to check it against.
    @Test func aRowTheTreeDidNotPlaceStandsUnasked() throws {
        let asked = Asked()
        #expect(try probe(asked).press(row(source: .pixels(confidence: Confidence(0.9)!))) == Checked(.kept, hitTests: 0))
        #expect(asked.hits == 0)
    }

    /// Something drawn over the row's point - a page's overlay - is not the element, and
    /// no part of the frame is claimed for it.
    @Test func aRowWhosePointLandsOnSomethingElseIsUnchecked() throws {
        var lineages = Self.lineages
        lineages[9] = Lineage(role: Self.page, frame: ScreenRect(x: 0, y: 0, width: 1500, height: 900), parent: nil)
        #expect(try probe(hit: { _ in .answered(9) }, lineages: lineages).press(row()) == Checked(.unchecked(.elsewhere), hitTests: 1))
        #expect(try probe(hit: { _ in .answered(nil) }).press(row()) == Checked(.unchecked(.elsewhere), hitTests: 1))
    }

    /// An element whose parents will not say is unknown, not outside the button.
    @Test func anUnansweredReadLeavesTheBoxUnchecked() throws {
        var lineages = Self.lineages
        lineages[0] = nil
        #expect(try probe(lineages: lineages).press(row()).pressed == .unchecked(.unanswered))
        var calls = 0
        let flaky: (ScreenPoint) -> Heard<Int?> = { p in calls += 1; return calls > 3 ? .unanswered : Self.safari(p) }
        #expect(try probe(hit: flaky).press(row()) == Checked(.unchecked(.unanswered), hitTests: 4))
    }

    /// Parents that run in a loop end the climb as unknown.
    @Test func parentsInALoopLeaveTheBoxUnchecked() throws {
        let loop: [Int: Lineage<Int>] = [
            1: Lineage(role: Self.label, frame: Self.text, parent: 2),
            2: Lineage(role: Self.label, frame: Self.text, parent: 1),
        ]
        #expect(try probe(hit: { _ in .answered(1) }, lineages: loop).press(row()).pressed == .unchecked(.unanswered))
    }

    /// A merge whose tree could not look holds only the pixels' rows: the tree checks none of
    /// them, so it asks no grant and makes no call, and the pixels' answer stands.
    @Test @MainActor func theTreeAsksNothingOfAReadingWithNoRowOfItsOwn() async throws {
        let seen = Found(text: Text("OK")!, frame: Self.frame, source: .pixels(confidence: Confidence(0.9)!))
        let reading = Reading(outcome: .matched(Matches([seen])!), scope: Scope(region: Self.frame, examined: 1, reach: .whole))
        let tree = TreeReader(granted: { _ in Issue.record("the grant was asked"); return false })
        #expect(try await tree.pressing(reading) == reading)
    }

    struct Revoked: Error {}

    /// A grant taken away mid-check is the reader blind, said as such, never a row
    /// quietly unchecked.
    @Test func aThrowFromTheHitTestIsThrown() {
        #expect(throws: Revoked.self) { try probe(hit: { _ in throw Revoked() }).press(row()) }
    }
}
