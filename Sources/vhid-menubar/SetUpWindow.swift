import AppKit
import Doctor
import DriverExtension
import Installations
import MenuBar
import os

/// The set-up window: doctor's unmet rows one at a time, each explained before the person
/// presses the button that makes macOS ask.
///
/// [LAW:one-source-of-truth] It draws the menu's readings and keeps nothing of its own but
/// the walk. It takes none itself: the menu reads the Mac every few seconds on its one
/// serial queue, and the window asks that queue for one at once when it opens, when it
/// comes back to the front - which is when a person returns from System Settings - and
/// after every button. A step met anywhere clears at the next reading, with no relaunch.
///
/// Taken from low-talker's SetUpWindow, which drew from a reading taken on the main thread.
@MainActor
final class SetUpWindow: NSObject, NSWindowDelegate {
    private var walk = Walk()
    /// Asks the menu's readings queue for a reading now, which lands in `update`.
    private let readNow: @MainActor () -> Void
    /// Why a request could not be made, shown while its row reads as it did when the
    /// request was refused: a reading that says something new about that row is a page
    /// the reason no longer describes.
    private var failure: (requirement: Requirement, reason: String)?
    /// The newest reading, drawn whenever the window is open, and redrawn by skipping and
    /// revisiting, which change nothing on the Mac.
    private var shown: Readiness?

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

    init(installation: Installation, readNow: @escaping @MainActor () -> Void) {
        self.readNow = readNow
        log = Logger(subsystem: installation.service, category: "setup")
    }

    /// Opens the walk at its first step, with nothing set aside.
    func show() {
        walk = Walk()
        failure = nil
        if let shown { draw(shown) } else { drawReading() }
        window.center()
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        readNow()
    }

    /// Every reading the menu takes; drawn while the window is open.
    func update(_ readiness: Readiness) {
        shown = readiness
        if window.isVisible { draw(readiness) }
    }

    /// Back at the front, most often from System Settings: where a step met there is first
    /// seen.
    func windowDidBecomeKey(_ notification: Notification) { readNow() }

    private func record(_ event: SetUpEvent) { log.info("\(event, privacy: .public)") }

    // MARK: - drawing

    private func draw(_ readiness: Readiness) {
        clear()
        let page = walk.page(readiness)
        switch page {
        case .step(let requirement, let left): drawStep(requirement, left: left)
        case .summary(let met, let skipped): drawSummary(met: met, skipped: skipped)
        }
        record(.page(page))
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
        if let failure, failure.requirement == requirement {
            add(label(failure.reason, size: 12, color: .systemRed))
        }
        let ask = requirement.ask.map { request in button(request.title) { [unowned self] in self.request(request, for: requirement) } }
        let openSettings = requirement.settingsPane.map { pane in button("Open System Settings") { [unowned self] in
            self.record(.openSettings(row))
            NSWorkspace.shared.open(pane)
        } }
        // Every page can be read again by hand, though the menu reads on its own every few
        // seconds: the button says the page is live, and does not make the person wait.
        let checkAgain = button("Check Again") { [unowned self] in
            self.record(.checkAgain(row))
            self.readNow()
        }
        let skip = button("Skip for Now") { [unowned self] in
            self.record(.skip(row))
            self.walk.skip(row)
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
        // Each row set aside says what not having it costs, and offers the way back in. A
        // row waiting on another has no way in of its own: it names the row that does.
        for requirement in skipped {
            let row = requirement.row
            add(label("\(requirement.name): \(requirement.reads)", size: 13, weight: .semibold))
            add(label(row.explanation.ifSkipped, size: 12, color: .secondaryLabelColor))
            if let earlier = requirement.waitsOn {
                add(label("Waits on \(earlier.rawValue).", size: 12, color: .secondaryLabelColor))
            } else {
                add(buttonRow([button("Set Up \(requirement.name)…") { [unowned self] in
                    self.record(.revisit(row))
                    self.walk.revisit(row)
                    self.shown.map(self.draw)
                }]))
            }
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
    /// the request landed is the readings' to say, and the menu's next one follows within
    /// seconds of it landing. [LAW:one-source-of-truth]
    private func request(_ ask: Requirement.Ask, for requirement: Requirement) {
        failure = nil
        let log = log
        DispatchQueue.global(qos: .userInitiated).async {
            let started = Result { try Self.perform(ask, log: log) }
            DispatchQueue.main.async { MainActor.assumeIsolated { [weak self] in self?.requested(ask, for: requirement, started) } }
        }
    }

    private func requested(_ ask: Requirement.Ask, for requirement: Requirement, _ started: Result<Void, any Error>) {
        switch started {
        case .success:
            record(.askStarted(ask))
        case .failure(let error):
            record(.askFailed(ask, reason: "\(error)"))
            failure = (requirement, "The request could not be made: \(error)")
        }
        shown.map(draw)
        readNow()
    }

    /// Runs one request as this process's user, which is the person: macOS attributes a
    /// driver activation to whoever asks, and the approval they give answers that request.
    /// What the Manager prints, and its exit, are logged when it ends. [LAW:effects-at-boundaries]
    nonisolated private static func perform(_ ask: Requirement.Ask, log: Logger) throws {
        switch ask {
        case .activateDriver:
            let manager = DriverProbe.managerExecutable
            // One left waiting - by postinstall, or an earlier press - is ended first, so
            // asking again does not pile them up. pkill's pattern is a regex, and the path's
            // dots are escaped so it matches that path alone. pkill exits 1 when none was.
            let pattern = NSRegularExpression.escapedPattern(for: "\(manager) activate")
            let ended = try Command("/usr/bin/pkill", "-u", "\(getuid())", "-f", pattern).run(within: Command.readingLimit)
            guard ended.status <= 1 else { throw ManagerError.pkill(ended.merged) }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: manager)
            process.arguments = ["activate"]
            process.standardInput = FileHandle.nullDevice
            let said = Pipe()
            process.standardOutput = said
            process.standardError = said
            process.terminationHandler = { ended in
                let output = String(decoding: said.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let event = SetUpEvent.askEnded(ask, status: ended.terminationStatus, said: output)
                log.info("\(event, privacy: .public)")
            }
            try process.run()
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
