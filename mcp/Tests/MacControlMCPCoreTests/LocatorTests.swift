import XCTest
@testable import MacControlMCPCore

final class LocatorTests: XCTestCase {
    private func locator(of ref: String, in tree: ElementNode) throws -> Locator {
        try XCTUnwrap(LocatorCapture.all(in: tree)[ref])
    }

    func testResolvesByIdentifierEvenWhenRefsAndOrderChange() throws {
        let old = ElementNode(ref: "e1", role: "AXWindow", children: [
            ElementNode(ref: "e2", role: "AXButton", identifier: "compose", title: "Compose", actions: ["AXPress"]),
            ElementNode(ref: "e3", role: "AXButton", identifier: "reply", title: "Reply", actions: ["AXPress"])
        ])
        let target = try locator(of: "e2", in: old)
        // Fresh snapshot: refs reassigned, order swapped — identifier persists.
        let new = ElementNode(ref: "w", role: "AXWindow", children: [
            ElementNode(ref: "x", role: "AXButton", identifier: "reply", title: "Reply"),
            ElementNode(ref: "y", role: "AXButton", identifier: "compose", title: "Compose")
        ])
        XCTAssertEqual(LocatorMatcher.resolve(target, in: new), .resolved("y"))
    }

    func testResolvesByTitleAndStructureWhenUnique() throws {
        let old = ElementNode(ref: "e1", role: "AXWindow", children: [
            ElementNode(ref: "e2", role: "AXButton", title: "OK", actions: ["AXPress"])
        ])
        let target = try locator(of: "e2", in: old)
        let new = ElementNode(ref: "w", role: "AXWindow", children: [
            ElementNode(ref: "z", role: "AXButton", title: "OK")
        ])
        XCTAssertEqual(LocatorMatcher.resolve(target, in: new), .resolved("z"))
    }

    func testAmbiguousReturnsCandidatesInsteadOfGuessing() throws {
        let old = ElementNode(ref: "e1", role: "AXList", children: [
            ElementNode(ref: "e2", role: "AXButton", title: "Delete")
        ])
        let target = try locator(of: "e2", in: old)
        // Two identical Delete buttons, no identifier, different structure → must fail loud.
        let new = ElementNode(ref: "w", role: "AXWindow", children: [
            ElementNode(ref: "a", role: "AXButton", title: "Delete"),
            ElementNode(ref: "b", role: "AXButton", title: "Delete")
        ])
        XCTAssertEqual(LocatorMatcher.resolve(target, in: new), .ambiguous(["a", "b"]))
    }

    func testGoneWhenNothingMatches() throws {
        let old = ElementNode(ref: "e1", role: "AXButton", title: "Save")
        let target = try locator(of: "e1", in: old)
        let new = ElementNode(ref: "w", role: "AXWindow", children: [
            ElementNode(ref: "x", role: "AXTextField", title: "Name")
        ])
        XCTAssertEqual(LocatorMatcher.resolve(target, in: new), .gone)
    }

    func testSiblingIndexDistinguishesSameRoleSiblings() throws {
        let tree = ElementNode(ref: "root", role: "AXList", children: [
            ElementNode(ref: "r0", role: "AXRow"),
            ElementNode(ref: "r1", role: "AXRow"),
            ElementNode(ref: "r2", role: "AXRow")
        ])
        let captured = LocatorCapture.all(in: tree)
        XCTAssertEqual(captured["r0"]?.siblingIndex, 0)
        XCTAssertEqual(captured["r2"]?.siblingIndex, 2)
        XCTAssertEqual(captured["r1"]?.parentRoles, ["AXList"])
    }
}
