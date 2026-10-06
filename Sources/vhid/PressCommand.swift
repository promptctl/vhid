import ArgumentParser
import Input
import KeyboardLayouts

/// Presses chords on the virtual keyboard, in the order they were given.
struct PressCommand: AsyncParsableCommand {
    static let configuration = Help.press.configuration

    @Argument(help: Help.sentence(Help.chords))
    var chords: [String]

    @OptionGroup var layoutOption: LayoutOption
    @OptionGroup var aimOption: AimOption
    @OptionGroup var service: ServiceOption

    func run() async throws {
        let (layout, aim) = (try layoutOption.layout(), try aimOption.aim())
        print(try await Devices.using(try service.installation()) { try await Self.press(chords, on: layout, into: aim, with: $0.typist, front: $0.front) })
    }

    /// The verb itself, over a typist from anywhere. [LAW:decomposition]
    static func press(_ chords: [String], on layout: KeyboardLayout, into aim: Aim, with typist: Typist,
                      front: () async throws -> FrontApp?) async throws -> String {
        // [LAW:parse-dont-validate] Both crossings - the spelling, then whether the device
        // can press what it names - are made for every chord before any key goes down. A
        // list that stops half way through has already pressed the chords before the bad
        // one, and those cannot be taken back.
        let pressable = try chords.map { spelling -> (chord: KeyChord, pressable: Typist.Chord) in
            let chord = try KeyChord(spelled: spelling, on: layout)
            return (chord, try typist.lower(chord))
        }
        try await aim.admit(front)
        try await typist.press(pressable.map(\.pressable))
        // Reported in the spelling `KeyChord.description` gives, which is the one that
        // reads back: what was typed may have been `s`, and what was pressed is the key
        // this layout puts `s` on. The chords say how many there were, so a count beside
        // them would only be a second way to get the number wrong.
        // [LAW:no-silent-failure] [LAW:polishing-by-subtraction]
        return "pressed \(pressable.map { "\($0.chord)" }.joined(separator: ", ")) on \(layout.name)\(aim.said)"
    }
}
