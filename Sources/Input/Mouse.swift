import Pointing

/// The mouse one click is made on: a button that goes down, a release that takes them all
/// back up, a set of buttons held at once, motion, and the wheel.
///
/// [LAW:effects-at-boundaries] Posting a report is an effect against the driver, so it
/// sits behind this seam - which is what lets a test drive a pointer across a screen of
/// its own, with an acceleration curve of its own, and read back every report it posted.
///
/// **None of its members is a veto**, for the reason `Keyboard` gives: the
/// `check()` that refused a report because focus had moved, and the alert reading that
/// refused a press because a system prompt was up, are both gone. A press that would land
/// somewhere the caller did not intend is the caller's problem to have; this says what
/// the device did.
public protocol Mouse: Sendable {
    func down(_ button: Button) async throws
    func releaseAll() async throws
    /// Exactly `buttons` down from now, whatever was down before.
    func hold(_ buttons: Set<Button>) async throws
    func move(by delta: Move) async throws
    func scroll(by delta: Scroll) async throws
}

/// A mouse whose reports are posted on the device queue. The mirror of `QueuedKeyboard`,
/// and it takes the same queue that keyboard was given: one sequence of reports, ordered
/// the way the caller asked for them. [LAW:decomposition]
public struct QueuedMouse: Mouse {
    public let pointing: any PointingDevice
    public let queue: DeviceQueue

    public init(pointing: any PointingDevice, queue: DeviceQueue) {
        self.pointing = pointing
        self.queue = queue
    }

    public func down(_ button: Button) async throws { try await queue.run { [pointing] in try pointing.down(button) } }
    public func releaseAll() async throws { try await queue.run { [pointing] in try pointing.releaseAll() } }
    public func hold(_ buttons: Set<Button>) async throws { try await queue.run { [pointing] in try pointing.hold(buttons) } }
    public func move(by delta: Move) async throws { try await queue.run { [pointing] in try pointing.move(by: delta) } }
    public func scroll(by delta: Scroll) async throws { try await queue.run { [pointing] in try pointing.scroll(by: delta) } }
}
