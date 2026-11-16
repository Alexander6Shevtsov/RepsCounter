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

    func testSingleMissingFrameInvalidatesLoweredPhaseWithoutLosingCountedRepetitions() {
        var counter = makeCounterAfterOneRepetition()
        for angle in [95.0, 95, 95] { _ = counter.process(angle: angle) }
        XCTAssertFalse(counter.process(angle: nil))
        XCTAssertEqual(counter.phase, .seekingStanding)
        XCTAssertEqual(counter.decision, .invalidMeasurement)
        for angle in [170.0, 170, 170] { XCTAssertFalse(counter.process(angle: angle)) }
        XCTAssertEqual(counter.repetitions, 1)
    }

    func testInvalidAnglesCannotConfirmStanding() {
        for angle in [Double.nan, .infinity, -.infinity, -1, 181] {
            var counter = SquatCounter()
            for _ in 0..<4 { XCTAssertFalse(counter.process(angle: angle)) }
            XCTAssertEqual(counter.phase, .seekingStanding)
            XCTAssertEqual(counter.consecutiveFrames, 0)
            XCTAssertEqual(counter.decision, .invalidMeasurement)
        }
    }

    func testExactThresholdsRequireThreeConsecutiveFramesPerTransition() {
        var counter = SquatCounter()
        XCTAssertFalse(counter.process(angle: 160))
        XCTAssertEqual(counter.consecutiveFrames, 1)
        XCTAssertEqual(counter.decision, .confirmingStanding)
        XCTAssertFalse(counter.process(angle: 160))
        XCTAssertEqual(counter.consecutiveFrames, 2)
        XCTAssertFalse(counter.process(angle: 160))
        XCTAssertEqual(counter.consecutiveFrames, 3)
        XCTAssertEqual(counter.decision, .standingConfirmed)
        for _ in 0..<3 { XCTAssertFalse(counter.process(angle: 105)) }
        XCTAssertEqual(counter.phase, .lowered)
        XCTAssertEqual(counter.decision, .loweredConfirmed)
        XCTAssertFalse(counter.process(angle: 160))
        XCTAssertFalse(counter.process(angle: 160))
        XCTAssertEqual(counter.decision, .confirmingReturn)
        XCTAssertTrue(counter.process(angle: 160))
        XCTAssertEqual(counter.decision, .repetitionCounted)
        XCTAssertEqual(counter.repetitions, 1)
    }

    func testIntermediateAngleBreaksConsecutiveDepthConfirmation() {
        var counter = SquatCounter()
        for angle in [170.0, 170, 170, 100, 100, 120] { _ = counter.process(angle: angle) }
        XCTAssertEqual(counter.consecutiveFrames, 0)
        XCTAssertEqual(counter.decision, .awaitingDepth)
        for angle in [100.0, 100] { _ = counter.process(angle: angle) }
        XCTAssertEqual(counter.phase, .standing)
        XCTAssertEqual(counter.consecutiveFrames, 2)
        XCTAssertFalse(counter.process(angle: 100))
        XCTAssertEqual(counter.phase, .lowered)
    }

    func testMissingFrameClearsPartialStandingConfirmation() {
        var counter = SquatCounter()
        for angle in [170.0, 170] { _ = counter.process(angle: angle) }
        _ = counter.process(angle: nil)
        _ = counter.process(angle: 170)
        XCTAssertEqual(counter.phase, .seekingStanding)
        XCTAssertEqual(counter.consecutiveFrames, 1)
    }

    func testHoldingStandingAfterCountDoesNotCountTwice() {
        var counter = makeCounterAfterOneRepetition()
        for _ in 0..<30 { XCTAssertFalse(counter.process(angle: 170)) }
        XCTAssertEqual(counter.repetitions, 1)
        XCTAssertEqual(counter.decision, .awaitingDepth)
    }

    func testStartingLoweredCannotCountWithoutConfirmedStanding() {
        var counter = SquatCounter()
        for angle in [90.0, 90, 90, 170, 170, 100, 100, 100, 170, 170, 170] {
            XCTAssertFalse(counter.process(angle: angle))
        }
        XCTAssertEqual(counter.repetitions, 0)
        XCTAssertEqual(counter.phase, .standing)
    }


    func testExperimentalDepthGateCountsThreeDeepAndRejectsThreeAlmostDeepMovements() {
        var counter = SquatCounter(maximumHipKneeHeightRatio: 0.35)
        for movement in 0..<6 {
            for _ in 0..<4 {
                _ = counter.process(measuredAngle: 170, smoothedAngle: 170, hipKneeHeightRatio: 0.98)
            }
            let isPartial = movement >= 3
            for _ in 0..<4 {
                XCTAssertFalse(counter.process(
                    measuredAngle: isPartial ? 99 : 70,
                    smoothedAngle: isPartial ? 99 : 70,
                    hipKneeHeightRatio: isPartial ? 0.48 : 0.08
                ))
            }
            XCTAssertEqual(counter.phase, isPartial ? .standing : .lowered)
            if isPartial { XCTAssertEqual(counter.decision, .awaitingHipKneeDepth) }
            for _ in 0..<4 {
                _ = counter.process(measuredAngle: 170, smoothedAngle: 170, hipKneeHeightRatio: 0.98)
            }
            XCTAssertEqual(counter.repetitions, min(movement + 1, 3))
        }
    }

    func testExperimentalDepthGateRequiresConsecutiveAngleAndHeightConfirmation() {
        var counter = SquatCounter(maximumHipKneeHeightRatio: 0.35)
        for _ in 0..<3 {
            _ = counter.process(measuredAngle: 170, smoothedAngle: 170, hipKneeHeightRatio: 0.98)
        }
        for _ in 0..<2 {
            XCTAssertFalse(counter.process(measuredAngle: 99, smoothedAngle: 99, hipKneeHeightRatio: 0.30))
        }
        XCTAssertEqual(counter.consecutiveFrames, 2)
        XCTAssertFalse(counter.process(measuredAngle: 99, smoothedAngle: 99, hipKneeHeightRatio: 0.48))
        XCTAssertEqual(counter.consecutiveFrames, 0)
        XCTAssertEqual(counter.decision, .awaitingHipKneeDepth)
        for _ in 0..<2 {
            XCTAssertFalse(counter.process(measuredAngle: 99, smoothedAngle: 99, hipKneeHeightRatio: 0.35))
        }
        XCTAssertEqual(counter.phase, .standing)
        XCTAssertFalse(counter.process(measuredAngle: 99, smoothedAngle: 99, hipKneeHeightRatio: 0.35))
        XCTAssertEqual(counter.phase, .lowered)
    }

    func testExperimentalDepthGateResetsOnMissingOrInvalidHeight() {
        for invalidHeight in [Optional<Double>.none, .some(.nan), .some(.infinity), .some(1.1)] {
            var counter = SquatCounter(maximumHipKneeHeightRatio: 0.35)
            for _ in 0..<3 {
                _ = counter.process(measuredAngle: 170, smoothedAngle: 170, hipKneeHeightRatio: 0.98)
                _ = counter.process(measuredAngle: 70, smoothedAngle: 70, hipKneeHeightRatio: 0.08)
            }
            XCTAssertEqual(counter.phase, .lowered)
            XCTAssertFalse(counter.process(measuredAngle: 170, smoothedAngle: 170, hipKneeHeightRatio: invalidHeight))
            XCTAssertEqual(counter.phase, .seekingStanding)
            XCTAssertEqual(counter.decision, .invalidMeasurement)
            for _ in 0..<3 {
                XCTAssertFalse(counter.process(measuredAngle: 170, smoothedAngle: 170, hipKneeHeightRatio: 0.98))
            }
            XCTAssertEqual(counter.repetitions, 0)
        }
    }

    func testExperimentalDepthGateKeepsLegacyCounterBehaviorWithoutConfiguration() {
        var counter = SquatCounter()
        for _ in 0..<3 {
            _ = counter.process(measuredAngle: 170, smoothedAngle: 170)
        }
        for _ in 0..<3 {
            _ = counter.process(measuredAngle: 99, smoothedAngle: 99)
        }
        for _ in 0..<3 {
            _ = counter.process(measuredAngle: 170, smoothedAngle: 170)
        }
        XCTAssertEqual(counter.repetitions, 1)
    }

    private func makeCounterAfterOneRepetition() -> SquatCounter {
        var counter = SquatCounter()
        for angle in [170.0, 170, 170, 95, 95, 95, 170, 170, 170] {
            _ = counter.process(angle: angle)
        }
        return counter
    }
}
