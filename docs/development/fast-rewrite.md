# Fast rewrites and keyboard editing

## Goal and constraints

Sable should make a simple text rewrite with a direct model request, without
starting a coding agent. Prefer the supported Sign in with ChatGPT flow; offer
an explicitly selected OpenRouter fallback. Keep existing Claude/Codex modes
usable and preserve all custom instructions, mode IDs, and hotkeys.

The owner authorized implementation, worktrees, review, merges, and installation.
Use `cldox` (`claude-opus-xhigh`) for UI/UX work and `cdxsx`
(`codex-sol-xhigh`) for backend work. Workers must run in background Herdr tabs,
be mediator-owned, and retain worktrees and branches. Do not force push. Avoid
visible application automation, global keystrokes, clipboard mutations, or
permission prompts during testing on the owner's working Mac.

## Source-verified feasibility (2026-10-28)

OpenAI now documents dynamic OAuth registration for open-source/local clients.
Sable is a public open-source native app. A client secret and partner key are
not required. Eligible ChatGPT Plus/Pro plans may authorize direct inference.

- Registration: https://developers.openai.com/siwc/token-sharing-open-source/sign-in
- Sessions: https://developers.openai.com/siwc/token-sharing-open-source/profiles-and-sessions
- Inference: https://developers.openai.com/siwc/token-sharing-open-source/models-and-inference
- Recovery: https://developers.openai.com/siwc/token-sharing-open-source/errors-and-recovery
- UI: https://developers.openai.com/siwc/ui-ux-guidelines
- Reference: https://github.com/openai/sign-in-with-chatgpt-devkit

Use `https://api.openai.com/v1/responses`, `store: false`, `stream: true` and
require `response.completed`. Do not reuse Codex tokens or use private ChatGPT
endpoints. Populate the ChatGPT model picker from the account's `/v1/models`
catalog (`models`, visible entries, `slug`, `display_name`), preserving order.

## Deep modules and seams

The **text generation module** presents one async rewrite operation to the app.
It owns provider routing, direct HTTP, model resolution, cancellation, response
completion, and actionable errors. Its existing CLI adapters remain explicit
advanced options; simple defaults use the direct path. Keep transport/model
discovery details behind this interface, not in SwiftUI views.

The **connection module** owns PKCE OAuth, a loopback-only callback listener,
state/nonce checks, verified JWT identity, credentials, refresh rotation and
disconnect. Store app-owned host identity and credentials under
`~/.config/sable/`; use atomic owner-only files and never log credentials.
Canceling a new sign-in must leave the active connection intact. A fresh attempt
may not overwrite verified credentials until it fully succeeds. OpenRouter
uses an app-owned protected key file and is selected explicitly; never silently
switch providers or consume paid fallback credit after a ChatGPT error.

The **review editor module** owns text, cursor, modal keys and local undo behind
a small interface. Keep the editing state independent of AppKit event delivery
so it can be tested without typing into the owner's apps. Native text input
continues to handle insertion, IME and standard macOS shortcuts.

The **interaction module** owns selection capture, run generations, clipboard
snapshots, cancellation and final delivery to the original app. A superseded
capture/run/sign-in must never mutate the current interaction. Capture the
source app before the overlay takes focus. Screenshot capture is optional and
off the direct text path; do not take screenshots on every grammar fix.

## User experience

1. Global picker or a direct mode hotkey captures selection; picker focuses its
   search field. Retain arrows; support Ctrl-j/Ctrl-k or Ctrl-n/Ctrl-p.
2. Instant modes run immediately. Ask waits for an instruction and Enter.
3. A compact, calm panel shows progress; cancellation stays responsive.
4. A review setting opens the result in a small editor in Normal mode. Support
   h/j/k/l, w/b/e, 0/^/$, gg/G, i/a/I/A/o/O, x, dd, dw/cw/ciw, d$/D/C,
   undo/redo and basic visual selection/yank/paste as practical. Essential
   correctness takes precedence over claiming a full Vim implementation.
   Include the owner's Insert-mode `jk` and `jj` escape mappings. Pending j
   must not be lost on blur, submit, or a slow chord.
5. In Normal mode Enter copies and closes. In Insert mode Enter is a newline.
   Cmd-Enter commits edits and pastes into the captured source application.
   If the destination cannot safely be restored, preserve the output on the
   clipboard and report that outcome. Escape exits Insert/Visual first;
   Escape in Normal cancels and restores the pre-interaction clipboard.
6. Keep a quick-copy setting for instant workflows. Copy-only completion must
   not steal focus or leave an auto-close task capable of closing a later run.
