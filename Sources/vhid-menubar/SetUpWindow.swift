import AppKit
import Doctor
import DriverExtension
import Installations
import MenuBar
import os

/// The set-up window: doctor's unmet rows one at a time, each explained before the person
/// presses the button that makes macOS ask.
///
/// [LAW:one-source-of-truth] It draws a `Readiness` and keeps nothing of its own but the
/// walk. Every page is drawn from a reading taken for it: when the window opens, when it
/// comes back to the front - which is when a person returns from System Settings - and
/// after every button. A step met anywhere clears at the next of those, with no relaunch.
///
/// Taken from low-talker's SetUpWindow, which drew from a reading taken on the main thread.
/// Doctor's reading can wait out a silent daemon's whole deadline, so here it is taken off
/// the main thread and drawn when it lands, the newest request winning.
@MainActor
final class SetUpWindow: NSObject, NSWindowDelegate {
    private let installation: Installation
    private var walk = Walk()
    /// What the last request said went wrong, shown on the page of the row it was made from.
    private var failure: (row: Requirement.Row, reason: String)?
    /// The request in flight, whose waiting words the page shows in place of its buttons.
    private var asking: Requirement.Ask?
    /// The reading on screen, which skipping and revisiting redraw from: neither changes
    /// anything on the Mac, so neither is worth a fresh reading.
    private var shown: Readiness?
    /// Counts readings asked for, so only the newest one to land is drawn.
    private var generation = 0

    private let log = Logger(subsystem: Installation.thisBuild.service, category: "setup")

