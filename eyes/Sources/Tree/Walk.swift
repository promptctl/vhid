import ApplicationServices
import Eyes

/// What one accessibility read came back as, before anything is made of it.
///
/// [LAW:types-are-the-program] Three answers, because two of them are easy to collapse
/// and must not be: an app saying an element has no such attribute has answered, and an
/// app that did not answer has not. Folding the second into the first prunes a subtree
/// and then calls the text missing.
enum Answer: Equatable {
    /// The app answered, with whatever it had.
    case answered
    /// The app answered that there is no such attribute: a leaf has no children, an
    /// unlabelled element has no title.
    case absent
    /// Looked, and this part would not say - the element is skipped and counted.
    case unanswered
}

/// What a read was for, which is the one thing that decides what a generic failure means.
enum Part {
    /// A value, title or description: what an element says.
    case text
    /// A role, position, size, children or window list: what holds the tree together.
    case structure
}

extension Answer {
    /// Every `AXError` a read can return, decided one value at a time: this part went unread
    /// and the walk goes on, or - with no grant - the reader could not look at all and throws.
    /// [LAW:no-silent-failure] Nothing is folded into absence except the codes that mean it.
    init(_ error: AXError, for part: Part) throws(TreeError) {
        switch error {
        case .success: self = .answered
        case .noValue, .attributeUnsupported: self = .absent
        // How AppKit says an element has no such text: measured, TextEdit answers a
        // description read on its text area with it every time, while the value beside it
        // holds the whole document. Read as unanswered, every wordless AppKit element would
        // leave the region unread, and no absence could ever be proven. Only for text: a
        // failed children read taken as "no children" would prune a subtree unseen.
        case .failure: self = part == .text ? .absent : .unanswered
        // The app is busy past the messaging timeout, the element went away mid-walk, or
        // the app does not implement the API. Each is a fact about this element, and the
        // rest of the tree may answer.
        case .cannotComplete, .invalidUIElement, .notImplemented: self = .unanswered
        // Codes a well-behaved app never returns for an attribute read. Another app's
        // implementation is not bound by that, and one odd element must not fail the read
        // of every window, so they too are this part unread.
        case .illegalArgument, .invalidUIElementObserver, .actionUnsupported,
             .notificationUnsupported, .notificationAlreadyRegistered, .notificationNotRegistered,
             .parameterizedAttributeUnsupported, .notEnoughPrecision:
            self = .unanswered
        // No grant: no element anywhere will answer, and waiting will not change that.
        case .apiDisabled: throw .noGrant
        @unknown default: self = .unanswered
        }
    }
}

/// A read that either answered, possibly with nothing, or did not. [LAW:types-are-the-program]
enum Heard<Value> {
    case answered(Value)
    case unanswered

    func map<T>(_ transform: (Value) -> T) -> Heard<T> {
        switch self {
        case .answered(let value): .answered(transform(value))
        case .unanswered: .unanswered
        }
    }

    /// What it said, flattened: nil when it did not answer. Only where a failed read costs
    /// nothing - the role, which names an element and never places or hides one, or a text
    /// already beaten by one that did answer.
    var answer: Value? {
        if case .answered(let value) = self { value } else { nil }
    }
}

extension Heard: Sendable where Value: Sendable {}
extension Heard: Equatable where Value: Equatable {}

/// What one element says about itself, each read as it came back.
///
/// Reads are kept apart rather than failing the element together, because apps fail
/// reads they have no use for. Whether a failed read matters is decided by what the
/// element needed from it.
struct Facts {
    /// `AXUnknown` - the tree's own word - when the app would not name it.
    let role: Role
    /// Its value, title and description, in that order.
    let texts: [Heard<String?>]
    /// Where it is: nil inside when it has no position or no size.
    let frame: Heard<ScreenRect?>
}

/// One element read: what it says, and what is under it.
struct Node<Element> {
    let facts: Facts
    let children: Heard<[Element]>
}

/// An element as something a reading can hold, or why it cannot be.
enum Candidate: Equatable {
    case found(Found)
    case excluded(Exclusion.Reason)
}

/// The part of `frame` a click can reach inside `clip`: none when they do not meet, or when
/// what they share lies wholly under one window in front.
///
/// One rule for an element's children and for a window the tree cannot walk, so "could
/// anything there be seen" means one thing. [LAW:single-enforcer]
func visible(_ frame: ScreenRect, in clip: ScreenRect, under covers: [ScreenRect]) -> ScreenRect? {
    let shared = frame.cgRect.intersection(clip.cgRect)
    guard !shared.isNull, !shared.isEmpty, !covers.contains(where: { $0.cgRect.contains(shared) }) else { return nil }
    return ScreenRect(shared)
}

