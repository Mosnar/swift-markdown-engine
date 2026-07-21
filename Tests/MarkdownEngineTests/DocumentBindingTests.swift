import SwiftUI
import Testing
@testable import MarkdownEngine

@MainActor
struct DocumentBindingTests {
    private final class Box<Value>: @unchecked Sendable {
        var value: Value

        init(_ value: Value) {
            self.value = value
        }

        var binding: Binding<Value> {
            Binding(
                get: { self.value },
                set: { self.value = $0 }
            )
        }
    }

    private func makeCoordinator(text: Binding<String>) -> NativeTextViewCoordinator {
        NativeTextViewCoordinator(
            text: text,
            fontName: "SF Pro",
            fontSize: 16,
            isWikiLinkActive: .constant(false),
            onLinkClick: nil,
            onInlineSelectionChange: nil
        )
    }

    private func drainMainQueue() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                continuation.resume()
            }
        }
    }

    @Test("Coordinator writes through the newest binding after a document switch")
    func writesThroughNewestBinding() async {
        let parent = Box("parent")
        let child = Box("child")
        let coordinator = makeCoordinator(text: parent.binding)
        coordinator.documentId = "parent"

        coordinator.updateBindings(text: child.binding, isWikiLinkActive: .constant(false))
        coordinator.documentId = "child"
        coordinator.scheduleTextBindingUpdate("edited child", forDocumentId: "child")
        await drainMainQueue()

        #expect(parent.value == "parent")
        #expect(child.value == "edited child")
    }

    @Test("A deferred outgoing edit cannot overwrite the incoming document")
    func dropsStaleDocumentWrite() async {
        let parent = Box("parent")
        let child = Box("child")
        let coordinator = makeCoordinator(text: parent.binding)
        coordinator.documentId = "parent"

        coordinator.scheduleTextBindingUpdate("late parent edit", forDocumentId: "parent")
        coordinator.updateBindings(text: child.binding, isWikiLinkActive: .constant(false))
        coordinator.documentId = "child"
        await drainMainQueue()

        #expect(parent.value == "parent")
        #expect(child.value == "child")
        #expect(coordinator.lastSyncedText == "parent")
    }
}
