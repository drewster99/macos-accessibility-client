import XCTest
@testable import MacControlMCPCore

final class ControlNodeTests: XCTestCase {

    // MARK: RoleNames

    func testRoleAliasViaSubrole() {
        XCTAssertEqual(RoleNames.humanize(role: "AXWindow", subrole: "AXStandardWindow"), "window")
        XCTAssertEqual(RoleNames.humanize(role: "AXRadioButton", subrole: "AXTabButton"), "tab")
        XCTAssertEqual(RoleNames.humanize(role: "AXOpaqueProviderGroup", subrole: "AXOpaqueProviderList"), "tablist")
    }

    func testRoleLiteralFallback() {
        XCTAssertEqual(RoleNames.humanize(role: "AXButton", subrole: nil), "button")
        XCTAssertEqual(RoleNames.humanize(role: "AXButton", subrole: "AXCloseButton"), "closeButton")
        XCTAssertEqual(RoleNames.humanize(role: "AXTextField", subrole: nil), "textField")
    }

    // MARK: StateNames

    func testStatesShowTrueBoolsSortedAndStripped() {
        let states = StateNames.render(["AXFocused": true, "AXMain": true, "AXModal": false, "AXFrontmost": true])
        XCTAssertEqual(states, ["focused", "frontmost", "main"])  // modal=false omitted, sorted
    }

    func testEnabledInversionAndDisclosingExcluded() {
        XCTAssertEqual(StateNames.render(["AXEnabled": true]), [])           // enabled=true never shown
        XCTAssertEqual(StateNames.render(["AXEnabled": false]), ["disabled"]) // false → disabled
        XCTAssertEqual(StateNames.render(["AXDisclosing": true]), [])         // disclosing is a capability, not a state
    }

    // MARK: ActionVocab

    func testActionDisplayLabels() {
        XCTAssertEqual(ActionVocab.displayLabel(forRaw: "AXPress"), "press")
        XCTAssertEqual(ActionVocab.displayLabel(forRaw: "AXShowMenu"), "menu")
        XCTAssertEqual(ActionVocab.displayLabel(forRaw: "close tab"), "close tab")
    }

    func testActionCleanMultiline() {
        XCTAssertEqual(ActionVocab.clean("Name:Move next\nTarget:0x0\nSelector:(null)"), "Move next")
    }

    func testActionCleanRobustness() {
        // Name: extracted wherever it appears, not just the first line.
        XCTAssertEqual(ActionVocab.clean("Target:0x0\nName:Move next\nSelector:(null)"), "Move next")
        // No Name: at all, multi-line → first non-empty line (not a joined blob).
        XCTAssertEqual(ActionVocab.clean("Do the thing\n(advanced)"), "Do the thing")
        XCTAssertEqual(ActionVocab.clean("plain"), "plain")
        // Line safety is absolute: no newline (any kind) ever survives, in any format.
        for raw in ["a\nb\nc", "Name:\nX", "Target:1\nFoo", "x\r\ny", "p\u{2028}q"] {
            XCTAssertFalse(ActionVocab.clean(raw).contains(where: { $0.isNewline }), "newline survived: \(raw)")
        }
    }

    func testActionLabelStripsCommasAndRoundTrips() {
        // A custom action name with a comma must not render as two actions, and must still
        // resolve back to its raw string for performing.
        let raw = "Sort by name, ascending"
        let label = ActionVocab.displayLabel(forRaw: raw)
        XCTAssertFalse(label.contains(","))
        XCTAssertTrue(ActionVocab.matches(input: label, rawName: raw))
        XCTAssertTrue(ActionVocab.matches(input: raw, rawName: raw))   // raw still accepted
    }

    func testActionMatchesAcceptsAllForms() {
        XCTAssertTrue(ActionVocab.matches(input: "press", rawName: "AXPress"))     // short verb
        XCTAssertTrue(ActionVocab.matches(input: "AXPress", rawName: "AXPress"))   // full AX name
        XCTAssertTrue(ActionVocab.matches(input: "close tab", rawName: "close tab")) // raw custom
        XCTAssertTrue(ActionVocab.matches(input: "Move next", rawName: "Name:Move next\nTarget:0x0")) // cleaned label
        XCTAssertFalse(ActionVocab.matches(input: "menu", rawName: "AXPress"))
    }

    // MARK: ControlRenderer.line

    func testLineSegmentsTextField() {
        let node = ControlNode(ref: "e10", type: "textField", label: "Name", identifier: "computerName",
                               textValue: "Andrew's Mac", placeholder: "Enter a name",
                               states: ["focused"], actions: ["confirm"])
        XCTAssertEqual(ControlRenderer.line(node),
                       "e10 textField \"Name\" #computerName =\"Andrew's Mac\" placeholder=\"Enter a name\" {focused} - confirm")
    }

    func testLineNumericRangeAndDescription() {
        let node = ControlNode(ref: "e14", type: "slider", label: "Brightness",
                               numericValue: 0.72, minValue: 0, maxValue: 1,
                               valueDescription: "72%", actions: ["inc", "dec"])
        XCTAssertEqual(ControlRenderer.line(node), "e14 slider \"Brightness\" =0.72 [0–1] (72%) - inc,dec")
    }

