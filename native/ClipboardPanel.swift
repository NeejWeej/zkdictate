import AppKit
import ImageIO

private final class ClipboardDocument: NSView {
    override var isFlipped: Bool { true }
}

final class ClipboardPreview: NSStackView {
    let detail = NSTextField(wrappingLabelWithString: "No backup")
    let preview = NSTextField(wrappingLabelWithString: "")
    let picture = NSImageView()
    let restore: NSButton
    private var shownID: UUID?

    init(title: String, target: AnyObject, action: Selector) {
        restore = NSButton(title: title, target: target, action: action)
        super.init(frame: .zero)
        orientation = .vertical; alignment = .leading; spacing = 6
        preview.maximumNumberOfLines = 3
        picture.imageScaling = .scaleProportionallyDown
        picture.heightAnchor.constraint(equalToConstant: 90).isActive = true
        picture.widthAnchor.constraint(equalToConstant: 240).isActive = true
        for view in [restore, detail, preview, picture] { addArrangedSubview(view) }
    }
    required init?(coder: NSCoder) { fatalError("Not used") }
    func update(_ backup: ClipboardBackup?, visible: Bool, seconds: Int, canRestore: Bool) {
        restore.isEnabled = canRestore
        detail.stringValue = backup == nil ? "No backup — not captured, expired, or cleared" : "Expires in \(seconds / 60)m \(seconds % 60)s"
        guard visible, let backup else {
            shownID = nil; preview.stringValue = ""; picture.image = nil
            preview.isHidden = true; picture.isHidden = true; return
        }
        guard shownID != backup.id else { return }
        shownID = backup.id; picture.image = nil; picture.isHidden = true
        preview.isHidden = false
        let items = backup.payload.items
        if items.isEmpty { preview.stringValue = "Empty clipboard"; return }
        let files = items.filter { $0[NSPasteboard.PasteboardType.fileURL.rawValue] != nil }
        if !files.isEmpty { preview.stringValue = "\(files.count) file reference(s). Files themselves are not backed up."; return }
        for item in items {
            for type in [NSPasteboard.PasteboardType.png.rawValue, NSPasteboard.PasteboardType.tiff.rawValue, "public.jpeg"] {
                if let data = item[type], let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
                   let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 256, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) {
                    picture.image = NSImage(cgImage: cgImage, size: .zero); picture.isHidden = false
                    preview.stringValue = "Image · \(items.count) clipboard item(s)"; return
                }
            }
        }
        if let data = items.first?[NSPasteboard.PasteboardType.string.rawValue] {
            preview.stringValue = String(decoding: data.prefix(2000), as: UTF8.self).prefix(300).description
        } else { preview.stringValue = "\(items.count) clipboard item(s), with original formats preserved" }
    }
}

final class ClipboardPane: NSObject {
    let view = NSScrollView()
    private var paneVisible = false
    private var enabledButton: NSButton!
    private var expiryPicker: NSPopUpButton!
    private var previewButton: NSButton!
    private var hideOnDeactivateButton: NSButton!
    private var status: NSTextField!
    private var operationMessage: String?
    private var last: ClipboardPreview!
    private var original: ClipboardPreview!
    private let manager: ClipboardManager
    private let settings: () -> AppSettings
    private let save: (AppSettings) -> Bool
    private let canInteract: () -> Bool
    private let durations = [1, 5, 15]

