import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate {
    static let isMenuBarApp = Bundle.main.object(forInfoDictionaryKey: "LSUIElement") as? Bool ?? false
    /// Posted by `Inkfix --trigger preview|instant` (testing from the shell, scripts, Shortcuts).
    static let triggerNotification = Notification.Name("com.viafirst.inkfix.trigger")

    private let settings = Settings.shared
    private let hotKeys = HotKeys()
    private let services = ServiceProvider()
    private var statusItem: NSStatusItem?
    private var settingsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenu.make()
        DispatchQueue.global(qos: .utility).async { _ = ClaudeCodeLocator.loginPath } // warm up off the main thread
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "drop.fill", accessibilityDescription: "Inkfix")
        item.button?.image?.isTemplate = true
        let menu = NSMenu()
        menu.delegate = self
        menu.userInterfaceLayoutDirection = AppLayout.direction
        item.menu = menu
        statusItem = item

        HotKeys.handler = { ImproveController.shared.hotKey($0) }
        hotKeys.register(settings.hotKey)
        settings.onHotKeyChange = { [weak self] in
            guard let self else { return }
            self.hotKeys.register(self.settings.hotKey)
        }

        NSApp.servicesProvider = services
        NSUpdateDynamicServices()

        DistributedNotificationCenter.default().addObserver(forName: Self.triggerNotification, object: nil, queue: .main) { note in
            let action: HotKeys.Action = (note.object as? String) == "instant" ? .instant : .preview
            MainActor.assumeIsolated { ImproveController.shared.hotKey(action) }
        }

        if !Permissions.hasAccessibility || UserDefaults.standard.object(forKey: "didOnboard") == nil {
            UserDefaults.standard.set(true, forKey: "didOnboard")
            showSettings()
        }
    }

    // MARK: Menu-bar menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        if !Permissions.hasAccessibility {
            menu.addItem(item("⚠︎ " + L("Allow Accessibility access…"), #selector(openAccessibility)))
            menu.addItem(.separator())
        }
        let preview = item(L("Improve Selected Text"), #selector(improvePreview))
        preview.toolTip = settings.hotKey.title
        menu.addItem(preview)
        let instant = item(L("Improve and Replace"), #selector(improveInstant))
        instant.toolTip = settings.hotKey.instantTitle
        menu.addItem(instant)
        let hint = NSMenuItem(title: String(format: L("Shortcuts: %@ preview, %@ replace at once"),
                                            settings.hotKey.title, settings.hotKey.instantTitle),
                              action: nil, keyEquivalent: "")
        hint.isEnabled = false
        menu.addItem(hint)
        menu.addItem(.separator())
        menu.addItem(item(L("Settings…"), #selector(openSettings), key: ","))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: L("Quit Inkfix"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.target = self
        return i
    }

    // From the menu the frontmost app is still the one being edited (the menu doesn't activate us).
    @objc private func improvePreview() { ImproveController.shared.hotKey(.preview) }
    @objc private func improveInstant() { ImproveController.shared.hotKey(.instant) }
    @objc private func openSettings() { showSettings() }
    @objc private func openAccessibility() {
        Permissions.requestAccessibility()
        Permissions.openSettings(.accessibility)
    }

    // MARK: Settings window

    func showSettings() {
        if settingsWindow == nil {
            let w = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 520, height: 520),
                             styleMask: [.titled, .closable], backing: .buffered, defer: false)
            w.title = L("Inkfix Settings")
            w.isReleasedWhenClosed = false
            let host = NSHostingView(rootView: SettingsView(settings: settings))
            host.sizingOptions = [.preferredContentSize]
            w.contentView = host
            w.center()
            w.delegate = self
            settingsWindow = w
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        NSApp.hide(nil)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings()
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

/// Services menu entry: right click → Services → Improve with Inkfix.
final class ServiceProvider: NSObject {
    @objc func improveText(_ pboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        guard let text = pboard.string(forType: .string) else { return }
        MainActor.assumeIsolated { ImproveController.shared.service(text: text) }
    }
}
