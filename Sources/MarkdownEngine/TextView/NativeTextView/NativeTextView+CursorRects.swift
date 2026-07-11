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
            super.mouseMoved(with: event)
            applyReadOnlyCursor(for: event)
        }
        updateAutomaticLinkHover(for: event)
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        if isInCursorExclusionZone(event) {
            NSCursor.arrow.set()
        } else {
            applyReadOnlyCursor(for: event)
        }
        updateAutomaticLinkHover(for: event)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        emitAutomaticLinkHover(nil)
    }

    override func flagsChanged(with event: NSEvent) {
        super.flagsChanged(with: event)
        let point = convert(window?.mouseLocationOutsideOfEventStream ?? .zero, from: nil)
        applyCursor(at: point, modifiers: event.modifierFlags)
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
            if !isEditable { NSCursor.arrow.set() }
            return
        }
        if !isEditable {
            NSCursor.pointingHand.set()
            return
        }
        let policy = AutomaticLinkService.activationPolicy(in: textStorage!, at: hit.index)
        if policy == .commandClickWhenEditable, modifiers.contains(.command) {
            NSCursor.pointingHand.set()
        } else if policy == .standard {
            NSCursor.pointingHand.set()
        } else {
            NSCursor.iBeam.set()
        }
    }

    private func updateAutomaticLinkHover(for event: NSEvent) {
        let viewPoint = convert(event.locationInWindow, from: nil)
        guard let hit = linkHit(at: viewPoint),
              let target = textStorage?.attribute(
                AutomaticLinkService.targetAttribute,
                at: hit.index,
                effectiveRange: nil
              ) as? String,
              let anchorRect = viewRect(forCharacterRange: hit.range, using: layoutBridge) else {
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
        let idx = line.characterIndex(for: pInLine)
        let lineString = line.attributedString
        guard idx >= 0, idx < lineString.length else { return nil }
        guard let textContentStorage else { return nil }
        let fragmentStart = textContentStorage.offset(
            from: textContentStorage.documentRange.location,
            to: fragment.rangeInElement.location
        )
        guard fragmentStart != NSNotFound else { return nil }
        let documentIndex = fragmentStart + line.characterRange.location + idx
        guard documentIndex >= 0, documentIndex < textStorage.length else { return nil }
        var effectiveRange = NSRange()
        guard textStorage.attribute(.link, at: documentIndex, effectiveRange: &effectiveRange) != nil else { return nil }
        return (documentIndex, effectiveRange)
    }
}
