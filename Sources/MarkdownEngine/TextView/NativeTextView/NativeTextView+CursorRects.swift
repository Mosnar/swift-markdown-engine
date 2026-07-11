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
            NSCursor.arrow.set()
        } else {
            applyReadOnlyCursor(for: event)
        }
        updateAutomaticLinkHover(for: event)
    }

    override func mouseEntered(with event: NSEvent) {
        if isInCursorExclusionZone(event) {
            NSCursor.arrow.set()
        } else {
            applyReadOnlyCursor(for: event)
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

    /// True when the mouse is inside an embedder-defined exclusion zone
    /// (e.g. a formatting toolbar) and edit-mode I-beam should be suppressed.
    private func isInCursorExclusionZone(_ event: NSEvent) -> Bool {
        guard isEditable, let excluded = isCursorExcluded else { return false }
        return excluded(event.locationInWindow)
    }

    /// In read-only mode, override NSTextView's I-beam: pointing hand over a
    /// `.link` range, arrow everywhere else.
    private func applyReadOnlyCursor(for event: NSEvent) {
        let viewPoint = convert(event.locationInWindow, from: nil)
        applyCursor(at: viewPoint, modifiers: event.modifierFlags)
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
        var effectiveRange = NSRange()
        guard textStorage.attribute(.link, at: documentIndex, effectiveRange: &effectiveRange) != nil else { return nil }
        return (documentIndex, effectiveRange)
    }
}