/// Roles whose frame is an area holding other elements. What such an element says names
/// the area - a window's title, a list's label - and the centre of the area is on whatever
/// sits there, never on the words: measured, a window's title came back at the middle of
/// its document. The words themselves, where they are drawn, are an element of their own.
/// Not a group: on a web page a labelled group is as often a control - an icon button
/// whose only child is its image - pressed at its centre.
let areas: Set<Role> = Set([
    kAXApplicationRole, kAXWindowRole, kAXSheetRole, kAXDrawerRole, kAXScrollAreaRole,
    kAXSplitGroupRole, kAXTabGroupRole, kAXToolbarRole, kAXListRole, kAXOutlineRole, kAXTableRole,
    kAXColumnRole, kAXBrowserRole, kAXLayoutAreaRole, kAXGridRole, kAXRadioGroupRole, kAXMenuRole,
    kAXMenuBarRole, kAXPopoverRole, "AXWebArea",
].map { Role(rawValue: $0) })

extension Node {
    /// The element as a finding: its first text that is not blank, at its own frame, if it
    /// is not an area, and the centre of that frame - the point a click lands on - is
    /// inside `clip` and under none of the windows in front of this one.
    ///
    /// An area is known by its role and children together: a list with nothing under it is
    /// the thing its label names, and its centre is where it is pressed. It is decided first, from reads that arrive with the role, so an area
    /// whose text would not answer never leaves the region unread over words that could
    /// not have been a finding. Placement is decided before text, so an element that could
    /// never be a finding here is unplaced or covered whatever its text reads did - a busy
    /// element off the region does not make the region unread. An element is unanswered
    /// only when a read it needed failed: its frame would not say, or no text answered and
    /// one would not say. [LAW:no-silent-failure] [LAW:effects-at-boundaries] Pure, so
    /// every rule an element is kept or dropped by is tested with facts a test wrote.
    func candidate(in clip: ScreenRect, under covers: [ScreenRect]) -> Candidate {
        let leaf = if case .answered(let children) = children { children.isEmpty } else { false }
        guard leaf || !areas.contains(facts.role) else { return .excluded(.area) }
        if case .answered(let placed) = facts.frame {
            guard let placed, !placed.isEmpty, clip.contains(placed.centre) else { return .excluded(.unplaced) }
            guard !covers.contains(where: { $0.contains(placed.centre) }) else { return .excluded(.covered) }
        }
        guard let text = facts.texts.lazy.compactMap({ $0.answer.flatMap { $0 }.flatMap(Text.init) }).first else {
            return .excluded(facts.texts.contains(.unanswered) ? .unanswered : .wordless)
        }
        guard case .answered(let placed?) = facts.frame else { return .excluded(.unanswered) }
        return .found(Found(text: text, frame: placed, source: .tree(role: facts.role)))
    }
}

extension Facts {
    /// Where this element's children can be clicked, nil when nothing of its frame is left
    /// to see in `clip`, so the walk does not descend.
    ///
    /// Only a scroll area cuts the clip down to its frame: a row scrolled out of its list
    /// is hidden by it, so no click reaches the row, and its centre lies under the toolbar.
    /// Any other element may draw its children outside its own frame - a web page's
    /// dropdown hangs below its header - so they keep the clip it was given, but only while
    /// some of that element can be seen: one wholly off the clip or covered is not
    /// descended into, whatever hangs off it. That bet is what lets a walk reach a window at
    /// all: measured, a full-screen terminal in front held four thousand elements, every
    /// one off the region, and walking them spent the whole element bound. An element with no frame, or an empty one, says nothing
    /// about where its children are, so the walk goes on into it.
    func inner(_ clip: ScreenRect, under covers: [ScreenRect]) -> ScreenRect? {
        guard case .answered(let placed?) = frame, !placed.isEmpty else { return clip }
        guard let shown = visible(placed, in: clip, under: covers) else { return nil }
        return role == Role(rawValue: kAXScrollAreaRole) ? shown : clip
    }
}

/// Where a walk starts: one window's element, the part of the screen a click inside it can
/// reach, and the frames of every window in front of it. Everything under it inherits the
/// covers, and the clip narrowed by each frame on the way down.
struct Root<Element> {
    let element: Element
    let clip: ScreenRect
    let covers: [ScreenRect]
}

/// What a walk established, ready to be judged.
struct Walked: Equatable {
    let found: [Found]
    let examined: Int
    let excluded: [Exclusion]
    let reach: Reach
}

/// How much one walk may read. A tree is read one synchronous call into another process
/// per element, and a browser's is tens of thousands wide, so a walk stops at these and
/// says so in its reach rather than outlasting its caller.
struct Bounds {
    let elements: Limit
    let time: Duration
}

