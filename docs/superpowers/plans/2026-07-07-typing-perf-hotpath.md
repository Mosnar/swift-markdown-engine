# Typing-Performance Hot-Path Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Cut the per-keystroke cost that scales with document length, so typing latency stays (near-)constant regardless of file size.

**Architecture:** The engine's per-keystroke path is `NativeTextViewCoordinator.textDidChange` → wiki-link storage sync → backtick census → `parsedDocument` (tokenize) → paragraph-scoped restyle → `ensureVisibleLayout`. Measured with PerfTrace (Debug build): a 139k-char doc costs ~12.8 ms/keystroke vs ~1.1 ms for a 456-char doc; a doc with 10 tables costs 13–28 ms because every table re-renders to NSImage on every keystroke. Each task below removes one measured O(doc) cost with a bounded, fallback-guarded replacement. No behavioral changes intended — every task must leave `swift test` green.

**Tech Stack:** Swift 5.9 SPM package (`swift build` / `swift test`), AppKit NSTextView + TextKit 2, Swift Testing (`import Testing`, `@Suite`/`@Test`/`#expect`) for tests.

## Global Constraints

- Repo: `/Users/lucachen/Desktop/swift-markdown-engine` (the `~/Documents/GitHub` clone is stale — never touch it).
- Work happens on branch `perf/typing-hotpath`, created from `main` in Task 0. Commit per task; **never push** and never tag/release — Luca releases manually after sign-off.
- Every **new** source file starts with the Xcode header comment: `//  <File>.swift` / `//  MarkdownEngine` / `//  Created by Luca Chen on 07.07.26.`
- The engine ships API only — no UI components.
- Build check: `swift build` → `Build complete!`. Test check: `swift test` → all suites pass. SourceKit "cannot find type" diagnostics in extensions are known false positives — trust `swift build` only.
- End commit messages with `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.
- The Nodes app repo (`~/Documents/GitHub/Nodes`) currently points at this local engine checkout via an uncommitted pbxproj override — needed for live measurement in Task 6. Do not commit anything in the app repo.
- PerfTrace instrumentation (Debug-only) stays in place through all tasks — Task 6 uses it for before/after numbers. Its eventual removal is a separate post-sign-off step.
- All measured numbers are Debug (`-Onone`); ratios are meaningful, absolute times are inflated. Algorithmic fixes here are build-independent.

**Measured baseline (2026-07-07, Debug):**

| Scenario | total/keystroke | dominant phases |
|---|---|---|
| 139k chars, plain | ~12.8 ms | parse 6.4, wiki 3.4, restyle 1.7, backtick 0.75 |
| 456 chars | ~1.1 ms | restyle ~1.0 |
| 7.9k chars, 10 tables | 13–28 ms | restyle 12–26 (styleTables 7–17, all 10 tables re-rendered), ensureVisibleLayout walks 130 frags (115 wasted) |

---

### Task 0: Branch setup + commit the PerfTrace instrumentation

**Files:**
- No source changes; git only. The working tree currently sits on `pr/87` with uncommitted edits to 4 files + the new `Sources/MarkdownEngine/Diagnostics/PerfTrace.swift`. None of these files differ between `pr/87` and `main` (verified via `git diff main...HEAD --name-only`), so the edits carry across the switch.

**Interfaces:**
- Produces: branch `perf/typing-hotpath` (from `main`) containing the committed PerfTrace instrumentation that all later tasks build on and Task 6 measures with.

- [ ] **Step 1: Switch to main and branch**

```bash
cd /Users/lucachen/Desktop/swift-markdown-engine
git fetch origin
git switch main
git pull --ff-only
git switch -c perf/typing-hotpath
```

Expected: switch succeeds with "M" markers for the 4 modified files (edits carried over), no conflicts.

- [ ] **Step 2: Build to verify the carried edits compile on main**

Run: `swift build`
Expected: `Build complete!`

- [ ] **Step 3: Commit the instrumentation**

```bash
git add Sources/MarkdownEngine/Diagnostics/PerfTrace.swift \
  Sources/MarkdownEngine/TextView/Coordinator/NativeTextViewCoordinator+TextDelegate.swift \
  Sources/MarkdownEngine/TextView/NativeTextView/NativeTextView+FrameAndOverscroll.swift \
  Sources/MarkdownEngine/Styling/MarkdownStyler+Tables.swift \
  Sources/MarkdownEngine/Renderer/WideTableOverlay.swift
git commit -m "chore: temporary PerfTrace typing instrumentation (Debug-only)

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 1: Cache rendered table images (biggest measured win: 7–17 ms → ~0 in table docs)

**Files:**
- Modify: `Sources/MarkdownEngine/Styling/MarkdownStyler+Tables.swift` (styleTables ~line 28–110)
- Test: Create `Tests/MarkdownEngineTests/TableImageCacheTests.swift`

**Interfaces:**
- Consumes: existing `renderTable(_:baseFont:theme:codeBackgroundColor:latex:appearance:)` and `parseTableSource(_:) -> ParsedTable?` in the same file; `MarkdownStyler.StylingContext` (fields: `baseFont`, `codeBackgroundColor`, `configuration`, `services`).
- Produces: `static func tableImage(for source: String, parsed: ParsedTable, ctx: StylingContext, appearance: NSAppearance) -> (image: NSImage, rendered: Bool)` on `MarkdownStyler` — `rendered == false` means cache hit.

