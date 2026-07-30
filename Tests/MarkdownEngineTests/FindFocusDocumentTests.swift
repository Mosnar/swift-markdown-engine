//
//  FindFocusDocumentTests.swift
//  MarkdownEngineTests
//
//  Headless tests for multi-document find: `focusDocumentId` targeting, and the
//  `documentId` / `query` / `matchRect` payload a host needs to aggregate
//  several documents into one "x of y" and scroll the match itself.
//

import AppKit
import SwiftUI
import Testing
@testable import MarkdownEngine

@MainActor
@Suite("Multi-document find")
struct FindFocusDocumentTests {
    private static let queryName = Notification.Name("test.find.query")
    private static let resultsName = Notification.Name("test.find.results")

    private struct Editor {
        let textView: NativeTextView
        let coordinator: NativeTextViewCoordinator
        /// Retains the scroll view so `wrapperAnchorRect` has one to convert into.
        let scrollView: NSScrollView
    }

    private func makeEditor(documentId: String, text: String) -> Editor {
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        let textView = NativeTextView(frame: scrollView.contentView.bounds)
        textView.minSize = .zero
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.isVerticallyResizable = true
        textView.isEditable = true

        var config = MarkdownEditorConfiguration.default
        config.services.bus = MarkdownEditorBus(
            findQuery: Self.queryName,
            findResults: Self.resultsName
        )
        textView.configuration = config

        let coordinator = NativeTextViewCoordinator(
            text: .constant(""),
            fontName: "SF Pro Text",
            fontSize: 14,
            isWikiLinkActive: .constant(false),
            onLinkClick: nil,
            onInlineSelectionChange: nil
        )
        coordinator.textView = textView
        coordinator.documentId = documentId
        // Assigning the configuration is what subscribes the bus observers.
        coordinator.configuration = config
        scrollView.documentView = textView
        textView.string = text

        // `wrapperAnchorRect` needs the TextKit 2 bridge and a laid-out
        // document to produce a match rect, exactly as the wrapper sets up in
        // `makeNSView`.
        if let textLayoutManager = textView.textLayoutManager {
            let bridge = LayoutBridge(textLayoutManager)
            coordinator.layoutBridge = bridge
            textView.layoutBridge = bridge
            textLayoutManager.ensureLayout(for: textLayoutManager.documentRange)
        }

        return Editor(textView: textView, coordinator: coordinator, scrollView: scrollView)
    }

    private func backgroundColors(in textView: NSTextView) -> [NSColor] {
        guard let storage = textView.textStorage else { return [] }
        var colors: [NSColor] = []
        storage.enumerateAttribute(
            .backgroundColor,
            in: NSRange(location: 0, length: storage.length)
        ) { value, _, _ in
            if let color = value as? NSColor {
                colors.append(color)
            }
        }
        return colors
    }

    // MARK: - Query targeting

    @Test("Only the focused document paints a current-match highlight")
    func onlyFocusedDocumentPaintsCurrentMatch() {
        let focused = makeEditor(documentId: "doc-a", text: "alpha alpha")
        let unfocused = makeEditor(documentId: "doc-b", text: "alpha alpha")
        let theme = MarkdownEditorConfiguration.default.theme
        let currentColor = theme.findCurrentMatchHighlight

        focused.coordinator.handleFindQuery(Notification(
            name: Self.queryName,
            object: nil,
            userInfo: ["query": "alpha", "currentIndex": 0, "focusDocumentId": "doc-a"]
        ))
        unfocused.coordinator.handleFindQuery(Notification(
            name: Self.queryName,
            object: nil,
            userInfo: ["query": "alpha", "currentIndex": 0, "focusDocumentId": "doc-a"]
        ))

        // Both highlight every match; only the focused one has a current match.
        #expect(backgroundColors(in: focused.textView).count == 2)
        #expect(backgroundColors(in: unfocused.textView).count == 2)
        #expect(backgroundColors(in: focused.textView).contains(currentColor))
        #expect(!backgroundColors(in: unfocused.textView).contains(currentColor))
    }

    @Test("Without focusDocumentId the single-document behavior is unchanged")
    func singleDocumentBehaviorIsUnchanged() {
        let editor = makeEditor(documentId: "doc-a", text: "alpha alpha")
        let currentColor = MarkdownEditorConfiguration.default.theme.findCurrentMatchHighlight

        editor.coordinator.handleFindQuery(Notification(
            name: Self.queryName,
            object: nil,
            userInfo: ["query": "alpha", "currentIndex": 1]
        ))

        #expect(backgroundColors(in: editor.textView).contains(currentColor))
    }