    private lazy var window: NSWindow = {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 360),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = Walk.title.replacingOccurrences(of: "…", with: "")
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = page
        return window
    }()

    private let page: NSStackView = {
        let page = NSStackView()
        page.orientation = .vertical
        page.alignment = .leading
        page.spacing = 10
        page.edgeInsets = NSEdgeInsets(top: 20, left: 24, bottom: 20, right: 24)
        return page
    }()

    private static let width: CGFloat = 540

    init(installation: Installation) {
        self.installation = installation
    }

    /// Opens the walk at its first step, with nothing set aside.
    func show() {
        walk = Walk()
        failure = nil
        let wasKey = window.isKeyWindow
        if shown == nil { drawReading() }
        window.center()
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        // A window that was key already does not become key again.
        if wasKey || !window.isKeyWindow { refresh() }
    }

    /// Back at the front, most often from System Settings: where a step met there is first
    /// seen.
    func windowDidBecomeKey(_ notification: Notification) { refresh() }

    /// Reads doctor off the main thread and draws the reading when it lands.
    private func refresh() {
        generation += 1
        let mine = generation
        let installation = installation
        Task.detached {
            let readiness = Readiness.read(for: installation)
            await MainActor.run { [weak self] in
                guard let self, mine == self.generation else { return }
                self.draw(readiness)
            }
        }
    }

    // MARK: - drawing

    private func draw(_ readiness: Readiness) {
        shown = readiness
        clear()
        let page = walk.page(readiness)
        switch page {
        case .step(let requirement, let left): drawStep(requirement, left: left)
        case .summary(let met, let skipped): drawSummary(met: met, skipped: skipped)
        }
        log.info("setup page: \(Self.describe(page), privacy: .public)")
        window.setContentSize(self.page.fittingSize)
    }

    /// The first draw, before any reading has landed, so the window never opens empty.
    private func drawReading() {
        clear()
        add(label("Reading this Mac…", size: 13, color: .secondaryLabelColor))
        window.setContentSize(page.fittingSize)
    }

    private func drawStep(_ requirement: Requirement, left: Int) {
        let row = requirement.row
        let explanation = row.explanation
        add(label(left == 1 ? "1 step left" : "\(left) steps left", size: 11, color: .secondaryLabelColor))
        add(label(requirement.name, size: 20, weight: .semibold))
        add(label("Now: \(requirement.reads)", size: 12, color: .secondaryLabelColor))
        add(label(explanation.why, size: 13))
        add(label("If you skip it: \(explanation.ifSkipped)", size: 12, color: .secondaryLabelColor))
        add(label(requirement.stepLines.joined(separator: "\n"), size: 11, monospaced: true))
        if walk.askedAlready(requirement) {
            add(label("macOS asks only once. If you said no, turn it on in System Settings.", size: 12, color: .secondaryLabelColor))
        }
        if let failure, failure.row == row {
            add(label(failure.reason, size: 12, color: .systemRed))
        }
        if let asking {
            add(label(asking.waiting, size: 12, color: .secondaryLabelColor))
            return
        }
        let ask = walk.ask(requirement).map { request in button(request.title) { [unowned self] in self.request(request, for: row) } }
        let openSettings = row.settingsPane.map { pane in button("Open System Settings") { NSWorkspace.shared.open(pane) } }
        // Every page can be read again by hand: a step met where this window cannot see it
        // arriving - System Settings left open beside it - clears here.
        let checkAgain = button("Check Again") { [unowned self] in self.refresh() }
        let skip = button("Skip for Now") { [unowned self] in
            self.walk.skip(row)
            self.failure = nil
            self.shown.map(self.draw)
        }
        // Return is the person choosing to be asked; once asked, System Settings; otherwise
        // a fresh reading.
        let primary = ask ?? openSettings ?? checkAgain
        primary.keyEquivalent = "\r"
        add(buttonRow([skip] + [checkAgain, openSettings, ask].compactMap { $0 }.filter { $0 !== primary } + [primary]))
    }

    private func drawSummary(met: [Requirement], skipped: [Requirement]) {
        add(label(skipped.isEmpty ? "vhid is set up" : "Set aside for now", size: 20, weight: .semibold))
        for requirement in met {
            add(label("✓ \(requirement.name): \(requirement.reads)", size: 13))
        }
        // Each row set aside says what not having it costs, and offers the way back in.
        for requirement in skipped {
            let row = requirement.row
            add(label("\(requirement.name): \(requirement.reads)", size: 13, weight: .semibold))
            add(label(row.explanation.ifSkipped, size: 12, color: .secondaryLabelColor))
            add(buttonRow([button("Set Up \(requirement.name)…") { [unowned self] in
                self.walk.revisit(row)
                self.shown.map(self.draw)
            }]))
        }
        let done = button("Done") { [unowned self] in self.window.close() }
        done.keyEquivalent = "\r"
        add(buttonRow([done]))
    }

    // MARK: - asking

    /// Makes the request off the main thread - the Manager's `activate` returns only once
    /// the person answers macOS - saying first what it waits for, then reads again.
    private func request(_ ask: Requirement.Ask, for row: Requirement.Row) {
        asking = ask
        failure = nil
        shown.map(draw)
        log.info("setup ask: \(String(describing: ask), privacy: .public)")
        Task.detached {
            let reason = Self.perform(ask)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.asking = nil
                // Only a request that went through counts as asked: one that failed showed
                // no dialog, so its button stays, beside the reason, to be tried again.
                if let reason { self.failure = (row, reason) } else { self.walk.asked(row) }
                self.log.info("setup ask ended: \(reason ?? "went through", privacy: .public)")
                self.refresh()
            }
        }
    }

    /// Runs one request as this process's user, which is the person: macOS attributes a
    /// driver activation to whoever asks, and the approval they give answers that request.
    /// Answers with what went wrong, or nil. [LAW:effects-at-boundaries]
    nonisolated private static func perform(_ ask: Requirement.Ask) -> String? {
        switch ask {
        case .activateDriver:
            let process = Process()
            process.executableURL = URL(fileURLWithPath: DriverProbe.managerExecutable)
            process.arguments = ["activate"]
            let said = Pipe()
            process.standardOutput = said
            process.standardError = said
            do {
                try process.run()
            } catch {
                return "The driver's Manager could not be run: \(error)"
            }
            let output = String(decoding: said.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                return "The driver's Manager exited \(process.terminationStatus): \(output.trimmingCharacters(in: .whitespacesAndNewlines))"
            }
            return nil
        }
    }

    private static func describe(_ page: Walk.Page) -> String {
        switch page {
        case .step(let requirement, let left): "step \(requirement.name) (\(requirement.reads)), \(left) left"
        case .summary(let met, let skipped): "summary, \(met.count) met, \(skipped.count) set aside"
        }
    }

    // MARK: - pieces

    private func clear() { page.arrangedSubviews.forEach { $0.removeFromSuperview() } }

    private func add(_ view: NSView) { page.addArrangedSubview(view) }

    private func label(
        _ text: String, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor = .labelColor, monospaced: Bool = false
    ) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = monospaced ? .monospacedSystemFont(ofSize: size, weight: weight) : .systemFont(ofSize: size, weight: weight)
        label.textColor = color
        label.isSelectable = true
        label.preferredMaxLayoutWidth = Self.width - 48
        return label
    }

    private func button(_ title: String, _ action: @escaping @MainActor () -> Void) -> NSButton {
        ActionButton(title: title, action: action)
    }

    private func buttonRow(_ buttons: [NSButton]) -> NSStackView {
        let row = NSStackView(views: buttons)
        row.orientation = .horizontal
        row.spacing = 8
        return row
    }
}

/// A button that runs a closure, so each page says what its buttons do where it draws them.
@MainActor
private final class ActionButton: NSButton {
    private let run: @MainActor () -> Void

    init(title: String, action: @escaping @MainActor () -> Void) {
        run = action
        super.init(frame: .zero)
        self.title = title
        bezelStyle = .push
        target = self
        self.action = #selector(pressed)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("built in code, never from a nib") }

    @objc private func pressed() { run() }
}
