import KeyboardLayouts
import Testing
@testable import vhid

/// What `--layout` becomes on `type` and `press`.
@Suite struct LayoutOptionTests {
    @Test func bothKeyboardVerbsReadIt() throws {
        let typed = try #require(try Vhid.parseAsRoot(["type", "--layout", "com.apple.keylayout.Dvorak", "a"]) as? TypeCommand)
        #expect(try typed.layoutOption.layout().name == "com.apple.keylayout.Dvorak")
        let pressed = try #require(try Vhid.parseAsRoot(["press", "--layout", "com.apple.keylayout.Dvorak", "return"]) as? PressCommand)
        #expect(try pressed.layoutOption.layout().name == "com.apple.keylayout.Dvorak")
    }

    @Test func anUnknownLayoutIsRefusedByName() {
        #expect(throws: NoLayout.noSourceNamed("com.apple.keylayout.Nope")) {
            try LayoutOption.parse(["--layout", "com.apple.keylayout.Nope"]).layout()
        }
    }

    @Test func itIsNotRequired() throws {
        #expect(try LayoutOption.parse([]).named == nil)
    }
}
