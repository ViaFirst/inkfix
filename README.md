# Inkfix

Fix and polish the text you are writing in **any** Mac app with one shortcut — Gmail, Outlook, WhatsApp,
Claude Code, Mail, Notes — using **your own Claude** (your Claude subscription through Claude Code, or an
Anthropic API key).

- **⌥⌘I** — a small popup next to your text shows the improved version with the changes highlighted.
  `↩` replaces, `⌘C` copies, `1`–`7` switch the mode, `⌘R` retries, `⌘D` toggles the changes view, `esc` cancels.
- **⇧⌥⌘I** — improves and replaces at once.
- Right click → **Services → Improve with Inkfix** in native apps.

Inkfix picks the style from the app you write in: business email in Mail, Outlook, Gmail;
chat style in WhatsApp, Telegram, Slack; a clear, structured **prompt** in Claude, ChatGPT and terminals.
Elsewhere the model decides. Modes: Auto, Fix errors, Business email, Messenger, AI prompt, Shorter, More polite.
The text stays in its language (English, Russian, Hebrew, mixed) — Inkfix never translates.

App UI: English, Russian, Hebrew.

## Install (build from source)

Requires macOS 14+, Xcode or the Swift toolchain.

```bash
git clone https://github.com/ViaFirst/inkfix.git
cd inkfix
./build.sh install     # builds, signs ad-hoc, installs to ~/Applications and launches
```

Then:

1. **Accessibility**: System Settings → Privacy & Security → Accessibility → turn on **Inkfix**.
   It is needed to read the selected text and paste the result back.
2. **Model** (menu-bar icon → Settings…):
   - **Claude Code (your subscription)** — install [Claude Code](https://claude.com/code), run `claude` once
     and sign in. Inkfix runs `claude -p` locally with no tools, so requests count against your own plan.
   - **Anthropic API key** — paid per use at console.anthropic.com, stored only in your Keychain.
3. Select some text anywhere and press ⌥⌘I.

## Privacy

Inkfix sends only the text you selected, the app name and window title (to pick the style) to the model you
chose. No telemetry, no history, no other network calls. Password fields are never read. Your clipboard is
saved and restored around copy/paste.

## Development

```bash
swift build && .build/debug/Inkfix --self-test        # logic tests
build/Inkfix.app/Contents/MacOS/Inkfix --render-test out.png [-AppleLanguages "(he)"]
build/Inkfix.app/Contents/MacOS/Inkfix --cli-test "текст с ашибками" fix   # one live request
Inkfix --trigger preview|instant                         # acts as if the shortcut was pressed
```

License: MIT.
