/// A mouse button, by the number the device gives it: 1 through 32, the width of the
/// button field in a pointing report. Left is 1, right is 2 and middle is 3, as HID
/// numbers them.
///
/// This module is the seam between deciding where to click and clicking, so it holds
/// the vocabulary and nothing else - no socket, no window server. Both ends need these
/// names and neither should have to link the other to say them. [LAW:one-way-deps]
public struct Button: RawRepresentable, Hashable, Comparable, Sendable {
    public let rawValue: UInt8

    /// The 32 the report has a bit for, and no other. [LAW:parse-dont-validate] A button
    /// this refuses never reaches a report, so no report has to wonder what bit 33 is.
    public init?(rawValue: UInt8) {
        guard (1...32).contains(rawValue) else { return nil }
        self.rawValue = rawValue
    }

    public static let left = Button(rawValue: 1)!
    public static let right = Button(rawValue: 2)!
    public static let middle = Button(rawValue: 3)!

    /// The bit this button sets in the report's 32-bit button field: button n is bit
    /// n - 1. Derived from the number rather than tabulated beside it, the way a modifier
    /// usage derives its bit. [LAW:one-source-of-truth]
    public var bit: UInt32 { 1 << UInt32(rawValue - 1) }

    public static func < (a: Button, b: Button) -> Bool { a.rawValue < b.rawValue }
}

public extension Button {
    /// The three buttons a person has a word for, and the words. The other twenty-nine are
    /// reachable too, by their number - a device with a thumb button is a device with a
    /// thumb button, and naming only three of thirty-two would be this module deciding
    /// which of them a caller is allowed to press. [LAW:one-source-of-truth] Printed and
    /// parsed from this one table, so a button that reads back as `right` is one that can
    /// be asked for as `right`.
    static let named: [String: Button] = ["left": .left, "right": .right, "middle": .middle]

    /// The button this word names, or nil for a word that names none.
    init?(name: String) {
        guard let button = Self.named[name] else { return nil }
        self = button
    }

    /// The word for this button, for the three that have one.
    var name: String? { Self.named.first { $0.value == self }?.key }
}

extension Button: CustomStringConvertible {
    /// The word, or the number for a button that has no word. Both spellings are ones
    /// `init?(name:)` and `init?(rawValue:)` read back. [LAW:one-source-of-truth]
    public var description: String { name ?? String(rawValue) }
}