**Why:** `styleTables` currently calls `renderTable` for **every inactive table in the document on every keystroke** (PerfTrace: `scanned=10, re-rendered=10 NSImage in 7–17ms`). Table content only changes when its source text changes — a source-keyed cache makes steady-state typing free.

- [ ] **Step 1: Write the failing test**

Create `Tests/MarkdownEngineTests/TableImageCacheTests.swift`:

```swift
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter TableImageCacheTests 2>&1 | tail -5`
Expected: FAIL / compile error — `tableImage(for:parsed:ctx:appearance:)` does not exist.

- [ ] **Step 3: Implement the cache**

In `Sources/MarkdownEngine/Styling/MarkdownStyler+Tables.swift`, add inside `extension MarkdownStyler` (above `styleTables`):

```swift
    /// Rendered-table image cache. A table's pixels depend only on its source,
    /// font, colors, and appearance — so identical keys can reuse the NSImage
    /// instead of re-rendering every inactive table on every keystroke.
    private static let tableImageCache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 128
        return cache
    }()

    /// Returns the rendered image for `source`, from cache when possible.
    /// `rendered` is true only when a fresh render actually happened.
    static func tableImage(
        for source: String,
        parsed: ParsedTable,
        ctx: StylingContext,
        appearance: NSAppearance
    ) -> (image: NSImage, rendered: Bool) {
        let key = "\(ctx.baseFont.fontName)|\(ctx.baseFont.pointSize)|\(appearance.name.rawValue)|\(ctx.configuration.theme.bodyText)|\(ctx.codeBackgroundColor)|\(source)" as NSString
        if let cached = tableImageCache.object(forKey: key) {
            return (cached, false)
        }
        let image = renderTable(
            parsed,
            baseFont: ctx.baseFont,
            theme: ctx.configuration.theme,
            codeBackgroundColor: ctx.codeBackgroundColor,
            latex: ctx.services.latex,
            appearance: appearance
        )
        tableImageCache.setObject(image, forKey: key)
        return (image, true)
    }
```

Then in `styleTables`, replace the direct render call:

```swift
            // See renderTable: resolve table colors under the text view's real appearance.
            let renderAppearance = ctx.layoutBridge?.firstTextContainer?.textView?.effectiveAppearance
                ?? NSApp.effectiveAppearance
            let image = renderTable(
                parsed,
                baseFont: ctx.baseFont,
                theme: ctx.configuration.theme,
                codeBackgroundColor: ctx.codeBackgroundColor,
                latex: ctx.services.latex,
                appearance: renderAppearance
            )
            renderedCount += 1
            let imageBounds = CGRect(x: 0, y: 0, width: image.size.width, height: image.size.height)
```

with:

```swift
            // See renderTable: resolve table colors under the text view's real appearance.
            let renderAppearance = ctx.layoutBridge?.firstTextContainer?.textView?.effectiveAppearance
                ?? NSApp.effectiveAppearance
            let (image, rendered) = tableImage(
                for: source,
                parsed: parsed,
                ctx: ctx,
                appearance: renderAppearance
            )
            if rendered { renderedCount += 1 }
            let imageBounds = CGRect(x: 0, y: 0, width: image.size.width, height: image.size.height)
```

(The existing PerfTrace note line stays as is — after this task, steady-state typing should print `re-rendered=0`.)

- [ ] **Step 4: Run tests**

Run: `swift test --filter TableImageCacheTests 2>&1 | tail -5` → PASS.
Run: `swift test 2>&1 | tail -5` → all suites pass (table rendering behavior unchanged).

- [ ] **Step 5: Commit**

