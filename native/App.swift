import AppKit
import AVFoundation
import CoreGraphics
import Darwin

private final class DictationDocument: NSView {
    override var isFlipped: Bool { true }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var window: NSWindow!
    private var activityLabel: NSTextField!
    private var activityPanel: NSBox!
    private var zoomLabel: NSTextField!
    private var zoomMonitor: Any?
    private var baseFonts: [(NSView, NSFont)] = []
    private var statusLabel: NSTextField!
    private var permissionLabel: NSTextField!
    private var notesLabel: NSTextField!
    private var transcript: NSTextView!
    private var startButton: NSButton!
    private var outputPicker: NSPopUpButton!
    private var modelPicker: NSPopUpButton!
    private var hotkeyLabel: NSTextField!
    private var recordKeyButton: NSButton!
    private var keyMonitor: Any?
    private var choosingKey = false
    private var finishAndPasteButton: NSButton!
    private var pasteIntent = FinishAndPaste()
    private var copyingDictation = false
    private static let pasteEventTag: Int64 = 0x5a4b5041535445
    private var beepButton: NSButton!
    private var folderButton: NSButton!
    private var fileButton: NSButton!
    private var menuItem: NSStatusItem!
    private var settings = AppSettings()
    private var settingsError: String?
    private var worker: WorkerProcess?
    private var workerFailed = false
    private var generation = UUID()
    private var gate = CaptureGate()
    private var recorder = Recorder()
    private var tap: CFMachPort?
    private var tapSource: CFRunLoopSource?
    private var deadline: TimeInterval?
    private var timer: Timer?
    private var recordingTimer: Timer?
    private var pendingID: String?
    private var pendingAudio: Data?
    private var outputSnapshot: AppSettings?
    private var lastText = ""
    private let clipboardManager = ClipboardManager(clipboard: SystemClipboard(.general))
    private var clipboardPane: ClipboardPane!
    private var sections: NSSegmentedControl!
    private var sideBySideButton: NSButton!
    private var panes: NSStackView!
    private var dictationPane: NSScrollView!
    private var clipboardSplitWidth: NSLayoutConstraint!
    private var dictationWidth: NSLayoutConstraint!
    private var dictationTabWidth: NSLayoutConstraint!
    private var clipboardTabWidth: NSLayoutConstraint!
    private var instanceFD: Int32 = -1
    private let modes = ["clipboard", "note", "file"]

