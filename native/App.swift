import AppKit
import AVFoundation
import CoreGraphics
import Darwin

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    private var statusLabel: NSTextField!
    private var permissionLabel: NSTextField!
    private var notesLabel: NSTextField!
    private var transcript: NSTextView!
    private var startButton: NSButton!
    private var pauseButton: NSButton!
    private var outputPicker: NSPopUpButton!
    private var hotkeyPicker: NSPopUpButton!
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
    private var instanceFD: Int32 = -1
    private let hotkeys = ["right_cmd", "left_cmd", "cmd", "right_alt", "left_alt", "f10"]
    private let modes = ["clipboard", "note", "file"]

    func applicationDidFinishLaunching(_ notification: Notification) {
        signal(SIGPIPE, SIG_IGN)
        do {
            try FileManager.default.createDirectory(at: appCacheDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            instanceFD = Darwin.open(appCacheDirectory.appendingPathComponent("instance.lock").path, O_CREAT | O_WRONLY | O_NOFOLLOW, 0o600)
            guard instanceFD >= 0 && flock(instanceFD, LOCK_EX | LOCK_NB) == 0 else { NSApp.terminate(nil); return }
            settings = try AppSettings.load()
        } catch { settingsError = String(describing: error) }
        makeWindow()
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(sleeping), name: NSWorkspace.willSleepNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(sleeping), name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self else { return }
            if let deadline = self.deadline, ProcessInfo.processInfo.systemUptime > deadline {
                self.failWorker("Transcription service timed out. Click Retry.")
            }
        }
        _ = refreshPermissions()
        show(settingsError.map { "Settings could not be loaded: \($0). Choose a notes folder to repair them." } ?? "Ready to set up. Click Start Dictation when permissions are allowed.")
        showWindow()
    }
    func applicationDidBecomeActive(_ notification: Notification) { if permissionLabel != nil { _ = refreshPermissions() } }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showWindow(); return true }

    private func makeWindow() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 720), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "ZK Dictate"; window.minSize = NSSize(width: 620, height: 680); window.center(); window.isReleasedWhenClosed = false
        let title = NSTextField(labelWithString: "Your voice. On your Mac."); title.font = .boldSystemFont(ofSize: 24)
        let intro = NSTextField(wrappingLabelWithString: "Hold your dictation key to speak. Release to transcribe locally.")
        permissionLabel = NSTextField(wrappingLabelWithString: "")
        let mic = NSButton(title: "Allow Microphone", target: self, action: #selector(microphone))
        let input = NSButton(title: "Allow Global Hotkey", target: self, action: #selector(inputPermission))
        outputPicker = NSPopUpButton(); outputPicker.addItems(withTitles: ["Copy to clipboard", "Save a new note", "Append to file"])
        outputPicker.selectItem(at: modes.firstIndex(of: settings.outputMode) ?? 0); outputPicker.target = self; outputPicker.action = #selector(changeOutput)
        hotkeyPicker = NSPopUpButton(); hotkeyPicker.addItems(withTitles: ["Right Command", "Left Command", "Either Command", "Right Option", "Left Option", "F10"])
        hotkeyPicker.selectItem(at: hotkeys.firstIndex(of: settings.hotkey) ?? 0); hotkeyPicker.target = self; hotkeyPicker.action = #selector(changeHotkey)
        beepButton = NSButton(checkboxWithTitle: "Sound cues", target: self, action: #selector(changeBeep)); beepButton.state = settings.beep ? .on : .off
        notesLabel = NSTextField(wrappingLabelWithString: ""); notesLabel.isSelectable = true; updateDestination()
        folderButton = NSButton(title: "Choose Notes Folder…", target: self, action: #selector(chooseFolder))
        fileButton = NSButton(title: "Choose Output File…", target: self, action: #selector(chooseFile))
        startButton = NSButton(title: "Start Dictation", target: self, action: #selector(toggleStart)); startButton.bezelStyle = .rounded
        pauseButton = NSButton(title: "Pause", target: self, action: #selector(togglePause)); pauseButton.isEnabled = false
        statusLabel = NSTextField(wrappingLabelWithString: ""); statusLabel.font = .boldSystemFont(ofSize: 14)
        transcript = NSTextView(); transcript.isEditable = false; transcript.isSelectable = true; transcript.font = .systemFont(ofSize: 16)
        transcript.textContainerInset = NSSize(width: 12, height: 12)
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder; scroll.documentView = transcript
        transcript.isVerticallyResizable = true; transcript.isHorizontallyResizable = false
        transcript.autoresizingMask = [.width]; transcript.textContainer?.widthTracksTextView = true
        let copy = NSButton(title: "Copy Transcript", target: self, action: #selector(copyTranscript))
        let save = NSButton(title: "Save Transcript as Note", target: self, action: #selector(saveTranscript))
        let clear = NSButton(title: "Clear", target: self, action: #selector(clearTranscript))
        let stack = NSStackView(views: [title, intro, row([mic, input]), permissionLabel,
            row([NSTextField(labelWithString: "Output:"), outputPicker]),
            row([NSTextField(labelWithString: "Hotkey:"), hotkeyPicker, beepButton]),
            notesLabel, row([folderButton, fileButton]), row([startButton, pauseButton]), statusLabel,
            NSTextField(labelWithString: "Latest transcript"), scroll, row([copy, save, clear])])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 12; stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 24), stack.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -24), stack.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 22), stack.bottomAnchor.constraint(equalTo: window.contentView!.bottomAnchor, constant: -22), scroll.widthAnchor.constraint(equalTo: stack.widthAnchor), scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 130)])
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
    private func show(_ value: String) { statusLabel.stringValue = value }
    private var busy: Bool { gate.recording || pendingID != nil }
    private func updateControls() {
        for control: NSControl in [outputPicker, hotkeyPicker, beepButton, folderButton, fileButton] { control.isEnabled = !busy && pendingAudio == nil }
        pauseButton.isEnabled = gate.approved && gate.ready && !busy
        pauseButton.title = gate.paused ? "Resume" : "Pause"
        startButton.title = worker != nil ? "Stop Dictation" : pendingAudio != nil ? "Retry Transcription" : workerFailed ? "Retry" : "Start Dictation"
    }
    private func updateDestination() { notesLabel.stringValue = settings.outputMode == "file" ? "Output file: \(settings.filePath ?? "Choose a file below")" : "Notes folder: \(settings.notesDirectory)" }
    private func persist(_ proposed: AppSettings) {
        do { try proposed.save(); settings = proposed; settingsError = nil } catch { show("Could not save settings: \(error.localizedDescription)") }
        outputPicker.selectItem(at: modes.firstIndex(of: settings.outputMode) ?? 0)
        hotkeyPicker.selectItem(at: hotkeys.firstIndex(of: settings.hotkey) ?? 0)
        beepButton.state = settings.beep ? .on : .off; updateDestination()
    }
    @objc func changeOutput() { guard !busy else { return }; var value = settings; value.outputMode = modes[outputPicker.indexOfSelectedItem]; persist(value) }
    @objc func changeHotkey() { guard !busy else { return }; var value = settings; value.hotkey = hotkeys[hotkeyPicker.indexOfSelectedItem]; persist(value) }
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
        guard settingsError == nil else { show("Choose a notes folder to repair settings first."); return }
        guard refreshPermissions() else { show("Allow microphone and Input Monitoring above, then restart the app if needed."); return }
        guard settings.outputMode != "file" || settings.filePath != nil else { show("Choose an output file first."); return }
        guard installHotkey() else { show("Could not enable the hotkey. Restart after granting Input Monitoring."); return }
        generation = UUID(); let session = generation
        workerFailed = false
        let service = WorkerProcess(); worker = service
        gate.approved = true; gate.ready = false; gate.paused = false
        deadline = ProcessInfo.processInfo.systemUptime + 600
        service.onEvent = { [weak self] object in guard let self, self.generation == session else { return }; self.workerEvent(object) }
        service.onExit = { [weak self] code in guard let self, self.generation == session else { return }; self.failWorker("Transcription service stopped (\(code)). Click Retry.") }
        do { try service.start(); show("Loading transcription model… First launch may download the model.") }
        catch { failWorker("Could not start transcription: \(error.localizedDescription)") }
        updateControls()
    }
    private func workerEvent(_ object: [String: Any]) {
        switch object["event"] as? String {
        case "loading": break
        case "ready":
            deadline = nil; gate.ready = true
            if let audio = pendingAudio { submit(audio) } else { show("Ready — hold \(hotkeyPicker.titleOfSelectedItem ?? "your dictation key") for at least 1.5 seconds to speak.") }
        case "transcript":
            guard let id = object["id"] as? String, id == pendingID, let text = object["text"] as? String else { failWorker("Invalid transcription response. Click Retry."); return }
            pendingID = nil; pendingAudio = nil; deadline = nil; gate.ready = true
            let target = outputSnapshot ?? settings; outputSnapshot = nil
            if text.isEmpty { show("No speech detected. Try again.") }
            else {
                lastText = text; transcript.string = text
                do {
                    if target.outputMode == "note" { let url = try NoteOutput.save(text, folder: URL(fileURLWithPath: target.notesDirectory)); show("Saved note: \(url.lastPathComponent)") }
                    else if target.outputMode == "file", let path = target.filePath { try NoteOutput.append(text, file: URL(fileURLWithPath: path)); show("Appended transcript to \(URL(fileURLWithPath: path).lastPathComponent)") }
                    else { copyText(text); show("Copied to clipboard. Ready for the next dictation.") }
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
        show("Transcribing…"); worker?.transcribe(audio, id: pendingID!); updateControls()
    }
    private func failWorker(_ message: String) {
        shutdownWorker(); workerFailed = true; show(message); updateControls()
    }
    private func shutdownWorker() {
        generation = UUID(); cancelCapture(); gate = CaptureGate(); pendingID = nil; deadline = nil
        worker?.stop(); worker = nil
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        if let tapSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), tapSource, .commonModes) }
        tap = nil; tapSource = nil
    }
    @objc func stopAction() { shutdownWorker(); workerFailed = false; pendingAudio = nil; outputSnapshot = nil; show("Stopped. Microphone and transcription worker are off."); updateControls() }
    @objc func sleeping() { stopAction() }
    @objc func togglePause() { guard !busy else { return }; gate.paused.toggle(); show(gate.paused ? "Paused. Microphone is off." : "Ready to dictate."); updateControls() }
    private func copyText(_ text: String) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string) }
    @objc func copyTranscript() { guard !busy, !lastText.isEmpty else { return }; copyText(lastText); show("Transcript copied.") }
    @objc func saveTranscript() {
        guard !busy, !lastText.isEmpty else { return }
        do { let url = try NoteOutput.save(lastText, folder: URL(fileURLWithPath: settings.notesDirectory)); show("Saved note: \(url.lastPathComponent)") }
        catch { show("Could not save note: \(error.localizedDescription)") }
    }
    @objc func clearTranscript() { guard !busy else { return }; lastText = ""; transcript.string = "" }
    func installHotkey() -> Bool {
        if tap != nil { return true }
        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue) | (1 << CGEventType.flagsChanged.rawValue)
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly, eventsOfInterest: CGEventMask(mask), callback: { _, type, event, data in
            if let data { Unmanaged<AppDelegate>.fromOpaque(data).takeUnretainedValue().keyEvent(type, event) }
            return Unmanaged.passUnretained(event)
        }, userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return false }
        self.tap = tap; tapSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), tapSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }
    func keyEvent(_ type: CGEventType, _ event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            cancelCapture(); if let tap { CGEvent.tapEnable(tap: tap, enable: true) }; return
        }
        guard window.attachedSheet == nil else { return }
        let code = event.getIntegerValueField(.keyboardEventKeycode)
        let keys = allowedHotkeys[settings.hotkey] ?? [54]
        if !keys.contains(code) {
            if gate.recording && (type == .keyDown || type == .flagsChanged) { gate.otherKey = true }
            return
        }
        let pressed = type == .keyDown || (type == .flagsChanged && modifierHotkeyIsDown(settings.hotkey, flags: event.flags.rawValue))
        if event.getIntegerValueField(.keyboardEventAutorepeat) != 0 { return }
        if pressed {
            guard gate.press(now: ProcessInfo.processInfo.systemUptime) else {
                let reason = !gate.approved ? "Session not approved" : !gate.ready ? "Transcription worker not ready" : gate.paused ? "Dictation paused" : "Already recording"
                show("Hotkey ignored: \(reason)")
                return
            }
            do {
                try recorder.start(); menuItem.button?.title = "● ZK"; show("Recording")
                if settings.beep { NSSound.beep() }
                recordingTimer = Timer.scheduledTimer(withTimeInterval: gate.maximumHold, repeats: false) { [weak self] _ in self?.cancelCapture(); self?.show("Recording reached 10-minute limit; discarded"); self?.updateControls() }
            } catch { gate.cancel(); show("Microphone error: \(error)") }
        } else if gate.recording {
            let accepted = gate.release(now: ProcessInfo.processInfo.systemUptime)
            recordingTimer?.invalidate(); recordingTimer = nil
            let audio = recorder.stop(discard: !accepted); menuItem.button?.title = "ZK"
            if settings.beep { NSSound.beep() }
            if let audio {
                show("Transcribing")
                outputSnapshot = settings
                submit(audio)
            } else { gate.ready = true; show("Recording discarded — hold at least \(gate.minimumHold)s without other keys") }
        }
        updateControls()
    }
    func cancelCapture() {
        gate.cancel(); _ = recorder.stop(discard: true)
        recordingTimer?.invalidate(); recordingTimer = nil
        menuItem.button?.title = "ZK"
    }
    func applicationWillTerminate(_ notification: Notification) {
        if window != nil { shutdownWorker() }; timer?.invalidate()
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
