import Pointing

/// The mouse one click is made on: a button that goes down, a release that takes them all
/// back up, motion, and the wheel.
///
/// [LAW:effects-at-boundaries] Posting a report is an effect against the driver, so it
/// sits behind this seam - which is what lets a test drive a pointer across a screen of
/// its own, with an acceleration curve of its own, and read back every report it posted.
///
/// **Four members, and none of them is a veto**, for the reason `Keyboard` gives: the
/// `check()` that refused a report because focus had moved, and the alert reading that
/// refused a press because a system prompt was up, are both gone. A press that would land
/// somewhere the caller did not intend is the caller's problem to have; this says what
/// the device did.
public protocol Mouse: Sendable {
    func down(_ button: Button) async throws
    func releaseAll() async throws
    func move(by delta: Move) async throws
    func scroll(by delta: Scroll) async throws
}

/// A mouse whose reports are posted on the device queue. The mirror of `QueuedKeyboard`,
/// and it takes the same queue that keyboard was given: one sequence of reports, ordered
/// the way the caller asked for them. [LAW:decomposition]
public struct QueuedMouse: Mouse {
    public let pointing: any Pointing
    public let queue: DeviceQueue

    public init(pointing: any Pointing, queue: DeviceQueue) {
        self.pointing = pointing
        self.queue = queue
    }

    public func down(_ button: Button) async throws { try await queue.run { [pointing] in try pointing.down(button) } }
    public func releaseAll() async throws { try await queue.run { [pointing] in try pointing.releaseAll() } }
    public func move(by delta: Move) async throws { try await queue.run { [pointing] in try pointing.move(by: delta) } }
    public func scroll(by delta: Scroll) async throws { try await queue.run { [pointing] in try pointing.scroll(by: delta) } }
}
