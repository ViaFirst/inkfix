import AppKit
import Carbon
import SwiftUI

/// Floating panel that takes keyboard focus without activating Inkfix, so the app being edited
/// stays frontmost and keeps its selection.
final class KeyPanel: NSPanel {
    var onKey: ((NSEvent) -> Bool)?

    init(content: NSView) {
        super.init(contentRect: .zero, styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .statusBar
        hidesOnDeactivate = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        isMovableByWindowBackground = true
        contentView = content
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func keyDown(with event: NSEvent) {
        if onKey?(event) != true { super.keyDown(with: event) }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if onKey?(event) == true { return true }
        return super.performKeyEquivalent(with: event)
    }

    /// Places the panel below the anchor (or above when there is no room), on the anchor's screen.
    func place(near anchor: CGRect?) {
        guard let content = contentView else { return }
        let size = content.fittingSize
        let point = anchor.map { CGPoint(x: $0.minX, y: $0.minY) } ?? NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main ?? NSScreen.screens[0]
        let visible = screen.visibleFrame
        var origin = CGPoint(x: point.x, y: point.y - size.height - 8)
        if origin.y < visible.minY, let anchor { origin.y = anchor.maxY + 8 }
        origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - size.width - 8)
        origin.y = min(max(origin.y, visible.minY + 8), visible.maxY - size.height - 8)
        setFrame(CGRect(origin: origin, size: size), display: true)
    }

    /// Keeps the top edge in place while SwiftUI content grows (streaming text).
    func fitContent() {
        guard let content = contentView else { return }
        let size = content.fittingSize
        let top = frame.maxY
        var f = CGRect(x: frame.minX, y: top - size.height, width: size.width, height: size.height)
        if let visible = screen?.visibleFrame, f.minY < visible.minY + 8 { f.origin.y = visible.minY + 8 }
        setFrame(f, display: true)
    }
}

/// Small non-interactive message near the cursor: progress for instant mode, results and errors.
@MainActor
final class Toast {
    static let shared = Toast()
    private var panel: NSPanel?
    private var hideWork: DispatchWorkItem?

    func show(_ message: String, symbol: String = "drop.fill", spinning: Bool = false, near anchor: CGRect? = nil,
              duration: TimeInterval? = 2.2) {
        hideWork?.cancel()
        let view = NSHostingView(rootView: ToastView(message: message, symbol: symbol, spinning: spinning)
            .environment(\.layoutDirection, AppLayout.direction == .rightToLeft ? .rightToLeft : .leftToRight))
        let p = panel ?? {
            let p = NSPanel(contentRect: .zero, styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
            p.level = .statusBar
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = true
            p.ignoresMouseEvents = true
            p.hidesOnDeactivate = false
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
            return p
        }()
        panel = p
        p.contentView = view
        let size = view.fittingSize
        let point = anchor.map { CGPoint(x: $0.minX, y: $0.minY - 8) } ?? NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main ?? NSScreen.screens[0]
        let v = screen.visibleFrame
        let origin = CGPoint(x: min(max(point.x + 12, v.minX + 8), v.maxX - size.width - 8),
                             y: min(max(point.y - size.height - 12, v.minY + 8), v.maxY - size.height - 8))
        p.setFrame(CGRect(origin: origin, size: size), display: true)
        p.orderFrontRegardless()
        if let duration {
            let work = DispatchWorkItem { [weak self] in self?.hide() }
            hideWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
        }
    }

    func hide() {
        hideWork?.cancel()
        panel?.orderOut(nil)
    }
}

private struct ToastView: View {
    let message: String
    let symbol: String
    let spinning: Bool

    var body: some View {
        HStack(spacing: 8) {
            if spinning { ProgressView().controlSize(.small) } else { Image(systemName: symbol).foregroundStyle(.tint) }
            Text(message).font(.callout).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .frame(maxWidth: 380, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.separator.opacity(0.6)))
    }
}
