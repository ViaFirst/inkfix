import AppKit
import ApplicationServices
import Carbon

/// Where the text came from and how to put the result back.
struct CapturedText {
    enum Source { case selection, wholeField, service }

    var text: String
    var source: Source
    /// Caret/selection rectangle in Cocoa screen coordinates (bottom-left origin), if known.
    var anchor: CGRect?
    var app: NSRunningApplication?
    var context: AppContext
}

enum CaptureError: Error {
    case noAccessibility, secureField, nothingSelected
}

/// Reads the selection of the focused app and writes the result back.
/// Accessibility API first; the clipboard (⌘C / ⌘V, saved and restored) where AX can't help (Chrome, Electron).
@MainActor
enum TextAccess {
    static let textRoles: Set<String> = [kAXTextAreaRole, kAXTextFieldRole, kAXComboBoxRole, "AXSearchField"]

    static func capture() async throws -> CapturedText {
        guard Permissions.hasAccessibility else { throw CaptureError.noAccessibility }
        await waitForModifiersRelease()

        let app = NSWorkspace.shared.frontmostApplication
        let element = focusedElement(app: app)
        let context = AppContext.current(app: app)

        if let element, string(element, kAXSubroleAttribute) == kAXSecureTextFieldSubrole {
            throw CaptureError.secureField
        }
        let anchor = element.flatMap(selectionRect)

        log.notice("capture in \(app?.bundleIdentifier ?? "?", privacy: .public), focused role \(element.flatMap { string($0, kAXRoleAttribute) } ?? "none", privacy: .public)")
        if let element, let selected = string(element, kAXSelectedTextAttribute), !selected.isBlank {
            return CapturedText(text: selected, source: .selection, anchor: anchor, app: app, context: context)
        }
        if let copied = await copySelection(), !copied.isBlank {
            return CapturedText(text: copied, source: .selection, anchor: anchor, app: app, context: context)
        }
        if let element, textRoles.contains(string(element, kAXRoleAttribute) ?? ""),
           let value = string(element, kAXValueAttribute), !value.isBlank {
            return CapturedText(text: value, source: .wholeField, anchor: anchor, app: app, context: context)
        }
        throw CaptureError.nothingSelected
    }

