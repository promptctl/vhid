import AppKit
import Foundation
import Helper
import Input
import Installations
import Keystrokes
import Pointing
import ScreenSpace
import struct Seeing.Front
import Telemetry

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
    /// The display layout as the daemon reads it, in the session in front, for the reason the
    /// cursor is read there. [LAW:single-enforcer] Every act reads its layout here.
    let layout: @Sendable () async throws -> DisplayLayout
    let front: @Sendable () async throws -> Front.App?
    /// The pointer this mouse is steered by, reading the cursor back after every report -
    /// which is the only place the truth about where the pointer went lives, since macOS
    /// accelerates the counts the device sends. One per opening, so a verb's moves draw
    /// from one seed, and that seed is on its record, as is every move it makes, however
    /// the verb ends. [LAW:nothing-unseen]
    let pointer: Pointer
    /// The typist these keys are typed by, timed on the pointer's clock and drawing from
    /// its random source, so the seed on a verb's record draws its keys again too.
    let typist: Typist
    /// What the pointer and the typist trace to: the pauses and moves noted on the verb's
    /// record when these devices are handed back. A pointer or typist a test builds over
    /// these devices traces here too, so its record is the one a verb's would be.
    let trail: Trail

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
        for count in Telemetry.Count.allCases where count.isSent { Telemetry.count(count, 0) }
        let trail = Trail()
        let mouse = TalliedMouse(mouse: QueuedMouse(pointing: helper.mouse, queue: queue))
        let cursor = cursor(helper, on: queue)
        let randomness = RandomSource(seed: UInt64.random(in: .min ... .max))
        Telemetry.note(.seed, .string(String(randomness.seed, radix: 16)))
        // Both are IOHIDSystem's parameters, HIDClickTime and HIDInitialKeyRepeat: one per
        // Mac, the values the HID system counts clicks and repeats keys by, so every process
        // reads the ones governing the session in front, whoever's it is. Not the user's
        // preferences, which only reach them through System Settings or a login. Measured on
        // studious, 2026-10-06: set there, NSEvent answered them for bmf and for a user with
        // no session alike; a user's `defaults write` left them alone. `Hand`, `Cadence`.
        let doubleClick = Duration.seconds(NSEvent.doubleClickInterval)
        Telemetry.note(.doubleClickMilliseconds, .double(doubleClick / .milliseconds(1)))
        let keyRepeatDelay = Duration.seconds(NSEvent.keyRepeatDelay)
        Telemetry.note(.keyRepeatDelayMilliseconds, .double(keyRepeatDelay / .milliseconds(1)))
        let keyboard = TalliedKeyboard(keyboard: QueuedKeyboard(keyboard: helper.keyboard, queue: queue))
        let devices = Devices(keyboard: keyboard, mouse: mouse, cursor: cursor, layout: layout(helper, on: queue), front: front(helper, on: queue),
                              pointer: Pointer(mouse: mouse, cursor: cursor, timeline: .suspending,
                                               randomness: randomness, hand: Hand(doubleClickInterval: doubleClick), traced: trail.traced),
                              typist: Typist(keyboard: keyboard, timeline: .suspending, randomness: randomness,
                                             cadence: Cadence(keyRepeatDelay: keyRepeatDelay), traced: trail.typed), trail: trail)
        let ran: Result<T, any Error>
        do { ran = .success(try await body(devices)) } catch { ran = .failure(error) }
        trail.noted()
        // On the queue, behind the last report this verb sent, however the verb ended: a
        // connection that is working hands the devices back rather than make the next client
        // wait on its disconnection. A leave that fails replaces nothing the verb did or why
        // it stopped - an error there would read as "nothing happened", and a caller that
        // retried would click twice or type the text twice - so it is noted beside it, on the
        // record and on stderr, and the disconnection that follows releases the devices
        // regardless. [LAW:no-silent-failure]
        do {
            try await queue.run { try helper.leave() }
        } catch {
            Telemetry.note(.leaveFailed, .string(error.reported))
            let ended = switch ran { case .success: "after the verb was done"; case .failure: "after the verb stopped" }
            FileHandle.standardError.write(Data("vhid: the devices were not handed back \(ended): \(error.reported)\n".utf8))
        }
        return try ran.get()
    }

    /// The app in front, asked once the daemon has answered that the devices are up.
    ///
    /// launchd starts vhidd on the first call, so asked any earlier the answer would be as
    /// old as the daemon's start by the first key - the window `--into` exists to close.
    /// `status` is answered once the daemon is listening, and refused while its devices
    /// are down, so a verb that gets past it has devices to send to. It is made on `queue`
    /// like every other call, and claims nothing. [LAW:no-ambient-temporal-coupling]
    static func front(_ helper: HelperConnection, on queue: DeviceQueue) -> @Sendable () async throws -> Front.App? {
        {
            _ = try await queue.run { try helper.status() }
            return try await Aim.inFront()
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
            do throws(NotAPlace) {
                return try ScreenPoint(x: at.x, y: at.y)
            } catch {
                throw CursorUnreadable(error)
            }
        }
    }

    /// The layout as the daemon reads it, waited for on `queue` for the reason the cursor is.
    static func layout(_ helper: HelperConnection, on queue: DeviceQueue) -> @Sendable () async throws -> DisplayLayout {
        { try await queue.run { try helper.layout() } }
    }

    /// The place a verb was given, placed by the one rule on one read of the layout's online
    /// displays, where the cursor moves. [LAW:one-source-of-truth]
    func placed(_ asked: Target.Asked) async throws -> Target {
        try asked.placed(on: try await layout().online)
    }

    /// A drag's two places, placed on one read: an act reads its layout once, so both its
    /// places and the path between them are decided on one. [LAW:one-source-of-truth]
    func placed(_ from: Target.Asked, _ to: Target.Asked) async throws -> (from: Target, to: Target) {
        let online = try await layout().online
        return (try from.placed(on: online), try to.placed(on: online))
    }
}

/// A keyboard that counts each report on the running invocation once it is acknowledged.
struct TalliedKeyboard: Keyboard {
    let keyboard: any Keyboard

    func down(_ usage: Usage) async throws { try await keyboard.down(usage); Telemetry.tally(.keyboardReports) }
    func releaseAll() async throws { try await keyboard.releaseAll(); Telemetry.tally(.keyboardReports) }
    func hold(_ keys: HeldKeys) async throws { try await keyboard.hold(keys); Telemetry.tally(.keyboardReports) }
}

/// A mouse that counts each report on the running invocation once it is acknowledged, and
/// each wheel report as a notch on every axis it carries a count on.
struct TalliedMouse: Mouse {
    let mouse: any Mouse

    func down(_ button: Button) async throws { try await mouse.down(button); Telemetry.tally(.mouseReports) }
    func releaseAll() async throws { try await mouse.releaseAll(); Telemetry.tally(.mouseReports) }
    func hold(_ buttons: Set<Button>) async throws { try await mouse.hold(buttons); Telemetry.tally(.mouseReports) }
    func move(by delta: Move) async throws { try await mouse.move(by: delta); Telemetry.tally(.mouseReports) }
    func scroll(by delta: Scroll) async throws {
        try await mouse.scroll(by: delta)
        Telemetry.tally(.mouseReports)
        Telemetry.tally(.verticalNotches, by: delta.vertical == .zero ? 0 : 1)
        Telemetry.tally(.horizontalNotches, by: delta.horizontal == .zero ? 0 : 1)
    }
}
