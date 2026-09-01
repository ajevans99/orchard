import AppKit

@MainActor
final class OutlineController {
    private enum Metrics {
        static let margin: CGFloat = 4
        static let lineWidth: CGFloat = 3
        static let windowCornerRadius: CGFloat = 16
        static let tagGap: CGFloat = 6
        static let tagHorizontalInset: CGFloat = 12
    }

    private let outlinePanel: NSPanel
    private let tagPanel: NSPanel
    private let outlineView = OutlineView(
        lineWidth: Metrics.lineWidth,
        cornerRadius: Metrics.windowCornerRadius + Metrics.margin
    )
    private let tagView = TitleTagView()
    private var displayedColor: OrchardColor?
    private var displayedTitle: String?
    private var displayedWindowID: String?

    var onRename: ((String, String) -> Void)?
    var onSelectColor: ((String, OrchardColor) -> Void)?
    var onRemoveTag: ((String) -> Void)?

    init() {
        outlinePanel = Self.makePanel(ignoresMouseEvents: true)
        outlinePanel.contentView = outlineView

        tagPanel = Self.makePanel(ignoresMouseEvents: false)
        tagPanel.contentView = tagView

        tagView.onCommitTitle = { [weak self] title in
            guard let self, let windowID = self.displayedWindowID else { return }
            let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalizedTitle.isEmpty else {
                self.displayedTitle = nil
                self.tagPanel.orderOut(nil)
                self.onRename?(windowID, title)
                return
            }
            self.displayedTitle = normalizedTitle
            self.resizeTag(for: normalizedTitle)
            self.onRename?(windowID, title)
        }
        tagView.onSelectColor = { [weak self] color in
            guard let self, let windowID = self.displayedWindowID else { return }
            self.displayedColor = color
            self.outlineView.setColor(color.nsColor, animated: true)
            self.onSelectColor?(windowID, color)
        }
        tagView.onRemoveTag = { [weak self] in
            guard let self, let windowID = self.displayedWindowID else { return }
            self.hide()
            self.onRemoveTag?(windowID)
        }
    }

    func show(frame: CGRect, color: OrchardColor, title: String?, windowID: String) {
        guard frame.hasFinitePositiveSize else {
            hide()
            return
        }

        let outlineFrame = frame.insetBy(dx: -Metrics.margin, dy: -Metrics.margin)
        outlinePanel.setFrame(outlineFrame, display: false)

        let colorChanged = displayedColor != color
        let windowChanged = displayedWindowID != windowID
        outlineView.setColor(color.nsColor, animated: colorChanged)
        displayedColor = color
        displayedWindowID = windowID

        if !outlinePanel.isVisible {
            outlinePanel.orderFrontRegardless()
            outlineView.animateAppearance()
        }

        let normalizedTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let normalizedTitle, !normalizedTitle.isEmpty else {
            displayedTitle = nil
            tagPanel.orderOut(nil)
            return
        }

        let titleChanged = displayedTitle != normalizedTitle
        if titleChanged || colorChanged || windowChanged {
            tagView.configure(
                title: normalizedTitle,
                color: color,
                animated: titleChanged || colorChanged
            )
        }
        let tagSize = tagView.size(for: normalizedTitle)
        let tagOrigin = CGPoint(
            x: outlineFrame.minX + Metrics.tagHorizontalInset,
            y: outlineFrame.maxY + Metrics.tagGap
        )
        let tagFrame = CGRect(origin: tagOrigin, size: tagSize)
        guard tagFrame.hasFinitePositiveSize else {
            tagPanel.orderOut(nil)
            return
        }
        tagPanel.setFrame(tagFrame, display: false)

        if !tagPanel.isVisible {
            tagPanel.orderFrontRegardless()
            tagView.animateAppearance()
        }
        displayedTitle = normalizedTitle
    }

    private func resizeTag(for title: String) {
        let size = tagView.size(for: title)
        let frame = CGRect(origin: tagPanel.frame.origin, size: size)
        guard frame.hasFinitePositiveSize else { return }
        tagPanel.setFrame(frame, display: false)
    }

