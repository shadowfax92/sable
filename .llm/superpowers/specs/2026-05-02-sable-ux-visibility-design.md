# Sable UX Visibility Design

## Summary

Sable needs a visible operational surface. Hotkeys should still be the primary workflow, but the user must be able to tell whether Sable is configured, whether permissions are granted, whether a run is currently capturing or calling Claude, and what output was copied.

## Goals

- Add a main Sable window opened from the menu bar and shown on launch.
- Persist recent run history locally so the user can inspect input, instruction, status, errors, and output.
- Show the current run state in both the main window and menu bar title.
- Add explicit copy-output and clear-history controls.
- Keep hotkey behavior unchanged: Quick Fix and Ask Claude still copy final output to clipboard.
- Improve debugging visibility when notifications are unavailable or denied.

## Non-Goals

- No rich text preservation.
- No screenshot thumbnails in this pass.
- No cloud sync.
- No auto-paste or auto-replace.

## UX

The main window has three areas:

- Status: config path/load state, permission state, current run state.
- History list: timestamp, status, and instruction preview.
- Details: selected text, instruction, screenshot path, output, error, copy output button.

The menu bar item exposes:

- Open Sable
- Reload Config
- Check Permissions
- Clear History
- Quit

During a run, Sable updates the current run through:

1. Capturing
2. Running Claude
3. Copied
4. Failed or Cancelled

## Storage

Persist history at:

```text
~/Library/Application Support/Sable/history.json
```

Keep the newest 50 records. Each record stores:

- id
- createdAt
- completedAt
- status
- instruction
- selectedText
- screenshotPath
- outputText
- errorMessage

## Implementation Notes

- Add `RunRecord`, `RunStatus`, and `RunHistoryStore` to `SableCore`.
- Add `MainWindowController` to `SableApp`.
- Update `StatusMenuController` with open and clear-history actions.
- Update `AppCoordinator` to create/update run records at each stage.
- Keep notifications, but do not rely on them for visibility.

## Verification

- Unit-test history insertion, update, max-count trimming, persistence, and clearing.
- Run `swift test`.
- Run `scripts/build-app.sh`.
- Launch `./scripts/run-debug.sh` and verify the main window opens.