    // MARK: - Results payload

    @Test("Results identify the document and echo the query")
    func resultsIdentifyDocumentAndEchoQuery() async {
        let editor = makeEditor(documentId: "doc-a", text: "alpha beta alpha")
        var received: [AnyHashable: Any]?
        let observer = NotificationCenter.default.addObserver(
            forName: Self.resultsName,
            object: nil,
            queue: nil
        ) { note in
            received = note.userInfo
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        editor.coordinator.handleFindQuery(Notification(
            name: Self.queryName,
            object: nil,
            userInfo: ["query": "alpha", "currentIndex": 0, "focusDocumentId": "doc-a"]
        ))

        #expect(received?["documentId"] as? String == "doc-a")
        #expect(received?["query"] as? String == "alpha")
        #expect(received?["count"] as? Int == 2)
    }

    @Test("Only the focused document reports a match rect")
    func onlyFocusedDocumentReportsMatchRect() {
        let focused = makeEditor(documentId: "doc-a", text: "alpha alpha")
        let unfocused = makeEditor(documentId: "doc-b", text: "alpha alpha")
        var rects: [String: CGRect?] = [:]
        let observer = NotificationCenter.default.addObserver(
            forName: Self.resultsName,
            object: nil,
            queue: nil
        ) { note in
            guard let id = note.userInfo?["documentId"] as? String else { return }
            rects[id] = note.userInfo?["matchRect"] as? CGRect
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        let info: [AnyHashable: Any] = [
            "query": "alpha",
            "currentIndex": 0,
            "focusDocumentId": "doc-a"
        ]
        focused.coordinator.handleFindQuery(
            Notification(name: Self.queryName, object: nil, userInfo: info)
        )
        unfocused.coordinator.handleFindQuery(
            Notification(name: Self.queryName, object: nil, userInfo: info)
        )

        // The focused document reports where to scroll; doc-b replied but
        // carries no rect, because it owns no focused match.
        #expect(rects["doc-a"] ?? nil != nil)
        #expect(rects["doc-b"] != nil)
        #expect(rects["doc-b"] ?? nil == nil)
    }

    /// The rest of these call `handleFindQuery` directly; this one goes through
    /// NotificationCenter so the bus subscription itself is covered — assigning
    /// `coordinator.configuration` is what installs those observers.
    @Test("A query posted on the bus reaches the coordinator")
    func postedQueryReachesTheCoordinator() async {
        let editor = makeEditor(documentId: "doc-posted", text: "alpha beta alpha")
        var count: Int?
        let observer = NotificationCenter.default.addObserver(
            forName: Self.resultsName,
            object: nil,
            queue: nil
        ) { note in
            guard note.userInfo?["documentId"] as? String == "doc-posted" else { return }
            count = note.userInfo?["count"] as? Int
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        NotificationCenter.default.post(
            name: Self.queryName,
            object: nil,
            userInfo: ["query": "alpha", "currentIndex": 0, "focusDocumentId": "doc-posted"]
        )
        // Bus observers are registered on the main queue, so delivery is a hop away.
        for _ in 0..<3 {
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async { continuation.resume() }
            }
        }

        #expect(count == 2)
        _ = editor
    }

    // MARK: - Preserving the styler's backgrounds

    /// Inline code, fenced blocks and code in tables are all drawn with
    /// `.backgroundColor`, the same attribute find highlights with, so find must
    /// restore them rather than leave the document stripped.
    @Test("Searching preserves the styler's own backgrounds and clearing restores them")
    func stylerBackgroundsSurviveFind() {
        let editor = makeEditor(documentId: "doc-a", text: "alpha `code` alpha")
        let storage = editor.textView.textStorage!
        let fullRange = NSRange(location: 0, length: storage.length)

        // Stand in for the styler: a background the find code did not apply.
        let codeRange = (editor.textView.string as NSString).range(of: "`code`")
        let codeBackground = NSColor.systemGray
        storage.addAttribute(.backgroundColor, value: codeBackground, range: codeRange)

        func codeBackgroundIsIntact() -> Bool {
            var effective = NSRange(location: 0, length: 0)
            let value = storage.attribute(
                .backgroundColor,
                at: codeRange.location,
                longestEffectiveRange: &effective,
                in: fullRange
            )
            return (value as? NSColor) == codeBackground
        }

        #expect(codeBackgroundIsIntact())

        editor.coordinator.handleFindQuery(Notification(
            name: Self.queryName,
            object: nil,
            userInfo: ["query": "alpha", "currentIndex": 0, "focusDocumentId": "doc-a"]
        ))

        // Matches are highlighted, and the code background is untouched.
        #expect(backgroundColors(in: editor.textView).contains(codeBackground))
        #expect(codeBackgroundIsIntact())

        // Re-running with a different query must not accumulate or drop it.
        editor.coordinator.handleFindQuery(Notification(
            name: Self.queryName,
            object: nil,
            userInfo: ["query": "lph", "currentIndex": 0, "focusDocumentId": "doc-a"]
        ))
        #expect(codeBackgroundIsIntact())

        editor.coordinator.handleFindClearHighlights(Notification(
            name: Notification.Name("test.find.clear"),
            object: nil
        ))

        // Done leaves exactly the styler's background behind.
        #expect(codeBackgroundIsIntact())
        #expect(backgroundColors(in: editor.textView) == [codeBackground])
    }

    @Test("Clearing without ever having searched leaves the document untouched")
    func clearingWithoutSearchingIsANoOp() {
        let editor = makeEditor(documentId: "doc-a", text: "alpha `code` alpha")
        let storage = editor.textView.textStorage!
        let codeRange = (editor.textView.string as NSString).range(of: "`code`")
        storage.addAttribute(.backgroundColor, value: NSColor.systemGray, range: codeRange)

        // Open-then-dismiss before typing: the host posts clearHighlights even
        // though no query ever ran.
        editor.coordinator.handleFindClearHighlights(Notification(
            name: Notification.Name("test.find.clear"),
            object: nil
        ))

        #expect(backgroundColors(in: editor.textView) == [NSColor.systemGray])
    }

    @Test("Highlights left in unrestyled paragraphs are not mistaken for styling")
    func staleHighlightsAreNotAdoptedAsStyling() {
        // Two paragraphs; an edit restyles only the one it touches, so find's
        // highlight survives in the other and must still be removable.
        let editor = makeEditor(documentId: "doc-a", text: "alpha one\n\nalpha two")
        let storage = editor.textView.textStorage!

        editor.coordinator.handleFindQuery(Notification(
            name: Self.queryName,
            object: nil,
            userInfo: ["query": "alpha", "currentIndex": 0, "focusDocumentId": "doc-a"]
        ))
        #expect(backgroundColors(in: editor.textView).count == 2)

        // Stand in for a paragraph-scoped restyle of the first paragraph only:
        // it rewrites attributes there, dropping both the highlight and its
        // marker, and leaves the second paragraph as find left it.
        let firstParagraph = NSRange(location: 0, length: 9)
        storage.removeAttribute(.backgroundColor, range: firstParagraph)
        storage.removeAttribute(.markdownFindHighlight, range: firstParagraph)

        editor.coordinator.handleFindClearHighlights(Notification(
            name: Notification.Name("test.find.clear"),
            object: nil
        ))

        // The surviving highlight is gone rather than adopted as permanent styling.
        #expect(backgroundColors(in: editor.textView).isEmpty)
    }

    @Test("A match overlapping code returns the code background after clearing")
    func matchInsideCodeRestoresBackground() {
        let editor = makeEditor(documentId: "doc-a", text: "see `alpha` here")
        let storage = editor.textView.textStorage!
        let codeRange = (editor.textView.string as NSString).range(of: "`alpha`")
        storage.addAttribute(.backgroundColor, value: NSColor.systemGray, range: codeRange)

        editor.coordinator.handleFindQuery(Notification(
            name: Self.queryName,
            object: nil,
            userInfo: ["query": "alpha", "currentIndex": 0, "focusDocumentId": "doc-a"]
        ))
        editor.coordinator.handleFindClearHighlights(Notification(
            name: Notification.Name("test.find.clear"),
            object: nil
        ))

        #expect(backgroundColors(in: editor.textView) == [NSColor.systemGray])
    }

    @Test("A query matching nothing reports zero for the document")
    func noMatchesReportsZero() {
        let editor = makeEditor(documentId: "doc-a", text: "alpha beta")
        var count: Int?
        let observer = NotificationCenter.default.addObserver(
            forName: Self.resultsName,
            object: nil,
            queue: nil
        ) { note in
            count = note.userInfo?["count"] as? Int
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        editor.coordinator.handleFindQuery(Notification(
            name: Self.queryName,
            object: nil,
            userInfo: ["query": "gamma", "currentIndex": 0, "focusDocumentId": "doc-a"]
        ))

        #expect(count == 0)
        #expect(backgroundColors(in: editor.textView).isEmpty)
    }
}
