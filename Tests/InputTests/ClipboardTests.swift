import AppKit
import Input
import Testing

/// The pasteboard write, against a pasteboard of this test's own.
///
/// [LAW:behavior-not-structure] What is asserted is what an app pasting from it would
/// get, not which AppKit calls were made - and never against `.general`, because the
/// person at this Mac is using theirs.
@Suite @MainActor struct ClipboardTests {
    private func scratch() -> NSPasteboard { NSPasteboard(name: NSPasteboard.Name("ai.promptctl.vhid.tests.\(UUID().uuidString)")) }

    @Test func theTextWrittenIsTheTextAnAppWouldPaste() throws {
        let pasteboard = scratch()
        defer { pasteboard.releaseGlobally() }
        try Clipboard(pasteboard).write("héllo — world")
        #expect(pasteboard.string(forType: .string) == "héllo — world")
    }

    /// The words replace what was there and stay. Said as a test because it is the cost a
    /// caller is accepting when it pastes rather than types.
    @Test func aWriteReplacesWhatWasThereAndDoesNotPutItBack() throws {
        let pasteboard = scratch()
        defer { pasteboard.releaseGlobally() }
        try Clipboard(pasteboard).write("what the user had copied")
        try Clipboard(pasteboard).write("what the caller wants pasted")
        #expect(pasteboard.string(forType: .string) == "what the caller wants pasted")
    }
}
