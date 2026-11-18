import Combine
import SwiftUI

/// Settings window: model backend, shortcut, behaviour, permissions.
struct SettingsView: View {
    @ObservedObject var settings: Settings
    @State private var apiKeyDraft = ""
    @State private var testOutput = ""
    @State private var testing = false
    @State private var accessibility = Permissions.hasAccessibility
    private let timer = Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            Section(L("Model")) {
                Picker(L("Use"), selection: $settings.provider) {
                    ForEach(ProviderKind.allCases) { Text($0.title).tag($0) }
                }
                if settings.provider == .claudeCode {
                    Picker(L("Model"), selection: $settings.cliModel) {
                        ForEach(ModelChoice.cli) { Text($0.title).tag($0.id) }
                    }
                    TextField(L("Path to claude"), text: $settings.cliPath, prompt: Text(L("Find automatically")))
                    Text(cliStatus).font(.caption).foregroundStyle(.secondary)
                } else {
                    Picker(L("Model"), selection: $settings.apiModel) {
                        ForEach(ModelChoice.api) { Text($0.title).tag($0.id) }
                    }
                    HStack {
                        SecureField(settings.hasAPIKey ? L("Key saved in Keychain") : "sk-ant-…", text: $apiKeyDraft)
                        Button(L("Save")) { settings.saveAPIKey(apiKeyDraft); apiKeyDraft = "" }
                            .disabled(apiKeyDraft.isBlank)
                        if settings.hasAPIKey {
                            Button(L("Remove")) { settings.saveAPIKey("") }
                        }
                    }
                    Text(L("Paid per use at console.anthropic.com. The key is stored only in your Mac's Keychain."))
                        .font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Button(L("Test")) { test() }.disabled(testing)
                    if testing { ProgressView().controlSize(.small) }
                    Text(testOutput).font(.caption).foregroundStyle(.secondary).lineLimit(3).textSelection(.enabled)
                }
            }

            Section(L("Shortcuts")) {
                Picker(L("Improve with preview"), selection: $settings.hotKeyId) {
                    ForEach(HotKeyPreset.all, id: \.id) { Text($0.title).tag($0.id) }
                }
                LabeledContent(L("Improve and replace at once"), value: settings.hotKey.instantTitle)
                Text(L("Also in the right-click menu: Services → Improve with Inkfix (native apps)."))
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section(L("Behaviour")) {
                Toggle(L("Show changes in the preview"), isOn: $settings.showDiff)
                Toggle(L("Launch at Login"), isOn: Binding(get: { settings.launchAtLogin },
                                                          set: { settings.launchAtLogin = $0 }))
            }

            Section(L("Permissions")) {
                HStack {
                    Image(systemName: accessibility ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(accessibility ? .green : .orange)
                    Text(accessibility ? L("Accessibility access is on") : L("Accessibility access is needed to read and replace text"))
                    Spacer()
                    if !accessibility {
                        Button(L("Open System Settings")) {
                            Permissions.requestAccessibility()
                            Permissions.openSettings(.accessibility)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        // The grouped Form is its own scroll view: let it fill the window and scroll, never size to all content.
        .frame(minWidth: 480, idealWidth: 520, minHeight: 320, idealHeight: 660)
        .onReceive(timer) { _ in accessibility = Permissions.hasAccessibility }
        .environment(\.layoutDirection, AppLayout.direction == .rightToLeft ? .rightToLeft : .leftToRight)
    }

    private var cliStatus: String {
        if let url = ClaudeCodeLocator.find(override: settings.cliPath) {
            return L("Found: ") + url.path
        }
        return L("Claude Code was not found. Install it (claude.com/code) or set its path in Settings.")
    }

    private func test() {
        testing = true
        testOutput = ""
        let started = Date()
        Task {
            defer { testing = false }
            do {
                let provider = try settings.makeProvider().get()
                let reply = try await provider.improve(system: PromptBuilder.system(mode: .fix),
                                                       user: PromptBuilder.user(text: L("Thsi is a smal test of Inkfix."), context: AppContext()),
                                                       onDelta: { _ in })
                testOutput = String(format: "%.1f s: ", Date().timeIntervalSince(started)) + reply
            } catch {
                testOutput = error.localizedDescription
            }
        }
    }
}
