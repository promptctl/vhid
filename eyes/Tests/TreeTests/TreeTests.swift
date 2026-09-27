import ApplicationServices
import Testing
import Eyes
@testable import Tree

/// Every rule the tree reader keeps or drops an element by, asked with trees a test wrote.
@Suite struct AnswerTests {
    /// Each value decided, and decided on purpose: a code missing here is a code the
    /// mapping has not been checked for.
    @Test(arguments: [
        (AXError.success, Answer.answered),
        (.noValue, .absent), (.attributeUnsupported, .absent), (.failure, .absent),
        (.cannotComplete, .unanswered), (.invalidUIElement, .unanswered), (.notImplemented, .unanswered),
    ])
    func aReadIsAnsweredAbsentOrUnanswered(error: AXError, answer: Answer) throws {
        #expect(try Answer(error) == answer)
    }

    @Test func noGrantThrowsByName() {
        #expect { try Answer(.apiDisabled) } throws: { ($0 as? TreeError).map { if case .noGrant = $0 { true } else { false } } ?? false }
    }

    @Test(arguments: [
        AXError.illegalArgument, .invalidUIElementObserver, .actionUnsupported, .notificationUnsupported,
        .notificationAlreadyRegistered, .notificationNotRegistered, .parameterizedAttributeUnsupported, .notEnoughPrecision,
    ])
    func aCodeNoAttributeReadReturnsIsABugNotAFact(error: AXError) {
        #expect { try Answer(error) } throws: {
            ($0 as? TreeError).map { if case .unexpected(error.rawValue) = $0 { true } else { false } } ?? false
        }
    }
}

let region = ScreenRect(x: 0, y: 0, width: 1000, height: 800)
let button = ScreenRect(x: 100, y: 100, width: 80, height: 30)

func facts(_ texts: [Heard<String?>] = [.answered("OK")], frame: Heard<ScreenRect?> = .answered(button), role: String = "AXButton") -> Facts {
    Facts(role: Role(rawValue: role), texts: texts, frame: frame)
}

@Suite struct CandidateTests {
    @Test func anElementWithTextInTheRegionIsFoundAtItsFrameWithItsRole() {
        #expect(facts().candidate(in: region, under: []) == .found(Found(text: Text("OK")!, frame: button, source: .tree(role: Role(rawValue: "AXButton")))))
    }

    /// The first text that says something wins: an empty value gives way to the title.
    @Test func theFirstTextThatIsNotBlankIsTheOneReported() {
        let c = facts([.answered(""), .answered("Save"), .answered("save the document")]).candidate(in: region, under: [])
        guard case .found(let run) = c else { Issue.record("\(c)"); return }
        #expect(run.text.value == "Save")
    }

    @Test func blankAndMissingTextIsWordless() {
        #expect(facts([.answered("  "), .answered(nil), .answered(nil)]).candidate(in: region, under: []) == .excluded(.wordless))
    }

    /// Measured on TextEdit: its text area fails the description read and holds the whole
    /// document in its value. The failed read it did not need costs it nothing.
    @Test func aFailedReadAfterTheTextDoesNotLoseTheText() {
        let c = facts([.answered("the document"), .answered(nil), .unanswered]).candidate(in: region, under: [])
        guard case .found = c else { Issue.record("\(c)"); return }
    }

    /// No text answered and one read would not say: whether it had text is unknown.
    @Test func noTextAndAnUnansweredReadIsUnansweredNotWordless() {
        #expect(facts([.answered(nil), .unanswered, .answered(nil)]).candidate(in: region, under: []) == .excluded(.unanswered))
    }

    @Test func aFrameThatWouldNotSayIsUnanswered() {
        #expect(facts(frame: .unanswered).candidate(in: region, under: []) == .excluded(.unanswered))
    }

    @Test(arguments: [
        nil,
        ScreenRect(x: 100, y: 100, width: 0, height: 30),
        ScreenRect(x: 990, y: 100, width: 80, height: 30),
    ])
    func noFrameAnEmptyOneOrACentreOutsideTheRegionIsUnplaced(frame: ScreenRect?) {
        #expect(facts(frame: .answered(frame)).candidate(in: region, under: []) == .excluded(.unplaced))
    }

    /// A click at its centre would land on the window in front, so it is not a finding.
    @Test func aCentreUnderAWindowInFrontIsCovered() {
        let front = ScreenRect(x: 120, y: 90, width: 300, height: 300)
        #expect(facts().candidate(in: region, under: [front]) == .excluded(.covered))
        #expect(facts().candidate(in: region, under: [ScreenRect(x: 400, y: 400, width: 10, height: 10)]) != .excluded(.covered))
    }
}

@Suite struct ScreensOffTests {
    @Test func aFrameOffTheRegionHoldsNothing() {
        #expect(facts(frame: .answered(ScreenRect(x: 2000, y: 0, width: 50, height: 50))).screensOff(region, under: []))
    }

