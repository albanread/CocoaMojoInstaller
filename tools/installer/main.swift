// The two faces: a command line when given flags, a window otherwise.

import AppKit

// ── The command line ────────────────────────────────────────────────────────

func runCommandLine(_ args: [String]) -> Int32 {
    var layout = Layout.standard()
    var operation: String?
    var alsoUserData = false
    var withPython = true
    var i = 1
    while i < args.count {
        switch args[i] {
        case "--install", "--reset", "--uninstall":
            operation = args[i]
        case "--user-data":
            alsoUserData = true
        case "--no-python":
            withPython = false
        case "--root", "--payload", "--user-data-root":
            guard i + 1 < args.count else {
                FileHandle.standardError.write(
                    Data("\(args[i]) needs a directory\n".utf8))
                return 64
            }
            let url = URL(fileURLWithPath: args[i + 1])
            switch args[i] {
            case "--root": layout.root = url
            case "--payload": layout.payload = url
            default: layout.userDataOverride = url
            }
            i += 1
        case "--help", "-h":
            print(usage)
            return 0
        default:
            FileHandle.standardError.write(
                Data("unknown argument: \(args[i])\n\(usage)\n".utf8))
            return 64
        }
        i += 1
    }
    guard let operation else {
        FileHandle.standardError.write(Data("\(usage)\n".utf8))
        return 64
    }
    let ops = Operations(layout) { print($0) }
    do {
        switch operation {
        case "--install": try ops.install(python: withPython)
        case "--reset": try ops.reset()
        default: try ops.uninstall(userData: alsoUserData)
        }
        return 0
    } catch {
        FileHandle.standardError.write(Data("error: \(error)\n".utf8))
        return 1
    }
}

let usage = """
usage: Install Roast --install|--reset|--uninstall [options]
  --root DIR       install somewhere other than /Applications/Roast
  --payload DIR    take the payload from somewhere other than beside this app
  --no-python      do not install the bundled CPython (saves 47 MB); the
                   database generator falls back to /usr/bin/python3 and
                   Roast looks for a framework Python already installed
  --user-data      with --uninstall, also remove Application Support/Roast
  --user-data-root DIR
                   treat DIR as Application Support/Roast. Tests that
                   exercise --user-data MUST pass this: without it they
                   delete the real thing, which is not a hypothetical.
"""

// ── The window ──────────────────────────────────────────────────────────────
//
// One window, three states, one identity. The header -- icon, name, version
// -- never moves; the zone beneath it changes with what is happening:
//
//   ready    what you get, one big Install button, maintenance in the footer
//   working  a progress bar and the phase it is on, nothing else to press
//   done     a green check and the next step (Open Roast), not a re-enabled
//            pile of buttons
//
// The log is the record, not the face: it lives behind "Show Details",
// collapsed until asked for -- except on failure, when it opens itself,
// because at that moment it IS the face.

private let CONTENT_W: CGFloat = 560
private let INNER_W: CGFloat = 512   // CONTENT_W minus the margins

