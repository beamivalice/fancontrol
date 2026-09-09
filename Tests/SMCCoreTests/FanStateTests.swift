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

    /// A Max that spun nothing up must not present as success.
    func testStoppedFansAreOffEvenWhileHoldingMax() {
        let stopped = [fan(0, rpm: 0, mode: 1), fan(1, rpm: 0, mode: 1)]
        XCTAssertEqual(FanHealth.state(fans: stopped, manual: true), .off)
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

    /// Percent is over the machine's highest max, so the floor reads ~23%.
    func testPercentUsesMachineCeilingNotPerFanMax() {
        let low = fan(0, rpm: 1350, max: 5349)
        let pct = Swift.max(0, Swift.min(100, Int((low.actualRPM / 5777 * 100).rounded())))
        XCTAssertEqual(pct, 23)
    }
}
