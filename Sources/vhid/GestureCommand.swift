import ArgumentParser
import CoreFoundation
import Input
import KeyboardLayouts

/// Does what a trackpad gesture does, by pressing the key that does it.
struct GestureCommand: AsyncParsableCommand {
    static let configuration = Help.gesture.configuration

    @Argument(help: Help.sentence(Help.gestureName))
    var gesture: Gesture

    @OptionGroup var layoutOption: LayoutOption
    @OptionGroup var service: ServiceOption

    func run() async throws {
        let chord = try Self.chord(for: gesture, on: try layoutOption.layout(), hotKeys: Self.hotKeys)
        print(try await Devices.using(try service.installation()) { try await Self.perform(chord, with: $0.typist) })
    }

    /// The chord that does what `gesture` does on this Mac, and how it was chosen.
    ///
    /// Decided before the devices are reached, so a gesture that is refused never connects.
    /// [LAW:effects-at-boundaries] The preferences are read by `hotKeys`, which a test hands
    /// in, so every route is decided here with nothing read.
    static func chord(for gesture: Gesture, on layout: KeyboardLayout, hotKeys: () -> Any?) throws -> GestureChord {
        switch gesture.route {
        case .command(let spelling):
            return GestureChord(gesture: gesture, chord: try KeyChord(spelled: spelling, on: layout), chosen: "on \(layout.name)")
        case .shortcut(let shortcut):
            let inForce = try shortcut.inForce(in: hotKeys())
            guard case .on(let chord) = inForce.binding else { throw GestureRefused.off(gesture, shortcut) }
            // [LAW:nothing-unseen] Whose binding was pressed - the user's or macOS's default -
            // is the decision a report has to carry: a press that did nothing reads very
            // differently under each.
            let source = switch inForce.source {
            case .set: "as set"
            case .byDefault: "by default"
            }
            return GestureChord(gesture: gesture, chord: chord, chosen: "its shortcut \(source) at \(shortcut.settingPath)")
        case .none(let why):
            throw GestureRefused.noRoute(gesture, why)
        }
    }

    /// The verb itself, over a typist from anywhere. [LAW:decomposition]
    static func perform(_ chosen: GestureChord, with typist: Typist) async throws -> String {
        try await typist.press(try typist.lower(chosen.chord))
        return "\(chosen.gesture): pressed \(chosen.chord), \(chosen.chosen)"
    }

    /// The calling user's system shortcuts, as cfprefsd holds them, or nil when they have
    /// never changed one.
    ///
    /// The caller's, as the keyboard layout is: a gesture asked for while another user is
    /// in front presses the caller's binding.
    static func hotKeys() -> Any? {
        CFPreferencesCopyAppValue("AppleSymbolicHotKeys" as CFString, "com.apple.symbolichotkeys" as CFString)
    }
}

/// A gesture as the chord that does it here, and the words saying how that chord was chosen.
struct GestureChord: Sendable {
    let gesture: Gesture
    let chord: KeyChord
    let chosen: String
}

/// A gesture the devices cannot do on this Mac, and why.
enum GestureRefused: Error, CustomStringConvertible, Equatable {
    case noRoute(Gesture, String)
    case off(Gesture, SystemShortcut)

    var description: String {
        switch self {
        case .noRoute(let gesture, let why):
            "\(gesture) has no key or button that does it: \(why)"
        case .off(let gesture, let shortcut):
            "\(gesture) is the shortcut at \(shortcut.settingPath), and it is off"
        }
    }
}

/// Read by its name, as `Gesture.init?(rawValue:)` reads it. [LAW:single-enforcer]
extension Gesture: ExpressibleByArgument {}
