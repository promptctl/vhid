import Carbon.HIToolbox
import KeyboardLayouts

/// A trackpad gesture, named by what it does.
///
/// No gesture reaches macOS as a gesture through the devices, which present a keyboard and
/// a mouse and nothing a touch is made of (docs/design/trackpad.md). What a gesture does
/// mostly has a key that does it too, and that key is the gesture's route. The routes are
/// the ones docs/design/gestures.md measured on a real Mac; a gesture it found no route for
/// is still named here, so asking for it is refused by name rather than approximated.
///
/// Scrolling, a secondary click, tap to click and dragging are the verbs `scroll`, `click`
/// and `drag` already, at a place, and are not repeated here.
public enum Gesture: String, CaseIterable, Sendable, CustomStringConvertible {
    case back, forward
    case zoomIn = "zoom-in", zoomOut = "zoom-out"
    case smartZoom = "smart-zoom"
    case rotate
    case lookUp = "look-up"
    case spaceLeft = "space-left", spaceRight = "space-right"
    case missionControl = "mission-control"
    case appExpose = "app-expose"
    case showDesktop = "show-desktop"
    case launchpad
    case notificationCenter = "notification-center"

    public var description: String { rawValue }

    /// The trackpad gesture that does this, in the words System Settings > Trackpad uses.
    public var onTrackpad: String {
        switch self {
        case .back: "swipe right with two fingers"
        case .forward: "swipe left with two fingers"
        case .zoomIn: "spread two fingers"
        case .zoomOut: "pinch two fingers"
        case .smartZoom: "double-tap with two fingers"
        case .rotate: "rotate two fingers"
        case .lookUp: "force click, or tap with three fingers"
        case .spaceLeft: "swipe right with three or four fingers"
        case .spaceRight: "swipe left with three or four fingers"
        case .missionControl: "swipe up with three or four fingers"
        case .appExpose: "swipe down with three or four fingers"
        case .showDesktop: "spread your thumb and three fingers"
        case .launchpad: "pinch your thumb and three fingers"
        case .notificationCenter: "swipe left from the right edge with two fingers"
        }
    }

    /// How the devices do what this gesture does.
    ///
    /// [LAW:one-type-per-behavior] Every gesture is one of three routes, and which one is a
    /// value here rather than a branch in whatever performs it.
    public var route: Route {
        switch self {
        case .back: .command("leftCommand+[")
        case .forward: .command("leftCommand+]")
        case .zoomIn: .command("leftCommand+=")
        case .zoomOut: .command("leftCommand+-")
        case .lookUp: .command("leftControl+leftCommand+d")
        case .smartZoom: .none("no key zooms on the block under the pointer; zoom-in zooms the whole page")
        case .rotate: .none("rotating is each app's own command, and no key rotates in every app")
        case .spaceLeft: .shortcut(.spaceLeft)
        case .spaceRight: .shortcut(.spaceRight)
        case .missionControl: .shortcut(.missionControl)
        case .appExpose: .shortcut(.appExpose)
        case .showDesktop: .shortcut(.showDesktop)
        case .launchpad: .shortcut(.launchpad)
        case .notificationCenter: .shortcut(.notificationCenter)
        }
    }
}

/// How the devices do what a gesture does.
public enum Route: Sendable, Equatable {
    /// A chord an app matches by the character its key types, so it is spelled as `press`
    /// spells one and read off the layout: ⌘[ is on another key on a layout that puts [
    /// elsewhere.
    case command(String)
    /// A system shortcut, which the user can change or turn off.
    case shortcut(SystemShortcut)
    /// No key or button does it, and why.
    case none(String)
}

/// One of macOS's system shortcuts: an entry under System Settings > Keyboard > Keyboard
/// Shortcuts, stored by number in the `AppleSymbolicHotKeys` dictionary of the
/// `com.apple.symbolichotkeys` preferences.
public struct SystemShortcut: Sendable, Equatable {
    /// Its number, the entry's key in `AppleSymbolicHotKeys`.
    public let id: Int
    /// Where System Settings shows it.
    public let setting: String
    /// What macOS does when the entry has never been written, which is until the user
    /// first changes it.
    public let byDefault: Binding

