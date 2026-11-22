import ScreenSpace

/// A string with something in it other than blank space.
///
/// [LAW:parse-dont-validate] A caller holding one cannot be holding `""` or `"   "`, so
/// nothing downstream re-checks. The accessibility tree answers the empty string for
/// elements that hold no text and a single space for spacers and blank labels about as
/// often, and a reading that carried either would be mostly rows saying nothing at a
/// coordinate - which is the thing this type exists to make unspellable. Whitespace
/// *around* text is kept: `" OK "` is a row that says OK, and trimming it would be this
/// type editing the screen rather than describing it.
public struct Text: Sendable, Hashable, CustomStringConvertible {
    public let value: String

    /// Refuses a string with nothing but blank space in it. The one crossing, and its
    /// output type is the proof it was made.
    public init?(_ value: String) {
        guard value.contains(where: { !$0.isWhitespace }) else { return nil }
        self.value = value
    }

    public var description: String { value }

    /// Words joined by a space, which cannot be blank because the first word is not.
    init(joining words: [Text]) {
        self.value = words.map(\.value).joined(separator: " ")
    }
}

/// One word on screen and where it is, the smallest piece a reader can place.
public struct Word: Sendable, Hashable {
    public let text: Text
    public let frame: ScreenRect

    public init(text: Text, frame: ScreenRect) {
        self.text = text
        self.frame = frame
    }
}

/// One piece of text on screen, as the words it is made of, and where a click presses it.
///
/// Words and not one rectangle, because a reader's run is not always one thing: measured,
/// Vision reads a menu bar's "Shell Edit View Session" as a single run, and the centre of
/// that run is on no menu at all. Carrying where each word sits is what lets a match be
/// narrowed to the stretch that matched, so a found point lands on what was asked for.
/// Never empty, for the reason `Matches` is not. [LAW:types-are-the-program]
///
/// Placed once, by the one pressing rule, from its words within its bound - the region cut
/// by every list viewport and web page above it - on the active displays. The bound goes
/// with the row, so every way to place its words again places them within it: a row half
/// under its list's edge stays pressed in the part a person sees, however it is narrowed,
/// cut or split. No constructor places words without a bound. [LAW:single-enforcer]
public struct Found: Sendable, Hashable {
    public let first: Word
    public let rest: [Word]
    public let source: Source
    /// Where the row is pressed: its bound, the part of it a display shows, and the point.
    public let placed: Placed<Shown>

    private init(first: Word, rest: [Word], source: Source, placed: Placed<Shown>) {
        self.first = first
        self.rest = rest
        self.source = source
        self.placed = placed
    }

    /// `first` and `rest`, placed from the box holding them all, within `bound` on `displays`.
    public init(first: Word, rest: [Word], source: Source, within bound: ScreenRect, on displays: Displays) throws(Unshown) {
        var held = first.frame
        for word in rest {
            do { held = try held.union(word.frame) } catch { throw .notABox(error) }
        }
        let placed: Placed<Shown>
        do { placed = try displays.place(held, within: bound) } catch { throw .unplaced(error) }
        self.init(first: first, rest: rest, source: source, placed: placed)
    }

    /// One run placed as a whole, from its own frame.
    public init(text: Text, frame: ScreenRect, source: Source, within bound: ScreenRect, on displays: Displays) throws(Unshown) {
        try self.init(first: Word(text: text, frame: frame), rest: [], source: source, within: bound, on: displays)
    }

    /// One run already placed as a whole - what the accessibility tree reports, whose frame
    /// is placed before its text is read. Its word's frame is the box `placed` was placed
    /// from, so the two cannot disagree. [LAW:one-source-of-truth]
    public init(text: Text, source: Source, placed: Placed<Shown>) {
        self.init(first: Word(text: text, frame: placed.value.box), rest: [], source: source, placed: placed)
    }

    /// Other words of `row` - a stretch narrowed to, pieces joined, a merge's split - placed
    /// as `row` is: within its bound, on its displays.
    public init(first: Word, rest: [Word], source: Source, placedAs row: Found) throws(Unshown) {
        try self.init(first: first, rest: rest, source: source, within: row.bound, on: row.placed.displays)
    }

    /// The row cut to `box`, the part of it a click presses what it names, placed within its
    /// bound on its displays.
    public func cut(to box: ScreenRect) throws(Unplaced) -> Found {
        Found(first: first, rest: rest, source: source, placed: try placed.displays.place(box, within: bound))
    }

    /// The row as `source` says it was seen, where it was placed.
    public func seen(by source: Source) -> Found {
        Found(first: first, rest: rest, source: source, placed: placed)
    }

    public var words: [Word] { [first] + rest }

    /// The words read as one line, derived so it cannot disagree with them.
    public var text: Text { Text(joining: words.map(\.text)) }

    /// What the row is drawn within, which every placing of its words again keeps to.
    public var bound: ScreenRect { placed.value.bound }

    /// The part of the row one display shows: what a reading orders, compares and prints as
    /// the row's box.
    public var part: ScreenRect { placed.value.part }

    /// The whole point in `part` a click presses the row at.
    public var press: ScreenPoint { placed.value.press }
}

