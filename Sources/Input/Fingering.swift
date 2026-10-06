import Keystrokes

/// The finger touch typing presses a key with, which is what the gap before a key depends
/// on: a pair split between the hands is quick, two keys under one finger are slow.
/// `docs/design/human.md`, "Typing".
///
/// Read off the key's position, not its character: a HID usage is the physical key, so a
/// Dvorak typist's "e" is under the same finger as a US typist's "d" was.
enum Finger: Equatable, Sendable {
    case leftPinky, leftRing, leftMiddle, leftIndex, thumb, rightIndex, rightMiddle, rightRing, rightPinky

    enum Hand: Equatable { case left, right, thumbs }

    var hand: Hand {
        switch self {
        case .leftPinky, .leftRing, .leftMiddle, .leftIndex: .left
        case .thumb: .thumbs
        case .rightIndex, .rightMiddle, .rightRing, .rightPinky: .right
        }
    }

    /// The finger for `usage`, or nil for a key off the typing block - an arrow, a function
    /// key - which no assignment covers.
    init?(_ usage: Usage) {
        guard let key = Self.keys.first(where: { $0.usage == usage.rawValue }) else { return nil }
        self = key.finger
    }

    /// The typing block of a US ANSI keyboard: each key's usage, the character it types
    /// unshifted on the US layout, and the finger touch typing gives it.
    /// [LAW:one-source-of-truth] The fingering and `Cadence`'s reference passage both read it.
    static let keys: [(usage: UInt16, character: Character, finger: Finger)] = [
        (0x35, "`", .leftPinky), (0x1E, "1", .leftPinky), (0x14, "q", .leftPinky), (0x04, "a", .leftPinky), (0x1D, "z", .leftPinky), (0x2B, "\t", .leftPinky),
        (0x1F, "2", .leftRing), (0x1A, "w", .leftRing), (0x16, "s", .leftRing), (0x1B, "x", .leftRing),
        (0x20, "3", .leftMiddle), (0x08, "e", .leftMiddle), (0x07, "d", .leftMiddle), (0x06, "c", .leftMiddle),
        (0x21, "4", .leftIndex), (0x22, "5", .leftIndex), (0x15, "r", .leftIndex), (0x17, "t", .leftIndex),
        (0x09, "f", .leftIndex), (0x0A, "g", .leftIndex), (0x19, "v", .leftIndex), (0x05, "b", .leftIndex),
        (0x2C, " ", .thumb),
        (0x23, "6", .rightIndex), (0x24, "7", .rightIndex), (0x1C, "y", .rightIndex), (0x18, "u", .rightIndex),
        (0x0B, "h", .rightIndex), (0x0D, "j", .rightIndex), (0x11, "n", .rightIndex), (0x10, "m", .rightIndex),
        (0x25, "8", .rightMiddle), (0x0C, "i", .rightMiddle), (0x0E, "k", .rightMiddle), (0x36, ",", .rightMiddle),
        (0x26, "9", .rightRing), (0x12, "o", .rightRing), (0x0F, "l", .rightRing), (0x37, ".", .rightRing),
        (0x27, "0", .rightPinky), (0x2D, "-", .rightPinky), (0x2E, "=", .rightPinky), (0x13, "p", .rightPinky),
        (0x2F, "[", .rightPinky), (0x30, "]", .rightPinky), (0x31, "\\", .rightPinky), (0x33, ";", .rightPinky),
        (0x34, "'", .rightPinky), (0x38, "/", .rightPinky), (0x28, "\n", .rightPinky),
    ]
}
