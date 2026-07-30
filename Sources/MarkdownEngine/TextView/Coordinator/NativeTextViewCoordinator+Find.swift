//
//  NativeTextViewCoordinator+Find.swift
//  MarkdownEngine
//
//  Created by Luca Chen on 16.03.26.
//
//  Find-in-document highlighting. The host app posts the bus notifications
//  registered in `MarkdownEditorBus.findScrollToRange` /
//  `findClearHighlights` to drive the highlight overlay; this extension
//  renders the highlights into the underlying NSTextStorage and scrolls the
//  current match into view.
//

import AppKit

extension NSAttributedString.Key {
    /// Marks a range find painted a highlight over, carrying whatever
    /// `.backgroundColor` was there beforehand so it can be put back exactly.
    /// The value is the prior `NSColor`, or `NSNull` when the range had none.
    ///
    /// Find can't just clear `.backgroundColor` when it's done: the styler draws
    /// inline code, fenced blocks and code in tables with that same attribute.
    /// And it can't snapshot the whole document either, because restyling is
    /// paragraph-scoped — an edit re-styles only the touched paragraphs, so a
    /// document-wide snapshot taken afterwards would capture find's own leftover
    /// colors elsewhere and mistake them for the styler's.
    static let markdownFindHighlight = NSAttributedString.Key("markdownFindHighlight")
}

extension NativeTextViewCoordinator {
    /// Legacy path: the host computes match ranges and posts them. Kept for compatibility, but
    /// it trusts SOURCE-coordinate ranges, which misalign wherever the displayed text is shorter
    /// than the source (node links etc.). Prefer `handleFindQuery`.
    @objc func handleFindScrollToRange(_ notification: Notification) {
        guard let info = notification.userInfo,
              let currentIndex = info["currentIndex"] as? Int,
              let allRanges = info["allRanges"] as? [NSRange] else { return }
        renderFindMatches(allRanges, currentIndex: currentIndex)
    }

    /// Find against the engine's OWN displayed text (`tv.string`). Matches are computed in
    /// DISPLAY coordinates, so highlights land correctly even where the displayed text differs
    /// from the source (node links rendered shorter than `[[Name|UUID]]`, LaTeX, images). Posts
    /// the match count back via `bus.findResults` so the host can show "x of y".
    /// Hosts that show several documents at once (one per field, say) pass
    /// `focusDocumentId` to name the one that owns the focused match. Every
    /// other document still highlights all of its matches, just without a
    /// focused one, and none of them scroll: a multi-document host owns the
    /// enclosing scroll view, so it does the scrolling from `matchRect`.
    @objc func handleFindQuery(_ notification: Notification) {
        guard let tv = textView,
              let info = notification.userInfo,
              let query = info["query"] as? String else { return }
        let requestedIndex = info["currentIndex"] as? Int ?? 0

        let allRanges = findMatches(of: query, in: tv.string as NSString)

        let focusDocumentId = info["focusDocumentId"] as? String
        let hostDrivenFocus = focusDocumentId != nil
        let ownsFocus = !hostDrivenFocus || focusDocumentId == documentId

        let currentIndex: Int? = {
            guard ownsFocus, !allRanges.isEmpty else { return nil }
            return min(max(requestedIndex, 0), allRanges.count - 1)
        }()

        renderFindMatches(
            allRanges,
            currentIndex: currentIndex,
            scrollsToCurrentMatch: !hostDrivenFocus
        )

        var matchRect: CGRect?
        if hostDrivenFocus, let currentIndex, allRanges.indices.contains(currentIndex) {
            matchRect = tv.wrapperAnchorRect(
                forCharacterRange: allRanges[currentIndex],
                using: layoutBridge
            )
        }
        postFindResults(count: allRanges.count, query: query, matchRect: matchRect)
    }

    /// Whether find currently has any highlight applied in this document.
    func hasFindHighlights(in storage: NSTextStorage?) -> Bool {
        guard let storage, storage.length > 0 else { return false }
        var found = false
        storage.enumerateAttribute(
            .markdownFindHighlight,
            in: NSRange(location: 0, length: storage.length)
        ) { value, _, stop in
            if value != nil {
                found = true
                stop.pointee = true
            }
        }
        return found
    }

