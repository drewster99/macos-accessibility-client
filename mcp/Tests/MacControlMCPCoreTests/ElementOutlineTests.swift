import XCTest
import CoreGraphics
@testable import MacControlMCPCore

final class ElementOutlineTests: XCTestCase {
    /// Mirrors the example tree in docs/MCP_DESIGN.md §9.
    private func sampleWindow() -> ElementNode {
        let plain = (0..<12).map { ElementNode(ref: "c\($0)", role: "AXStaticText") }
        let group = ElementNode(ref: "e4", role: "AXGroup", children: plain)
        let button = ElementNode(ref: "e2", role: "AXButton", title: "Reload", actions: ["AXPress"])
        let field = ElementNode(ref: "e3", role: "AXTextField", title: "Search", settable: true)
        return ElementNode(
            ref: "e1", role: "AXWindow", title: "Inbox — Mail",
            frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
            children: [button, group, field]
        )
    }

    func testInteractableFilterCollapsesDecorativeSubtree() {
        let out = ElementOutline.render(sampleWindow(), filter: .interactable)
        XCTAssertTrue(out.contains("e1 AXWindow \"Inbox — Mail\" [1440×900]"))
        XCTAssertTrue(out.contains("e2 AXButton \"Reload\" (AXPress)"))
        XCTAssertTrue(out.contains("e4 AXGroup ×12 children…"))
        XCTAssertTrue(out.contains("e3 AXTextField \"Search\" (settable)"))
        XCTAssertFalse(out.contains("c0"), "decorative children must not be rendered")
    }

    func testInteractableContainerIsNotCollapsed() {
        // A group that contains an interactable descendant must be kept and recursed into.
        let button = ElementNode(ref: "b1", role: "AXButton", title: "OK", actions: ["AXPress"])
        let group = ElementNode(ref: "g1", role: "AXGroup", children: [button])
        let out = ElementOutline.render(group, filter: .interactable)
        XCTAssertFalse(out.contains("children…"))
        XCTAssertTrue(out.contains("b1 AXButton \"OK\" (AXPress)"))
    }

    func testAllFilterRendersEveryNode() {
        let plain = (0..<3).map { ElementNode(ref: "c\($0)", role: "AXStaticText") }
        let group = ElementNode(ref: "e4", role: "AXGroup", children: plain)
        let window = ElementNode(ref: "e1", role: "AXWindow", title: "W", children: [group])
        let out = ElementOutline.render(window, filter: .all)
        XCTAssertTrue(out.contains("c0 AXStaticText"))
        XCTAssertTrue(out.contains("c2 AXStaticText"))
        XCTAssertFalse(out.contains("children…"))
    }

    func testIndentationReflectsDepth() {
        let leaf = ElementNode(ref: "x", role: "AXButton", title: "Deep", actions: ["AXPress"])
        let mid = ElementNode(ref: "m", role: "AXGroup", title: "Mid", children: [leaf])
        let root = ElementNode(ref: "r", role: "AXWindow", title: "Root", children: [mid])
        let lines = ElementOutline.render(root, filter: .interactable).split(separator: "\n", omittingEmptySubsequences: false)
        XCTAssertEqual(lines.count, 3)
        XCTAssertTrue(lines[0].hasPrefix("r "))
        XCTAssertTrue(lines[1].hasPrefix("  m "))
        XCTAssertTrue(lines[2].hasPrefix("    x "))
    }

    func testValueAndActionsAndSettableRendered() {
        let node = ElementNode(
            ref: "e3", role: "AXTextField", title: "Search",
            value: "hello", actions: ["AXConfirm"], settable: true
        )
        let out = ElementOutline.render(node)
        XCTAssertTrue(out.contains("(AXConfirm)"))
        XCTAssertTrue(out.contains("(settable)"))
        XCTAssertTrue(out.contains("value:\"hello\""))
    }

    /// A multi-line title/value/action must never split one element across lines (it would
    /// corrupt the line-based outline — as a real app's NSAccessibilityCustomAction blobs did).
    func testMultilineFieldsStayOnOneLine() {
        let node = ElementNode(
            ref: "e1", role: "AXButton",
            title: "first\nsecond", value: "alpha\nbeta",
            actions: ["AXPress", "Name:Move next\nTarget:0x0\nSelector:(null)"]
        )
        let out = ElementOutline.render(node, filter: .all)
        XCTAssertEqual(out.split(separator: "\n", omittingEmptySubsequences: false).count, 1,
                       "node must render on exactly one line: \(out)")
        XCTAssertFalse(out.contains("\n"))
    }
}
