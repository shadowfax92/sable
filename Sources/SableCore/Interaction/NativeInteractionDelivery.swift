import AppKit
import ApplicationServices
import Carbon

/// The native boundary is deliberately synchronous at the final global key.
/// The interaction owner checks its generation immediately before calling paste;
/// this adapter then rechecks the exact live application, focus and permissions.
@MainActor
public enum NativeInteractionDelivery {
    public static func captureSource() -> InteractionSource {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier > 0,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              app.bundleIdentifier != Bundle.main.bundleIdentifier else {
            return InteractionSource()
        }
        let pid = app.processIdentifier
        let isLive: () -> Bool = {
            guard !app.isTerminated,
                  let live = NSRunningApplication(processIdentifier: pid) else { return false }
            return live.isEqual(app)
        }
        let isFrontmost: () -> Bool = {
            isLive() && NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
                && NSWorkspace.shared.frontmostApplication?.isEqual(app) == true
        }
        let ready: () -> Bool = {
            isFrontmost() && AXIsProcessTrusted() && !IsSecureEventInputEnabled()
        }
        return InteractionSource(
            processIdentifier: pid, name: app.localizedName, canPasteBack: true,
            isFrontmost: isFrontmost,
            activate: {
                guard isLive() else { return false }
                if isFrontmost() { return true }
                return app.activate(options: [])
            },
            isReadyForPaste: ready,
            paste: {
                guard ready(), let eventSource = CGEventSource(stateID: .combinedSessionState),
                      let down = CGEvent(keyboardEventSource: eventSource, virtualKey: 0x09, keyDown: true),
                      let up = CGEvent(keyboardEventSource: eventSource, virtualKey: 0x09, keyDown: false) else { return false }
                down.flags = .maskCommand
                up.flags = .maskCommand
                // Keep construction outside this last check. No suspension or
                // activation may occur between target validation and posting.
                guard ready() else { return false }
                down.post(tap: .cghidEventTap)
                up.post(tap: .cghidEventTap)
                return true
            }
        )
    }
}