    func applicationDidFinishLaunching(_ notification: Notification) {
        signal(SIGPIPE, SIG_IGN)
        do {
            try FileManager.default.createDirectory(at: appCacheDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            instanceFD = Darwin.open(appCacheDirectory.appendingPathComponent("instance.lock").path, O_CREAT | O_WRONLY | O_NOFOLLOW, 0o600)
            guard instanceFD >= 0 && flock(instanceFD, LOCK_EX | LOCK_NB) == 0 else { NSApp.terminate(nil); return }
            settings = try AppSettings.load()
        } catch { settingsError = String(describing: error) }
        clipboardManager.configure(enabled: settings.clipboardBackups, minutes: settings.clipboardMinutes)
        clipboardPane = ClipboardPane(manager: clipboardManager, settings: { [weak self] in self?.settings ?? AppSettings() }, save: { [weak self] in self?.persist($0) ?? false }, canInteract: { [weak self] in self.map { !$0.busy && !$0.choosingKey } ?? false })
        makeWindow()
        clipboardManager.onChange = { [weak self] in self?.clipboardPane?.refresh(); self?.updateControls() }
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(clearClipboardBackups), name: NSWorkspace.screensDidSleepNotification, object: nil)
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(locked), name: Notification.Name("com.apple.screenIsLocked"), object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(sleeping), name: NSWorkspace.willSleepNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(sleeping), name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.clipboardManager.tick()
            if let deadline = self.deadline, ProcessInfo.processInfo.systemUptime > deadline {
                self.failWorker("Transcription service timed out. Click Retry.")
            }
        }
        if let timer { RunLoop.main.add(timer, forMode: .common) }
        _ = refreshPermissions()
        show(settingsError.map { "Settings could not be loaded: \($0). Choose a notes folder to repair them." } ?? "Ready to set up. Click Start Dictation when permissions are allowed.")
        showWindow()
    }
    func applicationDidBecomeActive(_ notification: Notification) { if permissionLabel != nil { _ = refreshPermissions() } }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func windowShouldClose(_ sender: NSWindow) -> Bool { NSApp.terminate(nil); return false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showWindow(); return true }

    private func makeWindow() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 780), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "ZK Dictate"; window.minSize = NSSize(width: 620, height: 500); window.center(); window.isReleasedWhenClosed = false; window.delegate = self
        let title = NSTextField(labelWithString: "Dictation"); title.font = .boldSystemFont(ofSize: 24)
        let intro = NSTextField(wrappingLabelWithString: "Hold your dictation key to speak. Release to transcribe locally.")
        permissionLabel = NSTextField(wrappingLabelWithString: "")
        let mic = NSButton(title: "Allow Microphone", target: self, action: #selector(microphone))
        let input = NSButton(title: "Allow Global Hotkey", target: self, action: #selector(inputPermission))
        outputPicker = NSPopUpButton(); outputPicker.addItems(withTitles: ["Copy to clipboard", "Save a new note", "Append to file"])
        outputPicker.selectItem(at: modes.firstIndex(of: settings.outputMode) ?? 0); outputPicker.target = self; outputPicker.action = #selector(changeOutput)
        hotkeyLabel = NSTextField(labelWithString: hotkeyTitle(settings.hotkey))
        recordKeyButton = NSButton(title: "Record Key…", target: self, action: #selector(recordKey))
        recordKeyButton.toolTip = "Stop dictation, then press a single modifier or function key. Escape cancels."
        modelPicker = NSPopUpButton(); modelPicker.addItems(withTitles: TranscriptionModel.allCases.map { $0.title })
        modelPicker.selectItem(at: TranscriptionModel.allCases.firstIndex(of: settings.model) ?? 0)
        modelPicker.target = self; modelPicker.action = #selector(changeModel)
        beepButton = NSButton(checkboxWithTitle: "Sound cues", target: self, action: #selector(changeBeep)); beepButton.state = settings.beep ? .on : .off
        finishAndPasteButton = NSButton(checkboxWithTitle: "Finish and paste with ⌘V (experimental)", target: self, action: #selector(changeFinishAndPaste))
        finishAndPasteButton.state = settings.finishAndPaste ? .on : .off
        finishAndPasteButton.toolTip = "Stop dictation to change. In clipboard mode, ⌘V finishes and pastes at the cursor when ready. Other keys cancel the queued paste. Requires Accessibility access."
        notesLabel = NSTextField(wrappingLabelWithString: ""); notesLabel.isSelectable = true; updateDestination()
        folderButton = NSButton(title: "Choose Notes Folder…", target: self, action: #selector(chooseFolder))
        fileButton = NSButton(title: "Choose Output File…", target: self, action: #selector(chooseFile))
        updateDestination()
        startButton = NSButton(title: "Start Dictation", target: self, action: #selector(toggleStart)); startButton.bezelStyle = .rounded
        statusLabel = NSTextField(wrappingLabelWithString: ""); statusLabel.font = .boldSystemFont(ofSize: 14)
        transcript = NSTextView(); transcript.isEditable = false; transcript.isSelectable = true; transcript.font = .systemFont(ofSize: 16)
        transcript.textContainerInset = NSSize(width: 12, height: 12)
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder; scroll.documentView = transcript
        transcript.isVerticallyResizable = true; transcript.isHorizontallyResizable = false
        transcript.autoresizingMask = [.width]; transcript.textContainer?.widthTracksTextView = true
        let copy = NSButton(title: "Copy", target: self, action: #selector(copyTranscript))
        let save = NSButton(title: "Save as note", target: self, action: #selector(saveTranscript))
        let clear = NSButton(title: "Clear", target: self, action: #selector(clearTranscript))
        let transcriptSection = InterfaceSection("Your words", views: [scroll, row([copy, save, clear])])
        let recordingSection = InterfaceSection("How you record", views: [
            row([hotkeyLabel, recordKeyButton]), beepButton, finishAndPasteButton
        ])
        let destinationSection = InterfaceSection("Where your words go", views: [
            outputPicker, notesLabel, folderButton, fileButton
        ])
        let setupSection = InterfaceSection("Setup & permissions", caption: "Model and microphone access. Open when needed.", views: [
            NSTextField(labelWithString: "Transcription model"), modelPicker,
            NSTextField(wrappingLabelWithString: "Downloads once, then works offline. Stop dictation to change it."),
            permissionLabel, mic, input
        ], collapsible: true)
        let stack = NSStackView(views: [title, intro, transcriptSection, recordingSection, destinationSection, setupSection])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 24; stack.translatesAutoresizingMaskIntoConstraints = false
        for section in [transcriptSection, recordingSection, destinationSection, setupSection] {
            section.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        intro.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        dictationPane = NSScrollView(); dictationPane.hasVerticalScroller = true
        let document = DictationDocument(); document.translatesAutoresizingMaskIntoConstraints = false
        dictationPane.documentView = document; document.addSubview(stack)
        NSLayoutConstraint.activate([
            document.leadingAnchor.constraint(equalTo: dictationPane.contentView.leadingAnchor),
            document.trailingAnchor.constraint(equalTo: dictationPane.contentView.trailingAnchor),
            document.topAnchor.constraint(equalTo: dictationPane.contentView.topAnchor),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: document.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -20),
            scroll.heightAnchor.constraint(equalToConstant: 180)
        ])
        sections = NSSegmentedControl(labels: ["Dictation", "Clipboard"], trackingMode: .selectOne, target: self, action: #selector(changeSection))
        sections.selectedSegment = 0
        sideBySideButton = NSButton(checkboxWithTitle: "Side by side", target: self, action: #selector(changeLayout))
        let smaller = NSButton(title: "−", target: self, action: #selector(zoomOut))
        let larger = NSButton(title: "+", target: self, action: #selector(zoomIn))
        let reset = NSButton(title: "Reset", target: self, action: #selector(resetZoom))
        smaller.toolTip = "Zoom out (⌘−)"; larger.toolTip = "Zoom in (⌘+)"; reset.toolTip = "Reset zoom (⌘0)"
        zoomLabel = NSTextField(labelWithString: "100%")
        let navigation = row([sections, sideBySideButton, smaller, zoomLabel, larger, reset]); navigation.translatesAutoresizingMaskIntoConstraints = false
        activityLabel = NSTextField(labelWithString: "STOPPED · Mic off")
        activityLabel.font = .boldSystemFont(ofSize: 26)
        activityPanel = NSBox(); activityPanel.boxType = .custom; activityPanel.borderWidth = 0; activityPanel.titlePosition = .noTitle
        activityPanel.cornerRadius = 12; activityPanel.contentViewMargins = .zero
        activityPanel.translatesAutoresizingMaskIntoConstraints = false
        let activity = NSStackView(views: [activityLabel, statusLabel, startButton])
        activity.orientation = .vertical; activity.alignment = .leading; activity.spacing = 8
        activity.translatesAutoresizingMaskIntoConstraints = false; activityPanel.contentView!.addSubview(activity)
        NSLayoutConstraint.activate([
            activity.leadingAnchor.constraint(equalTo: activityPanel.leadingAnchor, constant: 16),
            activity.trailingAnchor.constraint(equalTo: activityPanel.trailingAnchor, constant: -16),
            activity.topAnchor.constraint(equalTo: activityPanel.topAnchor, constant: 12),
            activity.bottomAnchor.constraint(equalTo: activityPanel.bottomAnchor, constant: -12),
            statusLabel.widthAnchor.constraint(equalTo: activity.widthAnchor)
        ])
        panes = NSStackView(views: [dictationPane, clipboardPane.view]); panes.orientation = .horizontal
        panes.alignment = .top; panes.spacing = 1; panes.translatesAutoresizingMaskIntoConstraints = false
        dictationWidth = dictationPane.widthAnchor.constraint(equalTo: panes.widthAnchor, multiplier: 0.53)
        clipboardSplitWidth = clipboardPane.view.widthAnchor.constraint(equalTo: panes.widthAnchor, multiplier: 0.47, constant: -1)
        dictationTabWidth = dictationPane.widthAnchor.constraint(equalTo: panes.widthAnchor)
        clipboardTabWidth = clipboardPane.view.widthAnchor.constraint(equalTo: panes.widthAnchor)
        let content = window.contentView!
        content.addSubview(navigation); content.addSubview(activityPanel); content.addSubview(panes)
        NSLayoutConstraint.activate([
            navigation.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            navigation.topAnchor.constraint(equalTo: content.topAnchor, constant: 14),
            activityPanel.topAnchor.constraint(equalTo: navigation.bottomAnchor, constant: 12),
            activityPanel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            activityPanel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            panes.topAnchor.constraint(equalTo: activityPanel.bottomAnchor, constant: 8),
            panes.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            panes.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            panes.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            dictationPane.heightAnchor.constraint(equalTo: panes.heightAnchor),
            clipboardPane.view.heightAnchor.constraint(equalTo: panes.heightAnchor)
        ])
        rememberFonts(in: content)
        applyZoom()
        zoomMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, !self.choosingKey,
                  event.modifierFlags.intersection([.command, .option, .control]) == .command else { return event }
            switch event.charactersIgnoringModifiers {
            case "+", "=": self.zoomIn(); return nil
            case "-", "_": self.zoomOut(); return nil
            case "0": self.resetZoom(); return nil
            default: return event
            }
        }
        menuItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength); menuItem.button?.title = "ZK"
        let menu = NSMenu()
        menu.addItem(withTitle: "Show ZK Dictate", action: #selector(showWindow), keyEquivalent: "")
        menu.addItem(withTitle: "Stop Dictation", action: #selector(stopAction), keyEquivalent: "")
        menu.addItem(withTitle: "Quit ZK Dictate", action: #selector(quit), keyEquivalent: "q")
        for item in menu.items { item.target = self }; menuItem.menu = menu
    }
    private func row(_ views: [NSView]) -> NSStackView { let stack = NSStackView(views: views); stack.orientation = .horizontal; stack.spacing = 10; return stack }
    @objc func showWindow() { window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
    @objc func quit() { NSApp.terminate(nil) }
    private func show(_ value: String) {
        statusLabel.stringValue = value
        menuItem.button?.title = gate.recording ? "● ZK" : pasteIntent.pending ? "ZK ⌘V" : "ZK"
        menuItem.button?.toolTip = value
        updateActivity()
    }
    private var busy: Bool { gate.recording || pendingID != nil || clipboardManager.busy }
    private func updateControls() {
        updateActivity()
        for control: NSControl in [outputPicker, beepButton, folderButton, fileButton] { control.isEnabled = !busy && pendingAudio == nil && !choosingKey }
        finishAndPasteButton.isEnabled = worker == nil && !busy && pendingAudio == nil && !choosingKey
        recordKeyButton.isEnabled = worker == nil && !busy && pendingAudio == nil
        recordKeyButton.title = choosingKey ? "Cancel" : "Record Key…"
        startButton.isEnabled = !choosingKey
        modelPicker.isEnabled = worker == nil && !busy && pendingAudio == nil && !choosingKey
        startButton.title = worker != nil ? "Stop Dictation" : pendingAudio != nil ? "Retry Transcription" : workerFailed ? "Retry" : "Start Dictation"
    }
    private func updateActivity() {
        guard activityLabel != nil else { return }
        let title: String
        let color: NSColor
        if gate.recording {
            title = gate.otherKey ? "CANCELLED · Release key" : "● RECORDING · Mic on"
            color = gate.otherKey ? .systemOrange : .systemRed
        } else if pendingID != nil || copyingDictation {
            title = pasteIntent.pending ? "TRANSCRIBING → PASTE · Mic off" : "TRANSCRIBING · Mic off"
            color = .systemOrange
        } else if worker == nil {
            title = workerFailed ? "ERROR · Mic off" : "STOPPED · Mic off"; color = workerFailed ? .systemRed : .secondaryLabelColor
        } else if gate.ready {
            title = "READY · Hold \(hotkeyTitle(settings.hotkey))"; color = .systemGreen
        } else {
            title = "LOADING · Mic off"; color = .systemOrange
        }
        activityLabel.stringValue = title
        activityLabel.textColor = color
        activityPanel.fillColor = color.withAlphaComponent(0.12)
    }
    private func rememberFonts(in view: NSView) {
        if let text = view as? NSTextView, let font = text.font { baseFonts.append((text, font)) }
        else if let control = view as? NSControl, let font = control.font { baseFonts.append((control, font)) }
        for child in (view as? NSStackView)?.arrangedSubviews ?? view.subviews { rememberFonts(in: child) }
    }
    private func applyZoom() {
        let scale = CGFloat(settings.zoomPercent) / 100
        for (view, font) in baseFonts {
            let scaled = NSFontManager.shared.convert(font, toSize: font.pointSize * scale)
            if let text = view as? NSTextView { text.font = scaled }
            else if let control = view as? NSControl { control.font = scaled }
        }
        zoomLabel.stringValue = "\(settings.zoomPercent)%"
        applyLayout()
    }
    private func setZoom(_ percent: Int) {
        var value = settings; value.zoomPercent = min(150, max(80, percent))
        guard value.zoomPercent != settings.zoomPercent else { return }
        if persist(value) { applyZoom() }
    }
    @objc private func zoomIn() { setZoom(settings.zoomPercent + 10) }
    @objc private func zoomOut() { setZoom(settings.zoomPercent - 10) }
    @objc private func resetZoom() { setZoom(100) }
    private func updateDestination() {
        notesLabel.isHidden = settings.outputMode == "clipboard"
        folderButton?.isHidden = settings.outputMode != "note"
        fileButton?.isHidden = settings.outputMode != "file"
        notesLabel.stringValue = settings.outputMode == "file" ? "Output file: \(settings.filePath ?? "Choose a file below")" : "Notes folder: \(settings.notesDirectory)" }
    @discardableResult private func persist(_ proposed: AppSettings) -> Bool {
        var saved = false
        do { try proposed.save(); settings = proposed; settingsError = nil; saved = true } catch { show("Could not save settings: \(error.localizedDescription)") }
        outputPicker.selectItem(at: modes.firstIndex(of: settings.outputMode) ?? 0)
        hotkeyLabel.stringValue = hotkeyTitle(settings.hotkey)
        modelPicker.selectItem(at: TranscriptionModel.allCases.firstIndex(of: settings.model) ?? 0)
        finishAndPasteButton.state = settings.finishAndPaste ? .on : .off
        beepButton.state = settings.beep ? .on : .off; updateDestination()
        return saved
    }
    @objc func changeModel() {
        guard worker == nil, !busy, pendingAudio == nil else { return }
        var value = settings; value.model = TranscriptionModel.allCases[modelPicker.indexOfSelectedItem]; persist(value)
    }
    @objc func changeOutput() { guard !busy else { return }; var value = settings; value.outputMode = modes[outputPicker.indexOfSelectedItem]; persist(value) }
    @objc func recordKey() {
        if choosingKey { cancelKeySelection(); return }
        guard worker == nil, !busy, pendingAudio == nil else { return }
        choosingKey = true
        show("Press one Command, Option, Control, Shift, or function key. Escape cancels.")
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { [weak self] event in
            guard let self, self.choosingKey else { return event }
            if event.type == .keyDown && event.keyCode == 53 { self.cancelKeySelection(); return nil }
            if event.type == .keyUp || (event.type == .keyDown && event.isARepeat) { return nil }
            if let name = recordableHotkey(code: Int64(event.keyCode), flags: UInt64(event.modifierFlags.rawValue), modifierEvent: event.type == .flagsChanged) {
                self.endKeySelection()
                var value = self.settings; value.hotkey = name
                if self.persist(value) { self.show("Hotkey set to \(hotkeyTitle(name)). Click Start Dictation when ready.") }
            } else {
                self.show("Use a single modifier or F1–F20 key. Letters, Space, and combinations aren't supported. Escape cancels.")
            }
            return nil
        }
        updateControls()
    }
    private func endKeySelection() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil; choosingKey = false; updateControls()
    }
    private func cancelKeySelection() {
        guard choosingKey else { return }
        endKeySelection(); show("Key selection cancelled. Hotkey is still \(hotkeyTitle(settings.hotkey)).")
    }
    func applicationDidResignActive(_ notification: Notification) { cancelKeySelection(); clipboardPane?.applicationDidResignActive() }
    @objc func changeFinishAndPaste() {
        guard worker == nil, !busy, pendingAudio == nil else { return }
        var value = settings; value.finishAndPaste = finishAndPasteButton.state == .on
        persist(value)
    }
    @objc func changeBeep() { var value = settings; value.beep = beepButton.state == .on; persist(value) }
    @objc func chooseFolder() {
        guard !busy else { return }
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true; panel.allowsMultipleSelection = false
        panel.prompt = "Use This Folder"; panel.directoryURL = URL(fileURLWithPath: settings.notesDirectory)
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let url = panel.url, !self.busy else { return }
            var value = self.settings; value.notesDirectory = url.path; self.persist(value)
        }
    }
    @objc func chooseFile() {
        guard !busy else { return }
        let panel = NSSavePanel(); panel.title = "Choose a file to append dictation"; panel.nameFieldStringValue = "dictation.md"; panel.prompt = "Use File"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let url = panel.url, !self.busy else { return }
            var value = self.settings; value.filePath = url.path; self.persist(value)
        }
    }
    @objc func microphone() {
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] _ in DispatchQueue.main.async { _ = self?.refreshPermissions() } }
        } else { openSettings("Privacy_Microphone") }
    }
    @objc func inputPermission() { if !CGPreflightListenEventAccess() { _ = CGRequestListenEventAccess() }; openSettings("Privacy_ListenEvent") }
    private func openSettings(_ pane: String) { if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") { NSWorkspace.shared.open(url) } }
    @discardableResult private func refreshPermissions() -> Bool {
        let mic = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        let input = CGPreflightListenEventAccess()
        permissionLabel.stringValue = "Microphone: \(mic ? "Allowed" : "Needs approval") · Input Monitoring: \(input ? "Allowed" : "Needs approval / restart")"
        let snapshot: [String: Any] = ["microphone": mic ? "Allowed" : "Needs approval", "input_monitoring": input, "app_path": Bundle.main.bundlePath, "pid": ProcessInfo.processInfo.processIdentifier, "checked_at": ISO8601DateFormatter().string(from: Date())]
        if let data = try? JSONSerialization.data(withJSONObject: snapshot) { try? data.write(to: appCacheDirectory.appendingPathComponent("permissions.json"), options: .atomic) }
        return mic && input
    }
    @objc func toggleStart() { if worker != nil { stopAction() } else { startWorker() } }
    private func startWorker() {
        guard !choosingKey else { return }
        guard settingsError == nil else { show("Choose a notes folder to repair settings first."); return }
        guard refreshPermissions() else { show("Open Setup & permissions to allow microphone and Input Monitoring, then restart if needed."); return }
        guard settings.outputMode != "file" || settings.filePath != nil else { show("Choose an output file first."); return }
        if settings.finishAndPaste && !AXIsProcessTrusted() {
            _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
            show("Allow ZK Dictate in Accessibility to use Finish and Paste, then click Start Dictation again.")
            return
        }
        guard installHotkey() else { show("Could not enable the hotkey. Restart after granting Input Monitoring."); return }
        generation = UUID(); let session = generation
        workerFailed = false
        let service = WorkerProcess(); worker = service
        gate.approved = true; gate.ready = false
        deadline = ProcessInfo.processInfo.systemUptime + 600
        service.onEvent = { [weak self] object in guard let self, self.generation == session else { return }; self.workerEvent(object) }
        service.onExit = { [weak self] code in guard let self, self.generation == session else { return }; self.failWorker("Transcription service stopped (\(code)). Click Retry.") }
        do { try service.start(model: settings.model); show("Loading \(settings.model.title)… First use may download the model.") }
        catch { failWorker("Could not start transcription: \(error.localizedDescription)") }
        updateControls()
    }
    private func workerEvent(_ object: [String: Any]) {
        switch object["event"] as? String {
        case "loading": break
        case "ready":
            deadline = nil; gate.ready = true
            if let audio = pendingAudio { submit(audio) } else { show("Ready — hold \(hotkeyTitle(settings.hotkey)) for at least 1.5 seconds to speak.") }
        case "transcript":
            guard let id = object["id"] as? String, id == pendingID, let text = object["text"] as? String else { failWorker("Invalid transcription response. Click Retry."); return }
            pendingID = nil; pendingAudio = nil; deadline = nil; gate.ready = true
            let target = outputSnapshot ?? settings; outputSnapshot = nil
            if text.isEmpty { pasteIntent.cancel(); show("No speech detected. Try again.") }
            else {
                lastText = text; transcript.string = text
                do {
                    if target.outputMode == "note" { let url = try NoteOutput.save(text, folder: URL(fileURLWithPath: target.notesDirectory)); show("Saved note: \(url.lastPathComponent)") }
                    else if target.outputMode == "file", let path = target.filePath { try NoteOutput.append(text, file: URL(fileURLWithPath: path)); show("Appended transcript to \(URL(fileURLWithPath: path).lastPathComponent)") }
                    else { copyText(text, automaticPaste: true) }
                } catch { show("Transcript preserved below, but saving failed: \(error.localizedDescription)") }
            }
        case "error", "fatal": failWorker("Transcription failed: \(object["message"] as? String ?? "Unknown error"). Click Retry.")
        default: failWorker("Unknown transcription response. Click Retry.")
        }
        updateControls()
    }
    private func submit(_ audio: Data) {
        pendingAudio = audio; pendingID = UUID().uuidString; gate.ready = false
        deadline = ProcessInfo.processInfo.systemUptime + 120
        show(pasteIntent.pending ? "Transcribing… will paste" : "Transcribing…"); worker?.transcribe(audio, id: pendingID!); updateControls()
    }
    private func failWorker(_ message: String) {
        shutdownWorker(); workerFailed = true; show(message); updateControls()
    }
    private func shutdownWorker() {
        generation = UUID(); cancelCapture(); pasteIntent = FinishAndPaste(); copyingDictation = false; gate = CaptureGate(); pendingID = nil; deadline = nil
        worker?.stop(); worker = nil
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        if let tapSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), tapSource, .commonModes) }
        tap = nil; tapSource = nil
    }
    @objc func stopAction() { cancelKeySelection(); shutdownWorker(); clipboardManager.cancelPending(); workerFailed = false; pendingAudio = nil; outputSnapshot = nil; show("Stopped. Microphone and transcription worker are off."); updateControls() }
    @objc func sleeping() { clearClipboardBackups(); stopAction() }
    @objc func locked() { sleeping() }
    @objc func clearClipboardBackups() { clipboardManager.clear(); clipboardPane?.hidePreviews() }
    @objc private func changeSection() { applyLayout(resizeWindow: false) }
    @objc private func changeLayout() {
        var value = settings; value.sideBySide = sideBySideButton.state == .on
        _ = persist(value); applyLayout()
    }
    private func applyLayout(resizeWindow: Bool = true) {
        let split = settings.sideBySide
        sideBySideButton.state = split ? .on : .off
        sections.isHidden = split
        dictationTabWidth.isActive = false; clipboardTabWidth.isActive = false
        dictationWidth.isActive = split; clipboardSplitWidth.isActive = split
        dictationPane.isHidden = !split && sections.selectedSegment == 1
        clipboardPane.view.isHidden = !split && sections.selectedSegment == 0
        dictationTabWidth.isActive = !split && sections.selectedSegment == 0
        clipboardTabWidth.isActive = !split && sections.selectedSegment == 1
        clipboardPane.setVisible(!clipboardPane.view.isHidden)
        let scale = CGFloat(settings.zoomPercent) / 100
        let screenWidth = (window.screen ?? NSScreen.main)?.visibleFrame.width ?? 1600
        window.minSize = NSSize(width: min(screenWidth, (split ? 1000 : 620) * scale), height: 500)
        guard resizeWindow else { return }
        var frame = window.frame
        frame.size.width = min(screenWidth, split ? max(frame.width, 1120 * scale) : 720 * scale)
        if let screen = window.screen ?? NSScreen.main {
            frame.size.height = min(frame.height, screen.visibleFrame.height)
            frame.origin.x = max(screen.visibleFrame.minX, min(frame.origin.x, screen.visibleFrame.maxX - frame.width))
            frame.origin.y = max(screen.visibleFrame.minY, min(frame.origin.y, screen.visibleFrame.maxY - frame.height))
        }
        window.setFrame(frame, display: true)
    }
    private func copyText(_ text: String, automaticPaste: Bool = false) {
        copyingDictation = automaticPaste
        let session = generation
        clipboardManager.copy(text) { [weak self] result in
            guard let self, self.generation == session else { return }
            self.copyingDictation = false
            switch result {
            case .success:
                if automaticPaste && self.pasteIntent.take() { self.postPaste() }
                else { self.show("Copied to clipboard. Ready for the next dictation.") }
            case .failure(let error):
                self.pasteIntent.cancel()
                self.show("\(error.localizedDescription) Transcript preserved below.")
            }
            self.updateControls()
        }
    }
    private func postPaste() {
        guard AXIsProcessTrusted(),
              let source = CGEventSource(stateID: .privateState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false) else {
            show("Automatic paste unavailable. Transcript copied; press ⌘V to paste."); return
        }
        for event in [down, up] {
            event.flags = .maskCommand
            event.setIntegerValueField(.eventSourceUserData, value: Self.pasteEventTag)
            event.post(tap: .cgSessionEventTap)
        }
        show("Paste sent. Ready for the next dictation.")
    }
    @objc func copyTranscript() { guard !busy, !lastText.isEmpty else { return }; copyText(lastText) }
    @objc func saveTranscript() {
        guard !busy, !lastText.isEmpty else { return }
        do { let url = try NoteOutput.save(lastText, folder: URL(fileURLWithPath: settings.notesDirectory)); show("Saved note: \(url.lastPathComponent)") }
        catch { show("Could not save note: \(error.localizedDescription)") }
    }
    @objc func clearTranscript() { guard !busy else { return }; lastText = ""; transcript.string = "" }
    func installHotkey() -> Bool {
        if tap != nil { return true }
        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue) | (1 << CGEventType.flagsChanged.rawValue)
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: settings.finishAndPaste ? .defaultTap : .listenOnly, eventsOfInterest: CGEventMask(mask), callback: { _, type, event, data in
            if let data, Unmanaged<AppDelegate>.fromOpaque(data).takeUnretainedValue().keyEvent(type, event) { return nil }
            return Unmanaged.passUnretained(event)
        }, userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return false }
        self.tap = tap; tapSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), tapSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }
    func keyEvent(_ type: CGEventType, _ event: CGEvent) -> Bool {
        if event.getIntegerValueField(.eventSourceUserData) == Self.pasteEventTag { return false }
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            cancelCapture(); if let tap { CGEvent.tapEnable(tap: tap, enable: true) }; return false
        }
        guard window.attachedSheet == nil else { return false }
        let code = event.getIntegerValueField(.keyboardEventKeycode)
        let action = pasteIntent.key(code: code, flags: event.flags.rawValue,
            down: type == .keyDown, modifier: type == .flagsChanged,
            repeated: event.getIntegerValueField(.keyboardEventAutorepeat) != 0,
            enabled: settings.finishAndPaste,
            active: (gate.canFinish(now: ProcessInfo.processInfo.systemUptime) || pendingID != nil || copyingDictation) && settings.outputMode == "clipboard")
        switch action {
        case .request:
            if gate.recording { finishCapture() }
            else { show("Transcribing… will paste") }
            updateControls(); return true
        case .swallow: return true
        case .cancel: show("Automatic paste cancelled. Transcription will still be copied.")
        case .pass: break
        }
        // A held/re-pressed microphone key must not restart capture or replace
        // the queued-paste status while this dictation is being processed.
        if settings.finishAndPaste && (pendingID != nil || clipboardManager.busy) { return false }
        let keys = allowedHotkeys[settings.hotkey] ?? [54]
        if !keys.contains(code) {
            if gate.recording && (type == .keyDown || type == .flagsChanged) { gate.otherKey = true; updateActivity() }
            return false
        }
        let pressed = type == .keyDown || (type == .flagsChanged && modifierHotkeyIsDown(settings.hotkey, flags: event.flags.rawValue))
        if event.getIntegerValueField(.keyboardEventAutorepeat) != 0 { return false }
        if pressed {
            guard !clipboardManager.busy else { show("Wait for the clipboard operation to finish."); return false }
            guard recordableHotkey(code: code, flags: event.flags.rawValue, modifierEvent: type == .flagsChanged) == settings.hotkey else {
                show("Hotkey ignored: release other modifier keys first."); return false
            }
            guard gate.press(now: ProcessInfo.processInfo.systemUptime) else {
                let reason = !gate.approved ? "Session not approved" : !gate.ready ? "Transcription worker not ready" : "Already recording"
                show("Hotkey ignored: \(reason)")
                return false
            }
            do {
                try recorder.start(); menuItem.button?.title = "● ZK"; show("Recording")
                if settings.beep { NSSound.beep() }
                recordingTimer = Timer.scheduledTimer(withTimeInterval: gate.maximumHold, repeats: false) { [weak self] _ in self?.cancelCapture(); self?.show("Recording reached 10-minute limit; discarded"); self?.updateControls() }
            } catch { gate.cancel(); show("Microphone error: \(error)") }
        } else if gate.recording {
            finishCapture()
        }
        updateControls()
        return false
    }
    private func finishCapture() {
        let accepted = gate.release(now: ProcessInfo.processInfo.systemUptime)
        recordingTimer?.invalidate(); recordingTimer = nil
        let audio = recorder.stop(discard: !accepted); menuItem.button?.title = "ZK"
        if settings.beep { NSSound.beep() }
        if let audio {
            show("Transcribing")
            outputSnapshot = settings
            submit(audio)
        } else { pasteIntent.cancel(); gate.ready = true; show("Recording discarded — hold at least \(gate.minimumHold)s without other keys") }
    }
    func cancelCapture() {
        pasteIntent.cancel()
        gate.cancel(); _ = recorder.stop(discard: true)
        recordingTimer?.invalidate(); recordingTimer = nil
        menuItem.button?.title = "ZK"
    }
    func applicationWillTerminate(_ notification: Notification) {
        if let zoomMonitor { NSEvent.removeMonitor(zoomMonitor) }
        clipboardManager.clear(); clipboardPane?.hidePreviews()
        if window != nil { endKeySelection(); shutdownWorker() }; timer?.invalidate()
        if instanceFD >= 0 { Darwin.close(instanceFD) }
    }
}

@main
struct ZKDictateApp {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate(); app.delegate = delegate
        app.setActivationPolicy(.regular); app.run()
    }
}