    init(manager: ClipboardManager, settings: @escaping () -> AppSettings, save: @escaping (AppSettings) -> Bool, canInteract: @escaping () -> Bool) {
        self.manager = manager; self.settings = settings; self.save = save; self.canInteract = canInteract
        super.init()
        build(); refresh()
    }
    func setVisible(_ visible: Bool) {
        paneVisible = visible
        if !visible { hidePreviews() } else { refresh() }
    }
    private func build() {
        enabledButton = NSButton(checkboxWithTitle: "Keep clipboard backups", target: self, action: #selector(changeSettings))
        expiryPicker = NSPopUpButton(); expiryPicker.addItems(withTitles: durations.map { "\($0) minute\($0 == 1 ? "" : "s")" })
        expiryPicker.target = self; expiryPicker.action = #selector(changeSettings)
        previewButton = NSButton(checkboxWithTitle: "Show previews", target: self, action: #selector(refresh))
        hideOnDeactivateButton = NSButton(checkboxWithTitle: "Hide previews when leaving the app", target: self, action: #selector(changePreviewPrivacy))
        let clear = NSButton(title: "Clear backups", target: self, action: #selector(clearBackups))
        last = ClipboardPreview(title: "Restore before last copy", target: self, action: #selector(restoreLast))
        original = ClipboardPreview(title: "Restore before dictation", target: self, action: #selector(restoreOriginal))
        let intro = NSTextField(wrappingLabelWithString: "Optional, memory-only backups before ZK Dictate copies text. Off by default. Clear on expiry, sleep, lock, or quit. Maximum 16 MB per backup.")
        let explanation = NSTextField(wrappingLabelWithString: "Before last copy: what was there just before our latest copy. Before dictation: the last content copied outside ZK Dictate. They can be the same.")
        status = NSTextField(wrappingLabelWithString: "")
        let options = NSStackView(views: [NSTextField(labelWithString: "Keep for:"), expiryPicker]); options.spacing = 10
        let actions = NSStackView(views: [previewButton, clear]); actions.spacing = 10
        let stack = NSStackView(views: [NSTextField(labelWithString: "Clipboard backups"), enabledButton, intro, options, actions, hideOnDeactivateButton, explanation, last, original, status])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 14; stack.translatesAutoresizingMaskIntoConstraints = false
        let scroll = view; scroll.hasVerticalScroller = true; scroll.translatesAutoresizingMaskIntoConstraints = false
        let document = ClipboardDocument(); document.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = document; document.addSubview(stack)
        NSLayoutConstraint.activate([
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: document.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -20)
        ])
    }
    @objc func refresh() {
        let preferences = settings()
        enabledButton.state = preferences.clipboardBackups ? .on : .off
        expiryPicker.selectItem(at: durations.firstIndex(of: preferences.clipboardMinutes) ?? 1)
        expiryPicker.isEnabled = preferences.clipboardBackups
        previewButton.isEnabled = preferences.clipboardBackups
        hideOnDeactivateButton.state = preferences.hidePreviewsOnDeactivate ? .on : .off
        if !preferences.clipboardBackups { previewButton.state = .off }
        let visible = previewButton.state == .on && paneVisible
        for (card, slot) in [(last!, ClipboardManager.Slot.lastCopy), (original!, .beforeDictation)] {
            let backup = manager.backup(slot)
            card.update(backup, visible: visible, seconds: backup.map(manager.remaining) ?? 0, canRestore: canInteract() && manager.canRestore(slot))
        }
        status.stringValue = manager.busy ? "Checking the clipboard…" : operationMessage ?? "Restore is available only while the clipboard still contains our latest copy or restore. Copying elsewhere disables restore."
    }
    @objc private func changeSettings() {
        operationMessage = nil
        var value = settings(); value.clipboardBackups = enabledButton.state == .on
        value.clipboardMinutes = durations[expiryPicker.indexOfSelectedItem]
        if save(value) { manager.configure(enabled: value.clipboardBackups, minutes: value.clipboardMinutes) }
        refresh()
    }
    @objc private func changePreviewPrivacy() {
        var value = settings(); value.hidePreviewsOnDeactivate = hideOnDeactivateButton.state == .on
        _ = save(value); refresh()
    }
    func applicationDidResignActive() {
        if settings().hidePreviewsOnDeactivate { hidePreviews() }
    }
    func hidePreviews() { previewButton?.state = .off; refresh() }
    @objc private func clearBackups() { operationMessage = nil; manager.clear(); hidePreviews() }
    @objc private func restoreLast() { restore(.lastCopy) }
    @objc private func restoreOriginal() { restore(.beforeDictation) }
    private func restore(_ slot: ClipboardManager.Slot) {
        guard canInteract() else { return }
        manager.restore(slot) { [weak self] result in
            switch result {
            case .success: self?.operationMessage = "Clipboard restored. The other backup is still available until it expires."
            case .failure(let error): self?.operationMessage = error.localizedDescription
            }
            self?.refresh()
        }
    }
}
