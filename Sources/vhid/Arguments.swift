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

/// A button as a command line writes one: the word for the three that have a word, the
/// number for the other twenty-nine.
///
/// [LAW:single-enforcer] Which strings are buttons is `Button.init?(_:)`'s to say, in
/// `Pointing`, where the MCP server's crossing reads it too; argv is already a string, so
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