```bash
git add Sources/MarkdownEngine/Styling/MarkdownStyler+Tables.swift Tests/MarkdownEngineTests/TableImageCacheTests.swift
git commit -m "perf(tables): cache rendered table images keyed by source+font+appearance

Every keystroke re-rendered every inactive table to a fresh NSImage
(7-17ms with 10 tables). Table pixels depend only on source, font,
colors and appearance, so identical keys now reuse the cached image.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 2: Incremental wiki-link storage sync (3.4 ms → ~0.1 ms at 139k)

**Files:**
- Modify: `Sources/MarkdownEngine/Services/WikiLinkService.swift` (add one function after `makeStorageState`, ~line 190)
- Modify: `Sources/MarkdownEngine/TextView/Coordinator/NativeTextViewCoordinator.swift` (add 2 stored properties near line 88)
- Modify: `Sources/MarkdownEngine/TextView/Coordinator/NativeTextViewCoordinator+TextDelegate.swift` (`textDidChange`, ~lines 105–137)
- Modify: `Sources/MarkdownEngine/TextView/Coordinator/NativeTextViewCoordinator+Restyling.swift` (`rebuildTextStorageAndStyle`, seed the new state, ~line 39)
- Test: Create `Tests/MarkdownEngineTests/WikiLinkIncrementalTests.swift`

**Interfaces:**
- Consumes: `WikiLinkService.RangeKey` (`.location`, `.length`, `init(_ NSRange)`), `WikiLinkService.LinkMetadata` (`.id`, `.storageRange`, public init), `WikiLinkService.makeStorageState(from:existingMetadata:textStorage:)` as the fallback; coordinator vars `lastSyncedText`, `wikiLinkMetadata`, `pendingEditedRange`.
- Produces: `WikiLinkService.updatedStorageState(displayText:editedRange:changeInLength:previousStorage:previousMetadata:) -> (storage: String, metadata: [RangeKey: LinkMetadata])?` — nil means "fall back to full rebuild". New coordinator vars `previousDisplayLength: Int`, `lastComputedStorage: String`, `wikiVerifyCounter: UInt` that Task 6 relies on being maintained.

**Why:** `makeStorageState` rescans and rebuilds the **entire** document string on every keystroke as soon as one `[[` exists anywhere (measured 3.4 ms at 139k). Outside link syntax, display text and storage text are byte-identical — a keystroke that doesn't touch link syntax can be spliced into the previous storage string in O(edit + #links), with all link ranges after the edit shifted by the length delta.

- [ ] **Step 1: Write the failing tests**

Create `Tests/MarkdownEngineTests/WikiLinkIncrementalTests.swift`:

```swift
//
//  WikiLinkIncrementalTests.swift
//  MarkdownEngine
//
//  Created by Luca Chen on 07.07.26.
//

import Foundation
import Testing
@testable import MarkdownEngine

@Suite("WikiLink incremental storage state")
struct WikiLinkIncrementalTests {

    /// storage: "Hello [[Note|abc123]] world" → display: "Hello [[Note]] world"
    /// display link range {6, 8}, storage link range {6, 15}.
    private func seed() -> (display: String, storage: String,
                            meta: [WikiLinkService.RangeKey: WikiLinkService.LinkMetadata]) {
        let storage = "Hello [[Note|abc123]] world"
        let state = WikiLinkService.makeDisplayState(from: storage)
        return (state.display, storage, state.metadata)
    }

    @Test func appendAfterLinkSplicesStorage() throws {
        let (display, storage, meta) = seed()
        let newDisplay = display + "x"                       // typed "x" at the end
        let result = try #require(WikiLinkService.updatedStorageState(
            displayText: newDisplay,
            editedRange: NSRange(location: (display as NSString).length, length: 1),
            changeInLength: 1,
            previousStorage: storage,
            previousMetadata: meta
        ))
        #expect(result.storage == "Hello [[Note|abc123]] worldx")
        // Link before the edit: metadata unchanged.
        let key = try #require(result.metadata.keys.first)
        #expect(key.location == 6 && key.length == 8)
        #expect(result.metadata[key]?.id == "abc123")
        #expect(result.metadata[key]?.storageRange == NSRange(location: 6, length: 15))
    }

    @Test func insertBeforeLinkShiftsMetadata() throws {
        let (display, storage, meta) = seed()
        let newDisplay = "x" + display                       // typed "x" at position 0
        let result = try #require(WikiLinkService.updatedStorageState(
            displayText: newDisplay,
            editedRange: NSRange(location: 0, length: 1),
            changeInLength: 1,
            previousStorage: storage,
            previousMetadata: meta
        ))
        #expect(result.storage == "xHello [[Note|abc123]] world")
        let key = try #require(result.metadata.keys.first)
        #expect(key.location == 7 && key.length == 8)        // shifted by +1
        #expect(result.metadata[key]?.storageRange == NSRange(location: 7, length: 15))
        #expect(result.metadata[key]?.id == "abc123")
    }

    @Test func deletionInPlainTextWorks() throws {
        let (display, storage, meta) = seed()
        // Delete the "l" of "world" (display location 18 — far enough from the
        // link that neither the ±3 probe nor the metadata guard band trips).
        let ns = display as NSString
        let newDisplay = ns.replacingCharacters(in: NSRange(location: 18, length: 1), with: "")
        let result = try #require(WikiLinkService.updatedStorageState(
            displayText: newDisplay,
            editedRange: NSRange(location: 18, length: 0),
            changeInLength: -1,
            previousStorage: storage,
            previousMetadata: meta
        ))
        #expect(result.storage == "Hello [[Note|abc123]] word")
    }

    @Test func editTouchingLinkFallsBack() {
        let (display, storage, meta) = seed()
        // Typing directly after "]]" (display location 14) is inside the ±3 guard band.
        let result = WikiLinkService.updatedStorageState(
            displayText: display + " ",
            editedRange: NSRange(location: 14, length: 1),
            changeInLength: 1,
            previousStorage: storage,
            previousMetadata: meta
        )
        #expect(result == nil)
    }

    @Test func editCreatingLinkSyntaxFallsBack() {
        // "[[x]" + typed "]" completes a link → the new-text probe sees "]]" → bail.
        let display = "pre [[x] post"
        let ns = display as NSString
        let newDisplay = ns.replacingCharacters(in: NSRange(location: 8, length: 0), with: "]")
        let result = WikiLinkService.updatedStorageState(
            displayText: newDisplay,
            editedRange: NSRange(location: 8, length: 1),
            changeInLength: 1,
            previousStorage: display,
            previousMetadata: [:]
        )
        #expect(result == nil)
    }

    @Test func unknownDeltaFallsBack() {
        let (display, storage, meta) = seed()
        let result = WikiLinkService.updatedStorageState(
            displayText: display,
            editedRange: NSRange(location: 0, length: 0),
            changeInLength: Int.min,
            previousStorage: storage,
            previousMetadata: meta
        )
        #expect(result == nil)
    }

    /// Property sweep: inserting one char at every position that takes the fast
    /// path must yield a storage string that (a) round-trips back to exactly the
    /// new display text and (b) preserves every link id. (Comparing against a
    /// full `makeStorageState(textStorage: nil)` rebuild would be wrong here —
    /// the full rebuild loses ids when link ranges shift, which is precisely
    /// what the incremental path fixes.)
    @Test func spliceRoundTripsAtEverySafePosition() {
        let storage = "aaaa [[One|id1]] bbbb [[Two|id2]] cccc"
        let state = WikiLinkService.makeDisplayState(from: storage)
        let display = state.display as NSString
        var fastPathTaken = 0

        for position in 0...display.length {
            let newDisplay = display.replacingCharacters(in: NSRange(location: position, length: 0), with: "q")
            guard let fast = WikiLinkService.updatedStorageState(
                displayText: newDisplay,
                editedRange: NSRange(location: position, length: 1),
                changeInLength: 1,
                previousStorage: storage,
                previousMetadata: state.metadata
            ) else { continue }                              // guarded position → fallback, fine
            fastPathTaken += 1
            let roundTrip = WikiLinkService.makeDisplayState(from: fast.storage)
            #expect(roundTrip.display == newDisplay, "display round-trip diverged at position \(position)")
            #expect(fast.metadata.values.compactMap(\.id).sorted() == ["id1", "id2"],
                    "link id lost at position \(position)")
        }
        #expect(fastPathTaken > 0, "sweep was vacuous — no position took the fast path")
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter WikiLinkIncrementalTests 2>&1 | tail -5`
Expected: compile error — `updatedStorageState` does not exist.

- [ ] **Step 3: Implement `updatedStorageState`**

In `Sources/MarkdownEngine/Services/WikiLinkService.swift`, add after `makeStorageState` (after line ~190):

```swift
    /// Incremental counterpart to `makeStorageState`: splice a single contiguous
    /// edit into the previous storage form in O(edit + #links).
    ///
    /// Outside link syntax, display and storage text are identical, so an edit
    /// that provably cannot create, destroy, or touch a link maps 1:1 into the
    /// storage string; links after the edit just shift by the length delta.
    /// Returns nil whenever that proof fails — callers fall back to the full
    /// `makeStorageState` rebuild.
    public static func updatedStorageState(
        displayText: String,
        editedRange: NSRange,
        changeInLength delta: Int,
        previousStorage: String,
        previousMetadata: [RangeKey: LinkMetadata]
    ) -> (storage: String, metadata: [RangeKey: LinkMetadata])? {
        let nsDisplay = displayText as NSString
        let nsPrevStorage = previousStorage as NSString

        // Only contiguous, small, well-formed edits take the fast path.
        guard delta != Int.min,
              editedRange.location != NSNotFound,
              editedRange.length >= 0, editedRange.length <= 4096,
              NSMaxRange(editedRange) <= nsDisplay.length,
              editedRange.length - delta >= 0 else { return nil }

        let oldEditLength = editedRange.length - delta
        let oldEditRange = NSRange(location: editedRange.location, length: oldEditLength)

        // The edit must not create or complete link syntax: no [[ or ]] near it
        // in the NEW text (±3 covers a bracket typed against an existing one)…
        let probeStart = max(0, editedRange.location - 3)
        let probeEnd = min(nsDisplay.length, NSMaxRange(editedRange) + 3)
        let probe = nsDisplay.substring(with: NSRange(location: probeStart, length: probeEnd - probeStart))
        if probe.contains("[[") || probe.contains("]]") { return nil }

        // …and no existing link may overlap the edit (old display coordinates;
        // ±3 also rejects edits adjacent to a link's markers).
        let guardRange = NSRange(location: max(0, oldEditRange.location - 3), length: oldEditLength + 6)
        for key in previousMetadata.keys {
            if NSIntersectionRange(NSRange(location: key.location, length: key.length), guardRange).length > 0 {
                return nil
            }
        }

        // Map the display edit offset into storage coordinates: every link
        // before the edit is longer in storage by (storage length − display length).
        var storageOffsetDelta = 0
        for (key, meta) in previousMetadata where key.location < editedRange.location {
            storageOffsetDelta += meta.storageRange.length - key.length
        }
        let storageEditStart = editedRange.location + storageOffsetDelta
        guard storageEditStart >= 0,
              storageEditStart + oldEditLength <= nsPrevStorage.length else { return nil }

        // Splice — outside links the replaced/inserted characters are identical
        // in both forms.
        let replacement = nsDisplay.substring(with: editedRange)
        let storage = nsPrevStorage.replacingCharacters(
            in: NSRange(location: storageEditStart, length: oldEditLength),
            with: replacement
        )

        // Shift every link after the edit by the delta; links before it are untouched.
        var metadata: [RangeKey: LinkMetadata] = [:]
        metadata.reserveCapacity(previousMetadata.count)
        for (key, meta) in previousMetadata {
            if key.location >= NSMaxRange(oldEditRange) {
                metadata[RangeKey(NSRange(location: key.location + delta, length: key.length))] =
                    LinkMetadata(id: meta.id,
                                 storageRange: NSRange(location: meta.storageRange.location + delta,
                                                       length: meta.storageRange.length))
            } else {
                metadata[key] = meta
            }
        }
        return (storage, metadata)
    }
