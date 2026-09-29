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
/// Doctor's reading can wait out a silent daemon's whole deadline, so here it is taken on
/// the menu's serial `readings` queue and drawn when it lands.
@MainActor
final class SetUpWindow: NSObject, NSWindowDelegate {
    private let installation: Installation
    private var walk = Walk()
    private let readings: DispatchQueue
    /// Why the last request could not be made, shown on its row's page until the next
    /// reading, which says where that row stands now.
    private var failure: (row: Requirement.Row, reason: String)?
    /// The reading on screen, which skipping and revisiting redraw from: neither changes
    /// anything on the Mac, so neither is worth a fresh reading.
    private var shown: Readiness?
    /// A reading is queued and not yet begun: asking again then adds nothing, since the
    /// queued one has not looked at the Mac yet.
    private var queued = false

    private let log: Logger

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

    init(installation: Installation, readings: DispatchQueue) {
        self.installation = installation
        self.readings = readings
        log = Logger(subsystem: installation.service, category: "setup")
    }

    /// Opens the walk at its first step, with nothing set aside.
    func show() {
        walk = Walk()
        failure = nil
        let wasKey = window.isKeyWindow
        if let shown { draw(shown) } else { drawReading() }
        window.center()
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        // A window that was key already does not become key again.
        if wasKey || !window.isKeyWindow { refresh() }
    }

    /// Back at the front, most often from System Settings: where a step met there is first
    /// seen.
    func windowDidBecomeKey(_ notification: Notification) { refresh() }

    /// Queues a reading of doctor behind the menu's and draws it when it lands. Asked for
    /// again while one waits its turn, it adds nothing; asked while one is being taken, it
    /// queues the next, since the Mac may have changed after that one looked.
    private func refresh() {
        guard !queued else { return }
        queued = true
        readings.async { @Sendable [installation, weak self] in
            DispatchQueue.main.sync { MainActor.assumeIsolated { self?.queued = false } }
            let readiness = Readiness.read(for: installation)
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.landed(readiness) } }
        }
    }

    private func landed(_ readiness: Readiness) {
        failure = nil
        draw(readiness)
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
        log.info("setup page: \(page, privacy: .public)")
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
        if let failure, failure.row == row {
            add(label(failure.reason, size: 12, color: .systemRed))
        }
        let ask = requirement.ask.map { request in button(request.title) { [unowned self] in self.request(request, for: row) } }
        let openSettings = row.settingsPane.map { pane in button("Open System Settings") { [unowned self] in
            self.log.info("setup open settings: \(row.rawValue, privacy: .public)")
            NSWorkspace.shared.open(pane)
        } }
        // Every page can be read again by hand: a step met where this window cannot see it
        // arriving - System Settings left open beside it - clears here.
        let checkAgain = button("Check Again") { [unowned self] in
            self.log.info("setup check again: \(row.rawValue, privacy: .public)")
            self.refresh()
        }
        let skip = button("Skip for Now") { [unowned self] in
            self.log.info("setup skip: \(row.rawValue, privacy: .public)")
            self.walk.skip(row)
            self.failure = nil
            self.shown.map(self.draw)
        }
        // Return is the person choosing to be asked; else System Settings; else a fresh reading.
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
                self.log.info("setup revisit: \(row.rawValue, privacy: .public)")
                self.walk.revisit(row)
                self.shown.map(self.draw)
            }]))
        }
        let done = button("Done") { [unowned self] in self.window.close() }
        done.keyEquivalent = "\r"
        add(buttonRow([done]))
    }

    // MARK: - asking

    /// Makes the request, then reads again. The Manager's `activate` does not exit until the
    /// person answers - on a Mac that never approved the driver, that answer is the switch
    /// in System Settings - and exits 0 whatever became of the request, so it is started
    /// and not waited on, as postinstall and scripts/virtual-hid-driver start it: whether
    /// the request landed is the next reading's to say. [LAW:one-source-of-truth]
    private func request(_ ask: Requirement.Ask, for row: Requirement.Row) {
        do {
            try Self.perform(ask)
            log.info("setup ask: \(String(describing: ask), privacy: .public) started")
            refresh()
        } catch {
            failure = (row, "The request could not be made: \(error)")
            log.error("setup ask: \(String(describing: ask), privacy: .public) failed to start: \(error, privacy: .public)")
            shown.map(draw)
        }
    }

    /// Runs one request as this process's user, which is the person: macOS attributes a
    /// driver activation to whoever asks, and the approval they give answers that request.
    /// [LAW:effects-at-boundaries]
    private static func perform(_ ask: Requirement.Ask) throws {
        switch ask {
        case .activateDriver:
            // One left waiting - by postinstall, or an earlier walk - is ended first, so
            // asking again does not pile them up. pkill exits 1 when none was waiting.
            let ended = try Command("/usr/bin/pkill", "-u", "\(getuid())", "-f", "\(DriverProbe.managerExecutable) activate").run()
            guard ended.status <= 1 else { throw ManagerError.pkill(ended.merged) }
            let manager = Process()
            manager.executableURL = URL(fileURLWithPath: DriverProbe.managerExecutable)
            manager.arguments = ["activate"]
            manager.standardInput = FileHandle.nullDevice
            try manager.run()
        }
    }

    private enum ManagerError: Error, CustomStringConvertible {
        case pkill(String)
        var description: String {
            switch self {
            case .pkill(let said): "ending the Manager an earlier request left waiting failed: \(said)"
            }
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
