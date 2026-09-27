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
    /// Every `AXError` a read can return, decided one value at a time: either this part
    /// went unread and the walk goes on, or the reader could not look at all and throws.
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
        // No grant: no element anywhere will answer, and waiting will not change that.
        case .apiDisabled: throw .noGrant
        // Codes a plain attribute read cannot produce unless this code asked wrongly, so
        // they are a bug in the reader, never a fact about the screen.
        case .illegalArgument, .invalidUIElementObserver, .actionUnsupported,
             .notificationUnsupported, .notificationAlreadyRegistered, .notificationNotRegistered,
             .parameterizedAttributeUnsupported, .notEnoughPrecision:
            throw .unexpected(error.rawValue)
        @unknown default: throw .unexpected(error.rawValue)
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

/// Whether nothing in `frame` can be clicked in `region`: the part of it inside the
/// region is empty, or lies wholly under one window in front.
///
/// One rule for an element's subtree and for a window the tree cannot walk, so "could
/// anything there be seen" means one thing. [LAW:single-enforcer]
func hidden(_ frame: ScreenRect, in region: ScreenRect, under covers: [ScreenRect]) -> Bool {
    let visible = frame.cgRect.intersection(region.cgRect)
    return visible.isNull || visible.isEmpty || covers.contains { $0.cgRect.contains(visible) }
}

extension Facts {
    /// The element as a finding in `region`: its first text that is not blank, at its own
    /// frame, if the centre of that frame - the point a click lands on - is in the region
    /// and under none of the windows in front of this one.
    ///
    /// Placement is decided before text, so an element that could never be a finding here
    /// is unplaced or covered whatever its text reads did - a busy element off the region
    /// does not make the region unread. An element is unanswered only when a read it needed
    /// failed: its frame would not say, or no text answered and one would not say.
    /// [LAW:no-silent-failure] [LAW:effects-at-boundaries] Pure, so every rule an element
    /// is kept or dropped by is tested with facts a test wrote.
    func candidate(in region: ScreenRect, under covers: [ScreenRect]) -> Candidate {
        if case .answered(let placed) = frame {
            guard let placed, !placed.isEmpty, region.contains(placed.centre) else { return .excluded(.unplaced) }
            guard !covers.contains(where: { $0.contains(placed.centre) }) else { return .excluded(.covered) }
        }
        guard let text = texts.lazy.compactMap({ $0.answer.flatMap { $0 }.flatMap(Text.init) }).first else {
            return .excluded(texts.contains(.unanswered) ? .unanswered : .wordless)
        }
        guard case .answered(let placed?) = frame else { return .excluded(.unanswered) }
        return .found(Found(text: text, frame: placed, source: .tree(role: role)))
    }

    /// Whether nothing under this element can be a finding, so the walk does not descend.
    ///
    /// Measured, this is what lets a walk reach a window at all: a full-screen terminal in
    /// front held four thousand elements, every one of them off the region asked about,
    /// and walking them spent the whole element bound. A child can lie outside its
    /// parent's frame - scrolled-off rows do - but then it is clipped by that parent and
    /// no click reaches it either. An element with no frame, or an empty one, says
    /// nothing about where its children are, so the walk goes on into it.
    func screensOff(_ region: ScreenRect, under covers: [ScreenRect]) -> Bool {
        guard case .answered(let placed?) = frame, !placed.isEmpty else { return false }
        return hidden(placed, in: region, under: covers)
    }
}

/// Where a walk starts: one window's element, and the frames of every window in front of
/// it, which everything under it inherits.
struct Root<Element> {
    let element: Element
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
    in region: ScreenRect,
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
            let candidate = node.facts.candidate(in: region, under: root.covers)
            switch candidate {
            case .found(let run) where !seen.insert(Place(text: run.text.value, frame: run.frame)).inserted:
                counts[.duplicate, default: 0] += 1
            case .found(let run): found.append(run)
            case .excluded(let reason): counts[reason, default: 0] += 1
            }
            let screened = node.facts.screensOff(region, under: root.covers)
            switch node.children {
            case .answered(let children) where !screened:
                queue.append(contentsOf: children.map { Root(element: $0, covers: root.covers) })
            case .answered: break
            // A subtree unread is one more unanswered part - unless nothing in it could be
            // seen, or this element was already counted as one.
            case .unanswered where !screened && candidate != .excluded(.unanswered):
                counts[.unanswered, default: 0] += 1
            case .unanswered: break
            }
        }
    }

    // Ordered by the reason's spelling so one screen always reports the same way.
    let excluded = counts.map { Exclusion(reason: $0.key, count: $0.value) }.sorted { $0.reason.rawValue < $1.reason.rawValue }
    let unread = counts[.unanswered] != nil || counts[.unwalked] != nil
    let reach: Reach = stop.map(Reach.stopped) ?? (unread ? .stopped(.unread) : .whole)
    return Walked(found: found, examined: examined, excluded: excluded, reach: reach)
}

/// The on-screen windows meeting `region`, front to back, as roots to walk and a count of
/// the ones with nothing to walk.
///
/// `matched` holds the accessibility element found for each window id. A window with none
/// is one of two things. Inside a matched window of its own app, it is that window's sheet
/// or drawer: its elements are under the parent's, so it covers nothing and is not
/// counted. Otherwise it is an open menu, a system surface, or a window whose app would
/// not list it: unwalked, and counted whenever any of it can be seen in the region.
/// [LAW:no-silent-failure] Pure, so the rule is tested with windows a test wrote.
func plan<Element>(_ windows: [Window], in region: ScreenRect, matched: [UInt32: Element]) -> (roots: [Root<Element>], unwalked: Int) {
    let attached = Set(windows.filter { window in
        matched[window.id] == nil && windows.contains {
            $0.pid == window.pid && matched[$0.id] != nil && $0.frame.cgRect.contains(window.frame.cgRect)
        }
    }.map(\.id))
    var roots: [Root<Element>] = []
    var unwalked = 0
    for (index, window) in windows.enumerated() where !attached.contains(window.id) {
        let covers = windows[..<index].filter { !attached.contains($0.id) }.map(\.frame)
        guard !hidden(window.frame, in: region, under: covers) else { continue }
        if let element = matched[window.id] {
            roots.append(Root(element: element, covers: covers))
        } else {
            unwalked += 1
        }
    }
    return (roots, unwalked)
}

/// Everything that means the tree reader could not look, as opposed to having looked and
/// found nothing. Each one throws, because a returned `Reading` is taken as proof of
/// looking.
public enum TreeError: Error, CustomStringConvertible {
    case noGrant
    case unexpected(Int32)

    public var description: String {
        switch self {
        case .noGrant:
            "Accessibility is not granted to this process, so no app's elements can be read."
                + " Grant it in System Settings > Privacy & Security > Accessibility."
        case .unexpected(let code):
            "an accessibility read failed with AXError \(code), which a read of an attribute should never return"
        }
    }
}
