import Keystrokes

/// Modifiers the device can hold, as the keyboard page names them.
///
/// [LAW:parse-dont-validate] A set of `Modifier`s is what a caller asks for and is not yet
/// proven holdable: Fn is no key to the device. This is the one crossing where that is
/// decided, the way `Keystroke(chord:)` decides it for a chord, so a caller holding one of
/// these holds modifiers every one of which can go down. Empty is legal and holds nothing.
public struct HeldModifiers: Hashable, Sendable {
    public let modifiers: Set<Modifier>
    /// In `Modifier.allCases` order, so the same set goes down in the same order every run.
    let usages: [Usage]

    public init(_ modifiers: Set<Modifier>) throws(UnholdableModifiers) {
        let ordered = Modifier.allCases.filter(modifiers.contains)
        let unholdable = ordered.filter { $0.usage == nil }
        guard unholdable.isEmpty else { throw UnholdableModifiers(modifiers: unholdable) }
        self.modifiers = modifiers
        self.usages = ordered.compactMap(\.usage)
    }

    public static let none = try! HeldModifiers([])
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
    /// keyboard, not off the mouse - and then everything comes up. The act is any pointer
    /// act, handed this pointer, so click, drag and scroll are one operation here rather
    /// than three. [LAW:composability]
    ///
    /// The same reports every time: no modifiers is zero downs and the same release, not a
    /// path of its own. [LAW:dataflow-not-control-flow]
    ///
    /// A run that stops anywhere - a modifier refused, the act failing, the release
    /// failing, a cancellation - releases both devices, whichever of them were touched, and
    /// throws `HoldingStopped`: the act's own stop already released the mouse, and letting
    /// it go twice costs a report and means nothing is assumed about how far the act got.
    public func holding<T: Sendable>(
        _ held: HeldModifiers,
        on keyboard: any Keyboard,
        isolation: isolated (any Actor)? = #isolation,
        _ act: (Pointer) async throws -> T
    ) async throws -> T {
        do {
            for usage in held.usages {
                try Task.checkCancellation()
                try await keyboard.down(usage)
            }
            let done = try await act(self)
            try await keyboard.releaseAll()
            return done
        } catch {
            let mouse = await release()
            let keys = await Self.release(keyboard)
            throw HoldingStopped(held: held, cause: error, unreleased: [mouse, keys].compactMap(\.self))
        }
    }

    /// Every key up on the way out, answering the failure rather than throwing it, for the
    /// reason `release()` gives. [LAW:no-silent-failure]
    private static func release(_ keyboard: any Keyboard, isolation: isolated (any Actor)? = #isolation) async -> (any Error)? {
        do {
            try await keyboard.releaseAll()
            return nil
        } catch {
            return error
        }
    }
}

/// A pointer act with modifiers held that stopped. What stopped it is the cause; whether
/// the keys and buttons are known to be up is the part the operator has to act on, since
/// a modifier left held changes every key typed after it.
public struct HoldingStopped: StoppedPartWay, CustomStringConvertible {
    public let held: HeldModifiers
    public let cause: any Error
    /// The failures of the releases that followed the stop. Empty says every key and
    /// button is up.
    public let unreleased: [any Error]

    public var description: String {
        let stopped = cause.reported
        guard !unreleased.isEmpty else { return stopped }
        let what = held.modifiers.isEmpty ? "A button" : "A button, or one of \(Modifier.allCases.filter(held.modifiers.contains).map(\.rawValue).joined(separator: "+")),"
        return unreleased.reduce(stopped) { $0.then("A release afterwards failed: \($1.reported)") }.then("\(what) may be left held")
    }
}