    static let missionControl = SystemShortcut(id: 32, setting: "Mission Control > Mission Control", byDefault: .key(kVK_UpArrow, [.leftControl]))
    static let appExpose = SystemShortcut(id: 33, setting: "Mission Control > Application windows", byDefault: .key(kVK_DownArrow, [.leftControl]))
    static let showDesktop = SystemShortcut(id: 36, setting: "Mission Control > Show Desktop", byDefault: .key(kVK_F11, []))
    static let spaceLeft = SystemShortcut(id: 79, setting: "Mission Control > Mission Control > Move left a space", byDefault: .key(kVK_LeftArrow, [.leftControl]))
    static let spaceRight = SystemShortcut(id: 81, setting: "Mission Control > Mission Control > Move right a space", byDefault: .key(kVK_RightArrow, [.leftControl]))
    static let launchpad = SystemShortcut(id: 160, setting: "Launchpad & Dock > Show Launchpad", byDefault: .off)
    static let notificationCenter = SystemShortcut(id: 163, setting: "Mission Control > Show Notification Center", byDefault: .off)

    /// The full path a person follows to the setting.
    public var settingPath: String { "System Settings > Keyboard > Keyboard Shortcuts > " + setting }

    /// The binding in force, given the `AppleSymbolicHotKeys` value the preferences hold,
    /// or nil when they hold none.
    ///
    /// [LAW:parse-dont-validate] The one crossing from the preferences' loose plist to a
    /// binding. An entry that is there but is not the shape macOS writes is refused, naming
    /// the entry, rather than read as the default: the default is what macOS does with *no*
    /// entry, and an entry it cannot read is something else. [LAW:no-silent-failure]
    public func inForce(in hotKeys: Any?) throws(UnreadableShortcut) -> InForce {
        guard let hotKeys else { return InForce(binding: byDefault, source: .byDefault) }
        guard let entries = hotKeys as? [String: Any] else { throw UnreadableShortcut(shortcut: self, entry: "\(hotKeys)") }
        guard let entry = entries[String(id)] else { return InForce(binding: byDefault, source: .byDefault) }
        let refused = UnreadableShortcut(shortcut: self, entry: "\(entry)")
        guard let fields = entry as? [String: Any], let enabled = fields["enabled"] as? Bool else { throw refused }
        guard enabled else { return InForce(binding: .off, source: .set) }
        guard let parameters = (fields["value"] as? [String: Any])?["parameters"] as? [Int], parameters.count == 3 else { throw refused }
        // [character, virtual key code, modifier flags]. The character is the layout's
        // reading of the key, which the key code already fixes; 0xFFFF is no key at all.
        let (code, flags) = (parameters[1], parameters[2])
        guard code != 0xFFFF else { return InForce(binding: .off, source: .set) }
        guard let key = UInt16(exactly: code), let modifiers = Self.modifiers(flags) else { throw refused }
        return InForce(binding: .on(KeyChord(key: Key(rawValue: key), modifiers: modifiers)), source: .set)
    }

    /// The modifiers held, from an `NSEvent.ModifierFlags` raw value, or nil for a flag that
    /// is no modifier the device can hold.
    ///
    /// The numeric pad and function flags are left out: macOS sets them on every arrow and
    /// function key, as part of the key rather than a key held with it, so ⌃↑ is stored
    /// with them and the device presses it as Control and the up arrow.
    static func modifiers(_ flags: Int) -> Set<Modifier>? {
        let held: [(Int, Modifier)] = [(1 << 17, .leftShift), (1 << 18, .leftControl), (1 << 19, .leftOption), (1 << 20, .leftCommand)]
        let partOfTheKey = 1 << 21 | 1 << 23
        let modifiers = Set(held.filter { flags & $0.0 != 0 }.map(\.1))
        let named = held.map(\.0).reduce(partOfTheKey, |)
        return flags & ~named == 0 ? modifiers : nil
    }
}

/// What a shortcut presses, or that it is off.
public enum Binding: Sendable, Equatable {
    case on(KeyChord)
    case off

    static func key(_ code: Int, _ modifiers: Set<Modifier>) -> Binding {
        .on(KeyChord(key: Key(rawValue: UInt16(code)), modifiers: modifiers))
    }
}

/// A shortcut's binding, and whether the user set it or it is macOS's default.
public struct InForce: Sendable, Equatable {
    public enum Source: Sendable, Equatable {
        /// The preferences hold an entry for it.
        case set
        /// They hold none, so macOS's default applies.
        case byDefault
    }

    public let binding: Binding
    public let source: Source

    public init(binding: Binding, source: Source) {
        self.binding = binding
        self.source = source
    }
}

/// A shortcut entry in the preferences that is not the shape macOS writes.
public struct UnreadableShortcut: Error, CustomStringConvertible, Equatable {
    public let shortcut: SystemShortcut
    public let entry: String

    public var description: String {
        "entry \(shortcut.id) of AppleSymbolicHotKeys in com.apple.symbolichotkeys, \(shortcut.settingPath), is not a shortcut vhid can read: \(entry)"
    }
}
