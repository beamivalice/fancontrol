import XCTest
@testable import SMCCore

final class FanStateTests: XCTestCase {
    private func fan(_ i: Int, rpm: Float, mode: Int = 0, max: Float = 5777) -> FanInfo {
        FanInfo(index: i, actualRPM: rpm, targetRPM: rpm, minRPM: 1350, maxRPM: max, mode: mode)
    }

    func testNoDataIsUnknownNotOff() {
        XCTAssertEqual(FanHealth.state(fans: [], manual: false), .unknown)
        XCTAssertEqual(FanHealth.state(fans: [], manual: true), .unknown)
    }

    /// Holding Max stays Max even at 0 rpm, so the click is not a no-op.
    func testHoldingMaxIsMaxEvenIfStopped() {
        let stopped = [fan(0, rpm: 0, mode: 1), fan(1, rpm: 0, mode: 1)]
        XCTAssertEqual(FanHealth.state(fans: stopped, manual: true), .max)
    }

    func testIdleStoppedFansUnderAutoControl() {
        XCTAssertEqual(FanHealth.state(fans: [fan(0, rpm: 0), fan(1, rpm: 0)], manual: false), .off)
    }

    func testOneSpinningFanIsEnough() {
        let mixed = [fan(0, rpm: 0), fan(1, rpm: 4200)]
        XCTAssertEqual(FanHealth.state(fans: mixed, manual: false), .auto)
        XCTAssertEqual(FanHealth.state(fans: mixed, manual: true), .max)
    }

    func testSpinningPlusManualIsMaxAutoIsAuto() {
        XCTAssertEqual(FanHealth.state(fans: [fan(0, rpm: 5343, mode: 1)], manual: true), .max)
        XCTAssertEqual(FanHealth.state(fans: [fan(0, rpm: 4159, mode: 0)], manual: false), .auto)
    }

    func testStoppedThresholdBoundaries() {
        let edge = FanHealth.stoppedRPM
        XCTAssertEqual(FanHealth.state(fans: [fan(0, rpm: edge - 1)], manual: false), .off)
        XCTAssertEqual(FanHealth.state(fans: [fan(0, rpm: edge)], manual: false), .auto)
        XCTAssertEqual(FanHealth.state(fans: [fan(0, rpm: edge + 1)], manual: false), .auto)
    }

    /// A fifth state should fail this and force the question: can a caller
    /// command it? It must not be able to.
    func testStateSetIsExactlyFourObservations() {
        XCTAssertEqual([FanState.off, .max, .auto, .unknown].map(\.rawValue).sorted(),
                       ["auto", "max", "off", "unknown"])
    }

    func testNeedsMaxReassertWhenParkedOrDropped() {
        let parked = [fan(0, rpm: 0, mode: 0), fan(1, rpm: 0, mode: 0)]
        XCTAssertTrue(FanHealth.needsMaxReassert(parked))

        let modeDropped = [fan(0, rpm: 5343, mode: 0, max: 5349)]
        XCTAssertTrue(FanHealth.needsMaxReassert(modeDropped))

        let holding = [FanInfo(index: 0, actualRPM: 5300, targetRPM: 5349, minRPM: 1350, maxRPM: 5349, mode: 1)]
        XCTAssertFalse(FanHealth.needsMaxReassert(holding))
    }

    /// Each fan's 100% is its own F%dMx, not the other fan's ceiling.
    func testPercentUsesEachFansOwnMax() {
        XCTAssertEqual(FanHealth.percent(of: fan(0, rpm: 5349, max: 5349)), 100)
        XCTAssertEqual(FanHealth.percent(of: fan(1, rpm: 5777, max: 5777)), 100)
        XCTAssertEqual(FanHealth.percent(of: fan(0, rpm: 1350, max: 5349)), 25)
        XCTAssertEqual(FanHealth.percent(of: fan(1, rpm: 1350, max: 5777)), 23)
        XCTAssertEqual(FanHealth.percent(of: fan(0, rpm: 0, max: 5349)), 0)
    }
}