```

- [ ] **Step 4: Run the service tests**

Run: `swift test --filter WikiLinkIncrementalTests 2>&1 | tail -5`
Expected: PASS (all 7 tests).

- [ ] **Step 5: Wire it into the coordinator**

In `Sources/MarkdownEngine/TextView/Coordinator/NativeTextViewCoordinator.swift`, next to `var previousBacktickCount: Int = 0` (line ~88), add:

```swift
    /// Display-text length after the previous textDidChange — yields the edit's
    /// length delta without retaining the previous text.
    var previousDisplayLength: Int = -1
    /// Storage form computed by the previous wiki sync, kept synchronously
    /// (unlike `lastSyncedText`, which updates via async dispatch and can lag a
    /// keystroke). This is the splice base for the incremental path.
    var lastComputedStorage: String = ""
    /// DEBUG-only sampling counter for verifying splices against full rebuilds.
    var wikiVerifyCounter: UInt = 0
```

In `NativeTextViewCoordinator+TextDelegate.swift`, `textDidChange`: replace the block from `let rawSelRange = tv.selectedRange()` down to the end of the `if !wtActive { … }` wiki-sync block (currently ~lines 105–128) with:

```swift
        let rawSelRange = tv.selectedRange()
        let docString = tv.string
        let fullText = docString as NSString
        let fullLength = fullText.length
        guard !tv.hasMarkedText() else { return }
        let safeLocation = min(rawSelRange.location, fullLength)
        let safeSelRange = NSRange(location: safeLocation, length: 0)
        previousCaretLocation = safeSelRange.location
        PerfTrace.begin(docLength: fullLength)

        // Edit descriptor, hoisted above the wiki sync so both it and the
        // paragraph scoping below share it.
        let editedRange = pendingEditedRange ?? tv.textStorage?.editedRange ?? safeSelRange
        pendingEditedRange = nil
        let lengthDelta = previousDisplayLength >= 0 ? fullLength - previousDisplayLength : Int.min
        previousDisplayLength = fullLength

        if !wtActive {
            let storageState = PerfTrace.measure("wiki") {
                WikiLinkService.updatedStorageState(
                    displayText: docString,
                    editedRange: editedRange,
                    changeInLength: lengthDelta,
                    previousStorage: lastComputedStorage,
                    previousMetadata: wikiLinkMetadata
                ) ?? WikiLinkService.makeStorageState(
                    from: docString,
                    existingMetadata: wikiLinkMetadata,
                    textStorage: tv.textStorage
                )
            }
            self.wikiLinkMetadata = storageState.metadata
            self.lastComputedStorage = storageState.storage
#if DEBUG
            // Sampled safety net: every 64th keystroke, prove the splice equals
            // a full rebuild. Remove together with PerfTrace after sign-off.
            wikiVerifyCounter &+= 1
            if wikiVerifyCounter % 64 == 0 {
                let reference = WikiLinkService.makeStorageState(
                    from: docString,
                    existingMetadata: wikiLinkMetadata,
                    textStorage: tv.textStorage
                )
                assert(reference.storage == storageState.storage,
                       "wiki incremental splice diverged from full rebuild")
            }
#endif
            if storageState.storage != self.lastSyncedText {
                DispatchQueue.main.async {
                    self.lastSyncedText = storageState.storage
                    self.text = storageState.storage
                }
            }
        }
