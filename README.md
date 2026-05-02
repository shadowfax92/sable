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
