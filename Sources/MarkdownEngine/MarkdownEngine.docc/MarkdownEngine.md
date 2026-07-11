# ``MarkdownEngine``

A TextKit 2-backed Markdown editor view for macOS, bridged to SwiftUI.

## Overview

MarkdownEngine provides a native AppKit Markdown editor with live styling,
wiki-style ``[[Name]]`` linking, fenced code blocks with syntax highlighting,
LaTeX rendering, embedded images, and GitHub-style task checkboxes.

The engine itself has **zero external dependencies**. Everything app-specific
is injected through small service protocols, so embedders stay in control of
where wiki-links resolve, where embedded images live, how code is highlighted,
and how LaTeX is rendered.

### Quick Start

```swift
import SwiftUI
import MarkdownEngine

struct EditorScreen: View {
    @State private var text: String = "# Hello, *world*"
    @State private var isLinkActive: Bool = false
    @State private var pendingReplacement: InlineReplacementRequest?

    var body: some View {
        NativeTextViewWrapper(
            text: $text,
            isWikiLinkActive: $isLinkActive,
            pendingInlineReplacement: $pendingReplacement,
            configuration: .default,
            fontName: "SF Pro",
            documentId: "doc-1"
        )
    }
}
```

The default ``MarkdownEditorConfiguration`` ships with no-op service
implementations, so the editor renders plain Markdown out of the box. Add
real services as you need them.

### Automatic Links

Inject an ``AutomaticLinkProvider`` through
``MarkdownEditorServices/automaticLinks`` to recognize host-defined targets
inside plain text. The engine excludes code and existing Markdown constructs,
then owns the resulting TextKit attributes in its normal scoped restyle pass.
Use ``AutomaticLinkMatch/ActivationPolicy/commandClickWhenEditable`` to keep
ordinary clicks available for caret placement, and
``NativeTextViewWrapper/onLinkHoverChange`` to drive preview UI.

### Customizing Appearance

```swift
var theme = MarkdownEditorTheme.default
theme.bodyText = .labelColor
theme.headingMarker = .secondaryLabelColor

var configuration = MarkdownEditorConfiguration.default
configuration.theme = theme
```

### Wiring Up Services

```swift
let services = MarkdownEditorServices(
    wikiLinks: MyWikiLinkResolver(),
    images:    MyImageProvider(),
    syntaxHighlighter: MySyntaxHighlighter(),
    latex:     MyLatexRenderer()
)

var configuration = MarkdownEditorConfiguration.default
configuration.services = services
```

## Topics

### Editor View

- ``NativeTextViewWrapper``

### Configuration

- ``MarkdownEditorConfiguration``
- ``MarkdownEditorTheme``

### Service Protocols

- ``AutomaticLinkProvider``
- ``AutomaticLinkMatch``
- ``LinkHoverState``
- ``WikiLinkResolver``
- ``EmbeddedImageProvider``
- ``SyntaxHighlighter``
- ``LatexRenderer``

### Services Container

- ``MarkdownEditorServices``
- ``MarkdownEditorBus``

### Default No-Op Implementations

- ``NoOpAutomaticLinkProvider``
- ``NoOpWikiLinkResolver``
- ``NoOpEmbeddedImageProvider``
- ``PlainTextSyntaxHighlighter``
- ``NoOpLatexRenderer``

### Selection & Replacement

- ``InlineSelectionState``
- ``InlineSelectionKind``
- ``WikiLinkSelection``
- ``InlineReplacementRequest``
- ``CodeBlockSelection``

### Wiki-Link Roundtripping

- ``WikiLinkService``

### Pasteboard Helpers

- ``PasteboardImageReader``
