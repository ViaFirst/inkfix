import Carbon
import Foundation

/// A global shortcut: physical key code + Carbon modifier mask, so it works in any keyboard layout.
struct HotKeyPreset: Equatable {
    let id: String
    let title: String
    let keyCode: UInt32
    let modifiers: UInt32

    /// The preview shortcut. The instant shortcut is the same keys plus Shift.
    static let all: [HotKeyPreset] = [
        HotKeyPreset(id: "optcmd-i", title: "⌥⌘I", keyCode: UInt32(kVK_ANSI_I), modifiers: UInt32(cmdKey | optionKey)),
        HotKeyPreset(id: "ctrlopt-i", title: "⌃⌥I", keyCode: UInt32(kVK_ANSI_I), modifiers: UInt32(controlKey | optionKey)),
        HotKeyPreset(id: "optcmd-k", title: "⌥⌘K", keyCode: UInt32(kVK_ANSI_K), modifiers: UInt32(cmdKey | optionKey)),
        HotKeyPreset(id: "ctrlopt-space", title: "⌃⌥Space", keyCode: UInt32(kVK_Space), modifiers: UInt32(controlKey | optionKey)),
    ]

    static func preset(id: String) -> HotKeyPreset { all.first { $0.id == id } ?? all[0] }

    var instantTitle: String { "⇧" + title }
}

/// Global hotkeys via Carbon `RegisterEventHotKey` (no permission needed to listen).
@MainActor
final class HotKeys {
    enum Action: UInt32 { case preview = 1, instant = 2 }

    static var handler: ((Action) -> Void)?
    private static var installed = false
    private var refs: [EventHotKeyRef] = []

    private static func installHandler() {
        guard !installed else { return }
        installed = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            let raw = id.id
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if let action = Action(rawValue: raw) { HotKeys.handler?(action) }
                }
            }
            return noErr
        }, 1, &spec, nil, nil)
    }

    func register(_ preset: HotKeyPreset) {
        unregister()
        HotKeys.installHandler()
        let signature = OSType(0x494E_4B46) // 'INKF'
        for (action, mods) in [(Action.preview, preset.modifiers), (Action.instant, preset.modifiers | UInt32(shiftKey))] {
            var ref: EventHotKeyRef?
            let status = RegisterEventHotKey(preset.keyCode, mods, EventHotKeyID(signature: signature, id: action.rawValue),
                                             GetApplicationEventTarget(), 0, &ref)
            if status == noErr, let ref { refs.append(ref) } else { log.error("hotkey register failed: \(status)") }
        }
    }

    func unregister() {
        refs.forEach { UnregisterEventHotKey($0) }
        refs = []
    }
}
