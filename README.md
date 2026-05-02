# Sable

Sable is a macOS background app that edits selected text through Claude Code CLI.

## Build

```bash
swift test
scripts/build-app.sh
```

You can also use `make`:

```bash
make test
make build
make run
make install
```

`make install` copies the app to `~/Applications/Sable.app` by default. Override the install directory with:

```bash
make install INSTALL_DIR=/Applications
```

## Run

```bash
scripts/run-debug.sh
```

The app opens a Sable window and also installs a menu bar item. Use the menu bar item to reopen the window, reload config, check permissions, clear history, or quit.

## Config

Sable reads config from:

```text
~/.config/sable/config.yaml
```

The app requires Accessibility, Screen Recording, and Notifications permissions.

## Manual Verification

- TextEdit Quick Fix: select text, press `ctrl+option+cmd+k`, paste corrected text.
- TextEdit Ask Claude: select text, press `ctrl+option+cmd+j`, enter instruction, paste rewritten text.
- Slack/Notion fallback: select text, run Quick Fix, confirm the clipboard contains only edited text.
- Cancel path: open Ask Claude and press Escape, confirm the previous clipboard remains intact.
- History window: confirm each run appears with status, selected text, output, screenshot path, and a working Copy Output button.
