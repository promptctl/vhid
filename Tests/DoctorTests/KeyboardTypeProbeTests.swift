import DriverExtension
import Foundation
import Installations
import Testing
@testable import Doctor

/// Reading Keyboard Setup Assistant's cache as the user, against files of the test's own:
/// the three readings, and each one as the row a person sees. [LAW:behavior-not-structure]
@Suite struct KeyboardTypeProbeTests {
    private let key = VirtualKeyboardIdentity.keyboardTypeKey

    private func scratch(_ name: String) -> String {
        FileManager.default.temporaryDirectory.appendingPathComponent("keyboardtype-\(name)-\(UUID().uuidString).plist").path
    }

    private func written(_ root: [String: Any], _ name: String) throws -> String {
        let path = scratch(name)
        try PropertyListSerialization.data(fromPropertyList: root, format: .binary, options: 0).write(to: URL(fileURLWithPath: path))
        return path
    }

    /// The KSA row a person would see for this reading, from the whole list.
    private func row(_ answered: Result<Bool, any Error>) -> Requirement {
        let list = Readiness(installation: .development, driver: .success(.running), job: .success(.holdingTheService),
                             daemon: .answered(holder: nil), keyboardSetupAssistantAnswered: answered)
        return list.requirements.first { $0.name == Requirement.Row.keyboardSetupAssistant.rawValue }!
    }

    @Test func theVirtualKeyboardsAnswerOnFileIsAnswered() throws {
        let path = try written(["keyboardtype": ["1031-4176-0": 40, key: 40]], "answered")
        #expect(try KeyboardTypeProbe.answered(at: path))
        #expect(row(Result { try KeyboardTypeProbe.answered(at: path) }).met)
    }

    /// Other keyboards' answers are not this one's.
    @Test func otherKeyboardsAnswersAloneAreUnanswered() throws {
        let path = try written(["keyboardtype": ["1031-4176-0": 40]], "others")
        #expect(try !KeyboardTypeProbe.answered(at: path))
        #expect(!row(Result { try KeyboardTypeProbe.answered(at: path) }).met)
    }

    /// A Mac that has met no keyboard has no file, and nothing is answered on it.
    @Test func noFileIsUnanswered() throws {
        #expect(try !KeyboardTypeProbe.answered(at: scratch("absent")))
        #expect(try !KeyboardTypeProbe.answered(at: written(["other": 1], "no-entry")))
    }

    /// A file this user may not read is never "unanswered": the answer may be in it. The
    /// row says so, with the mode the file should have.
    @Test func aFileThisUserCannotReadIsUnreadableAndNamesTheMode() throws {
        let path = try written(["keyboardtype": [key: 40]], "tight")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: path) }
        let unreadable = #expect(throws: KeyboardTypeUnreadable.self) { try KeyboardTypeProbe.answered(at: path) }
        #expect(unreadable?.reason == .notReadableByThisUser)
        let shown = row(Result { try KeyboardTypeProbe.answered(at: path) })
        #expect(!shown.met)
        #expect(shown.reads.contains("0644"), "\(shown.reads)")
    }

    /// Bytes that are not the cache, or a cache whose answers are the wrong shape.
    @Test func aFileThatIsNotTheCacheIsUnreadable() throws {
        let garbage = scratch("garbage")
        try Data("not a plist".utf8).write(to: URL(fileURLWithPath: garbage))
        for path in [garbage, try written(["keyboardtype": "not a dictionary"], "wrong-shape")] {
            let unreadable = #expect(throws: KeyboardTypeUnreadable.self) { try KeyboardTypeProbe.answered(at: path) }
            guard case .unparsable = unreadable?.reason else { Issue.record("read \(String(describing: unreadable))"); continue }
        }
    }

    /// This Mac's own cache, read without privilege, reads as one of the answers rather
    /// than failing: the daemon keeps it world-readable.
    @Test func thisMacsCacheIsReadWithoutRoot() throws {
        _ = try KeyboardTypeProbe.answered()
    }
}