```

Then, a few lines below, **delete** the now-duplicate declarations (the old `let fullText = tv.string as NSString` line and the old `let editedRange = pendingEditedRange ?? …` / `pendingEditedRange = nil` pair further down, ~old lines 126 and 136–137) — `fullText`, `fullLength`, and `editedRange` now come from the hoisted block. The later `let safeEditedRange` computation keeps working unchanged.

In `NativeTextViewCoordinator+Restyling.swift`, `rebuildTextStorageAndStyle`, directly after `lastSyncedText = text` (line ~39), seed the new state:

```swift
        lastSyncedText = text
        lastComputedStorage = text
        previousDisplayLength = (displayText as NSString).length
```

- [ ] **Step 6: Build and run the full suite**

Run: `swift build && swift test 2>&1 | tail -5`
Expected: `Build complete!`, all suites pass.

- [ ] **Step 7: Commit**

```bash
git add Sources/MarkdownEngine/Services/WikiLinkService.swift \
  Sources/MarkdownEngine/TextView/Coordinator/NativeTextViewCoordinator.swift \
  Sources/MarkdownEngine/TextView/Coordinator/NativeTextViewCoordinator+TextDelegate.swift \
  Sources/MarkdownEngine/TextView/Coordinator/NativeTextViewCoordinator+Restyling.swift \
  Tests/MarkdownEngineTests/WikiLinkIncrementalTests.swift
git commit -m "perf(wiki): splice keystroke edits into the storage form incrementally

