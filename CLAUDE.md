# Inkfix — notes for Claude

- Built to the **mac-app** standard (`~/.claude/skills/mac-app`): run `/mac-app Inkfix audit`
  before larger changes; follow its invariants (EN + RU + HE via `L()`, key codes for shortcuts,
  self-tests, stable signing, CHANGELOG + `scripts/bump-version.sh`).
- The folder is still named `ImproveMyText` (working name); the app, module and repo are **Inkfix**.
- Distribution channel: personal / build from source (public GitHub ViaFirst/inkfix, MIT). Not App Store:
  it needs Accessibility (reading selections, posting ⌘C/⌘V), which the sandbox forbids.
- Build/install: `./build.sh install`. Tests: `--self-test`, `--render-test <png>`, `--render-settings <png>`,
  `--cli-test "<text>" [mode]` (live), `--trigger preview|instant` (acts as the shortcut on the running copy).
- End-to-end check without clicking: run the built binary from the shell (it inherits the shell host's
  Accessibility), put text in TextEdit via `osascript`, select it, `Inkfix --trigger instant`, read the text back.
- Providers: `ClaudeCodeProvider` runs `claude -p` (no tools, no settings/MCP, stream-json) = the user's own
  subscription; `AnthropicAPIProvider` = raw HTTPS streaming, key in Keychain, `anthropic-version: 2026-10-21`.
- Modes and app→mode rules: `Improve/Modes.swift`. Backlog: `docs/BACKLOG.md`.
