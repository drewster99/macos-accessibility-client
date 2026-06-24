import XCTest
@testable import MacControlMCPCore

final class QuiescenceTests: XCTestCase {
    func testNoChangesSettlesAfterOneIdleWindow() {
        let result = Quiescence.settle(changes: [])
        XCTAssertEqual(result, SettleResult(settledAtMs: 400, quiesced: true))
    }

    func testBurstThenQuietSettlesAfterLastChange() {
        // Activity at 50/100/150ms with sub-idle gaps → settle 400ms after the last.
        let result = Quiescence.settle(changes: [50, 100, 150])
        XCTAssertEqual(result, SettleResult(settledAtMs: 550, quiesced: true))
    }

    func testGapTriggersEarlySettle() {
        // Quiet from 100→700 (>400) → settle at 100+400; the 700 change is "after settle".
        let result = Quiescence.settle(changes: [100, 700])
        XCTAssertEqual(result, SettleResult(settledAtMs: 500, quiesced: true))
    }

    func testPerpetualMotionHitsCapNotQuiesced() {
        let spinner = Array(stride(from: 0, through: 3000, by: 100))
        let result = Quiescence.settle(changes: spinner)
        XCTAssertEqual(result, SettleResult(settledAtMs: 3000, quiesced: false))
    }

    func testCustomConfig() {
        let cfg = QuiescenceConfig(idleMs: 100, capMs: 1000)
        XCTAssertEqual(Quiescence.settle(changes: [], config: cfg),
                       SettleResult(settledAtMs: 100, quiesced: true))
        let busy = Array(stride(from: 0, through: 1000, by: 50))
        XCTAssertEqual(Quiescence.settle(changes: busy, config: cfg),
                       SettleResult(settledAtMs: 1000, quiesced: false))
    }

    func testChangesAfterCapAreIgnored() {
        // A late change beyond the cap can't keep us from settling.
        let result = Quiescence.settle(changes: [3500])
        XCTAssertEqual(result, SettleResult(settledAtMs: 400, quiesced: true))
    }
}
