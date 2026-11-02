import AppKit
import ApplicationServices

/// Screen rectangle of the focused text insertion point (AppKit coordinates).
/// Returns nil whenever the focused element exposes no text caret — callers
/// fall back to the mouse position.
enum CaretLocator {

    static func currentRect() -> CGRect? {
        guard AXIsProcessTrusted() else { return nil }

        var focusedRef: CFTypeRef?
        let systemWide = AXUIElementCreateSystemWide()
        guard AXUIElementCopyAttributeValue(systemWide,
                                           kAXFocusedUIElementAttribute as CFString,
                                           &focusedRef) == .success,
              let focusedRef,
              CFGetTypeID(focusedRef) == AXUIElementGetTypeID()
        else { return nil }
        let element = focusedRef as! AXUIElement

        // A hung target app must not freeze our UI for seconds.
        AXUIElementSetMessagingTimeout(systemWide, 0.5)
        AXUIElementSetMessagingTimeout(element, 0.5)

        // Text controls report their selection; buttons, lists etc. don't.
        var rangeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element,
                                           kAXSelectedTextRangeAttribute as CFString,
                                           &rangeRef) == .success,
              let rangeRef
        else { return nil }

        var boundsRef: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(element,
                                                        kAXBoundsForRangeParameterizedAttribute as CFString,
                                                        rangeRef,
                                                        &boundsRef) == .success,
              let boundsRef,
              CFGetTypeID(boundsRef) == AXValueGetTypeID()
        else { return nil }

        var rect = CGRect.zero
        guard AXValueGetValue(boundsRef as! AXValue, .cgRect, &rect),
              rect.origin.x.isFinite, rect.origin.y.isFinite,
              rect.width.isFinite, rect.height.isFinite,
              rect.width > 0 || rect.height > 0
        else { return nil }

        var appKitRect = appKitRect(fromAXRect: rect)
        // The vertical extent is convention-dependent, measured on this machine:
        // WebKit reports the caret box correctly, while AppKit text controls
        // report it one line too high (its bottom edge sits where the top
        // belongs). Extending the box downward by its own height makes the
        // placement safe under either convention — the panel ends up a line
        // further away on the unneeded side, never on top of the caret.
        appKitRect.origin.y -= appKitRect.height
        appKitRect.size.height *= 2
        return appKitRect
    }

    /// AX screen coordinates put the origin at the top-left of the main display,
    /// AppKit at its bottom-left — flip across the main screen height.
    private static func appKitRect(fromAXRect rect: CGRect) -> CGRect {
        let mainHeight = NSScreen.screens.first { $0.frame.origin == .zero }?.frame.height
            ?? NSScreen.main?.frame.height
            ?? 0
        return CGRect(x: rect.minX,
                      y: mainHeight - rect.maxY,
                      width: rect.width,
                      height: rect.height)
    }
}
