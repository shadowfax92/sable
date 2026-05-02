import AppKit
import CoreGraphics
import Foundation
import ImageIO

public struct ScreenshotCapture {
    public init() {}

    /// Captures frontmost window context as a PNG, with full-screen capture as fallback.
    public func capture(to destination: URL) throws {
        if let windowID = frontmostWindowID(),
           let image = CGWindowListCreateImage(
                .null,
                [.optionIncludingWindow],
                windowID,
                [.boundsIgnoreFraming, .bestResolution]
           ),
           write(image, to: destination) {
            return
        }

        guard let image = CGWindowListCreateImage(
            .infinite,
            [.optionOnScreenOnly],
            kCGNullWindowID,
            [.bestResolution]
        ), write(image, to: destination) else {
            throw SableError.screenshotFailed("frontmost window and screen capture both failed")
        }
    }

    private func frontmostWindowID() -> CGWindowID? {
        guard let app = NSWorkspace.shared.frontmostApplication else {
            return nil
        }

        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }

        for window in windows {
            let pid = (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value
            let layer = (window[kCGWindowLayer as String] as? NSNumber)?.intValue
            let alpha = (window[kCGWindowAlpha as String] as? NSNumber)?.doubleValue
            guard pid == app.processIdentifier, layer == 0, (alpha ?? 0) > 0 else {
                continue
            }
            if let number = window[kCGWindowNumber as String] as? NSNumber {
                return CGWindowID(number.uint32Value)
            }
        }

        return nil
    }

    private func write(_ image: CGImage, to destination: URL) -> Bool {
        guard let destinationRef = CGImageDestinationCreateWithURL(
            destination as CFURL,
            "public.png" as CFString,
            1,
            nil
        ) else {
            return false
        }
        CGImageDestinationAddImage(destinationRef, image, nil)
        return CGImageDestinationFinalize(destinationRef)
    }
}
