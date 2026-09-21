import Keystrokes

/// The keyboard one character is typed on: keys that go down, and a release that takes
/// them all back up.
///
/// [LAW:effects-at-boundaries] Posting a key is an effect against the driver, so it sits
/// behind this seam - which is what lets a test throw at the third keystroke of a
/// four-keystroke character and read back the score the run would have reported, with no
/// driver in front.
///
/// **Two members, and neither of them is a veto.** What this protocol had besides these
/// was a `check()` a caller could fail: the run was refused because the operator had
/// interrupted, or because the app that was in front no longer was. Both are gone. A
/// driver says what the device did and what it could not do; it does not hold an opinion
/// about whether the caller should have asked. Cancellation is how a caller stops its own
/// run, and it travels as `CancellationError` through the same release path every other
/// failure takes.
///
/// The keys are awaited rather than returned from: each one waits for the far side's
/// acknowledgement, which is the pacing the driver needs.
public protocol Keyboard: Sendable {
    func down(_ usage: Usage) async throws
    func releaseAll() async throws
}

/// A keyboard whose reports are posted on the device queue.
///
/// [LAW:decomposition] One sentence: it makes a synchronous device asynchronous by
/// running each call somewhere the wait costs nothing. The queue is handed in rather than
/// made here, because the keyboard and the mouse a caller posts through must share one -
/// the helper takes their reports as a single sequence, and two queues would let the
/// order they were asked in and the order they arrive in differ.
public struct QueuedKeyboard: Keyboard {
    public let keyboard: any KeyPress
    public let queue: DeviceQueue

    public init(keyboard: any KeyPress, queue: DeviceQueue) {
        self.keyboard = keyboard
        self.queue = queue
    }

    public func down(_ usage: Usage) async throws { try await queue.run { [keyboard] in try keyboard.down(usage) } }
    public func releaseAll() async throws { try await queue.run { [keyboard] in try keyboard.releaseAll() } }
}
