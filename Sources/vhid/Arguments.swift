import ArgumentParser
import Input
import Pointing

/// A button as a command line writes one: the word for the three that have a word, the
/// number for the other twenty-nine.
///
/// [LAW:one-source-of-truth] The inverse of `Button.description`, which prints the same
/// two spellings, so a button this CLI reports is a button this CLI accepts. The rules
/// themselves stay in `Pointing` - which words name buttons, and that a button is 1
/// through 32 - and are not restated here.
extension Button: ExpressibleByArgument {
    public init?(argument: String) {
        if let named = Button(name: argument) { self = named; return }
        guard let number = UInt8(argument), let numbered = Button(rawValue: number) else { return nil }
        self = numbered
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
extension Clicks: ExpressibleByArgument {
    public init?(argument: String) {
        guard let count = Int(argument) else { return nil }
        self.init(rawValue: count)
    }

    public var defaultValueDescription: String { String(rawValue) }
}