makeStorageState rescanned and rebuilt the whole document per keystroke
once any [[ existed (3.4ms at 139k chars). Edits that provably cannot
touch link syntax now splice into the previous storage string in
O(edit + links); anything ambiguous falls back to the full rebuild.
DEBUG samples every 64th keystroke against the full rebuild.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 3: Backtick census without full-document split (0.75 ms → ~0.05 ms)

**Files:**
- Modify: `Sources/MarkdownEngine/Parser/MarkdownDetection.swift` (add one function)
- Modify: `Sources/MarkdownEngine/TextView/Coordinator/NativeTextViewCoordinator+TextDelegate.swift` (the `backtick` measure line, ~line 156)
- Test: Create `Tests/MarkdownEngineTests/BacktickCensusTests.swift`

**Interfaces:**
- Consumes: `fullText: NSString` already hoisted in Task 2's `textDidChange` block.
- Produces: `MarkdownDetection.tripleBacktickCount(in: NSString) -> Int` with semantics identical to `components(separatedBy: "```").count - 1` (non-overlapping, left-to-right).

**Why:** `components(separatedBy: "```")` allocates an array of substrings spanning the whole document on every keystroke. A single UTF-16 scan does the same count allocation-free.

- [ ] **Step 1: Write the failing test**

Create `Tests/MarkdownEngineTests/BacktickCensusTests.swift`:

```swift
//
//  BacktickCensusTests.swift
//  MarkdownEngine
//
//  Created by Luca Chen on 07.07.26.
//

import Foundation
import Testing
@testable import MarkdownEngine

@Suite("Backtick census")
struct BacktickCensusTests {

    @Test func matchesComponentsSemantics() {
        let samples = [
            "", "`", "``", "```", "````", "`````", "``````",
            "a```b```c",
            "x\n```swift\nlet a = 1\n```\ny",
            "inline `code` only",
            "```````"
        ]
        for sample in samples {
            let expected = sample.components(separatedBy: "```").count - 1
            #expect(MarkdownDetection.tripleBacktickCount(in: sample as NSString) == expected,
                    "mismatch for \(sample.debugDescription)")
        }
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter BacktickCensusTests 2>&1 | tail -5`
Expected: compile error — `tripleBacktickCount` does not exist.

- [ ] **Step 3: Implement**

In `Sources/MarkdownEngine/Parser/MarkdownDetection.swift`, add inside `enum MarkdownDetection`:

```swift
    /// Count of non-overlapping ``` occurrences, scanning left to right —
    /// exactly `components(separatedBy: "```").count - 1`, but as one UTF-16
    /// pass with no substring-array allocation.
    static func tripleBacktickCount(in text: NSString) -> Int {
        let length = text.length
        guard length >= 3 else { return 0 }
        var buffer = [unichar](repeating: 0, count: length)
        text.getCharacters(&buffer, range: NSRange(location: 0, length: length))
        var count = 0
        var i = 0
        while i + 2 < length {                           // i can reach length - 3
            if buffer[i] == 0x60, buffer[i + 1] == 0x60, buffer[i + 2] == 0x60 {
                count += 1
                i += 3
            } else {
                i += 1
            }
        }
        return count
    }
```

In `NativeTextViewCoordinator+TextDelegate.swift`, replace:

```swift
        let backtickCount = PerfTrace.measure("backtick") { tv.string.components(separatedBy: "```").count - 1 }
```

with:

```swift
        let backtickCount = PerfTrace.measure("backtick") { MarkdownDetection.tripleBacktickCount(in: fullText) }
```

Also replace the two remaining `tv.string` uses in `textDidChange` with the hoisted `docString` (the `parse` measure line 163: `parsedDocument(for: docString)`) so the bridge happens once per keystroke.

- [ ] **Step 4: Run tests**

Run: `swift test --filter BacktickCensusTests 2>&1 | tail -5` → PASS.
Run: `swift test 2>&1 | tail -5` → all pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/MarkdownEngine/Parser/MarkdownDetection.swift \
  Sources/MarkdownEngine/TextView/Coordinator/NativeTextViewCoordinator+TextDelegate.swift \
  Tests/MarkdownEngineTests/BacktickCensusTests.swift
git commit -m "perf(parse): count code fences with one UTF-16 scan, hoist tv.string

components(separatedBy:) allocated a whole-document substring array per
keystroke just to count fences. One allocation-free scan replaces it,
and textDidChange bridges tv.string exactly once.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 4: `ensureVisibleLayout` starts at the viewport, not the document head

**Files:**
- Modify: `Sources/MarkdownEngine/TextView/NativeTextView/NativeTextView+FrameAndOverscroll.swift` (`ensureVisibleLayout`, ~line 400)
- Test: none (AppKit layout — verified live via the PerfTrace `walked=` counter in Task 6; per Luca's convention no unit tests for view-layer tweaks)

**Interfaces:**
- Consumes: `textLayoutManager` (TextKit 2 `NSTextLayoutManager`), its `textViewportLayoutController.viewportRange`.
- Produces: same function, same guarantee ("visible fragments have ensured layout"), cost now O(viewport) instead of O(caret position).

**Why:** the walk currently starts at `documentRange.location` with `.ensuresLayout`, so typing at the bottom of a document forces a pass over every fragment above the viewport (measured: 115 of 130 fragments wasted at only 7.9k chars; grows linearly with position).

- [ ] **Step 1: Reimplement the walk**

Replace the body of `ensureVisibleLayout()`:

```swift
    /// Force TextKit 2 to lay out all fragments within the current visible rect.
    func ensureVisibleLayout() {
        guard let tlm = textLayoutManager else { return }
        let visBot = visibleRect.maxY
        // Start at the viewport instead of the document head: walking from the
        // start forces layout of every fragment above the viewport, making a
        // keystroke cost O(caret position in document).
        let start = tlm.textViewportLayoutController.viewportRange?.location
            ?? tlm.documentRange.location
        var walked = 0
        tlm.enumerateTextLayoutFragments(from: start, options: [.ensuresLayout]) { fragment in
            walked += 1
            return fragment.layoutFragmentFrame.minY <= visBot
        }
        PerfTrace.note { "ensureVisibleLayout walked=\(walked) frags from viewport" }
    }
