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
        (.noValue, .absent), (.attributeUnsupported, .absent),
        (.cannotComplete, .unanswered), (.invalidUIElement, .unanswered), (.notImplemented, .unanswered),
    ])
    func aReadIsAnsweredAbsentOrUnansweredWhateverItWasFor(error: AXError, answer: Answer) throws {
        #expect(try Answer(error, for: .text) == answer)
        #expect(try Answer(error, for: .structure) == answer)
    }

    /// Measured on TextEdit: a text read an element has no use for fails. A failed
    /// children read is never taken as "no children", which would prune a subtree unseen.
    @Test func aFailureIsAbsentTextButUnansweredStructure() throws {
        #expect(try Answer(.failure, for: .text) == .absent)
        #expect(try Answer(.failure, for: .structure) == .unanswered)
    }

    @Test func noGrantThrowsByName() {
        #expect { try Answer(.apiDisabled, for: .structure) } throws: { ($0 as? TreeError).map { if case .noGrant = $0 { true } else { false } } ?? false }
    }

    /// Another app's implementation is not bound by Apple's list of codes, so one odd
    /// element is that element unread - never the whole reading thrown away.
    @Test(arguments: [
        AXError.illegalArgument, .invalidUIElementObserver, .actionUnsupported, .notificationUnsupported,
        .notificationAlreadyRegistered, .notificationNotRegistered, .parameterizedAttributeUnsupported, .notEnoughPrecision,
    ])
    func aCodeNoAttributeReadShouldReturnIsThatPartUnread(error: AXError) throws {
        #expect(try Answer(error, for: .text) == .unanswered)
    }
}

let region = ScreenRect(x: 0, y: 0, width: 1000, height: 800)
let button = ScreenRect(x: 100, y: 100, width: 80, height: 30)

func facts(_ texts: [Heard<String?>] = [.answered("OK")], frame: Heard<ScreenRect?> = .answered(button), role: String = "AXButton", named: Bool = true) -> Facts {
    Facts(role: Role(rawValue: role), texts: texts, frame: frame, named: named)
}

/// The facts of an element with nothing under it, which is most of what a candidate rule asks.
extension Facts {
    func candidate(in clip: ScreenRect, under covers: Covers) -> Candidate {
        Node<String>(facts: self, children: .answered([])).candidate(in: clip, under: covers)
    }
}

@Suite struct CandidateTests {
    /// An area with nothing under it is the thing its label names; one holding something is not.
    @Test func aListWithNothingUnderItIsFoundAndOneHoldingSomethingIsAnArea() {
        let list = facts([.answered("Inbox")], role: "AXList")
        #expect(list.candidate(in: region, under: .none) != .excluded(.area))
        #expect(Node(facts: list, children: .answered(["row"])).candidate(in: region, under: .none) == .excluded(.area))
    }

    /// A web page's labelled icon button is a group holding its image, pressed at its centre.
    @Test func aLabelledGroupHoldingAnIconIsFound() {
        let group = facts([.answered("Settings")], role: "AXGroup")
        #expect(Node(facts: group, children: .answered(["icon"])).candidate(in: region, under: .none) != .excluded(.area))
    }

    /// An area's words could never be a finding, so a text read it failed leaves nothing unread.
    @Test func anAreaWhoseTextWouldNotAnswerIsAnAreaNotUnanswered() {
        let window = facts([.unanswered], frame: .unanswered, role: "AXWindow")
        #expect(Node(facts: window, children: .answered(["title"])).candidate(in: region, under: .none) == .excluded(.area))
    }

    @Test func anElementWithTextInTheRegionIsFoundAtItsFrameWithItsRole() {
        #expect(facts().candidate(in: region, under: .none) == .found(Found(text: Text("OK")!, frame: button, source: .tree(role: Role(rawValue: "AXButton")))))
    }

    /// The first text that says something wins: an empty value gives way to the title.
    @Test func theFirstTextThatIsNotBlankIsTheOneReported() {
        let c = facts([.answered(""), .answered("Save"), .answered("save the document")]).candidate(in: region, under: .none)
        guard case .found(let run) = c else { Issue.record("\(c)"); return }
        #expect(run.text.value == "Save")
    }

    @Test func blankAndMissingTextIsWordless() {
        #expect(facts([.answered("  "), .answered(nil), .answered(nil)]).candidate(in: region, under: .none) == .excluded(.wordless))
    }

