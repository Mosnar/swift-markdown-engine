//
//  NativeTextView+CursorRects.swift
//  MarkdownEngine
//
//  Created by Luca Chen on 27.05.26.
//
//  Read-only cursor handling: arrow over text, pointing hand over links.
//

import AppKit

extension NativeTextView {

    override func mouseMoved(with event: NSEvent) {
        if isInCursorExclusionZone(event) {
            // Editable+excluded = a panel over the editor (#81): own the arrow.
            // Read-only+excluded = a full-window overlay (search/transfer) owns
            // the cursor; stay silent — our tracking areas fire beneath it and
            // any set here fights the overlay's cursor (flicker).
            if isEditable { NSCursor.arrow.set() }
        } else if isEditable, isOverTaskCheckboxBox(event) {
            // The box is a clickable control, not text. super sets the I-beam
            // on every move, so setting the arrow after it flickers — skip
            // super entirely, like the exclusion-zone branch.
            NSCursor.arrow.set()
        } else if isEditable, isOverWideTableOverlay(event) {
            // Same treatment for wide-table scroll overlays: the overlay is a
            // control surface (rendered image + horizontal scroller), not
            // text, but the text view's tracking areas are not occlusion-aware
            // and super keeps setting the I-beam through it.
            NSCursor.arrow.set()
        } else {
            applyReadOnlyCursor(for: event)
            applyInvertedIBeamIfNeeded(for: event)
        }
        updateAutomaticLinkHover(for: event)
    }

    override func mouseEntered(with event: NSEvent) {
        if isInCursorExclusionZone(event) {
            if isEditable { NSCursor.arrow.set() }
        } else if isEditable, isOverTaskCheckboxBox(event) {
            NSCursor.arrow.set()
        } else if isEditable, isOverWideTableOverlay(event) {
            NSCursor.arrow.set()
        } else {
            super.mouseEntered(with: event)
            applyReadOnlyCursor(for: event)
            applyInvertedIBeamIfNeeded(for: event)
        }
        updateAutomaticLinkHover(for: event)
    }

    override func mouseExited(with event: NSEvent) {
        emitAutomaticLinkHover(nil)
    }

    /// NSTextView installs its own link cursor rects from `.link` attributes.
    /// Automatic editor links have a modifier-dependent cursor, so those static
    /// rects would fight `mouseMoved`/`cursorUpdate` and visibly flicker. The
    /// explicit tracking area owns cursor updates for the whole text view.
    override func resetCursorRects() {}

    override func flagsChanged(with event: NSEvent) {
        super.flagsChanged(with: event)
        let point = convert(window?.mouseLocationOutsideOfEventStream ?? .zero, from: nil)
        applyCursor(at: point, modifiers: event.modifierFlags)
    }

    override func cursorUpdate(with event: NSEvent) {
        applyCursor(
            at: convert(event.locationInWindow, from: nil),
            modifiers: event.modifierFlags
        )
    }

    /// True when the pointer is over a wide-table overlay's HORIZONTAL
    /// SCROLLER (mirrors the task-checkbox suppression above; read-only mode
    /// already shows the arrow via `applyReadOnlyCursor`). Only the scroller
    /// strip is a control surface — over the rendered table image itself the
    /// normal text cursor behavior stays.
    private func isOverWideTableOverlay(_ event: NSEvent) -> Bool {
        guard !wideTableOverlays.isEmpty else { return false }
        for (_, overlay) in wideTableOverlays where overlay.superview != nil && !overlay.isHidden {
            guard let scroller = overlay.horizontalScroller, !scroller.isHidden else { continue }
            let point = scroller.convert(event.locationInWindow, from: nil)
            if scroller.bounds.contains(point) { return true }
        }
        return false
    }

    /// True inside an embedder exclusion zone — a panel over the editor or a
    /// full-window overlay (search/transfer) that owns the cursor. NOT gated on
    /// `isEditable`: overlays make the editor read-only, and gating let its
    /// cursor path keep firing beneath them (flicker in search).
    private func isInCursorExclusionZone(_ event: NSEvent) -> Bool {
        guard let excluded = isCursorExcluded else { return false }
        return excluded(event.locationInWindow)
    }

