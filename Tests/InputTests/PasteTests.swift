import AppKit
import Carbon.HIToolbox
import KeyboardLayout
import Keystrokes
import Synchronization
import Testing
@testable import Input

/// A paste against a pasteboard of this test's own and a keyboard that reads that
/// pasteboard back as each key goes down - never `.general`, because the person at this
/// Mac is using theirs.
///
/// [LAW:behavior-not-structure] What is asserted is what an app would see: which keys went
/// down, and what was on the pasteboard when they did.
@Suite @MainActor struct PasteTests {
    static let us = try! KeyboardLayout.named("com.apple.keylayout.US")

    /// The write lands before the chord, so the app pasting finds the text there and not
    /// whatever was on the pasteboard before.
    @Test func theTextIsOnThePasteboardBeforeTheChordGoesDown() async throws {
        let pasteboard = scratch()
        defer { pasteboard.releaseGlobally() }
        try Clipboard(pasteboard).write("what the user had copied")
        let keyboard = PasteboardReadingKeyboard(pasteboard)
        let chord = try await Typist(keyboard: keyboard).paste("héllo ✅ 日本", on: Self.us, through: Clipboard(pasteboard).write)
        #expect(chord == KeyChord(key: Key(rawValue: UInt16(kVK_ANSI_V)), modifiers: [.leftCommand]))
        #expect(keyboard.log == ["up over what the user had copied", "down e3 over héllo ✅ 日本", "down 19 over héllo ✅ 日本", "up over héllo ✅ 日本"])
    }

    /// V is the key this layout puts `v` on with Command held: on Dvorak that is the key US
    /// calls period. Which key that is on every layer is ChordSpellingTests' to hold.
    @Test func onDvorakTheChordPressesTheKeyDvorakPutsVOn() async throws {
        let pasteboard = scratch()
        defer { pasteboard.releaseGlobally() }
        let keyboard = PasteboardReadingKeyboard(pasteboard)
        try await Typist(keyboard: keyboard).paste("text", on: KeyboardLayout.named("com.apple.keylayout.Dvorak"), through: Clipboard(pasteboard).write)
        #expect(keyboard.log == ["up over nothing", "down e3 over text", "down 37 over text", "up over text"])
    }

    /// Nothing to paste and a cancelled run are both refused with what the user had copied
    /// still on the clipboard, and no key down.
    @Test func emptyTextAndACancelledRunLeaveTheClipboardAlone() async throws {
        let pasteboard = scratch()
        defer { pasteboard.releaseGlobally() }
        try Clipboard(pasteboard).write("what the user had copied")
        let keyboard = RefusingKeyboard()
        let typist = Typist(keyboard: keyboard)
        await #expect(throws: NothingToPaste.self) { try await typist.paste("", on: Self.us, through: Clipboard(pasteboard).write) }
        // Made on this actor, so it does not begin until the test suspends: it is cancelled
        // before its first line runs.
        let run = Task { try await typist.paste("text", on: Self.us, through: Clipboard(pasteboard).write) }
        run.cancel()
        await #expect(throws: CancellationError.self) { try await run.value }
        #expect(pasteboard.string(forType: .string) == "what the user had copied")
        // The cancelled run reached the daemon, which holds nothing down; no key went down.
        #expect(keyboard.log == ["up"])
    }

    /// A run cancelled while the release waits on the daemon is refused before the write,
    /// not by the chord after it: the clipboard is still the user's and no key goes down.
    @Test func aRunCancelledWhileTheDaemonIsReachedLeavesTheClipboardAlone() async throws {
        let pasteboard = scratch()
        defer { pasteboard.releaseGlobally() }
        try Clipboard(pasteboard).write("what the user had copied")
        let keyboard = CancellingAtReleaseKeyboard()
        let run = Task { try await Typist(keyboard: keyboard).paste("text", on: Self.us, through: Clipboard(pasteboard).write) }
        keyboard.aim(at: run)
        await #expect(throws: CancellationError.self) { try await run.value }
        #expect(pasteboard.string(forType: .string) == "what the user had copied")
        #expect(keyboard.log == ["up"])
    }

