import AppKit
import ApplicationServices
import Carbon
import Foundation

/// Selection capture serializes temporary copy actions, including canceled ones.
/// A live fallback restores its sampled clipboard state before review. Updates
/// first observed after cancellation are ambiguous and preserved; a late native
/// Copy may consequently remain. Snapshots never survive into another capture.
@MainActor
public final class SelectionCapture {
    public struct Result {
        public let text: String
    }

    private let accessibilityText: () -> String?
    private let changeCount: () -> Int
    private let clipboardText: () -> String?
    private let snapshot: () -> (() -> Void)
    private let copy: () throws -> Void
    private let tick: () async -> Void
    private var tail: Task<Void, Never>?

    /// All native effects have in-memory replacements in lifecycle tests. The
    /// settle wait drains an already-posted copy for 150 ms after cancellation:
    /// a global key cannot be recalled once posted.
    public init(accessibilityText: @escaping () -> String?,
                changeCount: @escaping () -> Int,
                clipboardText: @escaping () -> String?,
                snapshot: @escaping () -> (() -> Void),
                copy: @escaping () throws -> Void,
                tick: @escaping () async -> Void) {
        self.accessibilityText = accessibilityText
        self.changeCount = changeCount
        self.clipboardText = clipboardText
        self.snapshot = snapshot
        self.copy = copy
        self.tick = tick
    }

    public convenience init(pasteboard: NSPasteboard = .general) {
        self.init(
            accessibilityText: Self.accessibilitySelectedText,
            changeCount: { pasteboard.changeCount },
            clipboardText: { pasteboard.string(forType: .string) },
            snapshot: {
                let saved = ClipboardSnapshot.capture(from: pasteboard)
                return { saved.restore(to: pasteboard) }
            },
            copy: Self.sendCopyShortcut,
            tick: {
                // A bounded child-independent wait lets a canceled capture
                // observe and restore its already-posted native copy.
                await Task { try? await Task.sleep(nanoseconds: 150_000_000) }.value
            }
        )
    }

    public func capture(isSourceCurrent: @escaping () -> Bool = { true }) async throws -> Result {
        try Task.checkCancellation()
        let predecessor = tail
        let operation = Task { @MainActor in
            await predecessor?.value
            try Task.checkCancellation()
            guard isSourceCurrent() else { throw SableError.noSelectedText }
            if let text = accessibilityText(), !text.isEmpty {
                return Result(text: text)
            }
            let before = changeCount()
            let restore = snapshot()
            guard changeCount() == before else { throw SableError.noSelectedText }
            // Recheck at the key boundary; a queued capture must not copy from
            // a different app after waiting for an older fallback to drain.
            guard isSourceCurrent() else { throw SableError.noSelectedText }
            do { try copy() }
            catch {
                if !Task.isCancelled, changeCount() == before + 1 { restore() }
                throw error
            }
            func observeCopy() throws -> String? {
                guard !Task.isCancelled else { return nil }
                let observed = changeCount()
                guard observed != before else { return nil }
                // changeCount is an ownership guard, not proof of provenance.
                // During a live request we sample the first Copy response, but
                // never claim an update first seen after cancellation: it could
                // be the user's copy following a synthetic Copy that did nothing.
                guard observed == before + 1 else { throw SableError.noSelectedText }
                let text = clipboardText()
                guard !Task.isCancelled else { return nil }
                if changeCount() == observed { restore() }
                guard let text,
                      !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw SableError.noSelectedText
                }
                return text
            }
            // An immediate response can be restored before a later cancel. Keep
            // the bounded settle window even then, so the next capture cannot
            // inherit a canceled predecessor's still-pending native Copy action.
            let immediate = try observeCopy()
            await tick()
            try Task.checkCancellation()
            let text = try immediate ?? observeCopy()
            guard isSourceCurrent(), let text else { throw SableError.noSelectedText }
            return Result(text: text)
        }
        tail = Task { _ = await operation.result }
        return try await withTaskCancellationHandler {
            try await operation.value
        } onCancel: {
            operation.cancel()
        }
    }

    private static func accessibilitySelectedText() -> String? {
        let system = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused else { return nil }
        var selected: CFTypeRef?
        guard AXUIElementCopyAttributeValue(focused as! AXUIElement, kAXSelectedTextAttribute as CFString, &selected) == .success else {
            return nil
        }
        return selected as? String
    }

    private static func sendCopyShortcut() throws {
        guard AXIsProcessTrusted(), !IsSecureEventInputEnabled(),
              let source = CGEventSource(stateID: .combinedSessionState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: 0x08, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 0x08, keyDown: false) else {
            throw SableError.missingAccessibilityPermission
        }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }
}