```

- [ ] **Step 2: Build and run the suite**

Run: `swift build && swift test 2>&1 | tail -5`
Expected: `Build complete!`, all pass (HeightBehaviorTests and ScrollingHeaderControllerTests are the layout-adjacent suites to watch).

- [ ] **Step 3: Commit**

```bash
git add Sources/MarkdownEngine/TextView/NativeTextView/NativeTextView+FrameAndOverscroll.swift
git commit -m "perf(layout): ensureVisibleLayout walks from the viewport, not the document head

Enumerating from documentRange.location with .ensuresLayout laid out
every fragment above the viewport on each keystroke - O(caret position).
Starting at viewportRange keeps the walk O(viewport).

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 5: O(1) `parsedDocument` cache hits + single UTF-16 extraction (parse 6.4 ms → target ≤ 3 ms)

**Files:**
- Modify: `Sources/MarkdownEngine/TextView/Coordinator/NativeTextViewCoordinator.swift` (cache vars near line 97)
- Modify: `Sources/MarkdownEngine/TextView/Coordinator/NativeTextViewCoordinator+Restyling.swift` (`parsedDocument`, line ~162; `rebuildTextStorageAndStyle`)
- Modify: `Sources/MarkdownEngine/TextView/Coordinator/NativeTextViewCoordinator+TextDelegate.swift` (`shouldChangeTextIn`, line ~460)
- Modify: `Sources/MarkdownEngine/Parser/BlockScopedTokenizer.swift` (`parseTokensViaAST`, line ~29)
- Modify: `Sources/MarkdownEngine/Parser/BlockParser.swift` (`parse`, line ~51)
- Test: existing parser suites must stay green (`BlockParserTests`, `ASTPipelineTests`, `InlineParserTests`, `ListParsingTests`); no new tests (pure caching/plumbing, observable behavior unchanged).

**Interfaces:**
- Consumes: `parsedDocument(for:)` call sites (TextDelegate, Restyling, Autocorrect, ContextMenu, InlineSelection — all pass the live display text).
- Produces: `BlockParser.parse(_ text: String, utf16Chars: [unichar]? = nil) -> [Block]` (existing single-argument calls keep compiling via the default); coordinator vars `parseGeneration: UInt64`, `cachedParseGeneration: UInt64`, `cachedParsedLength: Int` that any future storage-mutating code must bump (`parseGeneration &+= 1`).

**Why (two independent O(doc) costs inside the measured 6.4 ms):**
1. The `cachedParsedText == text` compare is O(doc) — it runs (and fails) on every keystroke, and runs (and fully scans) on every caret move.
2. `parseTokensViaAST` extracts the full UTF-16 buffer, then `BlockParser.parse` extracts the **same buffer again**.

- [ ] **Step 1: Generation-tagged cache**

In `NativeTextViewCoordinator.swift`, next to `var cachedParsedText: String?` (line ~97), add:

```swift
    /// Monotonic edit counter: bumped whenever the text storage can have
    /// changed. Lets `parsedDocument` return cache hits in O(1) instead of an
    /// O(doc) string compare. Any code that mutates the storage directly
    /// (bypassing shouldChangeText/textDidChange) must bump this.
    var parseGeneration: UInt64 = 0
    var cachedParseGeneration: UInt64 = .max
    var cachedParsedLength: Int = -1
```

In `NativeTextViewCoordinator+Restyling.swift`, rewrite the head and tail of `parsedDocument(for:)`:

```swift
    func parsedDocument(for text: String) -> ParsedDocument {
        let length = (text as NSString).length
        if let cachedParsedDocument, cachedParsedLength == length {
            // O(1) hit: nothing has edited the storage since the cached parse.
            if cachedParseGeneration == parseGeneration {
                return cachedParsedDocument
            }
            // Generation moved but the text may still be identical (e.g. an
            // attribute-only pass): verify once, then it's O(1) again.
            if let cachedParsedText, cachedParsedText == text {
                cachedParseGeneration = parseGeneration
                return cachedParsedDocument
            }
        }

        let tokens = MarkdownTokenizer.parseTokensViaAST(in: text)
        // … (existing token classification loop stays byte-identical) …

        cachedParsedText = text
        cachedParsedLength = length
        cachedParseGeneration = parseGeneration
        cachedParsedDocument = parsed
        return parsed
    }
```

Bump sites:
1. `NativeTextViewCoordinator+TextDelegate.swift`, inside `textView(_:shouldChangeTextIn:replacementString:)` (line ~460), first line of the body: `parseGeneration &+= 1`.
2. Same file, `textDidChange`, directly after `PerfTrace.begin(docLength: fullLength)`: `parseGeneration &+= 1` (belt for edits that reach `didChangeText` without the delegate ask — undo, some IME paths).
3. `NativeTextViewCoordinator+Restyling.swift`, `rebuildTextStorageAndStyle`, directly after `textView.string = displayText` inside the `if textView.string != displayText` branch: `parseGeneration &+= 1`.
4. Run `grep -rn "replaceCharacters(in:\|insertText(" Sources/MarkdownEngine --include="*.swift" | grep -v Tests` and for every hit that mutates the **editor's** textStorage without going through `shouldChangeText`/`didChangeText` (candidates: task-checkbox toggle, wiki-link snapback, the inline-replacement pipeline in Restyling), add `parseGeneration &+= 1` (via the coordinator reference available at that site) right after the mutation. If a site has no coordinator access, leave it — the length + string-compare fallback keeps it correct, just slower.

