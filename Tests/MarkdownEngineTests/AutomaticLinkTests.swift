import AppKit
import Foundation
import SwiftUI
import Testing
@testable import MarkdownEngine

private struct KnownTextProvider: AutomaticLinkProvider {
    let targets: Set<String>

    func matches(in text: String, range: NSRange) -> [AutomaticLinkMatch] {
        let ns = text as NSString
        return targets.compactMap { target in
            let found = ns.range(of: target, options: [], range: range)
            guard found.location != NSNotFound else { return nil }
            return AutomaticLinkMatch(
                range: found,
                target: target,
                activationPolicy: .commandClickWhenEditable
            )
        }
    }

    func fingerprint() -> AnyHashable { targets }
}

@Suite("Automatic links")
struct AutomaticLinkTests {
    @Test("only AST-approved plain text receives automatic links")
    func protectedMarkdownSyntaxIsExcluded() {
        let text = "bd-1 **bd-2** `bd-3` [bd-4](https://example.com) [[bd-5]] ![bd-6](image.png) ~~bd-7~~ ==bd-8==\n```\nbd-9\n```"
        let targets = Set((1...9).map { "bd-\($0)" })
        var config = MarkdownEditorConfiguration.default
        config.services.automaticLinks = KnownTextProvider(targets: targets)

        let styles = MarkdownStyler.styleAttributes(
            text: text,
            fontName: "SF Pro",
            fontSize: 16,
            caretLocation: -1,
            activeTokenIndices: [],
            configuration: config
        )
        let linkedTargets = Set(styles.compactMap { $0.attributes[AutomaticLinkService.targetAttribute] as? String })

        #expect(linkedTargets == ["bd-1", "bd-2", "bd-7", "bd-8"])
    }

    @Test("scoped styling invokes links only in the requested paragraph")
    func scopedStyling() {
        let text = "bd-1\n\nbd-2"
        var config = MarkdownEditorConfiguration.default
        config.services.automaticLinks = KnownTextProvider(targets: ["bd-1", "bd-2"])

        let styles = MarkdownStyler.styleAttributes(
            text: text,
            fontName: "SF Pro",
            fontSize: 16,
            caretLocation: -1,
            activeTokenIndices: [],
            scopedRanges: [NSRange(location: 0, length: 5)],
            configuration: config
        )

        #expect(styles.compactMap { $0.attributes[AutomaticLinkService.targetAttribute] as? String } == ["bd-1"])
    }

    @Test("automatic link activation policy is stored with the link")
    func activationPolicyRoundTrips() {
        let storage = NSTextStorage(string: "bd-1")
        storage.addAttribute(
            AutomaticLinkService.activationAttribute,
            value: 1,
            range: NSRange(location: 0, length: 4)
        )

        #expect(AutomaticLinkService.activationPolicy(in: storage, at: 2) == .commandClickWhenEditable)
        #expect(AutomaticLinkService.activationPolicy(in: storage, at: 4) == nil)
    }

    @Test("ordinary clicks on command-click links are consumed and place the caret")
    @MainActor
    func ordinaryClickDoesNotEscapeToLaunchServices() {
        var text = "bd-1"
        var isWikiLinkActive = false
        var clickedTargets: [String] = []
        let coordinator = NativeTextViewCoordinator(
            text: Binding(get: { text }, set: { text = $0 }),
            fontName: "SF Pro",
            fontSize: 16,
            isWikiLinkActive: Binding(
                get: { isWikiLinkActive },
                set: { isWikiLinkActive = $0 }
            ),
            onLinkClick: { clickedTargets.append($0) },
            onInlineSelectionChange: nil
        )
        let textView = NativeTextView(frame: CGRect(x: 0, y: 0, width: 200, height: 40))
        textView.string = text
        textView.isEditable = true
        textView.textStorage?.addAttributes([
            .link: "beads://bead/bd-1",
            AutomaticLinkService.activationAttribute: 1
        ], range: NSRange(location: 0, length: 4))
        textView.activeMouseDownModifierFlags = []

        let handled = coordinator.textView(
            textView,
            clickedOnLink: "beads://bead/bd-1",
            at: 2
        )

        #expect(handled)
        #expect(textView.selectedRange() == NSRange(location: 2, length: 0))
        #expect(clickedTargets.isEmpty)
    }

    @Test("native view installs automatic-link mouse tracking")
    @MainActor
    func installsMouseTracking() {
        let textView = NativeTextView(frame: CGRect(x: 0, y: 0, width: 200, height: 40))
        textView.updateTrackingAreas()

        let options = textView.automaticLinkTrackingArea?.options
        #expect(options?.contains(.mouseMoved) == true)
        #expect(options?.contains(.mouseEnteredAndExited) == true)
        #expect(options?.contains(.cursorUpdate) == true)
    }
}
