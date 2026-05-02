# Sable

Sable is a macOS background app that edits selected text through Claude Code CLI.

## Build

```bash
swift test
scripts/build-app.sh
```

## Run

```bash
scripts/run-debug.sh
```

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
