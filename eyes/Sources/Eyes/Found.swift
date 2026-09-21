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
}

/// One piece of text on screen and where it is.
public struct Found: Sendable, Hashable {
    public let text: Text
    /// Global screen coordinates, top-left origin, points. Its centre is a click target
    /// with no conversion.
    public let frame: ScreenRect
    public let source: Source

    public init(text: Text, frame: ScreenRect, source: Source) {
        self.text = text
        self.frame = frame
        self.source = source
    }
}

/// Which reader found it, carrying what only that reader can know.
///
/// [LAW:types-are-the-program] A role and a confidence as two optionals on `Found` would
/// admit four combinations where the domain has two: pixels carry no role, and the tree
/// reports no confidence. Attached to the source instead, the impossible pair cannot be
/// spelled and no caller guards for it.
public enum Source: Sendable, Hashable {
    /// Read from the accessibility tree, which names what kind of element it was.
    case tree(role: Role)
    /// Recognised from pixels, which know nothing of elements and answer with how sure
    /// the recogniser was.
    case pixels(confidence: Confidence)
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
