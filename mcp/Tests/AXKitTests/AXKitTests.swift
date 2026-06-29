import XCTest
@testable import AXKit

final class AXKitTests: XCTestCase {
    func testRefAllocatorIsSequential() {
        let allocator = RefAllocator()
        XCTAssertEqual(allocator.next(), "e1")
        XCTAssertEqual(allocator.next(), "e2")
        XCTAssertEqual(allocator.next(), "e3")
    }

    func testAllocatorsAreIndependent() {
        let a = RefAllocator()
        let b = RefAllocator()
        _ = a.next()
        _ = a.next()
        XCTAssertEqual(b.next(), "e1")
    }

    /// Exercises the snapshot builder's run path against a real system-wide element,
    /// assigning refs through the provided closure. Without a grant the attributes read as
    /// nil (role → "AXUnknown"), but the walk must still produce a rooted node.
    func testSnapshotBuildAssignsRefsViaProvider() {
        var counter = 0
        let node = AXSnapshot.build(.systemWide(), maxDepth: 1) { _ in
            counter += 1
            return "e\(counter)"
        }
        XCTAssertEqual(node.ref, "e1")
        XCTAssertFalse(node.role.isEmpty)
    }

    func testCleanActionNameReducesCustomActionBlobs() {
        // Standard single-line action tokens pass through untouched.
        XCTAssertEqual(AXElement.cleanActionName("AXPress"), "AXPress")
        // An NSAccessibilityCustomAction description blob collapses to its display name.
        XCTAssertEqual(AXElement.cleanActionName("Name:Move next\nTarget:0x0\nSelector:(null)"), "Move next")
        XCTAssertEqual(AXElement.cleanActionName("Name:Remove from toolbar\nTarget:0x0\nSelector:(null)"),
                       "Remove from toolbar")
        // Any other multi-line content is flattened to one line.
        XCTAssertEqual(AXElement.cleanActionName("foo\nbar"), "foo bar")
        XCTAssertFalse(AXElement.cleanActionName("Name:X\nTarget:0").contains("\n"))
    }
}

/// Deterministic coverage of the find_elements (§8) match predicate, exercised without a
/// live AX tree. Mirrors the real-world case the live e2e surfaced: Calculator labels its
/// digit buttons via AXIdentifier ("Seven"), not AXTitle.
final class FindPredicateTests: XCTestCase {
    private func m(role: String? = nil, title: String? = nil, identifier: String? = nil,
                   value: String? = nil, actions: [String] = [],
                   roleFilter: String? = nil, titleContains: String? = nil,
                   identifierFilter: String? = nil, valueContains: String? = nil,
                   actionable: Bool? = nil) -> Bool {
        ElementRegistry.elementMatches(role: role, title: title, identifier: identifier, value: value,
                                 actions: actions, roleFilter: roleFilter, titleContains: titleContains,
                                 identifierFilter: identifierFilter, valueContains: valueContains,
                                 actionable: actionable)
    }

    func testNoFiltersMatchesAnything() {
        XCTAssertTrue(m(role: "AXButton"))
    }

    func testRoleFilter() {
        XCTAssertTrue(m(role: "AXButton", roleFilter: "AXButton"))
        XCTAssertFalse(m(role: "AXButton", roleFilter: "AXWindow"))
    }

    func testIdentifierIsExactNotSubstring() {
        XCTAssertTrue(m(identifier: "Seven", identifierFilter: "Seven"))
        XCTAssertFalse(m(identifier: "Eight", identifierFilter: "Seven"))
        XCTAssertFalse(m(identifier: "SevenEighths", identifierFilter: "Seven"))
        XCTAssertFalse(m(identifier: nil, identifierFilter: "Seven"))
    }

    func testTitleAndValueContainsAreCaseInsensitive() {
        // The tool lowercases the needle before calling; the predicate lowercases the haystack.
        XCTAssertTrue(m(title: "Save As…", titleContains: "save"))
        XCTAssertFalse(m(title: "Cancel", titleContains: "save"))
        XCTAssertTrue(m(value: "Total: 78", valueContains: "78"))
        XCTAssertFalse(m(value: "Total: 12", valueContains: "78"))
    }

    func testActionableOnlyConstrainsWhenTrue() {
        XCTAssertTrue(m(actions: ["AXPress"], actionable: true))
        XCTAssertFalse(m(actions: [], actionable: true))
        XCTAssertTrue(m(actions: [], actionable: false))
        XCTAssertTrue(m(actions: [], actionable: nil))
    }

    func testCombinedFiltersAreConjunctive() {
        XCTAssertTrue(m(role: "AXButton", identifier: "Seven", actions: ["AXPress"],
                        roleFilter: "AXButton", identifierFilter: "Seven", actionable: true))
        XCTAssertFalse(m(role: "AXButton", identifier: "Seven", actions: ["AXPress"],
                         roleFilter: "AXButton", identifierFilter: "Eight", actionable: true))
    }
}