    /// Undo every highlight find applied, restoring the exact background each
    /// range had beforehand. Touches only ranges find marked, so the styler's
    /// backgrounds elsewhere are left alone. Returns whether anything changed.
    @discardableResult
    func removeFindHighlights(from storage: NSTextStorage?, range: NSRange) -> Bool {
        guard let storage, range.length > 0 else { return false }

        // Collect first: mutating attributes mid-enumeration is not safe.
        var marked: [(range: NSRange, priorColor: NSColor?)] = []
        storage.enumerateAttribute(.markdownFindHighlight, in: range) { value, subrange, _ in
            guard let value else { return }
            marked.append((subrange, value as? NSColor))
        }
        guard !marked.isEmpty else { return false }

        for entry in marked {
            storage.removeAttribute(.markdownFindHighlight, range: entry.range)
            if let priorColor = entry.priorColor {
                storage.addAttribute(.backgroundColor, value: priorColor, range: entry.range)
            } else {
                storage.removeAttribute(.backgroundColor, range: entry.range)
            }
        }
        return true
    }

    /// Paint `allRanges`, recording what each range's background was so
    /// `removeFindHighlights` can restore it. A match straddling a code span
    /// records the prior background run by run, so each part comes back right.
    private func applyFindHighlights(
        _ allRanges: [NSRange],
        currentIndex: Int?,
        in storage: NSTextStorage,
        fullRange: NSRange,
        matchColor: NSColor,
        currentMatchColor: NSColor
    ) {
        for (i, matchRange) in allRanges.enumerated() {
            guard NSMaxRange(matchRange) <= fullRange.length else { continue }

            var priors: [(range: NSRange, value: Any)] = []
            storage.enumerateAttribute(.backgroundColor, in: matchRange) { value, subrange, _ in
                priors.append((subrange, (value as? NSColor) ?? NSNull()))
            }
            for prior in priors {
                storage.addAttribute(.markdownFindHighlight, value: prior.value, range: prior.range)
            }

            let color = (i == currentIndex) ? currentMatchColor : matchColor
            storage.addAttribute(.backgroundColor, value: color, range: matchRange)
        }
    }

    /// All ranges of `query` in `haystack` (display coordinates), case- and
    /// diacritic-insensitive. Shared by find and replace.
    func findMatches(of query: String, in haystack: NSString) -> [NSRange] {
        guard !query.isEmpty else { return [] }
        var ranges: [NSRange] = []
        let opts: NSString.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        var searchStart = 0
        while searchStart < haystack.length {
            let scope = NSRange(location: searchStart, length: haystack.length - searchStart)
            let found = haystack.range(of: query, options: opts, range: scope)
            if found.location == NSNotFound { break }
            ranges.append(found)
            searchStart = found.location + max(found.length, 1)
        }
        return ranges
    }

    /// - Parameters:
    ///   - query: echoed so a multi-document host can drop replies for a query
    ///     the user has already moved on from. Replies are delivered a
    ///     main-queue hop later, so stale ones do arrive.
    ///   - matchRect: the focused match in the wrapper's top-leading coordinate
    ///     space, for hosts that scroll the match into view themselves.
    private func postFindResults(count: Int, query: String? = nil, matchRect: CGRect? = nil) {
        guard let resultsName = configuration.services.bus.findResults else { return }
        var info: [AnyHashable: Any] = ["count": count]
        if let documentId {
            info["documentId"] = documentId
        }
        if let query {
            info["query"] = query
        }
        if let matchRect {
            info["matchRect"] = matchRect
        }
        NotificationCenter.default.post(name: resultsName, object: nil, userInfo: info)
    }

