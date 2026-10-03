import Carbon.HIToolbox
import KeyboardLayouts
import Keystrokes
import Testing
import Input

/// What a gesture comes to, and a system shortcut read from the entry the preferences hold.
@Suite struct GestureTests {
    static let us = try! KeyboardLayout.named("com.apple.keylayout.US")

    /// An entry as macOS writes one: enabled, and [character, key code, modifier flags].
    static func entry(_ enabled: Bool, _ parameters: [Int]) -> [String: Any] {
        ["enabled": enabled, "value": ["parameters": parameters, "type": "standard"]]
    }

    /// The preferences holding only Mission Control's entry.
    static func holding(_ entry: Any) -> [String: Any] { ["32": entry] }

    static func shortcut(_ gesture: Gesture) -> SystemShortcut? {
        guard case .shortcut(let shortcut) = gesture.route else { return nil }
        return shortcut
    }

    static let missionControl = shortcut(.missionControl)!

    /// Every chord an app matches by character spells on a real layout, so none of them is
    /// refused for a typo in the table.
    @Test(arguments: Gesture.allCases)
    func everyCommandSpellsOnUSEnglish(_ gesture: Gesture) throws {
        guard case .command(let spelling) = gesture.route else { return }
        _ = try KeyChord(spelled: spelling, on: Self.us)
    }

    /// No entry is the default, and says so: the user never changed it. Preferences with
    /// no shortcuts at all are the same.
    @Test func noEntryIsMacOSsDefault() throws {
        let byDefault = SystemShortcut.InForce(binding: .on(KeyChord(key: Key(rawValue: UInt16(kVK_UpArrow)), modifiers: [.leftControl])), source: .byDefault)
        #expect(try Self.missionControl.inForce(in: nil) == byDefault)
        #expect(try Self.missionControl.inForce(in: ["79": Self.entry(false, [])]) == byDefault)
    }

    /// studious's Mission Control, measured: q, key code 12, Option.
    @Test func anEntryIsTheKeyAndModifiersItNames() throws {
        let inForce = try Self.missionControl.inForce(in: Self.holding(Self.entry(true, [113, 12, 524288])))
        #expect(inForce == SystemShortcut.InForce(binding: .on(KeyChord(key: Key(rawValue: 12), modifiers: [.leftOption])), source: .set))
    }

    /// ⌃↑ as macOS stores it carries the numeric pad and function flags, which are part of
    /// the arrow key and not keys held with it.
    @Test func theFlagsAnArrowKeyCarriesAreNotModifiers() throws {
        let inForce = try Self.missionControl.inForce(in: Self.holding(Self.entry(true, [65535, 126, 8650752])))
        #expect(inForce.binding == .on(KeyChord(key: Key(rawValue: UInt16(kVK_UpArrow)), modifiers: [.leftControl])))
    }

    @Test func aDisabledEntryIsOffWhateverItsKey() throws {
        #expect(try Self.missionControl.inForce(in: Self.holding(Self.entry(false, [113, 12, 524288]))) == SystemShortcut.InForce(binding: .off, source: .set))
        #expect(try Self.missionControl.inForce(in: Self.holding(["enabled": false])) == SystemShortcut.InForce(binding: .off, source: .set))
    }

    /// Enabled with no key, as studious's 175 is.
    @Test func anEnabledEntryWithNoKeyIsOff() throws {
        #expect(try Self.missionControl.inForce(in: Self.holding(Self.entry(true, [65535, 65535, 0]))).binding == .off)
    }

    /// Launchpad has no shortcut until the user gives it one.
    @Test func launchpadIsOffByDefault() throws {
        #expect(try #require(Self.shortcut(.launchpad)).inForce(in: nil) == SystemShortcut.InForce(binding: .off, source: .byDefault))
    }

    /// Entries macOS would not write, passed to the test below by index, since an entry is
    /// not `Sendable`.
    static var unreadable: [[String: Any]] { [
        ["enabled": true],
        entry(true, [113, 12]),
        // Caps Lock, 1 << 16, is no modifier the device holds.
        entry(true, [113, 12, 1 << 16]),
        ["enabled": "yes", "value": ["parameters": [113, 12, 0]]],
    ] }

    /// An entry that is there but unreadable is refused rather than read as the default,
    /// which is what macOS does with no entry at all. [LAW:no-silent-failure]
    @Test(arguments: unreadable.indices)
    func anEntryNotShapedAsMacOSWritesOneIsRefused(_ index: Int) {
        let refused = #expect(throws: UnreadableShortcut.self) { try Self.missionControl.inForce(in: Self.holding(Self.unreadable[index])) }
        #expect(refused?.description.contains("entry 32 of AppleSymbolicHotKeys") == true)
    }

    /// Preferences that are not a dictionary of entries are refused as a whole, not blamed
    /// on one entry.
    @Test func hotKeysThatAreNoDictionaryAreRefused() {
        let refused = #expect(throws: UnreadableHotKeys.self) { try SystemShortcut.entries([1, 2]) }
        #expect(refused?.description.hasPrefix("AppleSymbolicHotKeys in com.apple.symbolichotkeys is not a dictionary") == true)
    }

    /// Fn held with a key that does not carry the function flag is no modifier the device
    /// can hold, so 🌐M is refused rather than pressed as M.
    @Test func fnHeldWithALetterIsRefused() {
        #expect(throws: UnreadableShortcut.self) { try Self.missionControl.inForce(in: Self.holding(Self.entry(true, [109, 46, 1 << 23]))) }
    }
}