    /// Measured on TextEdit: its text area fails the description read and holds the whole
    /// document in its value. The failed read it did not need costs it nothing.
    @Test func aFailedReadAfterTheTextDoesNotLoseTheText() {
        let c = facts([.answered("the document"), .answered(nil), .unanswered]).candidate(in: region, under: .none)
        guard case .found = c else { Issue.record("\(c)"); return }
    }

    /// No text answered and one read would not say: whether it had text is unknown.
    @Test func noTextAndAnUnansweredReadIsUnansweredNotWordless() {
        #expect(facts([.answered(nil), .unanswered, .answered(nil)]).candidate(in: region, under: .none) == .excluded(.unanswered))
    }

    /// A busy element off the region could never have been a finding, so it does not
    /// leave the region unread.
    @Test func anUnansweredTextOffTheRegionIsUnplacedNotUnanswered() {
        let off = ScreenRect(x: 2000, y: 100, width: 80, height: 30)
        #expect(facts([.unanswered], frame: .answered(off)).candidate(in: region, under: .none) == .excluded(.unplaced))
    }

    @Test func aFrameThatWouldNotSayIsUnanswered() {
        #expect(facts(frame: .unanswered).candidate(in: region, under: .none) == .excluded(.unanswered))
    }

    @Test(arguments: [
        nil,
        ScreenRect(x: 100, y: 100, width: 0, height: 30),
        ScreenRect(x: 990, y: 100, width: 80, height: 30),
    ])
    func noFrameAnEmptyOneOrACentreOutsideTheRegionIsUnplaced(frame: ScreenRect?) {
        #expect(facts(frame: .answered(frame)).candidate(in: region, under: .none) == .excluded(.unplaced))
    }

    /// A click at its centre would land on the window in front, so it is not a finding.
    @Test func aCentreUnderAWindowInFrontIsCovered() {
        let front = ScreenRect(x: 120, y: 90, width: 300, height: 300)
        #expect(facts().candidate(in: region, under: .opaque([front])) == .excluded(.covered))
        #expect(facts().candidate(in: region, under: .opaque([ScreenRect(x: 400, y: 400, width: 10, height: 10)])) != .excluded(.covered))
    }

    /// A window in front covers only where a click lands in it: measured, Notification
    /// Center's full-screen window at layer 23 draws nothing but its widgets. A hit test
    /// that does not answer leaves the element unread, never found or covered by guess.
    @Test func aWindowInFrontCoversOnlyWhereTheHitTestLandsInIt() {
        let overlay = [Cover(frame: region, pid: 9)]
        #expect(facts().candidate(in: region, under: Covers(windows: overlay, owner: 1, hit: { _ in .answered(1) })) == .found(Found(text: Text("OK")!, frame: button, source: .tree(role: Role(rawValue: "AXButton")))))
        #expect(facts().candidate(in: region, under: Covers(windows: overlay, owner: 1, hit: { _ in .answered(9) })) == .excluded(.covered))
        #expect(facts().candidate(in: region, under: Covers(windows: overlay, owner: 1, hit: { _ in .unanswered })) == .excluded(.unanswered))
    }

    /// The menu bar is the Window Server's, but a click on it lands in the front app: a
    /// click landing in any process but the element's own covers it.
    @Test func aClickLandingInAnotherProcessCoversWhateverOwnsTheFrameInFront() {
        let menuBar = [Cover(frame: region, pid: 88)]
        #expect(facts().candidate(in: region, under: Covers(windows: menuBar, owner: 1, hit: { _ in .answered(5) })) == .excluded(.covered))
    }

    /// A window of the element's own app in front covers by its frame: a click landing in
    /// that app cannot say which of its windows it hit.
    @Test func aWindowOfTheSameAppInFrontCoversByItsFrame() {
        let sibling = [Cover(frame: region, pid: 1)]
        #expect(facts().candidate(in: region, under: Covers(windows: sibling, owner: 1, hit: { _ in .unanswered })) == .excluded(.covered))
    }