    /// In read-only mode, override NSTextView's I-beam: pointing hand over a
    /// `.link` range, arrow everywhere else.
    private func applyReadOnlyCursor(for event: NSEvent) {
        let viewPoint = convert(event.locationInWindow, from: nil)
        applyCursor(at: viewPoint, modifiers: event.modifierFlags)
    }

    /// True when the pointer is over a drawn task-checkbox square (edit mode
    /// suppresses the I-beam there — the box is a clickable control, not text;
    /// read-only mode already shows the arrow via `applyReadOnlyCursor`).
    private func isOverTaskCheckboxBox(_ event: NSEvent) -> Bool {
        let viewPoint = convert(event.locationInWindow, from: nil)
        let containerPoint = CGPoint(x: viewPoint.x - textContainerOrigin.x,
                                     y: viewPoint.y - textContainerOrigin.y)
        // Bound the attribute scan to the hovered line's fragment — a full-
        // document scan per mouse-move would be O(doc).
        guard let tlm = textLayoutManager,
              let tcs = tlm.textContentManager as? NSTextContentStorage,
              let fragment = tlm.textLayoutFragment(for: containerPoint) else { return false }
        let start = tcs.offset(from: tcs.documentRange.location, to: fragment.rangeInElement.location)
        let end = tcs.offset(from: tcs.documentRange.location, to: fragment.rangeInElement.endLocation)
        guard start != NSNotFound, end > start else { return false }
        let lineRange = NSRange(location: start, length: end - start)
        return taskCheckboxHit(at: containerPoint, in: lineRange) != nil
    }

    /// True when a clickable `.link` attribute exists under the given point
    /// (view coordinates). `.link` is what drives `clickedOnLink`, so this
    /// matches exactly what is clickable.
    private func applyCursor(at viewPoint: CGPoint, modifiers: NSEvent.ModifierFlags) {
        guard isSelectable else { return }
        guard let hit = linkHit(at: viewPoint) else {
            (isEditable ? NSCursor.iBeam : NSCursor.arrow).set()
            return
        }
        if !isEditable {
            NSCursor.pointingHand.set()
            return
        }
        guard let textStorage else {
            NSCursor.iBeam.set()
            return
        }
        let policy = AutomaticLinkService.activationPolicy(in: textStorage, at: hit.index)
        if policy == .commandClickWhenEditable, modifiers.contains(.command) {
            NSCursor.pointingHand.set()
        } else if policy == .standard {
            NSCursor.pointingHand.set()
        } else {
            NSCursor.iBeam.set()
        }
    }

    private func updateAutomaticLinkHover(for event: NSEvent) {
        updateAutomaticLinkHover(at: convert(event.locationInWindow, from: nil))
    }

    /// Re-evaluates hover from the current pointer position without a mouse
    /// event. Called on scroll: the text moves under a stationary pointer, so
    /// the emitted anchor rect (and whether a link is hovered at all) goes
    /// stale until the next `mouseMoved` otherwise.
    func refreshAutomaticLinkHover() {
        guard let window, onLinkHoverChange != nil else { return }
        let windowPoint = window.mouseLocationOutsideOfEventStream
        let viewPoint = convert(windowPoint, from: nil)
        guard visibleRect.contains(viewPoint) else {
            emitAutomaticLinkHover(nil)
            return
        }
        updateAutomaticLinkHover(at: viewPoint)
    }

    private func updateAutomaticLinkHover(at viewPoint: CGPoint) {
        guard let hit = linkHit(at: viewPoint),
              let target = textStorage?.attribute(
                AutomaticLinkService.targetAttribute,
                at: hit.index,
                effectiveRange: nil
              ) as? String,
              let anchorRect = wrapperAnchorRect(forCharacterRange: hit.range, using: layoutBridge) else {
            emitAutomaticLinkHover(nil)
            return
        }
        emitAutomaticLinkHover(LinkHoverState(
            target: target,
            characterRange: hit.range,
            anchorRect: anchorRect
        ))
    }

    private func emitAutomaticLinkHover(_ state: LinkHoverState?) {
        guard state != lastLinkHoverState else { return }
        lastLinkHoverState = state
        onLinkHoverChange?(state)
    }

    private func linkHit(at viewPoint: CGPoint) -> (index: Int, range: NSRange)? {
        guard let index = characterIndex(at: viewPoint), let textStorage else { return nil }
        var effectiveRange = NSRange()
        guard textStorage.attribute(.link, at: index, effectiveRange: &effectiveRange) != nil else { return nil }
        return (index, effectiveRange)
    }

