import Foundation
import Helper
import Input
import Installations
import Keystrokes
import Pointing

/// The two devices an installation's daemon owns, as a client reaches them.
///
/// [LAW:decomposition] One sentence, and the reason it is one type rather than two is
/// that the two cannot be made separately. vhidd serves one client at a time, so a
/// keyboard and a mouse in one process are one client and share one connection - two
/// would have the second refused as busy by the first. And vhidd takes their
/// reports as a single sequence, so they share one `DeviceQueue`: with a queue each, the
/// order reports were asked in and the order they arrive in could differ.
///
/// [LAW:effects-at-boundaries] Opening the connection is the only effect here. What each
/// verb then does with a keyboard and a mouse is decided against types that know nothing
/// about privilege, which is also what lets the verbs be tested against devices that
/// record instead of typing.
struct Devices {
    let keyboard: any Keyboard
    let mouse: any Mouse
    let cursor: @Sendable () async throws -> ScreenPoint
    let front: @Sendable () async throws -> FrontApp?
    /// The pointer this mouse is steered by, reading the cursor back after every report -
    /// which is the only place the truth about where the pointer went lives, since macOS
    /// accelerates the counts the device sends. One per opening, so a verb's moves draw
    /// from one seed, and that seed is on its record, as is every move it makes, however
    /// the verb ends. [LAW:nothing-unseen]
    let pointer: Pointer

    /// Runs `body` with the devices over a connection to this installation's daemon, and
    /// hands them back when it returns.
    ///
    /// **The one way a verb reaches the devices, and the scope is the holding.** The daemon
    /// serves one client at a time, so a verb holds the devices for exactly as long as this
    /// runs and then leaves, waiting for the daemon to say they are free. The next verb -
    /// in this process or another - is served on that answer rather than racing the
    /// daemon's cleanup of this one. [LAW:no-ambient-temporal-coupling]
    ///
    /// The connection is lazy - launchd starts the job on the first call, not here - so a
    /// daemon that is not installed is discovered when the first report goes out rather
    /// than at construction. Nothing is claimed about it before then. [LAW:no-silent-failure]
    static func using<T>(_ installation: Installation, _ body: (Devices) async throws -> T) async throws -> T {
        try await using(HelperConnection(installation: installation), body)
    }

    /// Over a connection someone else made, which is how a test puts a daemon of its own on
    /// the far end. [LAW:decomposition]
    static func using<T>(_ helper: HelperConnection, _ body: (Devices) async throws -> T) async throws -> T {
        let queue = DeviceQueue()
        // [LAW:nothing-unseen] Every report a verb sends passes here, so here is where they
        // are counted, from zero: a verb that opened the devices and sent nothing says so.
        for tally in Tally.allCases { Invocation.count(tally, by: 0) }
        let mouse = TalliedMouse(mouse: QueuedMouse(pointing: helper.mouse, queue: queue))
        let cursor = cursor(helper, on: queue)
        let randomness = RandomSource(seed: UInt64.random(in: .min ... .max))
        Invocation.set(.seed, .string(String(randomness.seed, radix: 16)))
        let devices = Devices(keyboard: TalliedKeyboard(keyboard: QueuedKeyboard(keyboard: helper.keyboard, queue: queue)),
                              mouse: mouse, cursor: cursor, front: front(helper, on: queue),
                              pointer: Pointer(mouse: mouse, cursor: cursor, clock: ContinuousClock(), randomness: randomness, traced: Invocation.moved))
        let done: T
        do {
            done = try await body(devices)
        } catch {
            // What stopped the verb is what the caller needs to hear. The leave still runs,
            // because a connection that is working should hand the devices back rather
            // than make the next client wait on its disconnection. When the leave fails
            // too, it is almost always the same failure - the connection that just broke -
            // and the disconnection that follows releases everything regardless.
            try? await queue.run { try helper.leave() }
            throw error
        }
        // On the queue, behind the last report this verb sent. A leave that fails after the
        // verb succeeded does not undo it, so it does not replace what the verb did: an
        // error there would read as "nothing happened", and a caller that retried would
        // click twice or type the text twice. [LAW:no-silent-failure] It is said on stderr,
        // and the disconnection that follows releases the devices regardless.
        do {
            try await queue.run { try helper.leave() }
        } catch {
            FileHandle.standardError.write(Data("vhid: done, but the devices were not handed back: \(error.reported)\n".utf8))
        }
        return done
    }

    /// The typist these keys are typed by.
    var typist: Typist { Typist(keyboard: keyboard) }

    /// The app in front, asked once the daemon has answered that the devices are up.
    ///
    /// launchd starts vhidd on the first call, so asked any earlier the answer would be as
    /// old as the daemon's start by the first key - the window `--into` exists to close.
    /// `status` is answered once the daemon is listening, and refused while its devices
    /// are down, so a verb that gets past it has devices to send to. It is made on `queue`
    /// like every other call, and claims nothing. [LAW:no-ambient-temporal-coupling]
    static func front(_ helper: HelperConnection, on queue: DeviceQueue) -> @Sendable () async throws -> FrontApp? {
        {
            _ = try await queue.run { try helper.status() }
            return try await FrontApp.inFront()
        }
    }

    /// The cursor as the daemon reads it, in the session in front, which may not be this
    /// process's: at the login window, or with another user in front, a read made here
    /// answers (0, 0). [LAW:single-enforcer] Every verb that steers the pointer, and
    /// `cursor`, reads it here. The wait for the daemon's answer is made on `queue`, for
    /// the reason the devices' are.
    static func cursor(_ helper: HelperConnection, on queue: DeviceQueue) -> @Sendable () async throws -> ScreenPoint {
        {
            let at = try await queue.run { try helper.cursor() }
            guard let point = ScreenPoint(x: at.x, y: at.y) else { throw CursorUnreadable() }
            return point
        }
    }
}

/// A keyboard that counts each report on the running invocation once it is acknowledged.
struct TalliedKeyboard: Keyboard {
    let keyboard: any Keyboard

    func down(_ usage: Usage) async throws { try await keyboard.down(usage); Invocation.count(.keyboardReports) }
    func releaseAll() async throws { try await keyboard.releaseAll(); Invocation.count(.keyboardReports) }
    func hold(_ keys: HeldKeys) async throws { try await keyboard.hold(keys); Invocation.count(.keyboardReports) }
}

/// A mouse that counts each report on the running invocation once it is acknowledged, and
/// each wheel report as a notch on every axis it carries a count on.
struct TalliedMouse: Mouse {
    let mouse: any Mouse

    func down(_ button: Button) async throws { try await mouse.down(button); Invocation.count(.mouseReports) }
    func releaseAll() async throws { try await mouse.releaseAll(); Invocation.count(.mouseReports) }
    func hold(_ buttons: Set<Button>) async throws { try await mouse.hold(buttons); Invocation.count(.mouseReports) }
    func move(by delta: Move) async throws { try await mouse.move(by: delta); Invocation.count(.mouseReports) }
    func scroll(by delta: Scroll) async throws {
        try await mouse.scroll(by: delta)
        Invocation.count(.mouseReports)
        Invocation.count(.verticalNotches, by: delta.vertical == .zero ? 0 : 1)
        Invocation.count(.horizontalNotches, by: delta.horizontal == .zero ? 0 : 1)
    }
}
