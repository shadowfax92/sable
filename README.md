# Sable

Sable is a macOS app that rewrites selected text through Claude Code or Codex CLI.
Select text in any app, press a shortcut, and a Superwhisper-style popup runs the
agent and drops the result on your clipboard.

## Build

```bash
make test
make build
```

`make build` creates `Sable.app` in the repo root (release by default; use
`make CONFIG=debug build` for a debug bundle).

Common targets:

```bash
make test
make build
make run
make install   # copies to /Applications/Sable.app
```

Override the install directory with `make install INSTALL_DIR=~/Applications`.

## Using Sable

Sable is a Dock app. Launching it opens the main window:

- **Home** — status, permissions, and a quick how-it-works.
- **Modes** — create and edit up to 6 reusable transformations. Each mode has its
  own instruction, harness (Claude/Codex), model, "ask for an instruction"
  toggle, and recordable keyboard shortcut.
- **History** — every run with its selected text, output, and status.
- **Settings** — the quick-popup shortcut, default popup mode, runtime binary
  paths, working directory, timeout, and live permission status.

### The popup

Trigger a mode's shortcut (or the quick-popup shortcut, seeded to `⌃⌥⌘Space` on
first launch) while text is selected. A floating popup shows the selection, an
instruction field, and a live `Thinking…` indicator. Press `⏎` to run, `esc` to
cancel. Instant modes (no instruction needed) run on open. The rewrite is copied
to your clipboard — paste it back with `⌘V`.

## Settings storage

Sable owns its settings as JSON, editable entirely from the app:

```text
~/.config/sable/settings.json
```

Keyboard shortcuts are stored by macOS (via the KeyboardShortcuts library) and
recorded inline in the Modes and Settings panes. Leave a runtime path blank to
use a `PATH` lookup.

## Permissions

- **Accessibility** (required) — lets Sable read the current selection.
- **Screen Recording** (optional) — adds a screenshot for visual context.

Grant both from the **Settings** pane; status refreshes live.

## Manual verification

- Select text in TextEdit, press `⌃⌥⌘Space`, type an instruction, press `⏎`, and
  paste the rewritten text.
- Create a "Fix Grammar" style instant mode, give it a shortcut, and confirm it
  runs on open with no typing.
- Press `esc` mid-run and confirm the original clipboard is restored.
- Confirm each run appears in History with status, selected text, and output.
