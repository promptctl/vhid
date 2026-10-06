/// Keys held down at once, no more than one keyboard report can carry.
///
/// [LAW:single-enforcer] The one place the report's width is a limit: the virtual keyboard
/// builds its report through this, and a script's `keys` line is parsed into it, so a set
/// a script could name is a set the device can hold.
public struct HeldKeys: Hashable, Sendable {
    /// Non-modifier keys one report carries; the modifiers ride in a byte of their own.
    public static let capacity = 32

    public let usages: Set<Usage>

    public init(_ usages: Set<Usage>) throws(TooManyKeys) {
        let keys = usages.filter { $0.modifierBit == nil }.count
        guard keys <= Self.capacity else { throw TooManyKeys(held: keys) }
        self.usages = usages
    }

    /// `modifiers` held, and `key` under them when there is one: what one keystroke holds
    /// at any moment. At most one key besides the modifiers, so it always fits.
    public init(_ modifiers: Modifiers, pressing key: Usage? = nil) {
        usages = Set(modifiers.usages + [key].compactMap { $0 })
    }

    public static let none = HeldKeys(Modifiers())

    /// How long vhidd lets a key stay down with no word from its client before it lets go.
    /// Here, where both ends can read it, because the daemon enforces it and a player that
    /// holds a key through a quiet stretch has to speak inside it. [LAW:one-source-of-truth]
    public static let silenceLimit: Duration = .seconds(2)
}

public struct TooManyKeys: Error, CustomStringConvertible {
    public let held: Int
    public var description: String { "\(held) keys are down, and one HID keyboard report carries \(HeldKeys.capacity)" }
}

public extension Usage {
    /// The keyboard page's usages that name keys: 4 is the first letter key and 231
    /// (0xE7) the last modifier; below are error codes, above are reserved.
    static let keys: ClosedRange<UInt16> = 4...0xE7
}
