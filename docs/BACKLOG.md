# Backlog

Agreed with the owner on 2026-11-17 as "next stages".

## Next
- **Translate mode** (EN ⇄ RU ⇄ HE), separate from improving; target language picker in the popup.
- **Custom modes**: user-written instructions, e.g. "how I write to clients" with examples of the owner's style.
- **Editable app rules**: which app / site title → which mode (now built in, see `AppContext`).
- **Claude Code in a terminal**: today the result is only copied (a terminal can't replace a selection).
  Idea: clear the prompt line (⌃U / ⌃A ⌃K) and type the result, opt-in per terminal.
- **Nothing selected in Chrome/Electron**: today the user selects first (AX doesn't expose the field there).
  Idea: ⌘A + ⌘C inside a focused text field when the role is known to be editable.

## Later
- Custom shortcut recorder (now: 4 presets).
- History of edits (off by default, retention limit) and "undo last replace".
- Faster Claude Code path: keep one `claude` process alive with `--input-format stream-json`.
- Developer ID signing + notarization + Sparkle updates when the Apple Developer Program is active.
- Local model provider (MLX/Ollama) for offline use.
