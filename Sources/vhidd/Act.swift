import Keystrokes
import Pointing

/// One act a client asks of the devices, in the devices' own values.
///
/// [LAW:parse-dont-validate] The wire is wider than the device on every count - a usage
/// outside the keyboard page's keys names no key, button 0 and 33 upward have no bit, and
/// -128 is below the descriptor's minimum, and more keys than a report carries are no
/// report. A seat makes its act here, before it takes any lock or claims the devices, so a
/// value the device cannot carry is refused by name with nothing claimed, and nothing past
/// this point checks a value again.
enum Act: Equatable {
    case down(Usage)
    case releaseKeys
    case hold(HeldKeys)
    case buttonDown(Button)
    case releaseButtons
    case holdButtons(Set<Button>)
    case move(Move)
    case scroll(Scroll)

    static func down(usage: UInt16) throws -> Act { .down(try key(usage)) }

    /// A usage named twice on the wire is one key held; more than a report carries is
    /// refused by `HeldKeys`, by name. [LAW:single-enforcer]
    static func hold(usages: [UInt16]) throws -> Act { .hold(try HeldKeys(Set(usages.map(key)))) }

    static func buttonDown(_ number: UInt8) throws -> Act {
        guard let button = Button(rawValue: number) else { throw NotOnTheDevice.button(number) }
        return .buttonDown(button)
    }

    static func holdButtons(_ field: UInt32) -> Act { .holdButtons(Button.buttons(in: field)) }

    static func move(x: Int8, y: Int8) throws -> Act { .move(Move(x: try count(x), y: try count(y))) }

    static func scroll(vertical: Int8, horizontal: Int8) throws -> Act {
        .scroll(Scroll(vertical: try count(vertical), horizontal: try count(horizontal)))
    }

    private static func key(_ value: UInt16) throws -> Usage {
        guard Usage.keys.contains(value) else { throw NotOnTheDevice.usage(value) }
        return Usage(rawValue: value)
    }

    private static func count(_ value: Int8) throws -> Count {
        guard let count = Count(exactly: value) else { throw NotOnTheDevice.count(value) }
        return count
    }
}

/// A value the wire can carry and the device cannot.
enum NotOnTheDevice: Error, CustomStringConvertible {
    case usage(UInt16)
    case button(UInt8)
    case count(Int8)

    var description: String {
        switch self {
        case .usage(let value): "usage \(value) is not one of the keys \(Usage.keys.lowerBound) through \(Usage.keys.upperBound)"
        case .button(let number): "button \(number) is not one of the 32 the device has a bit for"
        case .count(let value): "\(value) is outside the -127 through 127 a report carries"
        }
    }
}
