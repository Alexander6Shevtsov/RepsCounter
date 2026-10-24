import XCTest
@testable import RepsCounter

final class SquatCounterTests: XCTestCase {
    func testCountsOnlyFullMovementCycle() {
        var counter = SquatCounter()
        for angle in [170.0, 170, 170, 95, 95, 95, 170, 170, 170] {
            _ = counter.process(angle: angle)
        }
        XCTAssertEqual(counter.repetitions, 1)
        XCTAssertEqual(counter.phase, .standing)
    }

    func testDoesNotCountPartialSquat() {
        var counter = SquatCounter()
        for angle in [170.0, 170, 170, 130, 130, 130, 170, 170, 170] {
            _ = counter.process(angle: angle)
        }
        XCTAssertEqual(counter.repetitions, 0)
    }

    func testIgnoresJitterAroundThreshold() {
        var counter = SquatCounter()
        for angle in [170.0, 170, 170, 104, 108, 104, 108, 170, 170, 170] {
            _ = counter.process(angle: angle)
        }
        XCTAssertEqual(counter.repetitions, 0)
    }

    func testMissingPoseRequiresReacquisition() {
        var counter = SquatCounter()
        for angle in [170.0, 170, 170, 95, 95, 95] {
            _ = counter.process(angle: angle)
        }
        for _ in 0..<12 { _ = counter.process(angle: nil) }
        for angle in [170.0, 170, 170] { _ = counter.process(angle: angle) }
        XCTAssertEqual(counter.repetitions, 0)
    }
}