    func hide() {
        outlinePanel.orderOut(nil)
        tagPanel.orderOut(nil)
        displayedColor = nil
        displayedTitle = nil
        displayedWindowID = nil
    }

    private static func makePanel(ignoresMouseEvents: Bool) -> NSPanel {
        let panelType: NSPanel.Type = ignoresMouseEvents ? NSPanel.self : InteractiveTagPanel.self
        let panel = panelType.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = ignoresMouseEvents
        panel.becomesKeyOnlyIfNeeded = !ignoresMouseEvents
        panel.level = .floating
        panel.collectionBehavior = [.fullScreenAuxiliary, .transient]
        return panel
    }
}

private final class InteractiveTagPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private final class OutlineView: NSView {
    private let lineWidth: CGFloat
    private let cornerRadius: CGFloat
    private let glowLayer = CAShapeLayer()
    private let gradientLayer = CAGradientLayer()
    private let borderMask = CAShapeLayer()
    private var color = NSColor.systemGreen

    init(lineWidth: CGFloat, cornerRadius: CGFloat) {
        self.lineWidth = lineWidth
        self.cornerRadius = cornerRadius
        super.init(frame: .zero)

        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor

        glowLayer.fillColor = NSColor.clear.cgColor
        glowLayer.lineWidth = lineWidth + 2
        glowLayer.shadowRadius = 7
        glowLayer.shadowOpacity = 0.75
        glowLayer.shadowOffset = .zero
        layer?.addSublayer(glowLayer)

        gradientLayer.type = .conic
        gradientLayer.startPoint = CGPoint(x: 0.5, y: 0.5)
        gradientLayer.endPoint = CGPoint(x: 0.5, y: 0)

        borderMask.fillColor = NSColor.clear.cgColor
        borderMask.strokeColor = NSColor.white.cgColor
        borderMask.lineWidth = lineWidth
        gradientLayer.mask = borderMask
        layer?.addSublayer(gradientLayer)

        updateColors()
        startGradientAnimation()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()

        let strokeInset = lineWidth / 2
        let pathBounds = bounds.insetBy(dx: strokeInset, dy: strokeInset)
        let path = CGPath(
            roundedRect: pathBounds,
            cornerWidth: cornerRadius - strokeInset,
            cornerHeight: cornerRadius - strokeInset,
            transform: nil
        )

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        glowLayer.frame = bounds
        glowLayer.path = path
        gradientLayer.frame = bounds
        borderMask.frame = bounds
        borderMask.path = path
        CATransaction.commit()
    }

    func setColor(_ color: NSColor, animated: Bool) {
        guard self.color != color else { return }
        self.color = color

        if animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            let transition = CABasicAnimation(keyPath: "colors")
            transition.fromValue = gradientLayer.presentation()?.value(forKeyPath: "colors")
                ?? gradientLayer.colors
            transition.duration = 0.32
            transition.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            gradientLayer.add(transition, forKey: "colorTransition")

            let pulse = CAKeyframeAnimation(keyPath: "shadowOpacity")
            pulse.values = [0.75, 1, 0.75]
            pulse.keyTimes = [0, 0.4, 1]
            pulse.duration = 0.55
            glowLayer.add(pulse, forKey: "colorPulse")
        }

        updateColors()
    }

    func animateAppearance() {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }

        let animation = CASpringAnimation(keyPath: "opacity")
        animation.fromValue = 0
        animation.toValue = 1
        animation.mass = 0.7
        animation.stiffness = 180
        animation.damping = 18
        animation.duration = animation.settlingDuration
        layer?.add(animation, forKey: "appearance")
    }

    private func updateColors() {
        let resolvedColor = color.usingColorSpace(.deviceRGB) ?? color
        let brightColor = resolvedColor.blended(withFraction: 0.45, of: .white) ?? .white

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        glowLayer.strokeColor = resolvedColor.withAlphaComponent(0.72).cgColor
        glowLayer.shadowColor = resolvedColor.cgColor
        gradientLayer.colors = [
            resolvedColor.withAlphaComponent(0.45).cgColor,
            resolvedColor.cgColor,
            brightColor.cgColor,
            resolvedColor.cgColor,
            resolvedColor.withAlphaComponent(0.45).cgColor,
        ]
        gradientLayer.locations = [0, 0.22, 0.35, 0.52, 1]
        CATransaction.commit()
    }

    private func startGradientAnimation() {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }

        let animation = CAKeyframeAnimation(keyPath: "endPoint")
        animation.values = [
            CGPoint(x: 0.5, y: 0),
            CGPoint(x: 1, y: 0.5),
            CGPoint(x: 0.5, y: 1),
            CGPoint(x: 0, y: 0.5),
            CGPoint(x: 0.5, y: 0),
        ]
        animation.keyTimes = [0, 0.25, 0.5, 0.75, 1]
        animation.duration = 4.5
        animation.repeatCount = .infinity
        animation.timingFunction = CAMediaTimingFunction(name: .linear)
        gradientLayer.add(animation, forKey: "gradientFlow")
    }
}

