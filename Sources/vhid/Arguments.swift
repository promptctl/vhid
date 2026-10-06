import ArgumentParser
import Input
import Pointing

/// Two coordinates from a command line as a place on the screen, or the refusal that says
/// they are not one.
///
/// [LAW:parse-dont-validate] `ScreenPoint` refuses what is not a place on the screen, and
/// `inf` and `nan` are both things a shell hands over as a Double without complaint.
/// [LAW:single-enforcer] Every verb that takes a place reads it through here, from both
/// its `validate` and its `run`, so the refusal is worded one way everywhere.
func place(_ x: Double, _ y: Double) throws -> ScreenPoint {
    guard let point = ScreenPoint(x: x, y: y) else {
        throw ValidationError("(\(x), \(y)) is not a place on the screen")
    }
    return point
}

/// `count` places from a command line's words, in order: each a point as two numbers, `x y`,
/// or a box as one word, `x,y,width,height`, the form eyes prints beside each point. A word
/// with a comma in it is a box, and any other starts a point.
///
/// [LAW:single-enforcer] Every pointer verb reads its places through here, so a point is
/// refused by `place` and a box by `ScreenRect(spelled:)`, as the MCP server refuses them.
func places(_ words: [String], count: Int) throws -> [Target] {
    var rest = words[...], read: [Target] = []
    while let word = rest.first {
        if word.contains(",") {
            guard let box = ScreenRect(spelled: word) else {
                throw ValidationError("\(word) is not a box: a box is x,y,width,height in points, finite, each side at least a point")
            }
            read.append(.box(box))
            rest = rest.dropFirst()
        } else {
            let pair = Array(rest.prefix(2))
            guard pair.count == 2, let x = Double(pair[0]), let y = Double(pair[1]) else {
                throw ValidationError("\(pair.joined(separator: " ")) is not a point: a point is two numbers, x y")
            }
            read.append(.point(try place(x, y)))
            rest = rest.dropFirst(2)
        }
    }
    guard read.count == count else {
        throw ValidationError("\(words.joined(separator: " ")) is \(counted(read.count, "place")), and this takes \(count)")
    }
    return read
}

/// A button as a command line writes one: the word for the three that have a word, the
/// number for the other twenty-nine.
///
/// [LAW:single-enforcer] Which strings are buttons is `Button.init?(_:)`'s to say, in
/// module `Pointing`, where the MCP server's crossing reads it too; argv is already a string, so
/// this crossing is nothing but the call.
extension Button: ExpressibleByArgument {
    public init?(argument: String) {
        self.init(argument)
    }

    /// Printed the way it reads back, so the default shown in `--help` is a value the
    /// flag accepts. Without this, a `RawRepresentable` shows its raw value and the help
    /// offers `1` where `left` is what a reader would write.
    public var defaultValueDescription: String { description }

    // No `allValueStrings`. Twenty-nine of the thirty-two buttons have no word, so any
    // list short enough to print is a list that leaves out most of what the flag takes -
    // and a list ending in an ellipsis offers the ellipsis as a value. The rule is in the
    // help text, where it can be stated rather than enumerated. [LAW:no-silent-failure]
}

/// `--modifiers` as the verbs read it: `HeldModifiers(spelled:)`, whose refusal names the
/// word that is not a modifier, as the MCP parameter's does. A transform rather than
/// `ExpressibleByArgument`, whose failable init would drop that reason for "is invalid".
/// [LAW:no-silent-failure]
func heldModifiers(_ spelling: String) throws -> HeldModifiers {
    try HeldModifiers(spelled: spelling)
}

/// How a verb's report says what it held: nothing, when it held nothing.
func holding(_ held: HeldModifiers) -> String {
    held.pressed.isEmpty ? "" : " holding \(held)"
}

/// How many times a button is pressed without moving between presses.
///
/// [LAW:polishing-by-subtraction] Empty on purpose, and measured so before it was emptied.
/// ArgumentParser already conforms any `RawRepresentable` whose raw value is itself
/// `ExpressibleByArgument`, so both halves - reading an `Int` and handing it to
/// `Clicks.init?(rawValue:)`, which is what refuses `0` and `-1`, and printing the default
/// as `1` - are what it supplies. `Button` above needs its overrides because its spellings
/// are not its raw value. A body restating a default reads, beside that one, as though it
/// were load-bearing too.
extension Clicks: ExpressibleByArgument {}