    /// Only the part inside the region matters: a window mostly off it, whose visible
    /// part is under a window in front, holds nothing to click.
    @Test func theVisiblePartUnderOneWindowInFrontHoldsNothing() {
        let wide = ScreenRect(x: -500, y: 0, width: 800, height: 400)
        #expect(facts(frame: .answered(wide)).screensOff(region, under: [ScreenRect(x: 0, y: 0, width: 300, height: 400)]))
        #expect(!facts(frame: .answered(wide)).screensOff(region, under: [ScreenRect(x: 0, y: 0, width: 200, height: 400)]))
    }

    /// No frame says nothing about where the children are, so the walk goes on.
    @Test(arguments: [Heard<ScreenRect?>.unanswered, .answered(nil), .answered(ScreenRect(x: 5, y: 5, width: 0, height: 0))])
    func anElementWithNoUsableFrameIsDescendedInto(frame: Heard<ScreenRect?>) {
        #expect(!facts(frame: frame).screensOff(region, under: []))
    }
}

/// A tree as a test writes it: each element's facts and children by name.
struct FakeTree {
    var nodes: [String: Node<String>]

    func read(_ name: String) -> Node<String> { nodes[name]! }

    func walked(_ roots: [String] = ["window"], covers: [ScreenRect] = [], unansweredRoots: Int = 0,
                limit: Int = 100, elapsed: Duration = .zero) -> Walked {
        walk(
            from: roots.map { Root(element: $0, covers: covers) },
            unansweredRoots: unansweredRoots,
            in: region,
            within: Bounds(elements: Limit(limit)!, time: .seconds(5)),
            elapsed: { elapsed },
            read: read
        )
    }
}

func node(_ text: String?, _ frame: ScreenRect? = button, children: Heard<[String]> = .answered([]), texts: [Heard<String?>]? = nil) -> Node<String> {
    Node(facts: facts(texts ?? [.answered(text)], frame: .answered(frame)), children: children)
}

@Suite struct WalkTests {
    let dialog = FakeTree(nodes: [
        "window": node("Save changes?", region, children: .answered(["group", "busy"])),
        "group": node(nil, ScreenRect(x: 50, y: 50, width: 400, height: 200), children: .answered(["ok", "label"])),
        "ok": node("OK"),
        // The label inside the button: one text at one place, twice.
        "label": node("OK"),
        "busy": node("Cancel", ScreenRect(x: 300, y: 100, width: 80, height: 30), children: .unanswered),
    ])

    @Test func everyElementIsReadOnceAndEachOneIsCounted() {
        let w = dialog.walked()
        #expect(w.found.map(\.text.value) == ["Save changes?", "Cancel", "OK"])
        #expect(w.examined == 5)
        #expect(w.excluded == [
            Exclusion(reason: .duplicate, count: 1), Exclusion(reason: .unanswered, count: 1), Exclusion(reason: .wordless, count: 1),
        ])
    }

    /// A subtree that went unread keeps the region from having been read whole, so a busy
    /// app can never prove an absence.
    @Test func anUnreadSubtreeStopsTheReachShort() {
        #expect(dialog.walked().reach == .stopped(.unanswered))
        var answering = dialog
        answering.nodes["busy"] = node("Cancel")
        #expect(answering.walked().reach == .whole)
    }

    @Test func aWindowThatCouldNotBeListedIsUnansweredToo() {
        let tree = FakeTree(nodes: ["window": node("Hello")])
        let w = tree.walked(unansweredRoots: 2)
        #expect(w.excluded == [Exclusion(reason: .unanswered, count: 2)])
        #expect(w.reach == .stopped(.unanswered))
    }

    @Test func theElementBoundStopsTheWalkAndSaysSo() {
        let w = dialog.walked(limit: 2)
        #expect(w.examined == 2)
        #expect(w.reach == .stopped(.elementLimit(Limit(2)!)))
    }

    @Test func theTimeBoundStopsTheWalkAndSaysSo() {
        let w = dialog.walked(elapsed: .seconds(5))
        #expect(w.examined == 0)
        #expect(w.reach == .stopped(.timeBudget(.seconds(5))))
    }

    /// Nothing under a container off the region is read at all.
    @Test func aContainerOffTheRegionIsNotDescendedInto() {
        let tree = FakeTree(nodes: [
            "window": node(nil, region, children: .answered(["offscreen"])),
            "offscreen": node(nil, ScreenRect(x: 3000, y: 0, width: 100, height: 100), children: .answered(["never"])),
        ])
        let w = tree.walked()
        #expect(w.examined == 2)
        #expect(w.reach == .whole)
    }

    /// The covers a root starts with reach everything under it.
    @Test func windowsInFrontCoverEveryElementUnderTheRoot() {
        let w = dialog.walked(covers: [ScreenRect(x: 0, y: 0, width: 1000, height: 120)])
        #expect(w.found.map(\.text.value) == ["Save changes?"])
        #expect(w.excluded.contains(Exclusion(reason: .covered, count: 3)))
    }
}
