import Cocoa

/// Self-drawn candidate list. The controller owns the selection; this only draws it.
/// (IMKCandidates resets its selection on `update()` and fights programmatic control.)
final class CandidateWindow {
    static let pageSize = 9
    private let view = ListView()
    private lazy var panel: NSPanel = {
        let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        p.level = .popUpMenu
        p.hasShadow = true
        p.isOpaque = false
        p.backgroundColor = .clear
        p.contentView = view
        return p
    }()

    var isVisible: Bool { panel.isVisible }

    /// `caret`: screen rect of the marked text's first character.
    func show(_ items: [String], selected: Int, below caret: NSRect) {
        let page = selected / Self.pageSize * Self.pageSize
        view.items = Array(items[page..<min(page + Self.pageSize, items.count)])
        view.selected = selected - page
        let size = view.contentSize()
        var origin = NSPoint(x: caret.minX, y: caret.minY - size.height - 4)
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(caret.origin) }) ?? NSScreen.main {
            let v = screen.visibleFrame
            if origin.y < v.minY { origin.y = caret.maxY + 4 }  // no room below: show above
            origin.x = max(v.minX, min(origin.x, v.maxX - size.width))
        }
        panel.setFrame(NSRect(origin: origin, size: size), display: false)
        view.needsDisplay = true
        panel.orderFrontRegardless()
    }

    func hide() { panel.orderOut(nil) }
}

private final class ListView: NSView {
    var items: [String] = []
    var selected = 0
    private let font = NSFont.systemFont(ofSize: 15)
    private let numFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
    private let rowH: CGFloat = 24, pad: CGFloat = 4, textX: CGFloat = 24

    override var isFlipped: Bool { true }

    func contentSize() -> NSSize {
        let w = items.map { ($0 as NSString).size(withAttributes: [.font: font]).width }.max() ?? 0
        return NSSize(width: max(120, ceil(w) + textX + pad * 2 + 10), height: CGFloat(items.count) * rowH + pad * 2)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
        for (i, item) in items.enumerated() {
            let row = NSRect(x: pad, y: pad + CGFloat(i) * rowH, width: bounds.width - pad * 2, height: rowH)
            let on = i == selected
            if on {
                NSColor.selectedContentBackgroundColor.setFill()
                NSBezierPath(roundedRect: row, xRadius: 4, yRadius: 4).fill()
            }
            let fg: NSColor = on ? .alternateSelectedControlTextColor : .labelColor
            let sub: NSColor = on ? .alternateSelectedControlTextColor : .secondaryLabelColor
            ("\(i + 1)" as NSString).draw(at: NSPoint(x: row.minX + 6, y: row.minY + 5), withAttributes: [.font: numFont, .foregroundColor: sub])
            (item as NSString).draw(at: NSPoint(x: row.minX + textX, y: row.minY + 2), withAttributes: [.font: font, .foregroundColor: fg])
        }
    }
}
