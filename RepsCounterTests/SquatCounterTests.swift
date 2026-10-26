//
//  SquatCounterTests.swift
//  RepsCounter
//
//  Maintainer: Alexander Shevtsov
//  Copyright © 2026 Alexander Shevtsov.

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

    func testMovementResetPreservesCompletedRepetitions() {
        var counter = makeCounterAfterOneRepetition()
        for angle in [95.0, 95, 95] { _ = counter.process(angle: angle) }
        XCTAssertEqual(counter.phase, .lowered)

        counter.resetMovement()

        XCTAssertEqual(counter.repetitions, 1)
        XCTAssertEqual(counter.phase, .seekingStanding)
    }

    func testStandingAfterMovementResetDoesNotFinishPreviousSquat() {
        var counter = makeCounterAfterOneRepetition()
        for angle in [95.0, 95, 95] { _ = counter.process(angle: angle) }
        counter.resetMovement()

        for angle in [170.0, 170, 170] {
            XCTAssertFalse(counter.process(angle: angle))
        }

        XCTAssertEqual(counter.repetitions, 1)
        XCTAssertEqual(counter.phase, .standing)
    }

    func testLoweredPoseBeforeConfirmedStandingCannotCountAfterMovementReset() {
        var counter = makeCounterAfterOneRepetition()
        counter.resetMovement()

        for angle in [95.0, 95, 95, 170, 170, 95, 95, 95, 170, 170, 170] {
            XCTAssertFalse(counter.process(angle: angle))
        }

        XCTAssertEqual(counter.repetitions, 1)
        XCTAssertEqual(counter.phase, .standing)
    }

    func testMovementResetDiscardsStableFramesFromBeforePause() {
        var counter = makeCounterAfterOneRepetition()
        for angle in [95.0, 95] { _ = counter.process(angle: angle) }
        counter.resetMovement()

        XCTAssertFalse(counter.process(angle: 170))
        XCTAssertEqual(counter.phase, .seekingStanding)
        XCTAssertFalse(counter.process(angle: 170))
        XCTAssertEqual(counter.phase, .seekingStanding)
        XCTAssertFalse(counter.process(angle: 170))
        XCTAssertEqual(counter.phase, .standing)
        XCTAssertEqual(counter.repetitions, 1)
    }

    func testFullNewCycleAfterMovementResetCountsExactlyOneMoreRepetition() {
        var counter = makeCounterAfterOneRepetition()
        for angle in [95.0, 95, 95] { _ = counter.process(angle: angle) }
        counter.resetMovement()
        var countedMovements = 0

        for angle in [170.0, 170, 170, 95, 95, 95, 170, 170, 170, 170, 170, 170] {
            if counter.process(angle: angle) { countedMovements += 1 }
        }

        XCTAssertEqual(countedMovements, 1)
        XCTAssertEqual(counter.repetitions, 2)
        XCTAssertEqual(counter.phase, .standing)
    }

    func testFullResetClearsRepetitionsAndMovementProgress() {
        var counter = makeCounterAfterOneRepetition()
        for angle in [95.0, 95, 95, 170, 170] { _ = counter.process(angle: angle) }

        counter.reset()

        XCTAssertEqual(counter.repetitions, 0)
        XCTAssertEqual(counter.phase, .seekingStanding)
        for angle in [170.0, 170, 170] {
            XCTAssertFalse(counter.process(angle: angle))
        }
        XCTAssertEqual(counter.repetitions, 0)
        XCTAssertEqual(counter.phase, .standing)
    }

    private func makeCounterAfterOneRepetition() -> SquatCounter {
        var counter = SquatCounter()
        for angle in [170.0, 170, 170, 95, 95, 95, 170, 170, 170] {
            _ = counter.process(angle: angle)
        }
        return counter
    }
}
