import AppKit
import ApplicationServices
import ServiceManagement

/// User settings (UserDefaults; the API key lives in the keychain).
@MainActor
final class Settings: ObservableObject {
    static let shared = Settings()
    private let d = UserDefaults.standard

    enum Key {
        static let provider = "provider"
        static let cliModel = "cliModel"
        static let cliPath = "cliPath"
        static let apiModel = "apiModel"
        static let hotKey = "hotKey"
        static let showDiff = "showDiff"
    }

    @Published var provider: ProviderKind { didSet { d.set(provider.rawValue, forKey: Key.provider) } }
    @Published var cliModel: String { didSet { d.set(cliModel, forKey: Key.cliModel) } }
    @Published var cliPath: String { didSet { d.set(cliPath, forKey: Key.cliPath) } }
    @Published var apiModel: String { didSet { d.set(apiModel, forKey: Key.apiModel) } }
    @Published var hotKeyId: String { didSet { d.set(hotKeyId, forKey: Key.hotKey); onHotKeyChange?() } }
    @Published var showDiff: Bool { didSet { d.set(showDiff, forKey: Key.showDiff) } }
    @Published var hasAPIKey: Bool

    var onHotKeyChange: (() -> Void)?

    private init() {
        provider = ProviderKind(rawValue: d.string(forKey: Key.provider) ?? "") ?? .claudeCode
        cliModel = d.string(forKey: Key.cliModel) ?? "sonnet"
        cliPath = d.string(forKey: Key.cliPath) ?? ""
        apiModel = d.string(forKey: Key.apiModel) ?? "claude-opus-5-5"
        hotKeyId = d.string(forKey: Key.hotKey) ?? HotKeyPreset.all[0].id
        showDiff = d.object(forKey: Key.showDiff) as? Bool ?? true
        hasAPIKey = Keychain.load() != nil
    }

    var hotKey: HotKeyPreset { HotKeyPreset.preset(id: hotKeyId) }

    func saveAPIKey(_ key: String) {
        Keychain.save(key)
        hasAPIKey = Keychain.load() != nil
    }

    /// The configured provider, or an error message saying what is missing.
    func makeProvider() -> Result<TextProvider, ProviderError> {
        switch provider {
        case .claudeCode:
            guard let exe = ClaudeCodeLocator.find(override: cliPath) else {
                return .failure(ProviderError(message: L("Claude Code was not found. Install it (claude.com/code) or set its path in Settings.")))
            }
            return .success(ClaudeCodeProvider(executable: exe, model: cliModel))
        case .anthropicAPI:
            guard let key = Keychain.load() else {
                return .failure(ProviderError(message: L("No API key yet. Add one in Settings.")))
            }
            return .success(AnthropicAPIProvider(apiKey: key, model: apiModel))
        }
    }

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            objectWillChange.send()
            do { if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } }
            catch { NSAlert(error: error).runModal() }
        }
    }
}

extension Permissions {
    static var hasAccessibility: Bool { AXIsProcessTrusted() }

    /// Shows the system prompt (adds the app to the Accessibility list) without blocking.
    static func requestAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }
}
