import Foundation

/// What `/Library/Preferences/com.apple.keyboardtype` holds, and what filing this
/// keyboard's answer into it means.
///
/// [LAW:one-source-of-truth] The daemon files this keyboard's answer into the file as
/// root, and `vhid doctor` reads it back as the user. Both read the file through `read`,
/// and both ask `answersThisKeyboard`, so the file cannot mean one thing to the process
/// that wrote it and another to the one that checks it - not what an absent file is, not
/// what counts as filed.
public struct KeyboardTypeCache {
    /// Every top-level key, the answers included, as they were read - so a writer carries
    /// through what it does not know about rather than dropping it.
    public let root: [String: Any]
    /// The answers under `keyboardtype`, by device key: the same value `root` holds there,
    /// parsed. Both are set by this type alone, so they cannot disagree.
    public let answers: [String: Int]

    private static let entry = "keyboardtype"

    private init(root: [String: Any], answers: [String: Int]) {
        self.root = root
        self.answers = answers
    }

    /// Whether this keyboard's answer is filed, as the daemon files it: ANSI under the
    /// virtual keyboard's key. Any other value there is an answer this project's layout
    /// maps were not built against, and the daemon rewrites it. [LAW:single-enforcer]
    public var answersThisKeyboard: Bool {
        answers[VirtualKeyboardIdentity.keyboardTypeKey] == VirtualKeyboardIdentity.ansiKeyboardType
    }

    /// This cache with its answers replaced, and every other top-level key as it was.
    public func replacing(answers: [String: Int]) -> KeyboardTypeCache {
        var root = self.root
        root[Self.entry] = answers
        return KeyboardTypeCache(root: root, answers: answers)
    }

    /// The cache at `path`, or why it could not be read.
    ///
    /// [LAW:no-silent-failure] Only a file that is not there is an empty cache - a Mac that
    /// has met no keyboard has cached nothing. A file that is there and cannot be read or
    /// understood is refused, never read as empty: the writer would overwrite every other
    /// device's answer on that reading, and the reader would report an answer missing
    /// that may be there. Read once and told apart by the read's own error, so there is
    /// no window between asking whether it exists and reading it.
    public static func read(at path: String = VirtualKeyboardIdentity.keyboardTypePlist) throws(Unreadable) -> KeyboardTypeCache {
        let data: Data
        do {
            data = try Data(contentsOf: URL(fileURLWithPath: path))
        } catch CocoaError.fileReadNoSuchFile {
            return KeyboardTypeCache(root: [:], answers: [:])
        } catch CocoaError.fileReadNoPermission {
            throw Unreadable(path: path, reason: .notReadableByThisUser)
        } catch {
            throw Unreadable(path: path, reason: .readFailed("\(error)"))
        }
        return try parse(data, at: path)
    }

    /// [LAW:parse-dont-validate] The bytes as a cache, or the refusal naming what is wrong.
    private static func parse(_ data: Data, at path: String) throws(Unreadable) -> KeyboardTypeCache {
        let contents: Any
        do {
            contents = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        } catch {
            throw Unreadable(path: path, reason: .unparsable("\(error)"))
        }
        guard let root = contents as? [String: Any] else { throw Unreadable(path: path, reason: .unparsable("its root is not a dictionary")) }
        guard let cached = root[entry] else { return KeyboardTypeCache(root: root, answers: [:]) }
        guard let answers = cached as? [String: Int] else {
            throw Unreadable(path: path, reason: .unparsable("its \(entry) entry is not a dictionary of numbers"))
        }
        return KeyboardTypeCache(root: root, answers: answers)
    }

    /// The cache could not be read, and why.
    public struct Unreadable: Error, CustomStringConvertible, Equatable {
        public enum Reason: Sendable, Equatable {
            case notReadableByThisUser
            case readFailed(String)
            case unparsable(String)
        }

        public let path: String
        public let reason: Reason

        /// The one cause a person can see and act on gets its step in the words: the
        /// daemon asserts the mode as it starts, once the answer is filed, and logs why
        /// when it could not.
        public var description: String {
            switch reason {
            case .notReadableByThisUser:
                """
                \(path) is not readable by this user. The daemon sets it to 0644 as it \
                starts, once the answer is filed, and logs why when it cannot; to read \
                it now: sudo chmod 644 \(path)
                """
            case .readFailed(let why):
                "\(path) could not be read: \(why)"
            case .unparsable(let why):
                "\(path) is not a keyboard type cache: \(why)"
            }
        }
    }
}
