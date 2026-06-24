import XCTest
import CoreGraphics
@testable import MacControlMCPCore

final class DiffTests: XCTestCase {
    func testAddedRemovedAndValueChange() {
        // Mirrors the §6 click→settle example: Compose button gone, a sheet field added,
        // and an existing field's value changes.
        let before = ElementNode(ref: "e1", role: "AXWindow", title: "Mail", children: [
            ElementNode(ref: "e12", role: "AXButton", title: "Compose", actions: ["AXPress"]),
            ElementNode(ref: "e30", role: "AXTextField", title: "Body", value: "")
        ])
        let after = ElementNode(ref: "e1", role: "AXWindow", title: "Mail", children: [
            ElementNode(ref: "e30", role: "AXTextField", title: "Body", value: "Draft"),
            ElementNode(ref: "e90", role: "AXTextField", title: "To:",
                        frame: CGRect(x: 0, y: 0, width: 200, height: 24))
        ])
        let diff = Diff.compute(old: before, new: after)

        XCTAssertEqual(diff.removed, ["e12"])
        XCTAssertTrue(diff.added.contains { $0.hasPrefix("e90 AXTextField \"To:\"") })
        XCTAssertEqual(diff.changed.count, 1)
        XCTAssertEqual(diff.changed.first?.ref, "e30")
        XCTAssertEqual(diff.changed.first?.was, "value:\"\"")
        XCTAssertEqual(diff.changed.first?.now, "value:\"Draft\"")
    }

    func testIdenticalTreeIsEmptyDiff() {
        let tree = ElementNode(ref: "e1", role: "AXWindow", title: "W", children: [
            ElementNode(ref: "e2", role: "AXButton", title: "OK", actions: ["AXPress"])
        ])
        XCTAssertTrue(Diff.compute(old: tree, new: tree).isEmpty)
    }

    func testTitleChangeReported() {
        let before = ElementNode(ref: "e1", role: "AXStaticText", title: "Loading…")
        let after = ElementNode(ref: "e1", role: "AXStaticText", title: "Done")
        let diff = Diff.compute(old: before, new: after)
        XCTAssertEqual(diff.changed.first?.was, "title:\"Loading…\"")
        XCTAssertEqual(diff.changed.first?.now, "title:\"Done\"")
    }

    func testValueChangeTakesPrecedenceOverTitle() {
        let before = ElementNode(ref: "e1", role: "AXSlider", title: "Vol", value: "3")
        let after = ElementNode(ref: "e1", role: "AXSlider", title: "Volume", value: "7")
        let diff = Diff.compute(old: before, new: after)
        XCTAssertEqual(diff.changed.count, 1)
        XCTAssertEqual(diff.changed.first?.now, "value:\"7\"")
    }
}
