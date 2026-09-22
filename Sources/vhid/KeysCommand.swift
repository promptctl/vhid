import ArgumentParser
import Input
import KeyboardLayout

/// Presses chords on the virtual keyboard, in the order they were given.
struct KeysCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "keys",
        abstract: "Press chords on the virtual keyboard.",
        discussion: """
            A chord is modifier names and one key joined by +, e.g. leftCommand+s or \
            leftShift+leftCommand+left. A key is a name (\(KeyChord.namedKeys.keys.sorted().joined(separator: ", "))), \
            the character the layout types with it and nothing held, or a key code written key 0x24.

            Which key a letter is on is the layout's to say - s is key code 1 on US and 41 on Dvorak - so \
            a chord is read against the console user's layout, in this process rather than in the daemon.

            Every chord is proven pressable before the first one goes down.
            """)

    @Argument(help: "The chords, pressed in order.")
    var chords: [String]

    @OptionGroup var service: ServiceOption

    func run() async throws {
        let layout = try KeyboardLayout.current()
        print(try await Self.press(chords, on: layout, with: Devices(of: try service.installation()).typist))
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
        for chord in pressable { try await typist.press(chord.pressable) }
        // Reported in the spelling `KeyChord.description` gives, which is the one that
        // reads back: what was typed may have been `s`, and what was pressed is the key
        // this layout puts `s` on. [LAW:no-silent-failure]
        return "pressed \(pressable.count) chords on \(layout.name): \(pressable.map { "\($0.chord)" }.joined(separator: ", "))"
    }
}