    /// Puts `text` in place of the captured text in its app. Terminals only get it on the clipboard.
    /// Returns false when the text was only copied.
    @discardableResult
    static func replace(_ captured: CapturedText, with text: String) async -> Bool {
        if captured.context.isTerminal {
            copyToClipboard(text)
            return false
        }
        if let app = captured.app {
            // Our popup held the keyboard focus; hand it back to the edited app's window and give it a
            // moment to restore its focused field and selection before pasting.
            if app != NSWorkspace.shared.frontmostApplication || !app.isActive { app.activate() }
            for _ in 0..<20 where NSWorkspace.shared.frontmostApplication != app {
                try? await Task.sleep(nanoseconds: 25_000_000)
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        let target = focusedElement(app: captured.app)
        log.notice("replace (\(String(describing: captured.source), privacy: .public)) into \(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "?", privacy: .public), focused role \(target.flatMap { string($0, kAXRoleAttribute) } ?? "none", privacy: .public), selection \(target.flatMap { string($0, kAXSelectedTextAttribute) }?.count ?? -1, privacy: .public) chars")
        await waitForModifiersRelease()
        let pb = NSPasteboard.general
        let saved = PasteboardSnapshot(pb)
        pb.clearContents()
        pb.setString(text, forType: .string)
        pb.setData(Data(), forType: PasteboardSnapshot.transientType)
        if captured.source == .wholeField {
            Keys.press(kVK_ANSI_A, flags: .maskCommand)
            try? await Task.sleep(nanoseconds: 60_000_000)
        }
        Keys.press(kVK_ANSI_V, flags: .maskCommand)
        // Give the target app time to read the pasteboard before restoring the user's clipboard.
        try? await Task.sleep(nanoseconds: 450_000_000)
        saved.restore(pb)
        return true
    }

    static func copyToClipboard(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    // MARK: Clipboard copy

    private static func copySelection() async -> String? {
        let pb = NSPasteboard.general
        let saved = PasteboardSnapshot(pb)
        pb.clearContents()
        let before = pb.changeCount
        Keys.press(kVK_ANSI_C, flags: .maskCommand)
        var copied: String?
        for _ in 0..<20 {
            try? await Task.sleep(nanoseconds: 20_000_000)
            if pb.changeCount != before { copied = pb.string(forType: .string); break }
        }
        saved.restore(pb)
        return copied
    }

    /// The hotkey fires on key down; posted ⌘C/⌘V must not merge with the still-held ⌥/⇧.
    private static func waitForModifiersRelease() async {
        for _ in 0..<40 {
            let flags = CGEventSource.flagsState(.combinedSessionState)
            if !flags.contains(.maskAlternate), !flags.contains(.maskShift), !flags.contains(.maskControl), !flags.contains(.maskCommand) { return }
            try? await Task.sleep(nanoseconds: 15_000_000)
        }
    }

    // MARK: Accessibility helpers

    static func focusedElement(app: NSRunningApplication?) -> AXUIElement? {
        if let app {
            // Chromium/Electron build their accessibility tree only when asked.
            let appElement = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetAttributeValue(appElement, "AXManualAccessibility" as CFString, kCFBooleanTrue)
            if let el = element(appElement, kAXFocusedUIElementAttribute) { return el }
        }
        return element(AXUIElementCreateSystemWide(), kAXFocusedUIElementAttribute)
    }

    static func focusedWindowTitle(app: NSRunningApplication?) -> String? {
        guard let app else { return nil }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        guard let window = element(appElement, kAXFocusedWindowAttribute) else { return nil }
        return string(window, kAXTitleAttribute)
    }

    private static func element(_ el: AXUIElement, _ attr: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &value) == .success, let value,
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    static func string(_ el: AXUIElement, _ attr: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private static func selectionRect(_ el: AXUIElement) -> CGRect? {
        var rangeValue: CFTypeRef?
        var rect = CGRect.null
        if AXUIElementCopyAttributeValue(el, kAXSelectedTextRangeAttribute as CFString, &rangeValue) == .success,
           let rangeValue {
            var boundsValue: CFTypeRef?
            if AXUIElementCopyParameterizedAttributeValue(el, kAXBoundsForRangeParameterizedAttribute as CFString,
                                                          rangeValue, &boundsValue) == .success,
               let boundsValue, CFGetTypeID(boundsValue) == AXValueGetTypeID() {
                AXValueGetValue(boundsValue as! AXValue, .cgRect, &rect)
            }
        }
        if rect.isNull || rect.isEmpty && rect.origin == .zero {
            var pos = CGPoint.zero, size = CGSize.zero
            var p: CFTypeRef?, s: CFTypeRef?
            guard AXUIElementCopyAttributeValue(el, kAXPositionAttribute as CFString, &p) == .success,
                  AXUIElementCopyAttributeValue(el, kAXSizeAttribute as CFString, &s) == .success,
                  let p, let s else { return nil }
            AXValueGetValue(p as! AXValue, .cgPoint, &pos)
            AXValueGetValue(s as! AXValue, .cgSize, &size)
            // Very tall fields (whole editors): anchor to their top edge only.
            rect = CGRect(origin: pos, size: CGSize(width: size.width, height: min(size.height, 40)))
        }
        return ScreenGeometry.cocoaRect(fromAX: rect)
    }
}

enum ScreenGeometry {
    /// AX uses a top-left origin on the primary screen; Cocoa uses bottom-left.
    static func cocoaRect(fromAX rect: CGRect) -> CGRect {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }
}

/// Posts keyboard events with explicit flags from a private source, so held keys don't leak in.
enum Keys {
    static func press(_ keyCode: Int, flags: CGEventFlags) {
        let source = CGEventSource(stateID: .privateState)
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(keyCode), keyDown: down)
            event?.flags = flags
            event?.post(tap: .cgAnnotatedSessionEventTap)
        }
    }
}

/// A full copy of the pasteboard (every item, every type) to put back after we borrowed it.
struct PasteboardSnapshot {
    /// nspasteboard.org convention: clipboard managers skip items marked transient.
    static let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")

    let items: [[NSPasteboard.PasteboardType: Data]]

    init(_ pb: NSPasteboard) {
        items = (pb.pasteboardItems ?? []).map { item in
            var dict: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types { if let data = item.data(forType: type) { dict[type] = data } }
            return dict
        }
    }

    func restore(_ pb: NSPasteboard) {
        pb.clearContents()
        guard !items.isEmpty else { return }
        let restored = items.map { dict -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in dict { item.setData(data, forType: type) }
            return item
        }
        pb.writeObjects(restored)
    }
}

extension String {
    var isBlank: Bool { trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}
