import AppKit

@MainActor
final class OutlineController {
    private let panel: NSPanel

    init() {
        panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.level = .floating
        panel.collectionBehavior = [.fullScreenAuxiliary, .transient]
        panel.contentView = OutlineView()
    }

    func show(frame: CGRect, color: NSColor) {
        let margin: CGFloat = 4
        panel.setFrame(frame.insetBy(dx: -margin, dy: -margin), display: true)
        (panel.contentView as? OutlineView)?.color = color
        panel.orderFrontRegardless()
    }

    func hide() {
        panel.orderOut(nil)
    }
}

private final class OutlineView: NSView {
    var color: NSColor = .systemGreen {
        didSet {
            layer?.borderColor = color.cgColor
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.borderWidth = 3
        layer?.borderColor = color.cgColor
        layer?.cornerRadius = 9
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