    private func characterIndex(at viewPoint: CGPoint) -> Int? {
        guard let tlm = textLayoutManager,
              let textStorage = textStorage, textStorage.length > 0 else { return nil }

        let containerPoint = CGPoint(x: viewPoint.x - textContainerOrigin.x,
                                     y: viewPoint.y - textContainerOrigin.y)
        guard let fragment = tlm.textLayoutFragment(for: containerPoint) else { return nil }

        let fragFrame = fragment.layoutFragmentFrame
        let pInFrag = CGPoint(x: containerPoint.x - fragFrame.minX,
                              y: containerPoint.y - fragFrame.minY)
        // Only accept a line fragment that actually contains the point — guards
        // against clicks in trailing padding / past the end of a line.
        guard let line = fragment.textLineFragments.first(where: { $0.typographicBounds.contains(pInFrag) }) else { return nil }

        let pInLine = CGPoint(x: pInFrag.x - line.typographicBounds.minX,
                              y: pInFrag.y - line.typographicBounds.minY)
        let indexInFragment = line.characterIndex(for: pInLine)
        guard indexInFragment >= line.characterRange.location,
              indexInFragment < NSMaxRange(line.characterRange) else { return nil }
        guard let textContentStorage else { return nil }
        let fragmentStart = textContentStorage.offset(
            from: textContentStorage.documentRange.location,
            to: fragment.rangeInElement.location
        )
        guard fragmentStart != NSNotFound else { return nil }
        let documentIndex = fragmentStart + indexInFragment
        guard documentIndex >= 0, documentIndex < textStorage.length else { return nil }
        return documentIndex
    }

    /// Attributes at the pointer use document offsets, including wrapped lines.
    private func attributes(at viewPoint: CGPoint) -> [NSAttributedString.Key: Any]? {
        guard let index = characterIndex(at: viewPoint) else { return nil }
        return textStorage?.attributes(at: index, effectiveRange: nil)
    }

    /// Ink + block of a span that repaints its foreground under `event`, or nil.
    /// Same rule as the caret color: only a run that carries BOTH a background
    /// and a foreground of its own is inverted — inline code and find matches
    /// paint a background but keep the body ink, and the system I-beam is
    /// already right on those.
    func invertedRunColors(at event: NSEvent) -> (ink: NSColor, block: NSColor)? {
        guard configuration.cursorFollowsSpanInk else { return nil }
        let attrs = attributes(at: convert(event.locationInWindow, from: nil))
        guard let attrs,
              let block = attrs[.backgroundColor] as? NSColor,
              let ink = attrs[.foregroundColor] as? NSColor else { return nil }
        // Resolve inside the view's appearance: these are dynamic colors, and
        // `NSAppearance.current` during a mouse event is not necessarily ours —
        // a dark editor would otherwise get the light-mode pair.
        var resolved: (ink: NSColor, block: NSColor, body: NSColor)?
        effectiveAppearance.performAsCurrentDrawingAppearance {
            guard let ink = ink.usingColorSpace(.deviceRGB),
                  let block = block.usingColorSpace(.deviceRGB),
                  let body = configuration.theme.bodyText.usingColorSpace(.deviceRGB) else { return }
            resolved = (ink, block, body)
        }
        guard let resolved else { return nil }
        // Body ink on a background is inline code or a find match — the system
        // I-beam is already right there; only a run that repaints its ink needs us.
        guard resolved.ink != resolved.body else { return nil }
        return (resolved.ink, resolved.block)
    }

    /// Over an inverted span the system I-beam is drawn in the block's own
    /// color (macOS inverts it against the editor's backdrop, not against the
    /// run under it), so it disappears. Swap in the same glyph recolored to the
    /// span's own ink; anywhere else `super` keeps the system cursor.
    func applyInvertedIBeamIfNeeded(for event: NSEvent) {
        guard isEditable,
              linkHit(at: convert(event.locationInWindow, from: nil)) == nil,
              let colors = invertedRunColors(at: event),
              let cursor = InvertedIBeamCursor.cursor(ink: colors.ink, block: colors.block)
        else { return }
        cursor.set()
    }
}
