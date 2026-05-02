# Sable UX Visibility Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use obra-executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add visible run state, persistent history, and a main Sable window so the user can tell what the app is doing and copy previous outputs.

**Architecture:** Add a pure `SableCore` history model/store with XCTest coverage, then wire it into an AppKit `MainWindowController`. `AppCoordinator` owns run lifecycle updates and pushes records to both persistent history and the window.

**Tech Stack:** Swift, AppKit, Foundation Codable JSON, XCTest.

---

## Tasks

- [ ] Add `RunStatus`, `RunRecord`, and `RunHistoryStore` in `Sources/SableCore/History`.
- [ ] Add `RunHistoryStoreTests` covering upsert, newest-first ordering, max count, save/load, and clear.
- [ ] Add `MainWindowController` with status, history list, details, copy output, clear history, reload config, and permission buttons.
- [ ] Extend `StatusMenuController` with Open Sable and Clear History.
- [ ] Wire run lifecycle updates in `AppCoordinator`.
- [ ] Improve README run/debug section.
- [ ] Verify with `swift test`, `scripts/build-app.sh`, and `./scripts/run-debug.sh`.