final class Delegate: NSObject, NSApplicationDelegate {
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: CONTENT_W, height: 400),
        styleMask: [.titled, .closable, .miniaturizable,
                    .fullSizeContentView],
        backing: .buffered, defer: false)

    let stack = NSStackView()

    // The zones. Hidden/shown as a set per state; relayout() resizes the
    // window to whatever is visible so nothing is ever clipped.
    var featureZone = NSStackView()
    var cltZone: NSView?
    var actionZone = NSStackView()
    var progressZone = NSStackView()
    var resultZone = NSStackView()
    var failZone = NSStackView()
    var detailsZone = NSStackView()
    var footerZone = NSStackView()

    let installButton = NSButton()
    let pythonBox = NSButton(checkboxWithTitle:
        "Include Python (47 MB)", target: nil, action: nil)
    let installCaption = NSTextField(wrappingLabelWithString: "")
    let progress = NSProgressIndicator()
    let progressLabel = NSTextField(labelWithString: "")
    let resultSymbol = NSImageView()
    let resultTitle = NSTextField(labelWithString: "")
    let resultSubtitle = NSTextField(wrappingLabelWithString: "")
    let openButton = NSButton()
    let quitButton = NSButton()
    let failLabel = NSTextField(wrappingLabelWithString: "")
    let detailsButton = NSButton()
    let logScroll = NSScrollView()
    let log = NSTextView()

    var busy = false
    var detailsOpen = false

    // ── Construction ────────────────────────────────────────────────────

    func applicationDidFinishLaunching(_ note: Notification) {
        let layout = Layout.standard()
        let probe = Operations(layout) { _ in }

        window.title = "Install Roast"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true

        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 14
        // Top inset clears the traffic lights the transparent title bar
        // leaves floating over the content.
        stack.edgeInsets = NSEdgeInsets(top: 40, left: 24, bottom: 20,
                                        right: 24)

        // Header: the identity, stable across every state.
        let icon = NSImageView(image: NSApp.applicationIconImage)
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 96).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 96).isActive = true
        stack.addArrangedSubview(icon)

        let name = NSTextField(labelWithString: "Roast")
        name.font = .systemFont(ofSize: 26, weight: .bold)
        stack.addArrangedSubview(name)
        stack.setCustomSpacing(2, after: name)

        let subtitle = NSTextField(labelWithString:
            "CocoaMojo \(layout.payloadVersion) — the Mojo compiler,"
            + " IDE and tools")
        subtitle.font = .systemFont(ofSize: 13)
        subtitle.textColor = .secondaryLabelColor
        stack.addArrangedSubview(subtitle)
        stack.setCustomSpacing(18, after: subtitle)

        // What you get: four scannable rows, not a paragraph.
        featureZone = zone(spacing: 10, alignment: .leading)
        featureZone.addArrangedSubview(featureRow(
            "hammer.fill", "Compiler, debugger and language server",
            "Builds native Apple-silicon programs; breakpoints, completion"
            + " and go-to-definition included."))
        featureZone.addArrangedSubview(featureRow(
            "macwindow", "The Roast editor",
            "A Mac IDE for Mojo, itself written in Mojo — installed with"
            + " its own source."))
        featureZone.addArrangedSubview(featureRow(
            "books.vertical.fill", "Standard library and examples",
            "Source included, and yours to edit. Reset Installation puts"
            + " the originals back."))
        // Python was installed, used, and offered for deletion -- and never
        // once announced. The only mentions in this window were in the
        // uninstall and reset copy, which is a strange way to learn you
        // have an interpreter.
        featureZone.addArrangedSubview(featureRow(
            "chevron.left.forwardslash.chevron.right", "A Python, optional",
            "CPython 3.14 at CocoaMojo/current/bin/python3 — for Mojo's"
            + " Python interop and Roast's per-project environments. It"
            + " does not go on your PATH or shadow a Python you already"
            + " have. Leave it out and Roast's Python features are simply"
            + " off — it will not go looking for another one, because the"
            + " interop is built against this exact version. The Cocoa"
            + " database is built with it either way."))
        pythonBox.state = .on
        pythonBox.font = .systemFont(ofSize: 11)
        let boxRow = NSStackView()
        boxRow.orientation = .horizontal
        boxRow.spacing = 0
        let boxPad = NSView()
        boxPad.translatesAutoresizingMaskIntoConstraints = false
        boxPad.widthAnchor.constraint(equalToConstant: 28).isActive = true
        boxRow.addArrangedSubview(boxPad)
        boxRow.addArrangedSubview(pythonBox)
        featureZone.addArrangedSubview(boxRow)
        featureZone.addArrangedSubview(featureRow(
            "internaldrive.fill", "Cocoa database, built on this Mac",
            "Generated from your own macOS SDK in about fifteen seconds,"
            + " so it describes the frameworks you actually have — and it"
            + " is 343 MB the download did not have to carry."))
        stack.addArrangedSubview(featureZone)

        // Said before anyone presses anything, because it is the difference
        // between an editor that works and one that only opens.
        if !probe.commandLineToolsPresent() {
            let z = statusRow(
                symbol: "exclamationmark.triangle.fill",
                tint: .systemOrange,
                text: "Xcode Command Line Tools are not installed. Roast"
                + " will open, but nothing will compile until they are —"
                + " every build needs the macOS SDK, which Apple does not"
                + " allow anyone to redistribute.",
                buttonTitle: "Install…",
                action: #selector(installCLT))
            cltZone = z
            stack.addArrangedSubview(z)
        }

        // The one primary action.
        actionZone = zone(spacing: 8, alignment: .centerX)
        let installed = probe.installedVersion()
        let havePayload = FileManager.default.fileExists(
            atPath: layout.payloadToolchain.path)
        installButton.title = installed == nil ? "Install" : "Reinstall"
        installButton.isEnabled = havePayload
        installButton.target = self
        installButton.action = #selector(install)
        installButton.bezelStyle = .rounded
        installButton.controlSize = .large
        installButton.keyEquivalent = "\r"
        installButton.translatesAutoresizingMaskIntoConstraints = false
        installButton.widthAnchor.constraint(
            greaterThanOrEqualToConstant: 200).isActive = true
        actionZone.addArrangedSubview(installButton)

        if !havePayload {
            installCaption.stringValue =
                "No payload found beside this app — run the installer"
                + " from the disk image it came on."
        } else if let installed {
            installCaption.stringValue =
                "CocoaMojo \(installed) is already installed at"
                + " \(layout.root.path). This installs"
                + " \(layout.payloadVersion) over it; your edits and"
                + " projects are not touched."
        } else {
            installCaption.stringValue =
                "Installs to \(layout.root.path) — about 1 GB once the"
                + " database is built."
        }
        installCaption.font = .systemFont(ofSize: 11)
        installCaption.textColor = .secondaryLabelColor
        installCaption.alignment = .center
        installCaption.preferredMaxLayoutWidth = INNER_W - 60
        actionZone.addArrangedSubview(installCaption)
        stack.addArrangedSubview(actionZone)

        // Working: the bar and the phase. Nothing else to press.
        progressZone = zone(spacing: 8, alignment: .centerX)
        progress.isIndeterminate = false
        progress.minValue = 0
        progress.maxValue = 1
        progress.translatesAutoresizingMaskIntoConstraints = false
        progress.widthAnchor.constraint(
            equalToConstant: INNER_W - 40).isActive = true
        progressZone.addArrangedSubview(progress)
        progressLabel.font = .systemFont(ofSize: 12)
        progressLabel.textColor = .secondaryLabelColor
        progressZone.addArrangedSubview(progressLabel)
        stack.addArrangedSubview(progressZone)

        // Done: a landing, with the next step -- not re-enabled buttons.
        resultZone = zone(spacing: 6, alignment: .centerX)
        resultSymbol.contentTintColor = .systemGreen
        resultZone.addArrangedSubview(resultSymbol)
        resultZone.setCustomSpacing(10, after: resultSymbol)
        resultTitle.font = .systemFont(ofSize: 17, weight: .semibold)
        resultZone.addArrangedSubview(resultTitle)
        resultSubtitle.font = .systemFont(ofSize: 12)
        resultSubtitle.textColor = .secondaryLabelColor
        resultSubtitle.alignment = .center
        resultSubtitle.preferredMaxLayoutWidth = INNER_W - 60
        resultZone.addArrangedSubview(resultSubtitle)
        resultZone.setCustomSpacing(14, after: resultSubtitle)
        openButton.title = "Open Roast"
        openButton.target = self
        openButton.action = #selector(openRoast)
        openButton.bezelStyle = .rounded
        openButton.controlSize = .large
        openButton.keyEquivalent = "\r"
        resultZone.addArrangedSubview(openButton)
        quitButton.title = "Quit"
        quitButton.target = NSApp
        quitButton.action = #selector(NSApplication.terminate(_:))
        quitButton.isBordered = false
        quitButton.font = .systemFont(ofSize: 12)
        quitButton.contentTintColor = .secondaryLabelColor
        resultZone.addArrangedSubview(quitButton)
        stack.addArrangedSubview(resultZone)

        // Failure: one red line above the details, which open themselves.
        failZone = zone(spacing: 8, alignment: .leading)
        failZone.addArrangedSubview(iconTextRow(
            symbol: "xmark.octagon.fill", tint: .systemRed,
            label: failLabel, text: ""))
        stack.addArrangedSubview(failZone)

        // The record, behind a disclosure.
        detailsZone = zone(spacing: 6, alignment: .leading)
        detailsButton.title = "Show Details"
        detailsButton.target = self
        detailsButton.action = #selector(toggleDetails)
        detailsButton.isBordered = false
        detailsButton.font = .systemFont(ofSize: 11)
        detailsButton.contentTintColor = .controlAccentColor
        detailsZone.addArrangedSubview(detailsButton)
        logScroll.hasVerticalScroller = true
        logScroll.borderType = .bezelBorder
        logScroll.documentView = log
        logScroll.translatesAutoresizingMaskIntoConstraints = false
        logScroll.heightAnchor.constraint(equalToConstant: 150)
            .isActive = true
        logScroll.widthAnchor.constraint(equalToConstant: INNER_W)
            .isActive = true
        log.isEditable = false
        log.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        log.textContainerInset = NSSize(width: 6, height: 6)
        detailsZone.addArrangedSubview(logScroll)
        stack.addArrangedSubview(detailsZone)

        // Maintenance, demoted to the footer where it belongs.
        footerZone = zone(spacing: 0, alignment: .centerX)
        let line = NSBox()
        line.boxType = .separator
        line.translatesAutoresizingMaskIntoConstraints = false
        line.widthAnchor.constraint(equalToConstant: INNER_W)
            .isActive = true
        footerZone.addArrangedSubview(line)
        footerZone.setCustomSpacing(10, after: line)
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 12
        row.addArrangedSubview(smallButton("Reset Installation…",
                                           #selector(reset)))
        row.addArrangedSubview(smallButton("Uninstall All…",
                                           #selector(uninstall)))
        footerZone.addArrangedSubview(row)
        stack.addArrangedSubview(footerZone)

        window.contentView = stack
        failZone.isHidden = true
        setDetails(open: false, animate: false)
        show(state: .ready)
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        snapshotIfAsked()
    }

    /// INSTALLER_SNAPSHOT=/path.png captures the window and quits: the
    /// same TCC-free view drawing Roast's agent screenshot uses, so the
    /// layout can be reviewed without a hand on the pointer.
    /// INSTALLER_SNAPSHOT_STATE picks which face: ready, working, done.
    private func snapshotIfAsked() {
        guard let path = ProcessInfo.processInfo
            .environment["INSTALLER_SNAPSHOT"] else { return }
        switch ProcessInfo.processInfo
            .environment["INSTALLER_SNAPSHOT_STATE"] ?? "ready" {
        case "working":
            progress.doubleValue = 0.62
            progressLabel.stringValue =
                "Building the Cocoa database — asking the live"
                + " Objective-C runtime"
            show(state: .working)
        case "done":
            finish(with: ("Installed",
                "CocoaMojo \(Layout.standard().payloadVersion) is ready,"
                + " and the Cocoa database was built from this Mac's own"
                + " SDK.", true))
        case "fail":
            write("  toolchain copied")
            fail(with: "The database generator failed (exit 1)")
        default: break
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            guard let view = self.window.contentView,
                  let rep = view.bitmapImageRepForCachingDisplay(
                      in: view.bounds) else { NSApp.terminate(nil); return }
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?
                .write(to: URL(fileURLWithPath: path))
            NSApp.terminate(nil)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(
        _ app: NSApplication) -> Bool { true }

    // ── The states ──────────────────────────────────────────────────────

    enum State { case ready, working, done }

    private func show(state: State, animate: Bool = false) {
        let readyViews = [featureZone, cltZone, actionZone, footerZone]
            .compactMap { $0 }
        switch state {
        case .ready:
            readyViews.forEach { $0.isHidden = false }
            progressZone.isHidden = true
            resultZone.isHidden = true
        case .working:
            readyViews.forEach { $0.isHidden = true }
            failZone.isHidden = true
            progressZone.isHidden = false
            resultZone.isHidden = true
        case .done:
            readyViews.forEach { $0.isHidden = true }
            failZone.isHidden = true
            progressZone.isHidden = true
            resultZone.isHidden = false
        }
        if state != .ready { window.makeFirstResponder(nil) }
        relayout(animate: animate)
    }

    /// Size the window to what is actually visible. A fixed height clips
    /// the moment the text grows; measuring by hand is how it got clipped
    /// the last time.
    private func relayout(animate: Bool) {
        stack.layoutSubtreeIfNeeded()
        var size = stack.fittingSize
        size.width = CONTENT_W
        var frame = window.frameRect(
            forContentRect: NSRect(origin: .zero, size: size))
        frame.origin.x = window.frame.origin.x
        frame.origin.y = window.frame.maxY - frame.height
        window.setFrame(frame, display: true, animate: animate)
    }

    // ── View helpers ────────────────────────────────────────────────────

    private func zone(spacing: CGFloat,
                      alignment: NSLayoutConstraint.Attribute)
        -> NSStackView {
        let z = NSStackView()
        z.orientation = .vertical
        z.alignment = alignment
        z.spacing = spacing
        z.translatesAutoresizingMaskIntoConstraints = false
        z.widthAnchor.constraint(equalToConstant: INNER_W).isActive = true
        return z
    }

    private func symbolView(_ name: String, size: CGFloat,
                            tint: NSColor) -> NSImageView {
        let iv = NSImageView()
        iv.image = NSImage(systemSymbolName: name,
                           accessibilityDescription: nil)
        iv.symbolConfiguration = .init(pointSize: size, weight: .medium)
        iv.contentTintColor = tint
        iv.translatesAutoresizingMaskIntoConstraints = false
        iv.widthAnchor.constraint(equalToConstant: size + 12)
            .isActive = true
        return iv
    }

    private func featureRow(_ symbol: String, _ title: String,
                            _ detail: String) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .top
        row.spacing = 10
        row.addArrangedSubview(symbolView(symbol, size: 16,
                                          tint: .controlAccentColor))
        let text = NSStackView()
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 1
        let t = NSTextField(labelWithString: title)
        t.font = .systemFont(ofSize: 13, weight: .semibold)
        text.addArrangedSubview(t)
        let d = NSTextField(wrappingLabelWithString: detail)
        d.font = .systemFont(ofSize: 11)
        d.textColor = .secondaryLabelColor
        d.preferredMaxLayoutWidth = INNER_W - 44
        text.addArrangedSubview(d)
        row.addArrangedSubview(text)
        return row
    }

    private func iconTextRow(symbol: String, tint: NSColor,
                             label: NSTextField, text: String) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .top
        row.spacing = 10
        row.addArrangedSubview(symbolView(symbol, size: 14, tint: tint))
        label.stringValue = text
        label.font = .systemFont(ofSize: 11)
        label.preferredMaxLayoutWidth = INNER_W - 44
        row.addArrangedSubview(label)
        return row
    }

    private func statusRow(symbol: String, tint: NSColor, text: String,
                           buttonTitle: String,
                           action: Selector) -> NSView {
        let z = zone(spacing: 8, alignment: .leading)
        let label = NSTextField(wrappingLabelWithString: "")
        label.textColor = .secondaryLabelColor
        z.addArrangedSubview(iconTextRow(symbol: symbol, tint: tint,
                                         label: label, text: text))
        let b = NSButton(title: buttonTitle, target: self, action: action)
        b.bezelStyle = .rounded
        b.controlSize = .small
        let indent = NSStackView()
        indent.orientation = .horizontal
        indent.spacing = 0
        let pad = NSView()
        pad.translatesAutoresizingMaskIntoConstraints = false
        pad.widthAnchor.constraint(equalToConstant: 26).isActive = true
        indent.addArrangedSubview(pad)
        indent.addArrangedSubview(b)
        z.addArrangedSubview(indent)
        return z
    }

    private func smallButton(_ title: String,
                             _ action: Selector) -> NSButton {
        let b = NSButton(title: title, target: self, action: action)
        b.bezelStyle = .rounded
        b.controlSize = .small
        b.font = .systemFont(ofSize: 11)
        return b
    }

    private func write(_ line: String) {
        DispatchQueue.main.async {
            self.log.string += line + "\n"
            self.log.scrollToEndOfDocument(nil)
        }
    }

    @objc private func toggleDetails() {
        setDetails(open: !detailsOpen, animate: true)
    }

    private func setDetails(open: Bool, animate: Bool) {
        detailsOpen = open
        logScroll.isHidden = !open
        detailsButton.title = open ? "Hide Details" : "Show Details"
        relayout(animate: animate)
    }

    // ── The work ────────────────────────────────────────────────────────

    /// Runs one operation off the main thread with the window in its
    /// working state. The close button goes dark while it runs: closing
    /// mid-copy would abandon a half-written installation.
    private func perform(_ work: @escaping (Operations) throws -> Void,
                         done: @escaping () -> (title: String,
                                                subtitle: String,
                                                offerOpen: Bool)) {
        guard !busy else { return }
        busy = true
        window.standardWindowButton(.closeButton)?.isEnabled = false
        progress.doubleValue = 0
        progressLabel.stringValue = "Preparing…"
        show(state: .working, animate: true)

        let ops = Operations(.standard()) { self.write($0) }
        ops.onProgress = { label, fraction in
            DispatchQueue.main.async {
                self.progress.doubleValue = fraction
                self.progressLabel.stringValue = label
            }
        }
        DispatchQueue.global().async {
            do {
                try work(ops)
                DispatchQueue.main.async {
                    self.finish(with: done())
                }
            } catch {
                DispatchQueue.main.async {
                    self.fail(with: "\(error)")
                }
            }
        }
    }

    private func finish(with result: (title: String, subtitle: String,
                                      offerOpen: Bool)) {
        busy = false
        window.standardWindowButton(.closeButton)?.isEnabled = true
        resultSymbol.image = NSImage(
            systemSymbolName: "checkmark.circle.fill",
            accessibilityDescription: "done")
        resultSymbol.symbolConfiguration = .init(pointSize: 44,
                                                 weight: .regular)
        resultTitle.stringValue = result.title
        resultSubtitle.stringValue = result.subtitle
        openButton.isHidden = !result.offerOpen
        show(state: .done, animate: true)
    }

    private func fail(with message: String) {
        busy = false
        window.standardWindowButton(.closeButton)?.isEnabled = true
        write("error: \(message)")
        failLabel.stringValue = message
        failLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        failLabel.textColor = .labelColor
        show(state: .ready, animate: false)
        failZone.isHidden = false
        // On failure the log is the face: open it.
        setDetails(open: true, animate: true)
    }

    // ── Actions ─────────────────────────────────────────────────────────

    @objc func installCLT() {
        Operations(.standard(), say: { self.write($0) })
            .offerCommandLineTools()
        write("Asked macOS to install the Command Line Tools.")
    }

    @objc func install() {
        let layout = Layout.standard()
        let withPython = pythonBox.state == .on
        perform({ try $0.install(python: withPython) }, done: {
            ("Installed",
             "CocoaMojo \(layout.payloadVersion) is ready, and the Cocoa"
             + " database was built from this Mac's own SDK.",
             true)
        })
    }

    @objc func reset() {
        let layout = Layout.standard()
        perform({ try $0.reset() }, done: {
            ("Reset complete",
             "CocoaMojo \(layout.payloadVersion) is pristine again. Your"
             + " edits, projects and Python environments were not touched.",
             true)
        })
    }

    @objc func uninstall() {
        // The confirm states exactly what goes. The checkbox lives HERE,
        // in the dialog that acts on it -- in the main window it sat as a
        // standing question nobody had asked yet.
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Uninstall CocoaMojo and Roast?"
        alert.informativeText =
            "Removes \(Layout.standard().root.path) — every installed"
            + " version, the app, and the current symlink.\n\nYour own"
            + " projects, and any Python on this Mac outside Roast, are"
            + " never touched."
        let box = NSButton(checkboxWithTitle:
            "Also remove my edits and settings in Application Support"
            + "\n(edited standard library, examples, IDE source, and the"
            + " per-project Python environments Roast created there)",
            target: nil, action: nil)
        box.lineBreakMode = .byWordWrapping
        box.frame = NSRect(x: 0, y: 0, width: 380, height: 48)
        alert.accessoryView = box
        let go = alert.addButton(withTitle: "Uninstall")
        go.hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let wantsUserData = box.state == .on
        perform({ try $0.uninstall(userData: wantsUserData) }, done: {
            ("Uninstalled",
             wantsUserData
                 ? "The machine is the way you found it."
                 : "The installation is gone. Your edits and settings in"
                   + " Application Support were kept.",
             false)
        })
    }

    @objc func openRoast() {
        let app = Layout.standard().installedApp
        NSWorkspace.shared.openApplication(
            at: app, configuration: .init()) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }
}

// ── main ────────────────────────────────────────────────────────────────────

if CommandLine.arguments.count > 1 {
    exit(runCommandLine(CommandLine.arguments))
}
let app = NSApplication.shared
let delegate = Delegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
