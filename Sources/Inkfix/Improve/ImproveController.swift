import AppKit
import Carbon
import SwiftUI

/// The whole flow: capture text → ask the model → preview (or replace at once) → put it back.
@MainActor
final class ImproveController {
    static let shared = ImproveController()

    private var panel: KeyPanel?
    private var model: PopupModel?
    private var captured: CapturedText?
    private var task: Task<Void, Never>?
    private var busy = false

    // MARK: Entry points

    func hotKey(_ action: HotKeys.Action) {
        guard !busy else { return }
        if panel != nil { close(); return }   // pressing the shortcut again closes the popup
        busy = true
        Task {
            defer { busy = false }
            do {
                let text = try await TextAccess.capture()
                switch action {
                case .preview: showPopup(for: text)
                case .instant: await instant(text)
                }
            } catch let error as CaptureError {
                report(error)
            } catch {
                Toast.shared.show(error.localizedDescription, symbol: "exclamationmark.triangle")
            }
        }
    }

    /// Text handed over by the Services menu (right click → Services → Improve with Inkfix).
    func service(text: String) {
        guard !text.isBlank else { return }
        if panel != nil { close() }
        let app = NSWorkspace.shared.frontmostApplication
        showPopup(for: CapturedText(text: text, source: .service, anchor: nil, app: app,
                                    context: AppContext.current(app: app)))
    }

    private func report(_ error: CaptureError) {
        switch error {
        case .noAccessibility:
            Permissions.requestAccessibility()
            let alert = NSAlert()
            alert.messageText = L("Inkfix needs Accessibility access")
            alert.informativeText = L("It reads the text you selected and pastes the improved version back. Turn Inkfix on in System Settings → Privacy & Security → Accessibility, then press the shortcut again.")
            alert.addButton(withTitle: L("Open System Settings"))
            alert.addButton(withTitle: L("Cancel"))
            NSApp.activate(ignoringOtherApps: true)
            if alert.runModal() == .alertFirstButtonReturn { Permissions.openSettings(.accessibility) }
        case .secureField:
            Toast.shared.show(L("Password fields are never read."), symbol: "lock.fill")
        case .nothingSelected:
            Toast.shared.show(L("Select the text first (⌘A selects all), then press the shortcut again."),
                              symbol: "text.cursor", duration: 3.5)
        }
    }

    // MARK: Instant mode

    private func instant(_ text: CapturedText) async {
        let mode = text.context.suggestedMode ?? .auto
        Toast.shared.show(String(format: L("Improving: %@…"), mode.title), spinning: true, near: text.anchor, duration: nil)
        do {
            let result = try await run(text: text.text, mode: mode, context: text.context) { _ in }
            if TextDiff.diff(text.text, result).map(TextDiff.changeCount) == 0 {
                Toast.shared.show(L("No changes needed"), symbol: "checkmark.seal", near: text.anchor)
                return
            }
            let pasted = await TextAccess.replace(text, with: result)
            Toast.shared.show(pasted ? L("Text improved") : L("Copied. Paste it with ⌘V."),
                              symbol: pasted ? "checkmark.circle.fill" : "doc.on.clipboard", near: text.anchor)
        } catch {
            Toast.shared.show(error.localizedDescription, symbol: "exclamationmark.triangle", near: text.anchor, duration: 5)
        }
    }

    // MARK: Popup

    private func showPopup(for text: CapturedText) {
        captured = text
        let replaceTitle = text.context.isTerminal ? L("Copy and close") : L("Replace")
        let model = PopupModel(original: text.text, context: text.context, showDiff: Settings.shared.showDiff,
                               replaceTitle: replaceTitle)
        self.model = model
        let host = NSHostingView(rootView: PopupView(model: model) { [weak self] in self?.handle($0) })
        host.sizingOptions = [.intrinsicContentSize]
        let panel = KeyPanel(content: host)
        panel.onKey = { [weak self] in self?.key($0) ?? false }
        panel.place(near: text.anchor)
        panel.makeKeyAndOrderFront(nil)
        self.panel = panel
        start()
    }

    private func start() {
        guard let model, let captured else { return }
        task?.cancel()
        model.result = ""
        model.status = .working
        let mode = model.effectiveMode
        task = Task { [weak self] in
            do {
                let result = try await self?.run(text: captured.text, mode: mode, context: captured.context) { delta in
                    Task { @MainActor in
                        guard let self, let model = self.model, model.status != .done else { return }
                        model.result += delta
                        model.status = .streaming
                        self.panel?.fitContent()
                    }
                } ?? ""
                guard !Task.isCancelled, let self, let model = self.model else { return }
                model.result = result
                model.status = .done
            } catch {
                guard !Task.isCancelled, let self, let model = self.model else { return }
                model.status = .failed(error.localizedDescription)
            }
            self?.panel?.fitContent()
        }
    }

    private func run(text: String, mode: Mode, context: AppContext,
                     onDelta: @escaping @Sendable (String) -> Void) async throws -> String {
        let provider = try Settings.shared.makeProvider().get()
        let reply = try await provider.improve(system: PromptBuilder.system(mode: mode),
                                               user: PromptBuilder.user(text: text, context: context),
                                               onDelta: onDelta)
        let cleaned = PromptBuilder.clean(reply, original: text)
        guard !cleaned.isBlank else { throw ProviderError(message: L("Claude returned an empty answer.")) }
        return cleaned
    }

    private func key(_ event: NSEvent) -> Bool {
        let cmd = event.modifierFlags.contains(.command)
        switch Int(event.keyCode) {
        case kVK_Return, kVK_ANSI_KeypadEnter: handle(.replace)
        case kVK_Escape: handle(.cancel)
        case kVK_ANSI_C where cmd: handle(.copy)
        case kVK_ANSI_R where cmd: handle(.retry)
        case kVK_ANSI_D where cmd: handle(.toggleDiff)
        case kVK_ANSI_W where cmd: handle(.cancel)
        default:
            let digits = [kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5, kVK_ANSI_6, kVK_ANSI_7]
            if !cmd, let i = digits.firstIndex(of: Int(event.keyCode)), i < Mode.pickable.count {
                handle(.mode(Mode.pickable[i]))
            } else if cmd {
                return false
            }
        }
        return true
    }

    private func handle(_ action: PopupAction) {
        guard let model else { return }
        switch action {
        case .cancel:
            close()
        case .retry:
            start()
        case .toggleDiff:
            model.showDiff.toggle()
            Settings.shared.showDiff = model.showDiff
            panel?.fitContent()
        case .mode(let mode):
            model.mode = mode
            start()
        case .copy:
            guard model.status == .done else { return }
            TextAccess.copyToClipboard(model.result)
            close()
            Toast.shared.show(L("Copied"), symbol: "doc.on.clipboard")
        case .replace:
            guard model.status == .done, let captured else { return }
            let result = model.result
            close()
            Task {
                let pasted = await TextAccess.replace(captured, with: result)
                if !pasted { Toast.shared.show(L("Copied. Paste it with ⌘V."), symbol: "doc.on.clipboard") }
            }
        }
    }

    private func close() {
        task?.cancel()
        task = nil
        panel?.orderOut(nil)
        panel = nil
        model = nil
    }
}
