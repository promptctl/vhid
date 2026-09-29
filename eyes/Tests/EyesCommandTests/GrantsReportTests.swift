import Grants
import Testing
@testable import EyesCommand

struct GrantsReportTests {
    private let holder = Holder(executable: "/Applications/iTerm.app/Contents/MacOS/iTerm2")

    /// Each missing grant names the app to switch on and the pane it is in.
    @Test func aMissingGrantNamesTheAppAndThePane() {
        let said = GrantsVerb.report(GrantReading(held: [.screenRecording: false, .accessibility: true]), holder: holder, asked: false)
        #expect(said == """
            2 grants, read without asking. macOS charges them to iTerm (/Applications/iTerm.app), the app responsible for this eyes; that is the app to switch on.
            Screen Recording\tnot granted\tpixels\tturn on iTerm in System Settings > Privacy & Security > Screen Recording
            Accessibility\tgranted\ttree
            """)
    }

    /// After asking, a grant still missing says the dialog will not come again.
    @Test func stillMissingAfterAskingPointsAtTheSwitch() {
        let missing = GrantsVerb.report(GrantReading(held: [.screenRecording: false, .accessibility: false]), holder: holder, asked: true)
        #expect(missing.hasSuffix("Still missing after asking: if no dialog appeared, macOS already has an answer from iTerm, and only its switch in the pane changes it."))
        let held = GrantsVerb.report(GrantReading(held: [.screenRecording: true, .accessibility: true]), holder: holder, asked: true)
        #expect(!held.contains("Still missing"))
    }
}
