import AppKit

/// A readable group with one heading, optional context, and generous spacing.
/// Setup groups can fold away without hiding their controls from font scaling.
final class InterfaceSection: NSBox {
    private let body: NSStackView
    private var disclosure: NSButton?
    private let heading: String

    init(_ title: String, caption: String? = nil, views: [NSView], collapsible: Bool = false) {
        heading = title
        body = NSStackView(views: views)
        super.init(frame: .zero)
        boxType = .custom; titlePosition = .noTitle; borderWidth = 1
        borderColor = .separatorColor; fillColor = .controlBackgroundColor
        cornerRadius = 12; contentViewMargins = .zero
        body.orientation = .vertical; body.alignment = .leading; body.spacing = 14
        var contents: [NSView] = []
        if collapsible {
            let button = NSButton(title: "▸ \(title)", target: self, action: #selector(toggle))
            button.isBordered = false; button.alignment = .left
            button.font = .boldSystemFont(ofSize: 17)
            button.toolTip = "Show or hide \(title.lowercased())"
            disclosure = button; contents.append(button); body.isHidden = true
        } else {
            let label = NSTextField(wrappingLabelWithString: title)
            label.font = .boldSystemFont(ofSize: 18); contents.append(label)
        }
        if let caption {
            let label = NSTextField(wrappingLabelWithString: caption)
            label.textColor = .secondaryLabelColor; contents.append(label)
        }
        contents.append(body)
        let stack = NSStackView(views: contents)
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 10
        stack.detachesHiddenViews = true; stack.translatesAutoresizingMaskIntoConstraints = false
        contentView!.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -18),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 18),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -18),
            body.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        for view in contents where view is NSTextField {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        for view in views where view is NSTextField || view is NSScrollView || view is NSStackView {
            view.widthAnchor.constraint(equalTo: body.widthAnchor).isActive = true
        }
    }
    required init?(coder: NSCoder) { fatalError("Not used") }
    @objc private func toggle() {
        body.isHidden.toggle()
        disclosure?.title = "\(body.isHidden ? "▸" : "▾") \(heading)"
    }
}