/// Why a row's words were not placed: together they make no box, or no display shows a
/// part of them a point a side within their bound. Counted by `reason`: text read, not placed.
public enum Unshown: Error, Hashable, CustomStringConvertible {
    case notABox(NotABox)
    case unplaced(Unplaced)

    public var description: String {
        switch self {
        case .notABox(let why): "the words together make no box: \(why)"
        case .unplaced(let why): "\(why)"
        }
    }

    /// The reason a reading counts the words by.
    public var reason: Exclusion.Reason {
        switch self {
        case .notABox: .notABox
        case .unplaced: .unshown
        }
    }
}

/// An element or a run as something a reading can hold, or why it cannot be.
public enum Candidate: Sendable, Hashable {
    case found(Found)
    case excluded(Exclusion.Reason)
}

/// Which reader found it, carrying what only that reader can know.
///
/// [LAW:types-are-the-program] A role and a confidence as two optionals on `Found` would
/// admit four combinations where the domain has two: pixels carry no role, and the tree
/// reports no confidence. Attached to the source instead, the impossible pair cannot be
/// spelled and no caller guards for it.
public enum Source: Sendable, Hashable {
    /// Read from the accessibility tree, which names what kind of element it was, and what
    /// else the element says in words besides the row's text: a "+" button's description "Add".
    /// The element's frame, as it claimed it, goes with the row apart from where the row is
    /// placed: the press check finds the element again by it.
    case tree(role: Role, frame: ScreenRect, also: [Words])
    /// Recognised from pixels, which know nothing of elements and answer with how sure
    /// the recogniser was.
    case pixels(confidence: Confidence)
    /// Found by both readers of a merged read at the same place, first reader first -
    /// each still carrying what only it can know.
    indirect case merged(Source, Source)

    /// The element's role, when a reader that knows roles saw it: what tells a page's
    /// button from a browser bookmark of the same name, or a field from its label.
    public var role: Role? { element?.role }

    /// The element the tree read it from, by its role and the frame it claimed, when a
    /// reader that reads elements saw it.
    public var element: (role: Role, frame: ScreenRect)? {
        switch self {
        case .tree(let role, let frame, _): (role, frame)
        case .pixels: nil
        case .merged(let a, let b): a.element ?? b.element
        }
    }

    /// What else the element says in words, when a reader that reads elements saw it.
    public var also: [Words] {
        switch self {
        case .tree(_, _, let also): also
        case .pixels: []
        case .merged(let a, let b): a.role == nil ? b.also : a.also
        }
    }
}

/// Which of an element's texts said something: the three an accessibility element says itself
/// with, in the order a row's text is chosen from.
public enum Attribute: String, Sendable, Hashable, CaseIterable {
    case value, title, description
}

/// Text an element says in words, and which of its attributes said it.
public struct Words: Sendable, Hashable {
    public let attribute: Attribute
    public let text: Text

    public init(_ attribute: Attribute, _ text: Text) {
        self.attribute = attribute
        self.text = text
    }
}

/// Anything an element answered as text, and what kind: words, a number in figures - a
/// checkbox's 0 or 1, a slider's position - or a link's address. Only words name what an
/// element is; the other two say its state or where it goes. [LAW:types-are-the-program]
public struct Said: Sendable, Hashable {
    public enum Kind: Sendable, Hashable { case words, figure, address }

    public let attribute: Attribute
    public let text: Text
    public let kind: Kind

    public init(_ attribute: Attribute, _ text: Text, _ kind: Kind) {
        self.attribute = attribute
        self.text = text
        self.kind = kind
    }

    /// The words, when it said words.
    public var words: Words? { kind == .words ? Words(attribute, text) : nil }
}

/// An accessibility role string such as `AXButton`. Apps define their own, so this is an
/// open set rather than an enum.
public struct Role: RawRepresentable, Sendable, Hashable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }
}

/// How sure a recogniser was, 0 through 1.
///
/// Carried because it is what tells a near miss apart from a different word: text one
/// edit away that was read at low confidence is the recogniser slipping, and the same
/// text at high confidence is a genuinely different string on the screen. Whether it is
/// worth the tokens to print is the binary's call, not this type's.
public struct Confidence: Sendable, Hashable, Comparable {
    public let value: Double

    /// Clamps rather than refuses: a recogniser reporting 1.0000001 is not a failure to
    /// report, and a reading thrown away over a rounding error is worse than a reading
    /// that says 1. Infinities clamp the same way, to 1 and to 0.
    ///
    /// NaN is the one input refused, because it is not a number to clamp and clamping
    /// does not touch it - `max(.nan, 0)` is `.nan`, and so is the `min` after it. A
    /// `Confidence` holding NaN is unequal to itself, which breaks both conformances
    /// above it: a `Found` carrying one never dedupes in a `Set` and never compares equal
    /// to its own twin, and sorting findings by confidence returns them silently
    /// unsorted rather than trapping. Refusing it here is the only place that can be
    /// checked once. [LAW:parse-dont-validate]
    public init?(_ value: Double) {
        guard !value.isNaN else { return nil }
        self.value = min(max(value, 0), 1)
    }

    public static func < (lhs: Confidence, rhs: Confidence) -> Bool { lhs.value < rhs.value }
}
