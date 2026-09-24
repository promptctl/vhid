import Foundation

/// What `/Library/Preferences/com.apple.keyboardtype` holds, read out of its bytes.
///
/// [LAW:one-source-of-truth] The daemon files this keyboard's answer into the file as
/// root, and `vhid doctor` reads it back as the user. Both read it through this, so the
/// file cannot mean one thing to the process that wrote it and another to the one that
/// checks it.
public struct KeyboardTypeCache {
    /// Every top-level key, the answers included, as they were read - so a writer carries
    /// through what it does not know about rather than dropping it.
    public let root: [String: Any]
    /// The answers under `keyboardtype`, by device key.
    public let answers: [String: Int]

    /// The entry the answers live under.
    public static let entry = "keyboardtype"

    /// A Mac that has met no keyboard: no file, or a file with no answers yet.
    public static var empty: KeyboardTypeCache { KeyboardTypeCache(root: [:], answers: [:]) }

    public init(root: [String: Any], answers: [String: Int]) {
        self.root = root
        self.answers = answers
    }

    /// The cache these bytes hold, or why they hold none.
    ///
    /// [LAW:parse-dont-validate] A file that is there and cannot be understood is refused,
    /// never read as a cache with no answers: the writer would overwrite every other
    /// device's answer on that reading, and the reader would report an answer missing
    /// that may be there.
    public static func parse(_ data: Data) throws(Unparsable) -> KeyboardTypeCache {
        let contents: Any
        do {
            contents = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        } catch {
            throw Unparsable(reason: "\(error)")
        }
        guard let root = contents as? [String: Any] else { throw Unparsable(reason: "its root is not a dictionary") }
        guard let cached = root[entry] else { return KeyboardTypeCache(root: root, answers: [:]) }
        guard let answers = cached as? [String: Int] else {
            throw Unparsable(reason: "its \(entry) entry is not a dictionary of numbers")
        }
        return KeyboardTypeCache(root: root, answers: answers)
    }

    /// Bytes that are not a keyboard type cache, and what was wrong with them.
    public struct Unparsable: Error, CustomStringConvertible, Equatable {
        public let reason: String
        public var description: String { reason }
    }
}
