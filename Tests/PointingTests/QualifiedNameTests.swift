import Pointing
import Testing

/// An importer's own button, so the module's has to be named through the module. Were the
/// module to declare a type named `Pointing`, that type would shadow the module and
/// `Pointing.Button` below would not build.
private struct Button {}

@Suite struct QualifiedNameTests {
    @Test func anImporterWithItsOwnButtonStillQualifiesTheModulesButton() {
        #expect(Pointing.Button.left.rawValue == 1)
    }
}