    /// A wordless element could never be a finding, so a hit test that fails over it does
    /// not leave the region unread.
    @Test func aWordlessElementUnderAFrontWindowNeverAsksTheHitTest() {
        let covers = Covers(windows: [Cover(frame: region, pid: 9)], owner: 1, hit: { _ in Issue.record("hit test asked"); return .unanswered })
        #expect(facts([.answered(nil)], role: "AXGroup").candidate(in: region, under: covers) == .excluded(.wordless))
    }
}

@Suite struct DescentTests {
    /// The window: wider than the region, which is its left part.
    let window = ScreenRect(x: 0, y: 0, width: 2000, height: 800)
    let beside = ScreenRect(x: 1500, y: 0, width: 50, height: 50)
    let outside = ScreenRect(x: 3000, y: 0, width: 50, height: 50)

    private func descent(_ frame: ScreenRect?, _ role: String = "AXGroup", named: Bool = true, bound: ScreenRect? = nil,
                         covers: Covers = .none) -> Descent {
        facts(frame: .answered(frame), role: role, named: named).descent(clip: region, bound: bound ?? window, under: covers)
    }

    /// Off the region but inside where it can be drawn: what hangs off it may be seen.
    @Test func anElementOffTheRegionInsideItsBoundHasItsChildrenProbed() {
        #expect(descent(beside) == .probe)
    }

    /// Outside where anything under it can be drawn - a row scrolled out of its list.
    @Test func anElementOutsideItsBoundIsPruned() {
        #expect(descent(outside) == .prune)
    }

    /// What clips its children and is not seen shows none of them.
    @Test func aScrollAreaOrWebAreaNotSeenIsPruned() {
        #expect(descent(beside, "AXScrollArea") == .prune)
        #expect(descent(beside, "AXWebArea") == .prune)
    }

    /// Not seen, and its role would not say whether it clips: not read, counted unread. An
    /// app that answers `AXUnknown` has said it.
    @Test func anUnseenElementWhoseRoleWouldNotAnswerIsUnsure() {
        #expect(descent(beside, "AXUnknown", named: false) == .unsure)
        #expect(descent(beside, "AXUnknown") == .probe)
    }

    /// A clipping element seen cuts both the clip and the bound to its frame; anything else
    /// hands both on.
    @Test func onlyWhatClipsCutsTheClipAndTheBound() {
        let list = ScreenRect(x: 100, y: 100, width: 300, height: 200)
        #expect(descent(list, "AXScrollArea") == .descend(clip: list, bound: list))
        #expect(descent(list, "AXWebArea") == .descend(clip: list, bound: list))
        #expect(descent(list) == .descend(clip: region, bound: window))
    }

    /// Covered in the region, its children may still hang out from under the cover.
    @Test func aCoveredElementHasItsChildrenProbed() {
        #expect(descent(button, covers: .opaque([region])) == .probe)
    }

    /// No frame says nothing about where the children are, so they keep what was given.
    @Test(arguments: [Heard<ScreenRect?>.unanswered, .answered(nil), .answered(ScreenRect(x: 5, y: 5, width: 0, height: 0))])
    func anElementWithNoUsableFrameHandsOnItsClip(frame: Heard<ScreenRect?>) {
        #expect(facts(frame: frame).descent(clip: region, bound: window, under: .none) == .descend(clip: region, bound: window))
    }
}

/// A tree as a test writes it: each element's facts and children by name.
struct FakeTree {
    var nodes: [String: Node<String>]

    func read(_ name: String) -> Node<String> { nodes[name]! }

    func walked(_ roots: [String] = ["window"], covers: Covers = .none, unwalked: Int = 0,
                limit: Int = 100, elapsed: Duration = .zero) -> Walked {
        walk(
            from: roots.map { Root(element: $0, clip: region, bound: ScreenRect(x: 0, y: 0, width: 4000, height: 800), covers: covers) },
            unwalked: unwalked,
            within: Bounds(elements: Limit(limit)!, time: .seconds(5)),
            elapsed: { elapsed },
            read: read
        )
    }
}

func node(_ text: String?, _ frame: ScreenRect? = button, children: Heard<[String]> = .answered([]), role: String = "AXButton") -> Node<String> {
    Node(facts: facts([.answered(text)], frame: .answered(frame), role: role), children: children)
}

