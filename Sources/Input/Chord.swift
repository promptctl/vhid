import Carbon.HIToolbox
import Keystrokes

extension Modifier {
    /// The key that moves this modifier, by macOS key code.
    ///
    /// The one place a modifier becomes a key. Every chord holding one is lowered through
    /// here, so a modifier that is on the wrong key is wrong once rather than wrong in
    /// each place somebody wrote the mapping out. [LAW:one-source-of-truth]
    var keyCode: UInt16 {
        switch self {
        case .leftShift: UInt16(kVK_Shift)
        case .rightShift: UInt16(kVK_RightShift)
        case .leftControl: UInt16(kVK_Control)
        case .rightControl: UInt16(kVK_RightControl)
        case .leftOption: UInt16(kVK_Option)
        case .rightOption: UInt16(kVK_RightOption)
        case .leftCommand: UInt16(kVK_Command)
        case .rightCommand: UInt16(kVK_RightCommand)
        case .function: UInt16(kVK_Function)
        }
    }

    /// The HID usage that moves this modifier, or nil for one the keyboard page has no
    /// usage for: Fn is not a key to the device, so no chord holding it can be pressed.
    ///
    /// Derived through the modifier's key code and the one key-code table, rather than
    /// tabulated a second time here. [LAW:one-source-of-truth]
    public var usage: Usage? { Usage(virtualKeyCode: keyCode) }
}

extension Keystroke {
    /// A chord as the device presses it: the key under the modifiers held.
    ///
    /// [LAW:parse-dont-validate] A chord names keys by macOS key code and modifiers by
    /// name, and neither is proven pressable until here: the key may be one the keyboard
    /// page has no usage for, a modifier may be Fn, and a chord may be modifiers alone -
    /// a hotkey, which is held rather than struck, and which a keystroke cannot say. A
    /// caller holding a `Keystroke` holds one the device can press.
    public init(chord: KeyChord) throws(UnpressableChord) {
        guard let key = chord.key else { throw UnpressableChord(chord: chord, because: "it has no key to strike; modifiers alone are a hotkey, not a keystroke") }
        guard let usage = Usage(virtualKeyCode: key.rawValue) else { throw UnpressableChord(chord: chord, because: "key code \(key.rawValue) is not a key the keyboard page names") }
        let unpressable = chord.modifiers.filter { $0.usage == nil }
        guard unpressable.isEmpty else { throw UnpressableChord(chord: chord, because: "\(unpressable.map(\.rawValue).sorted().joined(separator: ", ")) is not a key the device can hold") }
        self.init(usage, Modifiers(chord.modifiers.compactMap(\.usage)))
    }
}

/// A chord the virtual keyboard cannot press, and why.
public struct UnpressableChord: Error, CustomStringConvertible, Equatable {
    public let chord: KeyChord
    public let because: String

    public init(chord: KeyChord, because: String) {
        self.chord = chord
        self.because = because
    }

    public var description: String { "the chord \(chord) cannot be pressed: \(because)" }
}