7. Main window is a small utility: modes, recent history and settings without
   a dashboard. Provider connection, model and shortcuts are primary settings;
   CLI paths, working directory and optional screenshots are advanced.
8. Borrow Focus's restraint, legible type, subtle glass and warm accent rather
   than its full-screen effects. Respect light/dark appearance and long text.

## Pieces and file ownership

Land the compiling skeleton before filling implementations. Each piece gets a
dedicated Grove worktree and PR. Merge the current main into published branches;
never rebase/force-push published history. Keep every side's intention when
resolving shared-file conflicts.

| Piece | Engine | Owns | Acceptance |
| --- | --- | --- | --- |
| 0. Backend skeleton | cdxsx | New `SableCore/Connections`, `SableCore/Generation`, `SableCore/Editing` contracts; provider/settings compatibility; new test file skeletons | Existing app compiles; exact contracts documented in shared report; no production default routed to an unfinished adapter |
| 1. ChatGPT connection | cdxsx | `Connections/*` and connection tests | Secure dynamic registration, verified identity/scopes, bounded cancellation-safe listener, atomic refresh and disconnect; isolated HTTP/credential tests |
| 2. Direct generation | cdxsx | `Generation/*`, generation tests, runtime/settings integration agreed in skeleton | One direct request, correct model discovery, complete SSE handling, cancellation, protected OpenRouter configuration, migration without destroying custom modes |
| 3. Editor engine | cdxsx | `Editing/*`, editing tests | Deterministic Unicode-safe modal edits and undo, jk/jj semantics, no GUI or system clipboard in tests |
| 4. Overlay UI | cldox | `Overlay/*`, native editor view under `SableApp/Editing/*` | Compact picker/progress/review, clear keyboard hints, native text insertion/selection; no visible UI automation |
| 5. Utility UI | cldox | `Views/*`, `Theme.swift`, `MainWindowController.swift`, `MainWindowModel.swift` | Simple utility navigation, ChatGPT connection actions/status, provider/model choice, protected key entry, review setting; bindings to connection callbacks |
| 6. Interaction wiring | cdxsx | `AppCoordinator.swift`, `Capture/*`, `Clipboard/*`, `History/*`, focused interaction tests, README | Race-safe capture/run/cancel/commit; no screenshot on direct path; safe explicit paste-back; meaningful tests with injected seams |
| 7. Independent review and finalization | corresponding engines | Findings in shared reports; narrow fixes only | Vet findings, fix material defects, build/test exact merged revision, install signed app once; retain all worktrees |

The mediator owns this plan, briefs and reports, review coordination, merge
order, and tiny shared glue. Backend and UI skeleton changes must remain
separate in ownership even when the first wave overlaps.

## Verification and rollout

Use `swift build`, focused headless core/interaction tests and a final release
`make build`. Tests use temporary config stores and private pasteboards only.
Do not launch the real app, request permissions or send synthetic global keys
from worker verification. No real inference is required before the owner signs
in; report that limit honestly. Install the final release to
`/Applications/Sable.app` once. Preserve the previous install when practical
and avoid bringing a window forward. Do not claim a live authenticated request
or paste into a real app was verified without evidence.

Keep credentials out of Git. Existing tracked `.llm` notes are preserved in the
shared project store while untracking them so Grove/Herdr can link that store.
All run briefs, source snapshots, findings and reports live in shared `.llm`.

## Follow-up: stable permission identity and Vim navigation

The installed ad-hoc build changes its designated code requirement on each
rebuild. Preserve a certificate-backed identity through build and install so
macOS can recognize later updates. Screenshot attachments remain optional,
default off, and restricted to the CLI provider; Accessibility separately
supports selected text and explicit paste-back.

| Piece | Engine | Owns | Acceptance |
| --- | --- | --- | --- |
| Stable signing | cdxsx | Makefile, a focused signing helper if needed, README signing instructions | Prefer a usable stable local identity, allow explicit selection and ad-hoc development, preserve signatures during install, verify different builds satisfy the same requirement; never change TCC or keychain policy |
| Vim search and line selection | cdxsx | SableCore/Editing and focused core tests | `/` search with `n`/`N`, characterwise visual selection and `V` logical-line selection with deletion/yank, Unicode-safe undo; publish additive UI contracts before integration |
| Native Vim presentation | cldox | SableApp/Editing, review presentation and focused windowless app tests | Compact search feedback, native text/IME handling, correct line selection and key routing; search Enter never delivers a result; keep the existing Enter and Cmd-Enter delivery contract |

Signing and editor work can proceed independently. The editor UI integrates the
engine contract before final verification. Keep checks headless, retain Grove
worktrees and branches, and install the combined accepted build once.
