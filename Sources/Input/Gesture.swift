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
        case .lookUp: .shortcut(.lookUp)
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

    /// How the devices do what a gesture does.
    public enum Route: Sendable, Equatable {
        /// A chord an app matches by the character its key types, so it is spelled as `press`
        /// spells one and read off the layout: ⌘[ is on another key on a layout that puts [
        /// elsewhere.
        case command(String)
        /// A system shortcut, which macOS matches by key code and the user can change or
        /// turn off.
        case shortcut(SystemShortcut)
        /// No key or button does it, and why.
        case none(String)
    }
}

/// One of macOS's system shortcuts, stored by number in the `AppleSymbolicHotKeys`
/// dictionary of the `com.apple.symbolichotkeys` preferences, which System Settings >
/// Keyboard > Keyboard Shortcuts writes.
public struct SystemShortcut: Sendable, Equatable {
    /// Its number, the entry's key in `AppleSymbolicHotKeys`.
    public let id: Int
    /// Where a person changes it.
    public let setting: String
    /// What macOS does when the entry has never been written, which is until the user
    /// first changes it.
    public let byDefault: Binding

    /// One System Settings lists, at `path` under Keyboard Shortcuts.
    init(id: Int, listedAt path: String, byDefault: Binding) {
        self.init(id: id, setting: "System Settings > Keyboard > Keyboard Shortcuts > " + path, byDefault: byDefault)
    }

    /// One System Settings does not list, which only its entry changes.
    init(unlisted id: Int, byDefault: Binding) {
        self.init(id: id, setting: "entry \(id) of AppleSymbolicHotKeys in com.apple.symbolichotkeys, which System Settings does not list", byDefault: byDefault)
    }

    private init(id: Int, setting: String, byDefault: Binding) {
        self.id = id
        self.setting = setting
        self.byDefault = byDefault
    }

    static let missionControl = SystemShortcut(id: 32, listedAt: "Mission Control > Mission Control", byDefault: .key(kVK_UpArrow, [.leftControl]))
    static let appExpose = SystemShortcut(id: 33, listedAt: "Mission Control > Application windows", byDefault: .key(kVK_DownArrow, [.leftControl]))
    static let showDesktop = SystemShortcut(id: 36, listedAt: "Mission Control > Show Desktop", byDefault: .key(kVK_F11, []))
    static let lookUp = SystemShortcut(unlisted: 70, byDefault: .key(kVK_ANSI_D, [.leftControl, .leftCommand]))
    static let spaceLeft = SystemShortcut(id: 79, listedAt: "Mission Control > Mission Control > Move left a space", byDefault: .key(kVK_LeftArrow, [.leftControl]))
    static let spaceRight = SystemShortcut(id: 81, listedAt: "Mission Control > Mission Control > Move right a space", byDefault: .key(kVK_RightArrow, [.leftControl]))
    static let launchpad = SystemShortcut(id: 160, listedAt: "Launchpad & Dock > Show Launchpad", byDefault: .off)
    static let notificationCenter = SystemShortcut(id: 163, listedAt: "Mission Control > Show Notification Center", byDefault: .off)

    /// The `AppleSymbolicHotKeys` value the preferences hold, as its entries by number, or
    /// nil when they hold none.
    ///
    /// [LAW:parse-dont-validate] The crossing for the value as a whole; `inForce` is the one
    /// for an entry in it.
    public static func entries(_ hotKeys: Any?) throws(UnreadableHotKeys) -> [String: Any]? {
        guard let hotKeys else { return nil }
        guard let entries = hotKeys as? [String: Any] else { throw UnreadableHotKeys(held: "\(type(of: hotKeys))") }
        return entries
    }

    /// The binding in force, given the preferences' entries by number, or nil when they
    /// hold none.
    ///
    /// [LAW:parse-dont-validate] The one crossing from an entry's loose plist to a binding.
    /// An entry that is there but is not the shape macOS writes is refused, naming the
    /// entry, rather than read as the default: the default is what macOS does with *no*
    /// entry, and an entry it cannot read is something else. [LAW:no-silent-failure]
    public func inForce(in entries: [String: Any]?) throws(UnreadableShortcut) -> InForce {
        guard let entry = entries?[String(id)] else { return InForce(binding: byDefault, source: .byDefault) }
        let refused = UnreadableShortcut(shortcut: self, entry: "\(entry)")
        guard let fields = entry as? [String: Any], let enabled = fields["enabled"] as? Bool else { throw refused }
        guard enabled else { return InForce(binding: .off, source: .set) }
        // A "button" entry binds a mouse button, its parameters no key code at all.
        guard let value = fields["value"] as? [String: Any], value["type"] as? String == "standard",
              let parameters = value["parameters"] as? [Int], parameters.count == 3 else { throw refused }
        // [character, virtual key code, modifier flags]. The character is the layout's
        // reading of the key, which the key code already fixes; 0xFFFF is no key at all.
        let (code, flags) = (parameters[1], parameters[2])
        guard code != 0xFFFF else { return InForce(binding: .off, source: .set) }
        guard let key = UInt16(exactly: code), let modifiers = Self.modifiers(flags, on: code) else { throw refused }
        return InForce(binding: .on(KeyChord(key: Key(rawValue: key), modifiers: modifiers)), source: .set)
    }

    /// The modifiers held with key code `code`, from an `NSEvent.ModifierFlags` raw value,
    /// or nil for a flag that is no modifier the device can hold.
    ///
    /// The numeric pad flag is left out, and so is the function flag on the keys macOS sets
    /// it on - arrows, function keys and the navigation keys - as part of the key rather
    /// than a key held with it: ⌃↑ is stored with both and the device presses it as Control
    /// and the up arrow. On any other key the function flag is Fn held, which the device
    /// cannot hold, so 🌐M is refused rather than pressed as M.
    static func modifiers(_ flags: Int, on code: Int) -> Set<Modifier>? {
        let held: [(Int, Modifier)] = [(1 << 17, .leftShift), (1 << 18, .leftControl), (1 << 19, .leftOption), (1 << 20, .leftCommand)]
        let partOfTheKey = 1 << 21 | (functionKeys.contains(code) ? 1 << 23 : 0)
        let modifiers = Set(held.filter { flags & $0.0 != 0 }.map(\.1))
        let named = held.map(\.0).reduce(partOfTheKey, |)
        return flags & ~named == 0 ? modifiers : nil
    }

    /// The keys macOS stores with the function flag whether or not Fn was held.
    static let functionKeys: Set<Int> = [
        kVK_LeftArrow, kVK_RightArrow, kVK_UpArrow, kVK_DownArrow,
        kVK_Home, kVK_End, kVK_PageUp, kVK_PageDown, kVK_ForwardDelete, kVK_Help,
        kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
        kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20,
    ]

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
}

/// An `AppleSymbolicHotKeys` value that is not a dictionary of entries, as macOS writes it.
public struct UnreadableHotKeys: Error, CustomStringConvertible, Equatable {
    public let held: String

    public var description: String {
        "AppleSymbolicHotKeys in com.apple.symbolichotkeys is not a dictionary of shortcuts but a \(held)"
    }
}

/// A shortcut entry in the preferences that is not the shape macOS writes.
public struct UnreadableShortcut: Error, CustomStringConvertible, Equatable {
    public let shortcut: SystemShortcut
    public let entry: String

    public var description: String {
        "entry \(shortcut.id) of AppleSymbolicHotKeys in com.apple.symbolichotkeys, the shortcut at \(shortcut.setting), is not a shortcut vhid can read: \(entry)"
    }
}