    /// A write the pasteboard refused is reported as it is, and no chord follows it: a
    /// paste then would put in whatever the pasteboard held instead.
    @Test func aRefusedWritePressesNothing() async throws {
        let keyboard = RefusingKeyboard()
        let refused = try await #require(throws: ClipboardRefused.self) {
            try await Typist(keyboard: keyboard).paste("text", on: Self.us) { _ in throw ClipboardRefused(pasteboard: "scratch") }
        }
        #expect(refused.pasteboard == "scratch")
        #expect(keyboard.log == ["up"])
    }

    /// A daemon that will not take keys is found out before the write, so the refusal costs
    /// the user nothing: what they had copied is still there. [LAW:no-silent-failure]
    @Test func aKeyboardThatRefusesEverythingLeavesTheClipboardAlone() async throws {
        let pasteboard = scratch()
        defer { pasteboard.releaseGlobally() }
        try Clipboard(pasteboard).write("what the user had copied")
        let keyboard = RefusingKeyboard()
        keyboard.allow = 0
        await #expect(throws: Refused.self) {
            try await Typist(keyboard: keyboard).paste("text", on: Self.us, through: Clipboard(pasteboard).write)
        }
        #expect(pasteboard.string(forType: .string) == "what the user had copied")
        #expect(keyboard.log.isEmpty)
    }

    /// A chord that stops after the write is reported with what the write already did: the
    /// clipboard holds the text, and what was copied there before is gone.
    @Test func aChordThatStopsSaysTheClipboardAlreadyHoldsTheText() async throws {
        let pasteboard = scratch()
        defer { pasteboard.releaseGlobally() }
        let keyboard = StuckKeyboard()
        let stopped = try await #require(throws: PasteStopped.self) {
            try await Typist(keyboard: keyboard).paste("text", on: Self.us, through: Clipboard(pasteboard).write)
        }
        #expect(stopped.cause is ChordStopped)
        #expect(stopped.causes.last is Refused)
        #expect(pasteboard.string(forType: .string) == "text")
        #expect("\(stopped)".contains("already on the clipboard"))
        #expect(keyboard.log == ["up", "down e3", "up"])
    }
}

/// A keyboard that notes what its pasteboard holds at every call: at a key going down,
/// which is the moment an app pasting would read it, and at a release, which is when the
/// daemon is reached.
///
/// Holds the pasteboard's name rather than the pasteboard, because a name is Sendable and
/// looks up the same pasteboard.
private final class PasteboardReadingKeyboard: Keyboard {
    private let pasteboard: String
    private let recorded = Mutex<[String]>([])

    init(_ pasteboard: NSPasteboard) { self.pasteboard = pasteboard.name.rawValue }

    var log: [String] { recorded.withLock { $0 } }

    private var holding: String { NSPasteboard(name: NSPasteboard.Name(pasteboard)).string(forType: .string) ?? "nothing" }

    func down(_ usage: Usage) throws {
        let holding = holding
        recorded.withLock { $0.append("down \(String(usage.rawValue, radix: 16)) over \(holding)") }
    }

    func releaseAll() throws {
        let holding = holding
        recorded.withLock { $0.append("up over \(holding)") }
    }
}

/// A keyboard that cancels the run it is part of at its first release - the paste's reach
/// for the daemon - so the cancellation lands between that and the write.
private final class CancellingAtReleaseKeyboard: Keyboard {
    private let state = Mutex<(log: [String], run: Task<KeyChord, any Error>?)>(([], nil))

    var log: [String] { state.withLock { $0.log } }

    func aim(at run: Task<KeyChord, any Error>) { state.withLock { $0.run = run } }

    func down(_ usage: Usage) throws { state.withLock { $0.log.append("down \(String(usage.rawValue, radix: 16))") } }

    func releaseAll() throws {
        state.withLock {
            $0.log.append("up")
            $0.run?.cancel()
        }
    }
}
