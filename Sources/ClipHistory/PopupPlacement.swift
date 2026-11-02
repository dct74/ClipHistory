import CoreGraphics

/// Where the popup goes relative to its anchor (caret rect, or a zero-size rect
/// at the pointer). Pure geometry so the four directions can be checked without
/// standing up an NSPanel.
enum PopupPlacement {
    /// Clearance between the caret and the panel edge — never flush against it.
    static let gap: CGFloat = 10

    /// Tries above → below → right → left and takes the first direction with
    /// enough room. The edge facing the anchor is pinned to the gap:
    ///   above → panel bottom = anchor top − gap
    ///   below → panel top    = anchor bottom + gap
    ///   right → panel left   = anchor right + gap
    ///   left  → panel right  = anchor left − gap
    ///
    /// Only the perpendicular axis slides to stay on screen, so fitting never
    /// pushes the panel over the caret.
    static func frame(for anchor: CGRect, size: CGSize, within visible: CGRect) -> CGRect {
        let above = vertical(bottom: anchor.maxY + gap, anchor: anchor, size: size, visible: visible)
        let below = vertical(top: anchor.minY - gap, anchor: anchor, size: size, visible: visible)
        let right = horizontal(left: anchor.maxX + gap, anchor: anchor, size: size, visible: visible)
        let left  = horizontal(right: anchor.minX - gap, anchor: anchor, size: size, visible: visible)

        if visible.maxY - (anchor.maxY + gap) >= size.height { return above }
        if (anchor.minY - gap) - visible.minY >= size.height { return below }
        if visible.maxX - (anchor.maxX + gap) >= size.width  { return right }
        if (anchor.minX - gap) - visible.minX >= size.width  { return left }

        // Screen smaller than the panel in every direction — best effort: put it
        // above the caret and slide both axes.
        return clamped(above, into: visible)
    }

    private static func vertical(bottom: CGFloat, anchor: CGRect, size: CGSize,
                                 visible: CGRect) -> CGRect {
        CGRect(x: slide(anchor.midX - size.width / 2, extent: size.width,
                        from: visible.minX, to: visible.maxX),
               y: bottom,
               width: size.width, height: size.height)
    }

    private static func vertical(top: CGFloat, anchor: CGRect, size: CGSize,
                                 visible: CGRect) -> CGRect {
        CGRect(x: slide(anchor.midX - size.width / 2, extent: size.width,
                        from: visible.minX, to: visible.maxX),
               y: top - size.height,
               width: size.width, height: size.height)
    }

    private static func horizontal(left: CGFloat, anchor: CGRect, size: CGSize,
                                   visible: CGRect) -> CGRect {
        CGRect(x: left,
               y: slide(anchor.midY - size.height / 2, extent: size.height,
                        from: visible.minY, to: visible.maxY),
               width: size.width, height: size.height)
    }

    private static func horizontal(right: CGFloat, anchor: CGRect, size: CGSize,
                                   visible: CGRect) -> CGRect {
        CGRect(x: right - size.width,
               y: slide(anchor.midY - size.height / 2, extent: size.height,
                        from: visible.minY, to: visible.maxY),
               width: size.width, height: size.height)
    }

    private static func clamped(_ rect: CGRect, into visible: CGRect) -> CGRect {
        CGRect(x: slide(rect.minX, extent: rect.width, from: visible.minX, to: visible.maxX),
               y: slide(rect.minY, extent: rect.height, from: visible.minY, to: visible.maxY),
               width: rect.width, height: rect.height)
    }

    /// Keeps `origin` such that `[origin, origin + extent]` stays within
    /// `[from, to]` — pinned to `from` when the screen is smaller than the panel.
    private static func slide(_ origin: CGFloat, extent: CGFloat,
                              from: CGFloat, to: CGFloat) -> CGFloat {
        min(max(origin, from), max(from, to - extent))
    }
}
