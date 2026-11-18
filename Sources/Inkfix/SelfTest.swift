import AppKit
import SwiftUI

/// Command-line self-tests, so the app can be verified without clicking it:
///   Inkfix --self-test                   logic checks, PASS/FAIL lines, exit 1 on failure
///   Inkfix --render-test <out.png>       renders the preview popup (sample text) into a PNG
///   Inkfix --render-settings <out.png>   renders the Settings window into a PNG
///   Inkfix --cli-test "<text>" [mode]    one real request through the configured provider (prints reply + time)
@MainActor
enum SelfTest {
    static func runIfRequested() -> Bool {
        let args = CommandLine.arguments
        if args.contains("--self-test") { selfTest() }
        if let i = args.firstIndex(of: "--render-test"), i + 1 < args.count {
            render(popupSample(), size: nil, out: args[i + 1])
            return true
        }
        if let i = args.firstIndex(of: "--render-settings"), i + 1 < args.count {
            render(AnyView(SettingsView(settings: Settings.shared)), size: CGSize(width: 520, height: 660), out: args[i + 1])
            return true
        }
        if let i = args.firstIndex(of: "--cli-test"), i + 1 < args.count {
            let mode = i + 2 < args.count ? Mode(rawValue: args[i + 2]) ?? .auto : .auto
            liveTest(text: args[i + 1], mode: mode)
            return true
        }
        return false
    }

    private static var failures = 0
    private static func check(_ ok: Bool, _ message: String) {
        print(ok ? "PASS" : "FAIL", message)
        if !ok { failures += 1 }
    }

