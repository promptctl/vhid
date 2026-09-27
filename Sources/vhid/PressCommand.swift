import ArgumentParser
import Input
import KeyboardLayouts

/// Presses chords on the virtual keyboard, in the order they were given.
struct PressCommand: AsyncParsableCommand {
    static let configuration = Help.press.configuration

    @Argument(help: Help.sentence(Help.chords))
    var chords: [String]

    @OptionGroup var service: ServiceOption

    func run() async throws {
        let layout = try KeyboardLayout.current()
        print(try await Devices.using(try service.installation()) { try await Self.press(chords, on: layout, with: $0.typist) })
    }

    /// The verb itself, over a typist from anywhere. [LAW:decomposition]
    static func press(_ chords: [String], on layout: KeyboardLayout, with typist: Typist) async throws -> String {
        // [LAW:parse-dont-validate] Both crossings - the spelling, then whether the device
        // can press what it names - are made for every chord before any key goes down. A
        // list that stops half way through has already pressed the chords before the bad
        // one, and those cannot be taken back.
        let pressable = try chords.map { spelling -> (chord: KeyChord, pressable: Typist.Chord) in
            let chord = try KeyChord(spelled: spelling, on: layout)
            return (chord, try typist.lower(chord))
        }
        for (pressed, chord) in pressable.enumerated() {
            do {
                try await typist.press(chord.pressable)
            } catch {
                throw ChordsStopped(pressed: pressed, of: pressable.count, cause: error)
            }
        }
        // Reported in the spelling `KeyChord.description` gives, which is the one that
        // reads back: what was typed may have been `s`, and what was pressed is the key
        // this layout puts `s` on. The chords say how many there were, so a count beside
        // them would only be a second way to get the number wrong.
        // [LAW:no-silent-failure] [LAW:polishing-by-subtraction]
        return "pressed \(pressable.map { "\($0.chord)" }.joined(separator: ", ")) on \(layout.name)"
    }
}

/// A list of chords that stopped part way.
///
/// `ChordStopped` is about the one chord whose press stopped, and says so well. How many
/// of the list had already gone down is a fact only the loop above holds, and it is the
/// one the operator has to act on: a `leftCommand+a` that landed in front of a `delete`
/// that did not has left the document selected, and without the count nothing says so.
/// Whether the keys came back up is the cause's to report, and it already does.
/// `type` has carried this since `TypingStopped`; a list of chords is the same promise
/// one unit up. [LAW:no-silent-failure]
///
/// The count lands after the cause's own sentence rather than inside it, where
/// `TypingStopped` puts its own. Interleaving would mean restating "the keyboard was not
/// released afterwards" here - `TypingStopped.unreleased` is what writes it and is not
/// public - and one sentence with two spellings is a worse trade than one report with its
/// clauses in a different order. [LAW:one-source-of-truth]
struct ChordsStopped: StoppedPartWay, CustomStringConvertible {
    let pressed: Int
    let of: Int
    let cause: any Error

    var description: String {
        cause.reported.then("\(pressed) of \(of) chords had been pressed before this, and the rest were not sent")
    }
}
