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
    static let dvorak = try! KeyboardLayout.named("com.apple.keylayout.Dvorak")

    private func scratch() -> NSPasteboard { NSPasteboard(name: NSPasteboard.Name("ai.promptctl.vhid.tests.\(UUID().uuidString)")) }

    /// The write lands before the chord, so the app pasting finds the text there and not
    /// whatever was on the pasteboard before.
    @Test func theTextIsOnThePasteboardBeforeTheChordGoesDown() async throws {
        let pasteboard = scratch()
        defer { pasteboard.releaseGlobally() }
        try Clipboard(pasteboard).write("what the user had copied")
        let keyboard = PasteboardReadingKeyboard(pasteboard)
        let chord = try await Typist(keyboard: keyboard).paste("héllo ✅ 日本", on: Self.us, through: Clipboard(pasteboard).write)
        #expect(chord == KeyChord(key: Key(rawValue: UInt16(kVK_ANSI_V)), modifiers: [.leftCommand]))
        #expect(keyboard.log == ["down e3 over héllo ✅ 日本", "down 19 over héllo ✅ 日本", "up"])
    }

    /// V is the key this layout puts `v` on: on Dvorak that is the key US calls period.
    @Test func onDvorakTheChordPressesTheKeyDvorakPutsVOn() async throws {
        let pasteboard = scratch()
        defer { pasteboard.releaseGlobally() }
        let keyboard = PasteboardReadingKeyboard(pasteboard)
        let chord = try await Typist(keyboard: keyboard).paste("text", on: Self.dvorak, through: Clipboard(pasteboard).write)
        #expect(chord.key == Key(rawValue: UInt16(kVK_ANSI_Period)))
        #expect(keyboard.log == ["down e3 over text", "down 37 over text", "up"])
    }

    /// A write the pasteboard refused is reported as it is, and no chord follows it: a
    /// paste then would put in whatever the pasteboard held instead.
    @Test func aRefusedWritePressesNothing() async throws {
        let keyboard = RefusingKeyboard()
        let refused = try await #require(throws: ClipboardRefused.self) {
            try await Typist(keyboard: keyboard).paste("text", on: Self.us) { _ in throw ClipboardRefused(pasteboard: "scratch") }
        }
        #expect(refused.pasteboard == "scratch")
        #expect(keyboard.log.isEmpty)
    }

    /// A layout with no `v` has no paste chord to spell, and says so before anything is
    /// written: the user's clipboard is still theirs.
    @Test func aLayoutWithNoVRefusesBeforeTheWrite() async throws {
        let russian = try KeyboardLayout.named("com.apple.keylayout.Russian")
        let pasteboard = scratch()
        defer { pasteboard.releaseGlobally() }
        try Clipboard(pasteboard).write("what the user had copied")
        let keyboard = RefusingKeyboard()
        await #expect(throws: ChordSpellingError.notOneKey("v", layout: russian.name)) {
            try await Typist(keyboard: keyboard).paste("text", on: russian, through: Clipboard(pasteboard).write)
        }
        #expect(pasteboard.string(forType: .string) == "what the user had copied")
        #expect(keyboard.log.isEmpty)
    }
}

/// A keyboard that notes what its pasteboard holds as each key goes down, which is the
/// moment an app pasting would read it.
///
/// Holds the pasteboard's name rather than the pasteboard, because a name is Sendable and
/// looks up the same pasteboard.
private final class PasteboardReadingKeyboard: Keyboard {
    private let pasteboard: String
    private let recorded = Mutex<[String]>([])

    init(_ pasteboard: NSPasteboard) { self.pasteboard = pasteboard.name.rawValue }

    var log: [String] { recorded.withLock { $0 } }

    func down(_ usage: Usage) throws {
        let holding = NSPasteboard(name: NSPasteboard.Name(pasteboard)).string(forType: .string) ?? "nothing"
        recorded.withLock { $0.append("down \(String(usage.rawValue, radix: 16)) over \(holding)") }
    }

    func releaseAll() throws { recorded.withLock { $0.append("up") } }
}
