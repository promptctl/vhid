import Foundation
import Input
import Installations
import Keystrokes
import Pointing
import Synchronization
import Testing
@testable import vhid

/// A keyboard that records instead of typing, and can be told to fail at the nth key.
///
/// Non-isolated and `Mutex`-backed, because the verbs take the caller's isolation and a
/// test that pinned these to an actor would be testing something the CLI does not do.
final class RecordingKeyboard: Keyboard {
    struct Refused: Error, CustomStringConvertible {
        let description = "the fake keyboard refused"
    }

    private let state = Mutex<(down: [Usage], releases: Int, holds: [HeldKeys], failAt: Int?)>((down: [], releases: 0, holds: [], failAt: nil))

    init(failingAtKey failAt: Int? = nil) {
        state.withLock { $0.failAt = failAt }
    }

    var down: [Usage] { state.withLock { $0.down } }
    var releases: Int { state.withLock { $0.releases } }
    var holds: [HeldKeys] { state.withLock { $0.holds } }

    func down(_ usage: Usage) async throws {
        try state.withLock {
            if $0.down.count == $0.failAt { throw Refused() }
            $0.down.append(usage)
        }
    }

    func releaseAll() async throws {
        state.withLock { $0.releases += 1 }
    }

    func hold(_ keys: HeldKeys) async throws {
        state.withLock { $0.holds.append(keys) }
    }
}

/// A mouse over a screen of its own, with an acceleration curve of its own.
///
/// The cursor it reports is the cursor it moved, so a `Pointer` driven against it
/// converges the same way it does against the window server - and lands somewhere that is
/// not exactly where it was aimed, which is the whole reason `click` reports a read-back
/// position rather than the one it was given.
final class FakeMouse: Mouse {
    private let state = Mutex<(x: Double, y: Double, buttons: [Button], releases: Int, moves: Int, scrolls: [Scroll], holds: [Set<Button>])>(
        (x: 0, y: 0, buttons: [], releases: 0, moves: 0, scrolls: [], holds: []))
    private let gain: Double

    init(at x: Double, _ y: Double, gain: Double = 1) {
        self.gain = gain
        state.withLock { $0.x = x; $0.y = y }
    }

    var cursor: ScreenPoint { state.withLock { ScreenPoint(x: $0.x, y: $0.y)! } }
    var buttons: [Button] { state.withLock { $0.buttons } }
    var releases: Int { state.withLock { $0.releases } }
    var moves: Int { state.withLock { $0.moves } }
    var scrolls: [Scroll] { state.withLock { $0.scrolls } }
    var holds: [Set<Button>] { state.withLock { $0.holds } }

    func down(_ button: Button) async throws { state.withLock { $0.buttons.append(button) } }
    func releaseAll() async throws { state.withLock { $0.releases += 1 } }
    func hold(_ buttons: Set<Button>) async throws { state.withLock { $0.holds.append(buttons) } }

    func move(by delta: Move) async throws {
        state.withLock {
            $0.moves += 1
            $0.x += Double(delta.x.value) * gain
            $0.y += Double(delta.y.value) * gain
        }
    }

    func scroll(by delta: Scroll) async throws { state.withLock { $0.scrolls.append(delta) } }
}

extension Installation {
    /// A service nothing registers, so an argument that is wrongly let through fails to
    /// connect rather than moving the pointer of the Mac running the tests, and a doctor
    /// asked about it is never ready, on any Mac.
    static let nobody = Installation(service: "ai.promptctl.vhid.tests.nobody")!
}

extension EventExport {
    /// An export to a file of its own under the temporary directory, and no collector, so
    /// a test's records never reach the operator's log.
    static func scratch() -> EventExport {
        EventExport(collector: nil, file: FileManager.default.temporaryDirectory.appending(path: "vhid-tests-\(UUID().uuidString)/events.jsonl"),
                    deliver: { _ in Issue.record("a scratch export has no collector to deliver to") })
    }

    /// Every record in the file, parsed back.
    var written: [[String: Any]] {
        get throws {
            guard FileManager.default.fileExists(atPath: file.path) else { return [] }
            return try String(contentsOf: file, encoding: .utf8).split(separator: "\n").map {
                try #require(try JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
            }
        }
    }
}

extension Displays {
    /// A screen whose edges are further than any test's path goes, for tests that are not
    /// about the edges.
    static let vast = Displays(frames: [CGRect(x: -100_000, y: -100_000, width: 200_000, height: 200_000)])!
}

extension Hand {
    /// The hand on a Mac at macOS's default double-click interval of 0.5 s, which both test
    /// Macs keep.
    static let atDefaults = Hand(doubleClickInterval: .milliseconds(500))
}