@Suite struct WalkTests {
    let dialog = FakeTree(nodes: [
        "window": node("Save changes?", region, children: .answered(["group", "busy"])),
        "group": node(nil, ScreenRect(x: 50, y: 50, width: 400, height: 200), children: .answered(["ok", "label"])),
        "ok": node("OK"),
        // The label inside the button: one text at one place, twice, whatever the roles.
        "label": node("OK", role: "AXStaticText"),
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
        #expect(dialog.walked().reach == .stopped(.unread))
        var answering = dialog
        answering.nodes["busy"] = node("Cancel")
        #expect(answering.walked().reach == .whole)
    }

    @Test func aWindowWithNothingToWalkLeavesTheRegionUnread() {
        let tree = FakeTree(nodes: ["window": node("Hello")])
        let w = tree.walked(unwalked: 2)
        #expect(w.excluded == [Exclusion(reason: .unwalked, count: 2)])
        #expect(w.reach == .stopped(.unread))
    }

    /// A subtree that would not answer under a scroll area off the region could not have
    /// held a finding; under any other element it could have hung into the region.
    @Test func anUnreadSubtreeOffTheRegionIsUnreadUnlessAScrollAreaHidesIt() {
        let far = ScreenRect(x: 3000, y: 0, width: 100, height: 100)
        for (role, reach): (String, Reach) in [("AXScrollArea", .whole), ("AXGroup", .stopped(.unread))] {
            let tree = FakeTree(nodes: [
                "window": node(nil, region, children: .answered(["far"])),
                "far": node(nil, far, children: .unanswered, role: role),
            ])
            #expect(tree.walked().reach == reach)
        }
    }

    /// Unseen, with a role it would not say: whether it hides its children is unknown.
    @Test func anUnseenElementWhoseRoleWouldNotAnswerLeavesItsChildrenUnread() {
        var far = node(nil, ScreenRect(x: 3000, y: 0, width: 100, height: 100), children: .answered(["x"]), role: "AXUnknown")
        far = Node(facts: Facts(role: far.facts.role, texts: far.facts.texts, frame: far.facts.frame, named: false), children: far.children)
        let tree = FakeTree(nodes: [
            "window": node(nil, region, children: .answered(["far"])),
            "far": far,
        ])
        let w = tree.walked()
        #expect(w.examined == 2)
        #expect(w.reach == .stopped(.unread))
    }

    /// Each window is walked to the end before the next, so a bound spends itself on the
    /// window in front and not on the shallow levels of one behind.
    @Test func theFrontWindowIsWalkedWholeBeforeTheNext() {
        let tree = FakeTree(nodes: [
            "front": node(nil, region, children: .answered(["deep"])),
            "deep": node(nil, region, children: .answered(["text"])),
            "text": node("Delete"),
            "behind": node(nil, region, children: .answered(["b1", "b2"])),
            "b1": node("One", ScreenRect(x: 500, y: 500, width: 20, height: 20)),
            "b2": node("Two", ScreenRect(x: 600, y: 500, width: 20, height: 20)),
        ])
        let w = tree.walked(["front", "behind"], limit: 4)
        #expect(w.found.map(\.text.value) == ["Delete"])
        #expect(w.reach == .stopped(.elementLimit(Limit(4)!)))
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

    /// Under a container off the region everything is read, to find what hangs into the
    /// region, and nothing that does not is counted.
    @Test func whatIsProbedAndNotSeenIsNotCounted() {
        let far = ScreenRect(x: 3000, y: 0, width: 100, height: 100)
        let tree = FakeTree(nodes: [
            "window": node(nil, region, children: .answered(["offscreen"])),
            "offscreen": node("Far", far, children: .answered(["child"]), role: "AXGroup"),
            "child": node(nil, far, children: .answered(["leaf"]), role: "AXGroup"),
            "leaf": node("Also far", far),
        ])
        let w = tree.walked()
        #expect(w.examined == 4)
        #expect(w.excluded == [Exclusion(reason: .unplaced, count: 1), Exclusion(reason: .wordless, count: 1)])
        #expect(w.reach == .whole)
    }

    /// A dropdown nested under a wrapper that is off the region too is still found.
    @Test func aChildHangingIntoTheRegionTwoLevelsDownIsFound() {
        let tree = FakeTree(nodes: [
            "window": node(nil, region, children: .answered(["header"]), role: "AXWindow"),
            "header": node(nil, ScreenRect(x: 0, y: 0, width: 400, height: 50), children: .answered(["nav"]), role: "AXGroup"),
            "nav": node(nil, ScreenRect(x: 0, y: 0, width: 200, height: 50), children: .answered(["item"]), role: "AXGroup"),
            "item": node("Sign out", ScreenRect(x: 0, y: 60, width: 120, height: 24), role: "AXMenuItem"),
        ])
        let below = ScreenRect(x: 0, y: 55, width: 1000, height: 745)
        let w = walk(from: [Root(element: "window", clip: below, bound: region, covers: .none)], unwalked: 0,
                     within: Bounds(elements: Limit(100)!, time: .seconds(5)), elapsed: { .zero }, read: tree.read)
        #expect(w.found.map(\.text.value) == ["Sign out"])
    }

    /// The repro: a region starting below a header, whose dropdown item hangs into it.
    /// The header is off the region, and its item is still read and found.
    @Test func aChildHangingIntoTheRegionFromAHeaderOffItIsFound() {
        let tree = FakeTree(nodes: [
            "window": node(nil, region, children: .answered(["header"]), role: "AXWindow"),
            "header": node(nil, ScreenRect(x: 0, y: 0, width: 400, height: 50), children: .answered(["menu"]), role: "AXGroup"),
            "menu": node(nil, ScreenRect(x: 0, y: 60, width: 120, height: 60), children: .answered(["item"]), role: "AXMenu"),
            "item": node("Sign out", ScreenRect(x: 0, y: 60, width: 120, height: 24), role: "AXMenuItem"),
        ])
        let below = ScreenRect(x: 0, y: 55, width: 1000, height: 745)
        let w = walk(from: [Root(element: "window", clip: below, bound: region, covers: .none)], unwalked: 0,
                     within: Bounds(elements: Limit(100)!, time: .seconds(5)), elapsed: { .zero }, read: tree.read)
        #expect(w.found.map(\.text.value) == ["Sign out"])
        #expect(w.reach == .whole)
    }

    /// A scroll area hides what hangs off it, so nothing under one off the region is read.
    @Test func nothingUnderAScrollAreaOffTheRegionIsRead() {
        let tree = FakeTree(nodes: [
            "window": node(nil, region, children: .answered(["list"])),
            "list": node(nil, ScreenRect(x: 3000, y: 0, width: 100, height: 100), children: .answered(["row"]), role: "AXScrollArea"),
        ])
        #expect(tree.walked().examined == 2)
    }

    /// The covers a root starts with reach everything under it.
    @Test func windowsInFrontCoverEveryElementUnderTheRoot() {
        let w = dialog.walked(covers: .opaque([ScreenRect(x: 0, y: 0, width: 1000, height: 120)]))
        #expect(w.found.map(\.text.value) == ["Save changes?"])
        #expect(w.excluded.contains(Exclusion(reason: .covered, count: 3)))
    }

    /// A row scrolled out of its list, still inside the window, sits under the toolbar: it
    /// is clipped by the list, so no click reaches it and nothing under it is read.
    @Test func aRowScrolledOutOfItsListIsNotAFinding() {
        let list = ScreenRect(x: 0, y: 100, width: 400, height: 300)
        let tree = FakeTree(nodes: [
            "window": node(nil, region, children: .answered(["toolbar", "list"]), role: "AXWindow"),
            "toolbar": node("Back", ScreenRect(x: 0, y: 0, width: 80, height: 40)),
            "list": node(nil, list, children: .answered(["shown", "scrolled"]), role: "AXScrollArea"),
            "shown": node("Kept", ScreenRect(x: 0, y: 150, width: 400, height: 20), role: "AXRow"),
            "scrolled": node("Gone", ScreenRect(x: 0, y: 10, width: 400, height: 20), children: .answered(["cell"]), role: "AXRow"),
            "cell": node("Gone", ScreenRect(x: 0, y: 10, width: 400, height: 20), role: "AXStaticText"),
        ])
        let w = tree.walked()
        #expect(w.found.map(\.text.value) == ["Back", "Kept"])
        #expect(w.examined == 5)
        #expect(w.excluded.contains(Exclusion(reason: .unplaced, count: 1)))
    }

    /// Only a scroll area clips: a dropdown hanging below the header that holds it is on
    /// screen and pressed where it is.
    @Test func aChildDrawnOutsideAGroupIsStillFound() {
        let tree = FakeTree(nodes: [
            "window": node(nil, region, children: .answered(["header"]), role: "AXWindow"),
            "header": node(nil, ScreenRect(x: 0, y: 0, width: 400, height: 50), children: .answered(["item"]), role: "AXGroup"),
            "item": node("Sign out", ScreenRect(x: 0, y: 60, width: 120, height: 24), role: "AXMenuItem"),
        ])
        #expect(tree.walked().found.map(\.text.value) == ["Sign out"])
    }

    /// A window's title is where its title bar draws it, not the middle of its document.
    @Test func anAreaSaysNothingAtItsCentreAndItsTitleIsFoundWhereItIsDrawn() {
        let tree = FakeTree(nodes: [
            "window": node("Tree Target", region, children: .answered(["title"]), role: "AXWindow"),
            "title": node("Tree Target", ScreenRect(x: 400, y: 0, width: 200, height: 28), role: "AXStaticText"),
        ])
        let w = tree.walked()
        #expect(w.found.map(\.frame) == [ScreenRect(x: 400, y: 0, width: 200, height: 28)])
        #expect(w.excluded == [Exclusion(reason: .area, count: 1)])
    }

    /// A frameless wrapper under a probe goes on probing: what is under it is not counted.
    @Test func aFramelessWrapperDoesNotEndAProbe() {
        let far = ScreenRect(x: 3000, y: 0, width: 100, height: 100)
        let tree = FakeTree(nodes: [
            "window": node(nil, region, children: .answered(["header"])),
            "header": node(nil, far, children: .answered(["wrapper"]), role: "AXGroup"),
            "wrapper": node(nil, nil, children: .answered(["leaf"]), role: "AXGroup"),
            "leaf": node("Far", far),
        ])
        let w = tree.walked()
        #expect(w.examined == 4)
        #expect(w.excluded == [Exclusion(reason: .unplaced, count: 1), Exclusion(reason: .wordless, count: 1)])
    }

    /// In a browser: the header is inside the page, just above the region, and its
    /// dropdown hangs into it.
    @Test func aDropdownInsideAWebPageHangingIntoTheRegionIsFound() {
        let tree = FakeTree(nodes: [
            "window": node(nil, region, children: .answered(["page"]), role: "AXWindow"),
            "page": node(nil, region, children: .answered(["header"]), role: "AXWebArea"),
            "header": node(nil, ScreenRect(x: 0, y: 0, width: 400, height: 50), children: .answered(["item"]), role: "AXGroup"),
            "item": node("Sign out", ScreenRect(x: 0, y: 60, width: 120, height: 24), role: "AXMenuItem"),
        ])
        let below = ScreenRect(x: 0, y: 55, width: 1000, height: 745)
        let w = walk(from: [Root(element: "window", clip: below, bound: region, covers: .none)], unwalked: 0,
                     within: Bounds(elements: Limit(100)!, time: .seconds(5)), elapsed: { .zero }, read: tree.read)
        #expect(w.found.map(\.text.value) == ["Sign out"])
    }

    /// A row just above the region, inside its list, whose popover hangs into the region.
    @Test func aPopoverHangingFromARowAboveTheRegionIsFound() {
        let tree = FakeTree(nodes: [
            "window": node(nil, region, children: .answered(["list"]), role: "AXWindow"),
            "list": node(nil, region, children: .answered(["row"]), role: "AXScrollArea"),
            "row": node(nil, ScreenRect(x: 0, y: 250, width: 400, height: 40), children: .answered(["pop"]), role: "AXRow"),
            "pop": node("Rename", ScreenRect(x: 0, y: 300, width: 120, height: 40), role: "AXButton"),
        ])
        let below = ScreenRect(x: 0, y: 300, width: 1000, height: 500)
        let w = walk(from: [Root(element: "window", clip: below, bound: region, covers: .none)], unwalked: 0,
                     within: Bounds(elements: Limit(100)!, time: .seconds(5)), elapsed: { .zero }, read: tree.read)
        #expect(w.found.map(\.text.value) == ["Rename"])
    }
}

/// Accessibility frames are global top-left points, the space `vhid click` presses in, so
/// an element on a display left of and above the main one is found at negative points and
/// its centre is the click with no conversion.
@Suite struct DisplayTests {
    let left = ScreenRect(x: -1920, y: -300, width: 1920, height: 1080)

    @MainActor @Test func aFrameAsTheTreeAnswersItIsTheScreenRectUnchanged() {
        var origin = CGPoint(x: -1500, y: -200)
        var size = CGSize(width: 80, height: 30)
        let frame = TreeReader.frame(AXValueCreate(.cgPoint, &origin), AXValueCreate(.cgSize, &size))
        #expect(frame == ScreenRect(x: -1500, y: -200, width: 80, height: 30))
        #expect(frame?.centre == ScreenPoint(x: -1460, y: -185))
    }

    @Test func anElementOnADisplayAtANegativeOriginIsFoundThere() {
        let button = ScreenRect(x: -1500, y: -200, width: 80, height: 30)
        let tree = FakeTree(nodes: [
            "window": node(nil, ScreenRect(x: -1800, y: -250, width: 800, height: 600), children: .answered(["ok"]), role: "AXWindow"),
            "ok": node("OK", button),
        ])
        let w = walk(from: [Root(element: "window", clip: left, bound: region, covers: .none)], unwalked: 0,
                     within: Bounds(elements: Limit(10)!, time: .seconds(5)), elapsed: { .zero }, read: tree.read)
        #expect(w.found.map(\.frame) == [button])
        #expect(w.reach == .whole)
    }
}

@Suite struct PlanTests {
    func window(_ id: UInt32, pid: Int32 = 1, _ frame: ScreenRect) -> Window {
        Window(id: id, owner: "App", pid: pid, frame: frame, layer: 0)
    }

    let document = ScreenRect(x: 100, y: 100, width: 600, height: 400)

    @Test func eachMatchedWindowIsARootCoveredByTheOnesInFront() {
        let front = window(1, pid: 2, ScreenRect(x: 0, y: 0, width: 300, height: 300))
        let (roots, unwalked) = plan(seen([front, window(2, document)], in: region, hit: { _ in .answered(1) }), matched: [1: "front", 2: "doc"])
        #expect(roots.map(\.element) == ["front", "doc"])
        #expect(roots.map { $0.covers.windows.map(\.frame) } == [[], [front.frame]])
        #expect(roots.map(\.clip) == [front.frame, document])
        #expect(unwalked == 0)
    }

    /// An open menu, a status item, a window its app would not list: on screen, nothing in
    /// it read, and it says so - it also covers what is under it.
    @Test func aVisibleWindowWithNothingToWalkIsCountedAndCovers() {
        let menu = window(5, ScreenRect(x: 150, y: 120, width: 200, height: 300))
        let (roots, unwalked) = plan(seen([menu, window(2, document)], in: region, hit: { _ in .answered(1) }), matched: [2: "doc"])
        #expect(roots.map(\.element) == ["doc"])
        #expect(roots[0].covers.windows.map(\.frame) == [menu.frame])
        #expect(unwalked == 1)
    }

    /// Off the region or wholly behind a window in front, a window holds nothing to read.
    @Test func aWindowNothingOfWhichCanBeSeenIsNeitherWalkedNorCounted() {
        let full = window(1, pid: 2, region)
        let visible = seen([full, window(2, document), window(3, pid: 4, ScreenRect(x: 2000, y: 0, width: 10, height: 10))], in: region, hit: { _ in .answered(2) })
        #expect(visible.map(\.window.id) == [1])
        let (roots, unwalked) = plan(visible, matched: [1: "full"])
        #expect(roots.map(\.element) == ["full"])
        #expect(unwalked == 0)
    }

    /// A window over the whole screen that a click passes through hides nothing behind it.
    @Test func aWindowInFrontAClickPassesThroughHidesNothing() {
        let overlay = window(1, pid: 9, region)
        let visible = seen([overlay, window(2, document)], in: region, hit: { _ in .answered(1) })
        #expect(visible.map(\.window.id) == [1, 2])
        #expect(visible.map(\.clip) == [region, document])
    }
}

extension Covers {
    static var none: Covers { Covers(windows: [], owner: 1, hit: { _ in .answered(1) }) }
    /// Windows in front that a click anywhere in them lands on.
    static func opaque(_ frames: [ScreenRect]) -> Covers {
        Covers(windows: frames.map { Cover(frame: $0, pid: 0) }, owner: 1, hit: { _ in .answered(0) })
    }
}