    func testLineUrlAndHiddenMarkers() {
        let known = ControlNode(ref: "e2", type: "window", actions: ["raise"], hidden: .known(2))
        XCTAssertEqual(ControlRenderer.line(known), "e2 window - raise [2 hidden]")
        let more = ControlNode(ref: "e3", type: "list", hidden: .unknown)
        XCTAssertEqual(ControlRenderer.line(more), "e3 list [more hidden]")
        let link = ControlNode(ref: "e5", type: "link", label: "Privacy", url: "https://x.example/p", actions: ["press"])
        XCTAssertEqual(ControlRenderer.line(link), "e5 link \"Privacy\" url=\"https://x.example/p\" - press")
    }

    func testValueDescriptionSuppressedWhenDuplicatingValue() {
        let dup = ControlNode(ref: "e1", type: "textArea", textValue: "Almost home", valueDescription: "Almost home")
        XCTAssertEqual(ControlRenderer.line(dup), "e1 textArea =\"Almost home\"")          // gloss dropped
        let gloss = ControlNode(ref: "e2", type: "slider", numericValue: 0.72, valueDescription: "72%")
        XCTAssertEqual(ControlRenderer.line(gloss), "e2 slider =0.72 (72%)")               // kept — differs
    }

    func testValueNewlinesCollapsed() {
        let node = ControlNode(ref: "e1", type: "textField", textValue: "line one\nline two")
        XCTAssertEqual(ControlRenderer.line(node), "e1 textField =\"line one line two\"")
    }

    func testQuotesAndBackslashesEscaped() {
        let node = ControlNode(ref: "e1", type: "button", label: "Save \"Draft\"", textValue: "a\\b")
        // Embedded quotes/backslashes are escaped so they can't break the quoted line grammar.
        XCTAssertEqual(ControlRenderer.line(node), "e1 button \"Save \\\"Draft\\\"\" =\"a\\\\b\"")
    }

    // MARK: ControlRenderer.render

    func testRenderIndentationAndLegend() {
        let child = ControlNode(ref: "e2", type: "button", label: "OK", actions: ["press"])
        let root = ControlNode(ref: "e1", type: "window", label: "W", children: [child])
        let out = ControlRenderer.render(root)
        XCTAssertTrue(out.hasPrefix("// HIERARCHY"))
        XCTAssertTrue(out.contains("\ne1 window \"W\""))
        XCTAssertTrue(out.contains("\n  e2 button \"OK\" - press"))
    }

    func testCollectionShapeAndHeader() {
        let table = ControlNode(ref: "e30", type: "table", label: "Mailboxes",
                                states: ["focused"], rowCount: 248, columnCount: 3,
                                columnTitles: ["Name", "Date", "Size"], hidden: .known(243))
        XCTAssertEqual(ControlRenderer.line(table),
                       "e30 table \"Mailboxes\" [248 rows × 3 cols] cols=[Name,Date,Size] {focused} [243 hidden]")
        let grid = ControlNode(ref: "e40", type: "grid", label: "Docs", rowCount: 86, hidden: .known(80))
        XCTAssertEqual(ControlRenderer.line(grid), "e40 grid \"Docs\" [86 items] [80 hidden]")
    }

    // MARK: ControlTree pure ops

    func testTreeFindAndReplaceAndParents() {
        let leaf = ControlNode(ref: "e3", type: "button", label: "OK")
        let mid = ControlNode(ref: "e2", type: "group", children: [leaf])
        let root = ControlNode(ref: "e1", type: "window", children: [mid])

        XCTAssertEqual(ControlTree.find("e3", in: root)?.label, "OK")
        XCTAssertNil(ControlTree.find("e9", in: root))
        XCTAssertEqual(ControlTree.parentLinks(of: root), ["e2": "e1", "e3": "e2"])

        let replacement = ControlNode(ref: "e2", type: "group", label: "expanded",
                                      children: [ControlNode(ref: "e8", type: "row")])
        let spliced = ControlTree.replacingSubtree("e2", in: root, with: replacement)
        XCTAssertEqual(spliced.ref, "e1")                               // root preserved
        XCTAssertEqual(ControlTree.find("e2", in: spliced)?.label, "expanded")
        XCTAssertNotNil(ControlTree.find("e8", in: spliced))            // new child present
        XCTAssertNil(ControlTree.find("e3", in: spliced))              // old subtree gone
    }

    func testWithChildrenPreservesAttributes() {
        let node = ControlNode(ref: "e1", type: "slider", numericValue: 0.5, minValue: 0, maxValue: 1,
                               states: ["focused"], hidden: .known(2))
        let updated = node.withChildren([ControlNode(ref: "e2", type: "button")])
        XCTAssertEqual(updated.numericValue, 0.5)
        XCTAssertEqual(updated.minValue, 0)
        XCTAssertEqual(updated.states, ["focused"])
        XCTAssertEqual(updated.hidden, .known(2))
        XCTAssertEqual(updated.children.map(\.ref), ["e2"])
    }

    func testOutlineDisclosureLevelIndentation() {
        // Two flat sibling rows at disclosure levels 0 and 1 — the level-1 row indents one deeper.
        let row0 = ControlNode(ref: "r0", type: "row", label: "iCloud", disclosureLevel: 0)
        let row1 = ControlNode(ref: "r1", type: "row", label: "Inbox", disclosureLevel: 1)
        let outline = ControlNode(ref: "e1", type: "outline", children: [row0, row1])
        let out = ControlRenderer.render(outline, includeLegend: false)
        XCTAssertEqual(out, "e1 outline\n  r0 row \"iCloud\"\n    r1 row \"Inbox\"")
    }
}
