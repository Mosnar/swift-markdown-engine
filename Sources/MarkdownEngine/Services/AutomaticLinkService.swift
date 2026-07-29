import AppKit
import Foundation

enum AutomaticLinkService {
    static let targetAttribute = NSAttributedString.Key("MarkdownEngineAutomaticLinkTarget")
    static let activationAttribute = NSAttributedString.Key("MarkdownEngineAutomaticLinkActivation")

    static func styledRanges(
        in text: String,
        blocks: [BlockNode],
        provider: any AutomaticLinkProvider
    ) -> [StyledRange] {
        let documentLength = (text as NSString).length
        guard documentLength > 0 else { return [] }

        var result: [StyledRange] = []
        for range in plainTextRanges(in: blocks) {
            for match in provider.matches(in: text, range: range) {
                guard isValid(match.range, inside: range, documentLength: documentLength),
                      !match.target.isEmpty else { continue }
                result.append((match.range, [
                    .link: match.target,
                    targetAttribute: match.target,
                    activationAttribute: activationValue(match.activationPolicy)
                ]))
            }
        }
        return result
    }

    static func activationPolicy(
        in textStorage: NSTextStorage,
        at characterIndex: Int
    ) -> AutomaticLinkMatch.ActivationPolicy? {
        guard characterIndex >= 0, characterIndex < textStorage.length,
              let raw = textStorage.attribute(activationAttribute, at: characterIndex, effectiveRange: nil) as? Int else {
            return nil
        }
        return raw == 1 ? .commandClickWhenEditable : .standard
    }

    private static func activationValue(_ policy: AutomaticLinkMatch.ActivationPolicy) -> Int {
        policy == .commandClickWhenEditable ? 1 : 0
    }

    private static func isValid(_ match: NSRange, inside allowed: NSRange, documentLength: Int) -> Bool {
        match.location != NSNotFound
            && match.length > 0
            && match.location >= allowed.location
            && NSMaxRange(match) <= NSMaxRange(allowed)
            && NSMaxRange(match) <= documentLength
    }

    private static func plainTextRanges(in blocks: [BlockNode]) -> [NSRange] {
        var ranges: [NSRange] = []
        for block in blocks {
            switch block {
            case .paragraph(_, let inlines), .heading(_, _, _, let inlines), .blockquote(_, let inlines):
                appendPlainRanges(from: inlines, into: &ranges)
            case .list(_, let items):
                for item in items {
                    appendPlainRanges(from: item.inlines, into: &ranges)
                }
            // Extension blocks are fence-delimited like code blocks, so their
            // content stays literal — the extension owns what its fences mean.
            case .codeBlock, .blockLatex, .table, .thematicBreak, .blank, .ext:
                break
            }
        }
        return ranges
    }

    private static func appendPlainRanges(from nodes: [InlineNode], into ranges: inout [NSRange]) {
        for node in nodes {
            switch node {
            case .text(let range):
                ranges.append(range)
            case .emphasis(_, _, _, let children):
                appendPlainRanges(from: children, into: &ranges)
            // Strikethrough and highlight are extension-contributed spans now.
            // Opaque extensions carry no children, so this is a no-op for them.
            case .ext(let node):
                appendPlainRanges(from: node.children, into: &ranges)
            case .code, .link, .image, .wikiLink, .imageEmbed, .inlineLatex, .escape:
                break
            }
        }
    }
}