- [ ] **Step 2: Share the UTF-16 buffer**

In `BlockParser.swift`, change the `parse` signature and buffer setup (line ~51):

```swift
    /// Splits `text` into gap-free tiling blocks; memoizes the last parse so both per-keystroke callers share one line-scan.
    /// Pass `utf16Chars` when the caller already extracted the buffer (must match `text`).
    static func parse(_ text: String, utf16Chars: [unichar]? = nil) -> [Block] {
        let textNS = text as NSString
        let newLen = textNS.length
        let newChars: [unichar]
        if let utf16Chars, utf16Chars.count == newLen {
            newChars = utf16Chars
        } else {
            var buffer = [unichar](repeating: 0, count: newLen)
            if newLen > 0 { textNS.getCharacters(&buffer, range: NSRange(location: 0, length: newLen)) }
            newChars = buffer
        }
```

(the rest of the function body is unchanged — it already uses `newChars`).

In `BlockScopedTokenizer.swift`, `parseTokensViaAST` (line ~29), pass the buffer it already extracted:

```swift
        let blocks = BlockParser.parse(text, utf16Chars: newChars)
```

- [ ] **Step 3: Build and run the full suite**

Run: `swift build && swift test 2>&1 | tail -5`
Expected: `Build complete!`, all suites pass — especially `BlockParserTests` and `ASTPipelineTests` (identical outputs, only plumbing changed).

- [ ] **Step 4: Commit**

```bash
git add Sources/MarkdownEngine/TextView/Coordinator/NativeTextViewCoordinator.swift \
  Sources/MarkdownEngine/TextView/Coordinator/NativeTextViewCoordinator+Restyling.swift \
  Sources/MarkdownEngine/TextView/Coordinator/NativeTextViewCoordinator+TextDelegate.swift \
  Sources/MarkdownEngine/Parser/BlockParser.swift \
  Sources/MarkdownEngine/Parser/BlockScopedTokenizer.swift
git commit -m "perf(parse): O(1) parsedDocument cache hits, single UTF-16 extraction

The parse cache compared the whole document string on every call -
O(doc) per keystroke AND per caret move. A generation counter bumped on
every storage edit makes hits O(1), with the string compare kept as a
correctness fallback. BlockParser now reuses the UTF-16 buffer the
tokenizer already extracted instead of re-extracting it.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 6: Live before/after measurement and report

**Files:**
- No engine changes. Uses the Nodes app (already wired to this local engine checkout) and the PerfTrace output.

**Interfaces:**
- Consumes: PerfTrace `⌨️ PERF` lines and `└─` notes from Tasks 0–5.

- [ ] **Step 1: Build the app against the finished branch**

```bash
cd /Users/lucachen/Documents/GitHub/Nodes
xcodebuild -project Nodes.xcodeproj -scheme Nodes -configuration Debug CODE_SIGNING_ALLOWED=NO build 2>&1 | tail -3
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 2: Ask Luca to repeat the exact baseline scenario**

Same three docs as the 2026-07-07 baseline: the 139k-char note (typing mid-document), the ~456-char note, and the 10-table note (typing at the bottom). ~10 keystrokes each, paste the console.

- [ ] **Step 3: Evaluate against these acceptance targets (Debug numbers)**

| Metric | Baseline | Target |
|---|---|---|
| 139k doc: `total` | ~12.8 ms | ≤ 5 ms |
| 139k doc: `wiki` | ~3.4 ms | ≤ 0.3 ms steady (no fallback churn) |
| 139k doc: `parse` | ~6.4 ms | ≤ 3 ms |
| 139k doc: `backtick` | ~0.75 ms | ≤ 0.1 ms |
| Table doc: `styleTables` note | `re-rendered=10` | `re-rendered=0` steady-state |
| Table doc: `total` | 13–28 ms | ≤ 6 ms |
| Bottom-of-doc: `ensureVisibleLayout` | `115 above viewport (wasted)` | walked ≈ viewport fragment count, independent of caret position |

Also confirm zero `assertionFailure` from the wiki DEBUG sampler and that links still round-trip (type near links, rename nothing, check `[[Name|UUID]]` survives in the saved file).

- [ ] **Step 4: Report to Luca and stop**

Summarize before/after per metric. Do **not** push, do not open a PR, do not release — Luca decides integration (and the eventual PerfTrace removal) after reviewing the numbers.

---

## Explicitly Out of Scope (follow-ups, not part of this plan)

- **Latex/imageEmbed restyle scope** (`TextDelegate.swift:188` appends every latex/image paragraph in the doc to each restyle): measured 0.00 ms in the baseline docs (none present). Re-measure with a formula-heavy doc first; only then scope it.
- **Green-tree incremental block parse** (relative-width ranges, no suffix shifting): the BlockParser header marks this as deliberate "Phase 3"; today's suffix-shift is O(#tokens) struct copies and acceptable.
- **First-keystroke-after-switch spike** (64 ms / restyle 45 ms once): one-time cost, different mechanism (full initial restyle), separate investigation.
- **`updateCodeBlockSelection`** (0.35 ms at 139k) and **overscroll recalc** (0.14 ms): below the noise floor after the fixes above.
- **WideTableOverlay full-doc ensureLayout**: measured 0.1 ms (layout already settled when it runs) — the audit flagged the code shape, but the data says leave it.
- **PerfTrace removal** and the app repo's pbxproj revert to the remote engine reference: after Luca signs off.
