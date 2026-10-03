import ArgumentParser
import KeyboardLayouts

/// Which keyboard layout `type`, `press` and `gesture` read keys off.
///
/// [LAW:one-source-of-truth] Declared once and taken by every such verb through `@OptionGroup`,
/// worded by `Help.layout`, which the tools' `layout` parameter is described by too.
struct LayoutOption: ParsableArguments {
    @Option(name: .customLong("layout"), help: Help.sentence(Help.layout))
    var named: String?

    func layout() throws -> KeyboardLayout {
        try KeyboardLayout.chosen(named)
    }

    init() {}
}