    /// Replace the current find match with the replacement string (one undo
    /// step), then re-highlight and report the remaining match count.
    @objc func handleReplaceCurrent(_ notification: Notification) {
        guard let tv = textView, tv.isEditable,
              let info = notification.userInfo,
              let query = info["query"] as? String, !query.isEmpty,
              let replacement = info["replacement"] as? String else { return }
        let requestedIndex = info["currentIndex"] as? Int ?? 0

        let matches = findMatches(of: query, in: tv.string as NSString)
        guard !matches.isEmpty else { postFindResults(count: 0, query: query); return }
        let idx = min(max(requestedIndex, 0), matches.count - 1)
        let target = matches[idx]
        guard NSMaxRange(target) <= (tv.string as NSString).length else { return }

        tv.breakUndoCoalescing()
        isProgrammaticEdit = true
        defer { isProgrammaticEdit = false }
        guard tv.shouldChangeText(in: target, replacementString: replacement) else { return }
        tv.textStorage?.replaceCharacters(in: target, with: replacement)
        tv.didChangeText()
        tv.undoManager?.setActionName("Replace")
        tv.breakUndoCoalescing()

        // Re-find on the edited text; keep the index so focus lands on the next
        // occurrence (or clamps to the last remaining one).
        let updated = findMatches(of: query, in: tv.string as NSString)
        let nextIndex = updated.isEmpty ? 0 : min(idx, updated.count - 1)
        renderFindMatches(updated, currentIndex: nextIndex)
        postFindResults(count: updated.count, query: query)
    }

    /// Replace every find match in a single undo step, then re-highlight.
    @objc func handleReplaceAll(_ notification: Notification) {
        guard let tv = textView, tv.isEditable,
              let info = notification.userInfo,
              let query = info["query"] as? String, !query.isEmpty,
              let replacement = info["replacement"] as? String else { return }

        let matches = findMatches(of: query, in: tv.string as NSString)
        guard !matches.isEmpty else { postFindResults(count: 0, query: query); return }

        // Group as one undo; edit back-to-front so earlier ranges stay valid.
        let orderedRanges = matches.reversed().map { NSValue(range: $0) }
        let replacements = Array(repeating: replacement, count: matches.count)

        tv.breakUndoCoalescing()
        isProgrammaticEdit = true
        defer { isProgrammaticEdit = false }
        guard tv.shouldChangeText(inRanges: orderedRanges, replacementStrings: replacements) else { return }
        tv.textStorage?.beginEditing()
        for match in matches.reversed() {
            tv.textStorage?.replaceCharacters(in: match, with: replacement)
        }
        tv.textStorage?.endEditing()
        tv.didChangeText()
        tv.undoManager?.setActionName("Replace All")
        tv.breakUndoCoalescing()

        // Usually zero remain; non-zero only if the replacement contains the query.
        let remaining = findMatches(of: query, in: tv.string as NSString)
        renderFindMatches(remaining, currentIndex: 0)
        postFindResults(count: remaining.count, query: query)
    }

    /// Highlight all matches (current one stronger) and scroll the current match into view.
    ///
    /// - Parameters:
    ///   - currentIndex: the focused match, or `nil` to highlight every match
    ///     without focusing any — what a document holds when a sibling document
    ///     owns the focus.
    ///   - scrollsToCurrentMatch: pass `false` when the host scrolls instead.
    private func renderFindMatches(
        _ allRanges: [NSRange],
        currentIndex: Int?,
        scrollsToCurrentMatch: Bool = true
    ) {
        guard let tv = textView else { return }
        let storage = tv.textStorage
        let fullRange = NSRange(location: 0, length: (tv.string as NSString).length)

        // Highlight all matches; the focused match gets a stronger color.
        let theme = configuration.theme
        let matchAlpha = configuration.markers.findMatchHighlightAlpha
        let highlightColor = theme.findMatchHighlight.withAlphaComponent(matchAlpha)
        let currentHighlightColor = theme.findCurrentMatchHighlight

        // One editing group: each attribute write is an edit that invalidates
        // layout on its own, so a query matching many times in a long document
        // would otherwise invalidate once per match, on every keystroke.
        storage?.beginEditing()
        // Undo the previous render's highlights before painting this one, which
        // also sweeps up any left in paragraphs an edit didn't restyle.
        removeFindHighlights(from: storage, range: fullRange)
        if let storage {
            applyFindHighlights(
                allRanges,
                currentIndex: currentIndex,
                in: storage,
                fullRange: fullRange,
                matchColor: highlightColor,
                currentMatchColor: currentHighlightColor
            )
        }
        storage?.endEditing()

        if let tlm = tv.textLayoutManager {
            tlm.ensureLayout(for: tlm.documentRange)
        }

        // Scroll the current match into view.
        guard scrollsToCurrentMatch,
              let currentIndex,
              allRanges.indices.contains(currentIndex) else { return }
        let range = allRanges[currentIndex]
        guard range.location + range.length <= fullRange.length else { return }
        // Scroll via TextKit 2 fragment layout, which works whether or not the
        // reading column is active. `scrollRangeToVisible` is unreliable for
        // off-screen content in a TextKit 2 text view (it routes through the
        // absent TextKit 1 layout manager), so it's only the last-resort fallback.
        // When the text view IS the document view, `tv.frame.origin.y` is 0 and
        // the offset below is a no-op, so the same math serves both layouts.
        guard let tlm = tv.textLayoutManager,
              let scrollView = tv.enclosingScrollView,
              let matchStart = tlm.textContentManager?.location(tlm.documentRange.location, offsetBy: range.location) else {
            tv.scrollRangeToVisible(range)
            return
        }
        tlm.enumerateTextLayoutFragments(from: matchStart, options: [.ensuresLayout]) { fragment in
            let cv = scrollView.contentView
            let insetsTop = scrollView.contentInsets.top
            // Fragment frames are text-view-local; the scroll offset is in
            // document-view space — lift by the text view's offset inside the
            // container (the header band).
            let frame = fragment.layoutFragmentFrame.offsetBy(dx: 0, dy: tv.frame.origin.y)
            let visibleTop = cv.bounds.origin.y + insetsTop
            let visibleBottom = cv.bounds.origin.y + cv.bounds.height
            // Only scroll when the match is off-screen; reveal it a little below the top.
            if frame.minY < visibleTop || frame.maxY > visibleBottom {
                let targetY = frame.minY - insetsTop - cv.bounds.height * 0.2
                cv.scroll(to: NSPoint(x: cv.bounds.origin.x, y: targetY))
                scrollView.reflectScrolledClipView(cv)
                (scrollView as? ClampedScrollView)?.clampToInsets()
            }
            return false
        }
    }

