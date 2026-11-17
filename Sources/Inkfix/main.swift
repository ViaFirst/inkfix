import AppKit

MainActor.assumeIsolated {
    // `Inkfix --trigger preview|instant`: ask the running copy to act as if the shortcut was pressed.
    let args = CommandLine.arguments
    if let i = args.firstIndex(of: "--trigger") {
        let action = i + 1 < args.count ? args[i + 1] : "preview"
        DistributedNotificationCenter.default().postNotificationName(AppDelegate.triggerNotification, object: action,
                                                                     userInfo: nil, deliverImmediately: true)
        exit(0)
    }
    let app = NSApplication.shared
    if SelfTest.runIfRequested() {
        app.setActivationPolicy(.accessory)
        app.run()
    }
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
