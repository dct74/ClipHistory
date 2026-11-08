import Foundation
import Observation

/// A destructive action waiting for confirmation inside the popup.
///
/// Using an in-panel card instead of NSAlert is deliberate: the panel never
/// activates the app, so a modal alert cannot receive ⏎ (key events route to the
/// app the user came from). The card is driven by the event tap we already own.
enum PopupConfirmation: Equatable {
    case clearAll
}

/// Shared mutable state between PopupWindowController and PopupView.
/// Lives in the controller; the view observes it via @Bindable.
@Observable
final class PopupState {
    /// Bumped every time the popup opens — SwiftUI uses this to reset the
    /// search field's visual state (there is no AppKit field to focus; the
    /// event tap feeds the query).
    var showToken    = UUID()
    var searchText   = ""
    /// Text the input method is still composing (shown underlined).
    var markedText   = ""
    var selectedIndex = 0
    /// Non-nil while the confirmation card is up; it owns the keyboard.
    var confirmation: PopupConfirmation?

    /// What the list filters on: committed text plus the composition in progress.
    var queryText: String { searchText + markedText }

    /// Prepare for a fresh open. Search is always cleared (it's transient);
    /// pass `keepSelection: true` to preserve the highlighted row so the list
    /// reopens where the user left off instead of snapping to the start.
    func reset(keepSelection: Bool = false) {
        showToken  = UUID()
        searchText = ""
        markedText = ""
        confirmation = nil
        if !keepSelection { selectedIndex = 0 }
    }
}
