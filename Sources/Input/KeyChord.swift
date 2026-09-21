/// Keys pressed together: the shortcut a caller asks for, named the way a person writes
/// one down. Never empty: every constructor takes at least one key.
///
/// [LAW:one-type-per-behavior] A chord is what is asked for; `Keystroke` is what the
/// device presses. The two are kept apart because not every chord is pressable - one of
/// modifiers alone is held rather than struck, and Fn is no key to the device at all -
/// and `Keystroke(chord:)` is the one crossing where that is decided.
///
/// Side-specific throughout, because the device presses a side: a chord naming
/// `leftCommand` is a different act from one naming `rightCommand`, and nothing here may
/// collapse them into "Command".
public struct KeyChord: Hashable, Codable, Sendable, CustomStringConvertible {
    public let modifiers: Set<Modifier>
    /// The non-modifier key, if the chord has one. A chord of modifiers alone is a thing
    /// a person holds, which is why it parses and why it cannot be pressed.
    public let key: Key?

    public init(key: Key, modifiers: Set<Modifier> = []) {
        self.modifiers = modifiers
        self.key = key
    }

    public init(modifiers first: Modifier, _ rest: Modifier...) {
        self.modifiers = Set(rest).union([first])
        self.key = nil
    }

    /// [LAW:parse-dont-validate] The one place a chord made of parts arrives unproven, a
    /// decoded one and a spelled one alike; an empty one is nil here so no consumer has to
    /// check. [LAW:single-enforcer]
    public init?(modifiers: Set<Modifier>, key: Key?) {
        guard key != nil || !modifiers.isEmpty else { return nil }
        self.modifiers = modifiers
        self.key = key
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let modifiers = try container.decode(Set<Modifier>.self, forKey: .modifiers)
        let key = try container.decodeIfPresent(Key.self, forKey: .key)
        guard let chord = KeyChord(modifiers: modifiers, key: key) else {
            throw DecodingError.dataCorruptedError(forKey: .modifiers, in: container, debugDescription: "a chord needs at least one key")
        }
        self = chord
    }

    /// The chord written the way `init(spelled:on:)` reads one back: `rightOption`,
    /// `leftCommand+leftShift+key 0x1`.
    ///
    /// **One spelling, and it is the one the parser accepts.** [LAW:one-source-of-truth]
    /// A printed chord a person cannot hand straight back to the tool is a map of the
    /// territory that does not lead anywhere, and two spellings - one to print, one to
    /// parse - is how they drift apart. `aChordPrintsAsSomethingThatParsesBackToIt` holds
    /// this, over every chord the tests name. [LAW:verifiable-goals]
    ///
    /// The key is spelled by code rather than by the character on it, because which
    /// character that is belongs to the layout in front of the user and this type has no
    /// layout. A spelling that reads better to a person is the layout's to give.
    ///
    /// Ordered by `Modifier.allCases` rather than by the words, because `modifiers` is a
    /// Set and a Set has none: without an order fixed somewhere, two readings of one chord
    /// could spell it two ways. [LAW:one-source-of-truth]
    public var description: String {
        let modifiers = Modifier.allCases.filter(self.modifiers.contains).map(\.rawValue)
        return (modifiers + (key.map { [Self.keyPrefix + String($0.rawValue, radix: 16)] } ?? []))
            .joined(separator: "+")
    }

    /// How a key spelled by code begins, printed and parsed from this one place.
    /// [LAW:one-source-of-truth]
    static let keyPrefix = "key 0x"
}

/// Side-specific, because a device presses a side and reporting the wrong one is
/// reporting a different keystroke than the one that happened.
public enum Modifier: String, Hashable, Codable, CaseIterable, Sendable, CustomStringConvertible {
    case leftShift, rightShift
    case leftControl, rightControl
    case leftOption, rightOption
    case leftCommand, rightCommand
    case function

    /// The spelling a chord is written in, so a report reads back in the words its author
    /// typed rather than in Swift's name for the case.
    public var description: String { rawValue }

    /// [LAW:single-enforcer] Which modifiers exist is this type's rule, so a spelling that
    /// names another is answered from the cases themselves and never falls out of step
    /// with them.
    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        guard let modifier = Modifier(rawValue: raw) else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "\"\(raw)\" is not a modifier: \(Modifier.allCases.map(\.rawValue).joined(separator: ", "))"))
        }
        self = modifier
    }
}

/// A macOS virtual key code (the `kVK_*` constants; `CGKeyCode`). Key codes rather
/// than characters because posting an event needs the code, and the code is the same
/// under every keyboard layout.
public struct Key: RawRepresentable, Hashable, Codable, Sendable {
    public let rawValue: UInt16

    public init(rawValue: UInt16) {
        self.rawValue = rawValue
    }
}
