import Keystrokes

/// Modifiers the device can hold, as the keyboard page names them.
///
/// [LAW:parse-dont-validate] A set of `Modifier`s is what a caller asks for and is not yet
/// proven holdable: Fn is no key to the device. This is the one crossing where that is
/// decided - `Keystroke(chord:)` goes through it for a chord's modifiers - so a caller
/// holding one of these holds modifiers every one of which can go down.
/// [LAW:single-enforcer] Empty is legal and holds nothing.
public struct HeldModifiers: Hashable, Sendable, CustomStringConvertible {
    /// As the device presses them, in the one order `Modifiers` gives every chord.
    public let pressed: Modifiers

    public init(_ modifiers: Set<Modifier>) throws(UnholdableModifiers) {
        let unholdable = Modifier.allCases.filter { modifiers.contains($0) && $0.usage == nil }
        guard unholdable.isEmpty else { throw UnholdableModifiers(modifiers: unholdable) }
        pressed = Modifiers(modifiers.compactMap(\.usage))
    }

    public static let none = HeldModifiers(pressed: [])

    private init(pressed: Modifiers) { self.pressed = pressed }

    /// The modifiers joined the way a chord spells them.
    public var description: String {
        Modifier.allCases.filter { $0.usage.map(pressed.usages.contains) ?? false }.map(\.rawValue).joined(separator: "+").nonEmpty ?? "no modifiers"
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}

public struct UnholdableModifiers: Error, CustomStringConvertible, Equatable {
    public let modifiers: [Modifier]

    public var description: String { "\(modifiers.map(\.rawValue).joined(separator: ", ")) is not a key the device can hold" }
}

extension Pointer {
    /// Holds `held` down on `keyboard` for the length of `act`, then lets every key go.
    ///
    /// A Shift-click is the keyboard and the mouse in one run: the modifiers go down, the
    /// pointer act makes its reports with them held - macOS reads the modifier flags off the
    /// keyboard, not off the mouse - and then the keys come up. The act is any pointer act,
    /// handed this pointer, so click, drag and scroll are one operation here rather than
    /// three. [LAW:composability]
    ///
    /// The same reports every time: no modifiers is zero downs and the same release, not a
    /// path of its own. [LAW:dataflow-not-control-flow]
    ///
    /// **The mouse is the act's to release and the keyboard is this one's.** A pointer act
    /// lets every button go on its way out, stopped or not, so a stop here releases the
    /// keys and nothing else; letting the mouse go a second time would report its release
    /// twice, or report a button held that the second release freed. [LAW:single-enforcer]
    public func holding<T: Sendable>(
        _ held: HeldModifiers,
        on keyboard: any Keyboard,
        isolation: isolated (any Actor)? = #isolation,
        _ act: (Pointer) async throws -> T
    ) async throws -> T {
        var stage = HoldingStopped.Stage.pressing
        do {
            for usage in held.pressed.usages {
                try Task.checkCancellation()
                try await keyboard.down(usage)
            }
            stage = .acting
            let done = try await act(self)
            stage = .releasing
            try await keyboard.releaseAll()
            return done
        } catch {
            throw HoldingStopped(held: held, stage: stage, cause: error, unreleased: await failure(of: keyboard.releaseAll))
        }
    }
}

/// A pointer act with modifiers held that stopped. What stopped it is the cause; how far
/// it got, and whether the keys are known to be up, are the parts the operator has to act
/// on - an act that was made cannot be taken back, and a modifier left held changes every
/// key typed after it.
public struct HoldingStopped: StoppedPartWay, CustomStringConvertible {
    /// How far the run got. [LAW:types-are-the-program] The act either had not begun, was
    /// under way, or was made and only the keys' release failed - three facts a caller
    /// retrying on a stop has to tell apart.
    public enum Stage: Equatable, Sendable {
        case pressing, acting, releasing
    }

    public let held: HeldModifiers
    public let stage: Stage
    public let cause: any Error
    /// The failure of the key release that followed the stop, when it failed too. Nil says
    /// every key is up; the mouse is in the cause's account.
    public let unreleased: (any Error)?

    public init(held: HeldModifiers, stage: Stage, cause: any Error, unreleased: (any Error)? = nil) {
        self.held = held
        self.stage = stage
        self.cause = cause
        self.unreleased = unreleased
    }

    public var description: String {
        let stopped = switch stage {
        case .pressing: "Holding \(held) stopped before the pointer moved: \(cause.reported)"
        case .acting: cause.reported
        case .releasing: "The pointer act was made with \(held) held, and the keys would not come up: \(cause.reported)"
        }
        return unreleased.map { stopped.then("The keys were not released afterwards: \($0.reported)").then("\(held) may be left held") } ?? stopped
    }
}
