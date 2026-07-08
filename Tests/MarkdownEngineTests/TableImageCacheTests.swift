//
//  TableImageCacheTests.swift
//  MarkdownEngine
//
//  Created by Luca Chen on 07.07.26.
//

import AppKit
import Foundation
import Testing
@testable import MarkdownEngine

@Suite("Table image cache")
struct TableImageCacheTests {

    private func makeContext(for source: String) -> MarkdownStyler.StylingContext {
        let font = NSFont.systemFont(ofSize: 15)
        return MarkdownStyler.StylingContext(
            nsText: source as NSString,
            tokens: [],
            codeTokens: [],
            activeTokenIndices: [],
            baseFont: font,
            layoutBridge: nil,
            baseDefaultLineHeight: 18,
            codeBackgroundColor: .windowBackgroundColor,
            latexMarkerFont: font,
            configuration: .default,
            wikiLinkIDProvider: { _ in nil }
        )
    }

    @Test func secondRequestIsServedFromCache() throws {
        let source = "| alpha | beta |\n|---|---|\n| 1 | 2 |"
        let parsed = try #require(MarkdownStyler.parseTableSource(source))
        let ctx = makeContext(for: source)
        let aqua = try #require(NSAppearance(named: .aqua))

        let first = MarkdownStyler.tableImage(for: source, parsed: parsed, ctx: ctx, appearance: aqua)
        let second = MarkdownStyler.tableImage(for: source, parsed: parsed, ctx: ctx, appearance: aqua)

        #expect(first.rendered)
        #expect(!second.rendered)
        #expect(first.image === second.image)
    }

    @Test func appearanceChangeRendersFresh() throws {
        let source = "| gamma | delta |\n|---|---|\n| 3 | 4 |"
        let parsed = try #require(MarkdownStyler.parseTableSource(source))
        let ctx = makeContext(for: source)
        let aqua = try #require(NSAppearance(named: .aqua))
        let dark = try #require(NSAppearance(named: .darkAqua))

        _ = MarkdownStyler.tableImage(for: source, parsed: parsed, ctx: ctx, appearance: aqua)
        let darkResult = MarkdownStyler.tableImage(for: source, parsed: parsed, ctx: ctx, appearance: dark)

        #expect(darkResult.rendered)
    }
}