private final class TitleTagView: NSView, NSTextFieldDelegate {
    private enum Layout {
        static let horizontalPadding: CGFloat = 12
        static let menuWidth: CGFloat = 24
        static let menuTrailingPadding: CGFloat = 5
    }

    private let textField = NSTextField()
    private let menuButton = NSButton()
    private var color = OrchardColor.green
    private var displayedTitle = ""
    private var isEditingTitle = false

    var onCommitTitle: ((String) -> Void)?
    var onSelectColor: ((OrchardColor) -> Void)?
    var onRemoveTag: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.borderWidth = 1
        layer?.shadowRadius = 6
        layer?.shadowOpacity = 0.35
        layer?.shadowOffset = CGSize(width: 0, height: -2)

        textField.isBordered = false
        textField.isBezeled = false
        textField.drawsBackground = false
        textField.isEditable = false
        textField.isSelectable = false
        textField.focusRingType = .none
        textField.font = .systemFont(ofSize: 12, weight: .semibold)
        textField.textColor = .white
        textField.lineBreakMode = .byClipping
        textField.maximumNumberOfLines = 1
        textField.delegate = self
        textField.target = self
        textField.action = #selector(commitEditing)
        textField.isHidden = true
        addSubview(textField)

        let symbolConfiguration = NSImage.SymbolConfiguration(
            pointSize: 13,
            weight: .semibold
        )
        menuButton.image = NSImage(
            systemSymbolName: "ellipsis",
            accessibilityDescription: "Tag options"
        )?.withSymbolConfiguration(symbolConfiguration)
        menuButton.title = ""
        menuButton.isBordered = false
        menuButton.imagePosition = .imageOnly
        menuButton.imageScaling = .scaleProportionallyDown
        menuButton.contentTintColor = .white
        menuButton.target = self
        menuButton.action = #selector(showContextMenu)
        menuButton.toolTip = "Tag options"
        addSubview(menuButton)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func mouseDown(with event: NSEvent) {
        beginEditing()
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard !isEditingTitle, !displayedTitle.isEmpty else { return }

        let font = textField.font ?? .systemFont(ofSize: 12, weight: .semibold)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.white,
        ]
        let textSize = (displayedTitle as NSString).size(withAttributes: attributes)
        let availableWidth = max(
            0,
            menuButton.frame.minX - Layout.horizontalPadding - 3
        )
        let textRect = NSRect(
            x: Layout.horizontalPadding,
            y: floor((bounds.height - textSize.height) / 2),
            width: min(textSize.width, availableWidth),
            height: textSize.height
        )
        (displayedTitle as NSString).draw(
            with: textRect,
            options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
            attributes: attributes
        )
    }

    func size(for title: String) -> NSSize {
        let font = textField.font ?? .systemFont(ofSize: 12, weight: .semibold)
        let textWidth = (title as NSString).size(
            withAttributes: [.font: font]
        ).width
        let chromeWidth = (Layout.horizontalPadding * 2)
            + Layout.menuWidth
            + Layout.menuTrailingPadding
        return NSSize(width: min(max(ceil(textWidth) + chromeWidth, 128), 520), height: 28)
    }

    override func layout() {
        super.layout()
        guard bounds.hasFinitePositiveSize else {
            textField.frame = .zero
            menuButton.frame = .zero
            return
        }

        menuButton.frame = NSRect(
            x: bounds.maxX - Layout.menuTrailingPadding - Layout.menuWidth,
            y: floor((bounds.height - Layout.menuWidth) / 2),
            width: Layout.menuWidth,
            height: Layout.menuWidth
        )
        textField.frame = NSRect(
            x: Layout.horizontalPadding,
            y: 0,
            width: max(
                0,
                menuButton.frame.minX - Layout.horizontalPadding - 3
            ),
            height: bounds.height - 6
        )
    }

    func configure(title: String, color: OrchardColor, animated: Bool) {
        if !isEditingTitle {
            displayedTitle = title
            textField.stringValue = title
            setAccessibilityLabel(title)
            needsDisplay = true
        }
        self.color = color
        updateColors()

        if animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            let pulse = CASpringAnimation(keyPath: "transform.scale")
            pulse.fromValue = 0.92
            pulse.toValue = 1
            pulse.mass = 0.6
            pulse.stiffness = 220
            pulse.damping = 16
            pulse.duration = pulse.settlingDuration
            layer?.add(pulse, forKey: "tagPulse")
        }
    }

    func animateAppearance() {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }

        let animation = CASpringAnimation(keyPath: "transform.scale")
        animation.fromValue = 0.72
        animation.toValue = 1
        animation.mass = 0.7
        animation.stiffness = 220
        animation.damping = 17
        animation.duration = animation.settlingDuration
        layer?.add(animation, forKey: "appearance")
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        finishEditing()
    }

    @objc private func beginEditing() {
        guard !isEditingTitle else { return }
        isEditingTitle = true
        textField.stringValue = displayedTitle
        textField.isEditable = true
        textField.isSelectable = true
        textField.isHidden = false
        needsDisplay = true
        window?.makeKey()
        window?.makeFirstResponder(textField)
        textField.currentEditor()?.selectAll(nil)
    }

    @objc private func commitEditing() {
        window?.makeFirstResponder(nil)
        finishEditing()
    }

    private func finishEditing() {
        guard isEditingTitle else { return }
        isEditingTitle = false
        displayedTitle = textField.stringValue
        textField.isEditable = false
        textField.isSelectable = false
        textField.isHidden = true
        setAccessibilityLabel(displayedTitle)
        needsDisplay = true
        onCommitTitle?(textField.stringValue)
    }

    @objc private func showContextMenu() {
        let menu = NSMenu()
        for orchardColor in OrchardColor.allCases {
            let item = NSMenuItem(
                title: orchardColor.displayName,
                action: #selector(selectColor(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = orchardColor.rawValue
            item.state = orchardColor == color ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())

        let removeItem = NSMenuItem(
            title: "Remove Tag",
            action: #selector(removeTag),
            keyEquivalent: ""
        )
        removeItem.target = self
        menu.addItem(removeItem)
        menu.popUp(
            positioning: nil,
            at: NSPoint(x: menuButton.bounds.minX, y: menuButton.bounds.minY),
            in: menuButton
        )
    }

    @objc private func selectColor(_ sender: NSMenuItem) {
        guard
            let rawValue = sender.representedObject as? String,
            let selectedColor = OrchardColor(rawValue: rawValue)
        else {
            return
        }
        color = selectedColor
        updateColors()
        onSelectColor?(selectedColor)
    }

    @objc private func removeTag() {
        onRemoveTag?()
    }

    private func updateColors() {
        let nsColor = color.nsColor
        let resolvedColor = nsColor.usingColorSpace(.deviceRGB) ?? nsColor
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.backgroundColor = resolvedColor.withAlphaComponent(0.92).cgColor
        layer?.borderColor = resolvedColor.blended(withFraction: 0.45, of: .white)?.cgColor
        layer?.shadowColor = resolvedColor.cgColor
        CATransaction.commit()
    }
}

private extension CGRect {
    var hasFinitePositiveSize: Bool {
        !isNull
            && !isInfinite
            && origin.x.isFinite
            && origin.y.isFinite
            && width.isFinite
            && height.isFinite
            && width > 0
            && height > 0
    }
}