    private static func selfTest() {
        check(Bundle.main.bundleIdentifier == nil || Bundle.main.bundleIdentifier == "com.viafirst.inkfix", "bundle id")

        // Context detection
        func ctx(_ id: String, _ title: String? = nil) -> AppContext { AppContext(bundleId: id, appName: nil, windowTitle: title) }
        check(ctx("com.google.Chrome", "Inbox (3) - me@gmail.com - Gmail").suggestedMode == .email, "Gmail in Chrome → email")
        check(ctx("com.google.Chrome", "Mail - Dana Levi - Outlook").suggestedMode == .email, "Outlook web → email")
        check(ctx("com.google.Chrome", "(2) WhatsApp").suggestedMode == .messenger, "WhatsApp web → messenger")
        check(ctx("net.whatsapp.WhatsApp").suggestedMode == .messenger, "WhatsApp app → messenger")
        check(ctx("com.anthropic.claudefordesktop").suggestedMode == .prompt, "Claude app → prompt")
        check(ctx("com.apple.Terminal").suggestedMode == .prompt && ctx("com.apple.Terminal").isTerminal, "Terminal → prompt, copy only")
        check(ctx("com.google.Chrome", "Claude").suggestedMode == .prompt, "claude.ai → prompt")
        check(ctx("com.google.Chrome", "Wikipedia").suggestedMode == nil, "other site → model decides")
        check(ctx("com.apple.TextEdit").suggestedMode == nil, "TextEdit → model decides")

        // Prompt
        let sys = PromptBuilder.system(mode: .email)
        check(sys.contains("Never translate") && sys.contains("business email"), "system prompt has rules + mode")
        let user = PromptBuilder.user(text: "hi", context: ctx("com.google.Chrome", "Gmail"))
        check(user.contains("<text>\nhi\n</text>") && user.contains("<context>"), "user message wraps text and context")
        check(Mode.allCases.allSatisfy { !$0.instruction.isEmpty && !$0.title.isEmpty }, "every mode has an instruction")

        // Cleanup of replies
        check(PromptBuilder.clean("\"Привет!\"", original: "привет") == "Привет!", "strips added quotes")
        check(PromptBuilder.clean("\"Hi\" he said", original: "\"hi\" he said") == "\"Hi\" he said", "keeps quotes the original had")
        check(PromptBuilder.clean("<text>\nFixed\n</text>", original: "fixd") == "Fixed", "strips echoed tags")
        check(PromptBuilder.clean("```\ncode fixed\n```", original: "code fxd") == "code fixed", "strips added fences")
        check(PromptBuilder.clean("Fixed", original: "fixd\n") == "Fixed\n", "keeps trailing newline")

        // Diff
        let ops = TextDiff.diff("я хочу сказть что завтра немогу", "Я хочу сказать, что завтра не могу.") ?? []
        check(ops.contains(.removed("сказть")) && ops.contains(.added("сказать,")) && ops.contains(.same(" что завтра ")), "word diff finds changed words")
        check(TextDiff.changeCount(TextDiff.diff("same text", "same text") ?? []) == 0, "no changes → 0")
        let rebuilt = ops.reduce("") { s, op in if case .removed = op { return s }; if case .same(let t) = op { return s + t }; if case .added(let t) = op { return s + t }; return s }
        check(rebuilt == "Я хочу сказать, что завтра не могу.", "diff rebuilds the new text")
        check(TextDirection.of("שלום, מה שלומך?") == .rightToLeft && TextDirection.of("Привет") == .leftToRight, "text direction")

        // Stream parsers (recorded shapes)
        let delta = #"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Привет!"}},"session_id":"x"}"#
        check(StreamParsers.claudeCodeLine(delta) == .delta("Привет!"), "claude stream-json delta")
        let result = #"{"type":"result","subtype":"success","is_error":false,"result":"Done."}"#
        check(StreamParsers.claudeCodeLine(result) == .final("Done."), "claude stream-json result")
        let err = #"{"type":"result","subtype":"error","is_error":true,"result":"Not logged in · Please run /login"}"#
        check(StreamParsers.claudeCodeLine(err) == .error("Not logged in · Please run /login"), "claude stream-json error")
        check(ClaudeCodeProvider.friendly("Not logged in · Please run /login").contains("claude"), "login error explained")
        check(StreamParsers.sseLine(#"data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hi"}}"#) == .delta("Hi"), "SSE delta")
        check(StreamParsers.sseLine(#"data: {"type":"message_delta","delta":{"stop_reason":"refusal"}}"#) == .refusal, "SSE refusal")
        check(StreamParsers.sseLine("event: ping") == .none, "SSE ignores event lines")
        let body = AnthropicAPIProvider.body(model: "claude-opus-5-5", system: "s", user: "u")
        check(body["fallbacks"] as? String == "default" && body["stream"] as? Bool == true, "API body: stream + fallback")
        check(AnthropicAPIProvider.body(model: "claude-haiku-5-5", system: "s", user: "u")["fallbacks"] == nil, "no fallback on Haiku")

        // StreamState line splitting across chunks
        let state = StreamState()
        let a = state.lines(Data("{\"a\":1}\n{\"b\"".utf8)), b = state.lines(Data(":2}\n".utf8))
        check(a == ["{\"a\":1}"] && b == ["{\"b\":2}"], "line splitting across chunks")

        // Pasteboard snapshot round trip (private pasteboard, never the user's clipboard)
        let pb = NSPasteboard(name: NSPasteboard.Name("com.viafirst.inkfix.selftest"))
        pb.clearContents()
        pb.setString("original", forType: .string)
        pb.setData(Data([1, 2, 3]), forType: NSPasteboard.PasteboardType("com.viafirst.test"))
        let snap = PasteboardSnapshot(pb)
        pb.clearContents()
        pb.setString("temporary", forType: .string)
        snap.restore(pb)
        check(pb.string(forType: .string) == "original" && pb.data(forType: NSPasteboard.PasteboardType("com.viafirst.test")) == Data([1, 2, 3]),
              "pasteboard snapshot restores all types")
        pb.releaseGlobally()

        // Hotkeys
        check(Set(HotKeyPreset.all.map(\.id)).count == HotKeyPreset.all.count, "hotkey ids unique")
        check(HotKeyPreset.preset(id: "nope") == HotKeyPreset.all[0], "unknown hotkey falls back")

        print("layout:", AppLayout.direction == .rightToLeft ? "rtl" : "ltr")
        print(failures == 0 ? "ALL PASS" : "\(failures) FAILED")
        exit(failures == 0 ? 0 : 1)
    }

    private static func popupSample() -> AnyView {
        let lang = Bundle.main.preferredLocalizations.first ?? "en"
        let (original, result, ctx): (String, String, AppContext) = {
            switch lang {
            case "he": return ("היי, אני לא יכול מחר לבוא אפשר לדחות ליום חמישי?",
                               "היי, אני לא אוכל להגיע מחר. אפשר לדחות ליום חמישי?",
                               AppContext(bundleId: "net.whatsapp.WhatsApp", appName: "WhatsApp", windowTitle: nil))
            case "ru": return ("Добрый день, я хотел уточнить по поводу счета который вы прислали вчера, там ошибка в сумме",
                               "Добрый день! Хотел уточнить по поводу счёта, который вы прислали вчера: в нём ошибка в сумме.",
                               AppContext(bundleId: "com.google.Chrome", appName: "Google Chrome", windowTitle: "Inbox - Gmail"))
            default: return ("hi, i wanted to ask about the invoice you sent yesterday, theres a mistake in the amount",
                             "Hi, I wanted to ask about the invoice you sent yesterday: there's a mistake in the amount.",
                             AppContext(bundleId: "com.google.Chrome", appName: "Google Chrome", windowTitle: "Inbox - Gmail"))
            }
        }()
        let model = PopupModel(original: original, context: ctx, showDiff: true, replaceTitle: L("Replace"))
        model.result = result
        model.status = .done
        return AnyView(PopupView(model: model) { _ in }.padding(20))
    }

    private static func liveTest(text: String, mode: Mode) {
        let started = Date()
        Task { @MainActor in
            do {
                let provider = try Settings.shared.makeProvider().get()
                let reply = try await provider.improve(system: PromptBuilder.system(mode: mode),
                                                       user: PromptBuilder.user(text: text, context: AppContext()),
                                                       onDelta: { _ in })
                print(String(format: "time: %.2f s", Date().timeIntervalSince(started)))
                print(PromptBuilder.clean(reply, original: text))
                exit(0)
            } catch {
                print("ERROR:", error.localizedDescription)
                exit(1)
            }
        }
    }

    /// SwiftUI draws in layers `cacheDisplay` misses: show the view in a real window (below the desktop),
    /// let it render, then draw its layer tree at 2x.
    private static func render(_ root: AnyView, size: CGSize?, out: String) {
        let view = NSHostingView(rootView: root)
        let fitting = size ?? view.fittingSize
        view.sizingOptions = []
        let window = NSWindow(contentRect: CGRect(origin: NSScreen.screens.first?.frame.origin ?? .zero, size: fitting),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) - 1)
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.orderFrontRegardless()
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 800_000_000)
            let scale: CGFloat = 2
            guard let layer = view.layer,
                  let ctx = CGContext(data: nil, width: Int(fitting.width * scale), height: Int(fitting.height * scale),
                                      bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue) else { exit(1) }
            ctx.setFillColor(NSColor.windowBackgroundColor.cgColor)
            ctx.fill(CGRect(origin: .zero, size: CGSize(width: fitting.width * scale, height: fitting.height * scale)))
            ctx.scaleBy(x: scale, y: scale)
            ctx.translateBy(x: 0, y: fitting.height)
            ctx.scaleBy(x: 1, y: -1)
            layer.render(in: ctx)
            let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out))
            print("wrote", out, "layout:", AppLayout.direction == .rightToLeft ? "rtl" : "ltr")
            exit(0)
        }
    }
}
