import KeyboardLayouts
import Testing

/// An importer's own refusal, so the module's has to be named through the module. Were the
/// module to declare a type named `KeyboardLayouts`, that type would shadow the module and
/// `KeyboardLayouts.NoLayout` below would not build.
private enum NoLayout {}

@Suite struct QualifiedNameTests {
    @Test func anImporterWithItsOwnNoLayoutStillQualifiesTheModulesNoLayout() {
        #expect(KeyboardLayouts.NoLayout.noSourceNamed("x") == .noSourceNamed("x"))
    }
}