    @objc func handleFindClearHighlights(_ notification: Notification) {
        guard let tv = textView else { return }
        // Nothing to undo means nothing to do. Without this, opening find and
        // dismissing it before typing would run the restore path over a document
        // find never touched, and the scroll-anchor bookkeeping below would move
        // the view for no reason.
        guard hasFindHighlights(in: tv.textStorage) else { return }

        let scrollView = tv.enclosingScrollView
        let preY = scrollView?.contentView.bounds.origin.y ?? 0
        let insetsTop = scrollView?.contentInsets.top ?? 0
        let visualTopDocY = preY + insetsTop
        var anchorOffsetFromTop: CGFloat = 0
        var anchorTextRange: NSTextRange? = nil
        // Fragment frames are text-view-local; visualTopDocY is in document-view
        // space — lift them by the text view's offset inside the container (the
        // header band) before comparing.
        let textViewTop = tv.frame.origin.y
        if let tlm = tv.textLayoutManager {
            tlm.enumerateTextLayoutFragments(from: tlm.documentRange.location, options: [.ensuresLayout]) { fragment in
                let frame = fragment.layoutFragmentFrame.offsetBy(dx: 0, dy: textViewTop)
                if frame.maxY < visualTopDocY { return true }
                anchorTextRange = fragment.rangeInElement
                anchorOffsetFromTop = visualTopDocY - frame.minY
                return false
            }
        }

        // Restore what find overwrote rather than clearing `.backgroundColor`
        // wholesale: inline code, fenced blocks and code in tables are drawn
        // with that same attribute, so a blanket removal outlives the search.
        let fullRange = NSRange(location: 0, length: (tv.string as NSString).length)
        tv.textStorage?.beginEditing()
        removeFindHighlights(from: tv.textStorage, range: fullRange)
        tv.textStorage?.endEditing()
        if let tlm = tv.textLayoutManager {
            tlm.ensureLayout(for: tlm.documentRange)
        }

        if let tlm = tv.textLayoutManager, let anchor = anchorTextRange {
            tlm.enumerateTextLayoutFragments(from: anchor.location, options: [.ensuresLayout]) { fragment in
                let newDocY = fragment.layoutFragmentFrame.minY + textViewTop + anchorOffsetFromTop
                let targetScrollY = newDocY - insetsTop
                if let cv = scrollView?.contentView, abs(cv.bounds.origin.y - targetScrollY) > 0.5 {
                    cv.scroll(to: NSPoint(x: cv.bounds.origin.x, y: targetScrollY))
                    scrollView?.reflectScrolledClipView(cv)
                }
                return false
            }
        }
    }
}
