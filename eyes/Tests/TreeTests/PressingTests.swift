import CoreGraphics
import Testing
import Eyes
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

    final class Asked { var hits = 0 }

    private func probe(_ asked: Asked = Asked(), hit: @escaping (ScreenPoint) throws -> Heard<Int?> = safari,
                       lineages: [Int: Lineage<Int>] = lineages) -> Probe<Int> {
        Probe(hit: { asked.hits += 1; return try hit($0) },
              lineage: { lineages[$0].map(Heard.answered) ?? .unanswered },
              same: ==)
    }

    private func row(_ frame: ScreenRect = frame, source: Source = .tree(role: button)) -> Found {
        Found(text: Text("Target B")!, frame: frame, source: source)
    }

    /// The case measured: a click 4.7 points inside the frame's top pressed the page. The
    /// box comes back within the resolution of the element, never outside it.
    @Test func aFrameWiderThanItsElementIsCutToTheElement() throws {
        guard case .narrowed(let cut) = try probe().press(row()) else { Issue.record("not narrowed"); return }
        let res = Probe<Int>.resolution
        #expect(cut.x >= Self.element.x && cut.x - Self.element.x <= res)
        #expect(cut.y >= Self.element.y && cut.y - Self.element.y <= res)
        #expect(cut.x + cut.width < Self.element.x + Self.element.width && Self.element.x + Self.element.width - (cut.x + cut.width) <= 2 * res)
        #expect(cut.y + cut.height < Self.element.y + Self.element.height && Self.element.y + Self.element.height - (cut.y + cut.height) <= 2 * res)
    }

    /// A row merged from both readers carries the tree's role and frame, and is checked.
    @Test func aMergedRowIsCheckedAsTheTreesRowIs() throws {
        let merged = Source.merged(.tree(role: Self.button), .pixels(confidence: Confidence(0.9)!))
        guard case .narrowed = try probe().press(row(source: merged)) else { Issue.record("not narrowed"); return }
    }

    /// A native control's frame is where it is pressed: the four edges each answer at the
    /// first try, and the box stands.
    @Test func aFramePressedToItsEdgesStandsAfterOneHitAPerEdge() throws {
        let asked = Asked()
        #expect(try probe(asked, hit: { p in .answered(Self.frame.cgRect.contains(CGPoint(x: p.x, y: p.y)) ? 1 : 0) }).press(row()) == .kept)
        #expect(asked.hits == 5)
    }

    /// The pixels reader placed it, so the tree has nothing to check it against.
    @Test func aRowTheTreeDidNotPlaceStandsUnasked() throws {
        let asked = Asked()
        #expect(try probe(asked).press(row(source: .pixels(confidence: Confidence(0.9)!))) == .kept)
        #expect(asked.hits == 0)
    }

    /// Something drawn over the row's point - a page's overlay - is not the element, and
    /// no part of the frame is claimed for it.
    @Test func aRowWhosePointLandsOnSomethingElseIsUnchecked() throws {
        var lineages = Self.lineages
        lineages[9] = Lineage(role: Self.page, frame: ScreenRect(x: 0, y: 0, width: 1500, height: 900), parent: nil)
        #expect(try probe(hit: { _ in .answered(9) }, lineages: lineages).press(row()) == .unchecked)
        #expect(try probe(hit: { _ in .answered(nil) }).press(row()) == .unchecked)
    }

    /// An element whose parents will not say is unknown, not outside the button.
    @Test func anUnansweredReadLeavesTheBoxUnchecked() throws {
        var lineages = Self.lineages
        lineages[0] = nil
        #expect(try probe(lineages: lineages).press(row()) == .unchecked)
        var calls = 0
        let flaky: (ScreenPoint) -> Heard<Int?> = { p in calls += 1; return calls > 3 ? .unanswered : Self.safari(p) }
        #expect(try probe(hit: flaky).press(row()) == .unchecked)
    }

    /// Parents that run in a loop end the climb as unknown.
    @Test func parentsInALoopLeaveTheBoxUnchecked() throws {
        let loop: [Int: Lineage<Int>] = [
            1: Lineage(role: Self.label, frame: Self.text, parent: 2),
            2: Lineage(role: Self.label, frame: Self.text, parent: 1),
        ]
        #expect(try probe(hit: { _ in .answered(1) }, lineages: loop).press(row()) == .unchecked)
    }

    struct Revoked: Error {}

    /// A grant taken away mid-check is the reader blind, said as such, never a row
    /// quietly unchecked.
    @Test func aThrowFromTheHitTestIsThrown() {
        #expect(throws: Revoked.self) { try probe(hit: { _ in throw Revoked() }).press(row()) }
    }
}
