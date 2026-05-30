# Sable

Sable is a macOS background app that edits selected text through Claude Code or Codex CLI.

## Build

```bash
make test
make build
```

`make build` creates `Sable.app` in the repo root. It builds release by default; use `make CONFIG=debug build` for a debug bundle.

Common targets:

```bash
make test
make build
make run
make install
```

`make install` copies the app to `/Applications/Sable.app` by default. Override the install directory with:

```bash
make install INSTALL_DIR=~/Applications
```

## Run

```bash
make run
```

The app opens a Sable window and also installs a menu bar item. Use the menu bar item to reopen the window, reload config, check permissions, clear history, or quit.

## Config

Sable reads config from:

```text
~/.config/sable/config.yaml
```

Runtime binary paths are stored separately and can be edited from the Sable window:

```text
~/.config/sable/runtime.json
```

Use `runtime.id` in `config.yaml` to select `claude` or `codex`. Leave a path blank in `runtime.json` to use PATH lookup.

The app requires Accessibility, Screen Recording, and Notifications permissions.

## Manual Verification

- TextEdit Quick Fix: select text, press `ctrl+option+cmd+k`, paste corrected text.
- TextEdit Ask Sable: select text, press `ctrl+option+cmd+j`, enter instruction, paste rewritten text.
- Slack/Notion fallback: select text, run Quick Fix, confirm the clipboard contains only edited text.
- Cancel path: open Ask Sable and press Escape, confirm the previous clipboard remains intact.
- History window: confirm each run appears with status, selected text, output, screenshot path, and a working Copy Output button.