/// One text at one place, whatever role said it: a button and the label inside it are two
/// elements and one thing on screen.
private struct Place: Hashable {
    let text: String
    let frame: ScreenRect
}

/// Each root in turn, front to back, breadth first within it, every element read once,
/// until the roots run out or a bound is hit - so a walk cut short has spent its bounds on
/// the windows in front, never on the shallow levels of one behind.
///
/// [LAW:dataflow-not-control-flow] An element that will not answer is a value the walk
/// carries on past - counted, and its subtree unread - not an abort: the text is usually
/// in another branch. `unwalked` counts on-screen windows in the region with no element to
/// start from; they were never read, so the region was not read whole.
///
/// Held apart from every accessibility call so the walk, its bounds and its counts are
/// checked with no app to read from. [LAW:effects-at-boundaries]
func walk<Element>(
    from roots: [Root<Element>],
    unwalked: Int,
    within bounds: Bounds,
    elapsed: () -> Duration,
    read: (Element) throws -> Node<Element>
) rethrows -> Walked {
    var found: [Found] = []
    var seen: Set<Place> = []
    var counts: [Exclusion.Reason: Int] = unwalked > 0 ? [.unwalked: unwalked] : [:]
    var examined = 0
    var stop: Stop?

    roots: for start in roots {
        var queue = [start][...]
        while let root = queue.popFirst() {
            guard examined < bounds.elements.count else { stop = .elementLimit(bounds.elements); break roots }
            guard elapsed() < bounds.time else { stop = .timeBudget(bounds.time); break roots }
            let node = try read(root.element)
            examined += 1
            let candidate = node.candidate(in: root.clip, under: root.covers)
            switch candidate {
            case .found(let run) where !seen.insert(Place(text: run.text.value, frame: run.frame)).inserted:
                counts[.duplicate, default: 0] += 1
            case .found(let run): found.append(run)
            case .excluded(let reason): counts[reason, default: 0] += 1
            }
            let inner = node.facts.inner(root.clip, under: root.covers)
            switch (node.children, inner) {
            case (.answered(let children), let inner?):
                queue.append(contentsOf: children.map { Root(element: $0, clip: inner, covers: root.covers) })
            case (.answered, nil): break
            // A subtree unread is one more unanswered part - unless nothing in it could be
            // seen, or this element was already counted as one.
            case (.unanswered, _?) where candidate != .excluded(.unanswered):
                counts[.unanswered, default: 0] += 1
            case (.unanswered, _): break
            }
        }
    }

    // Ordered by the reason's spelling so one screen always reports the same way.
    let excluded = counts.map { Exclusion(reason: $0.key, count: $0.value) }.sorted { $0.reason.rawValue < $1.reason.rawValue }
    let unread = counts[.unanswered] != nil || counts[.unwalked] != nil
    let reach: Reach = stop.map(Reach.stopped) ?? (unread ? .stopped(.unread) : .whole)
    return Walked(found: found, examined: examined, excluded: excluded, reach: reach)
}

/// The on-screen windows any of which can be seen in `region`, front to back, each with
/// the part of it that can be seen there and the frames of every window in front of it -
/// every layer, so the menu bar and the Dock cover what they cover. A window off the
/// region or wholly behind one in front holds nothing to read, so it is never matched,
/// walked or counted. Pure, so the rule is tested with windows a test wrote.
func seen(_ windows: [Window], in region: ScreenRect) -> [Seen] {
    windows.enumerated().compactMap { index, window in
        let covers = windows[..<index].map(\.frame)
        return visible(window.frame, in: region, under: covers).map { Seen(window: window, clip: $0, covers: covers) }
    }
}

/// A window that can be seen, where, and under what.
struct Seen {
    let window: Window
    let clip: ScreenRect
    let covers: [ScreenRect]
}

/// Seen windows as roots to walk, and a count of the ones with no element to start from -
/// an open menu, a system surface, a window whose app would not list it. Those were on
/// screen and never read. [LAW:no-silent-failure]
func plan<Element>(_ seen: [Seen], matched: [UInt32: Element]) -> (roots: [Root<Element>], unwalked: Int) {
    let roots = seen.compactMap { entry in matched[entry.window.id].map { Root(element: $0, clip: entry.clip, covers: entry.covers) } }
    return (roots, seen.count - roots.count)
}

/// Everything that means the tree reader could not look, as opposed to having looked and
/// found nothing. Each one throws, because a returned `Reading` is taken as proof of
/// looking.
public enum TreeError: ReaderError, CustomStringConvertible {
    case noGrant

    public var missingGrant: Bool { self == .noGrant }

    public var description: String {
        switch self {
        case .noGrant:
            "Accessibility is not granted to this process, so no app's elements can be read."
                + " Grant it in System Settings > Privacy & Security > Accessibility."
        }
    }
}
