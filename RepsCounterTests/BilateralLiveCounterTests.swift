import XCTest
@testable import RepsCounter

final class BilateralLiveCounterTests: XCTestCase {
    private func feed(
        _ counter: inout BilateralLiveCounter,
        clock: inout TimeInterval,
        leftConfidence: Float = 0.93,
        rightConfidence: Float = 0.93,
        partial: Bool = false
    ) {
        for (angle, frames) in [
            (170.0, 20), (partial ? 120.0 : 90.0, 20), (170.0, 20)
        ] {
            let pose = SquatPoseFixture.pose(
                leftAngle: angle, rightAngle: angle,
                leftConfidence: leftConfidence, rightConfidence: rightConfidence
            )
            for _ in 0..<frames {
                clock += 0.08
                _ = counter.process(pose, at: clock)
            }
        }
    }


    #if DEBUG
    func testDebugTelemetryKeepsBothLegMeasurementsIndependent() {
        var counter = BilateralLiveCounter()
        let pose = SquatPoseFixture.pose(
            leftAngle: 170, rightAngle: 120,
            leftConfidence: 0.93, rightConfidence: 0.85
        )
        for frameNumber in 1...20 {
            _ = counter.process(pose, at: Double(frameNumber) * 0.08)
        }
        let diagnostics = counter.telemetry
        XCTAssertEqual(diagnostics.left.measuredAngle ?? 0, 170, accuracy: 0.01)
        XCTAssertEqual(diagnostics.right.measuredAngle ?? 0, 120, accuracy: 0.01)
        XCTAssertEqual(diagnostics.left.confidence ?? 0, 0.93, accuracy: 0.001)
        XCTAssertEqual(diagnostics.right.confidence ?? 0, 0.85, accuracy: 0.001)
        XCTAssertEqual(diagnostics.left.phase, .standing)
        XCTAssertEqual(diagnostics.right.phase, .seekingStanding)
        XCTAssertEqual(diagnostics.left.event, .tracking)
        XCTAssertEqual(diagnostics.right.event, .tracking)
    }

    func testDebugTelemetryShowsBriefLossAndSecondMissingFrameReset() {
        var counter = BilateralLiveCounter()
        var currentTime: TimeInterval = 0
        let standingPose = SquatPoseFixture.pose(leftAngle: 170, rightAngle: 170)
        let loweredPose = SquatPoseFixture.pose(leftAngle: 90, rightAngle: 90)
        for (pose, frameCount) in [(standingPose, 20), (loweredPose, 20)] {
            for _ in 0..<frameCount {
                currentTime += 0.08
                _ = counter.process(pose, at: currentTime)
            }
        }
        XCTAssertEqual(counter.telemetry.left.phase, .lowered)
        XCTAssertEqual(counter.telemetry.right.phase, .lowered)

        currentTime += 0.08
        _ = counter.process(nil, at: currentTime)
        XCTAssertEqual(counter.telemetry.left.phase, .lowered)
        XCTAssertEqual(counter.telemetry.left.event, .briefLoss)
        XCTAssertEqual(counter.telemetry.left.missedFrames, 1)
        XCTAssertNil(counter.telemetry.left.measuredAngle)

        currentTime += 0.08
        _ = counter.process(nil, at: currentTime)
        XCTAssertEqual(counter.telemetry.left.phase, .seekingStanding)
        XCTAssertEqual(counter.telemetry.right.phase, .seekingStanding)
        XCTAssertEqual(counter.telemetry.left.event, .reset(.missingJoint))
        XCTAssertEqual(counter.telemetry.left.lastReset, .missingJoint)
        XCTAssertEqual(counter.telemetry.left.resetCount, 1)
        XCTAssertEqual(counter.telemetry.pendingCount, 0)
    }

    func testDebugTelemetryExplainsLowConfidenceOnOnlyOneLeg() {
        var counter = BilateralLiveCounter()
        let pose = SquatPoseFixture.pose(
            leftAngle: 170, rightAngle: 170,
            leftConfidence: 0.49, rightConfidence: 0.94
        )
        for frameNumber in 1...20 {
            _ = counter.process(pose, at: Double(frameNumber) * 0.08)
        }
        let diagnostics = counter.telemetry
        XCTAssertEqual(diagnostics.left.event, .reset(.lowConfidence))
        XCTAssertEqual(diagnostics.left.confidence ?? 0, 0.49, accuracy: 0.001)
        XCTAssertNil(diagnostics.left.measuredAngle)
        XCTAssertEqual(diagnostics.right.phase, .standing)
        XCTAssertEqual(diagnostics.right.confidence ?? 0, 0.94, accuracy: 0.001)
    }

    func testDebugTelemetryTracksCandidatesAndMergedDuplicates() {
        var counter = BilateralLiveCounter()
        var currentTime: TimeInterval = 0
        feed(&counter, clock: &currentTime)
        let diagnostics = counter.telemetry
        XCTAssertEqual(diagnostics.left.candidateCount, 1)
        XCTAssertEqual(diagnostics.right.candidateCount, 1)
        XCTAssertEqual(diagnostics.mergedDuplicates, 1)
        XCTAssertEqual(diagnostics.repetitions, 1)
        XCTAssertEqual(diagnostics.pendingCount, 0)
    }

    func testDebugTelemetryIdentifiesInvalidGeometryReset() {
        var counter = BilateralLiveCounter()
        var currentTime: TimeInterval = 0
        let standingPose = SquatPoseFixture.pose(leftAngle: 170, rightAngle: 170)
        let loweredPose = SquatPoseFixture.pose(leftAngle: 90, rightAngle: 90)
        for (pose, frameCount) in [(standingPose, 20), (loweredPose, 20)] {
            for _ in 0..<frameCount {
                currentTime += 0.08
                _ = counter.process(pose, at: currentTime)
            }
        }
        let invalidPose = BodyPose(joints: loweredPose.joints, aspectRatio: .nan)
        currentTime += 0.08
        _ = counter.process(invalidPose, at: currentTime)
        XCTAssertEqual(counter.telemetry.left.lastReset, .invalidGeometry)
        XCTAssertEqual(counter.telemetry.right.lastReset, .invalidGeometry)
        XCTAssertEqual(counter.telemetry.left.phase, .seekingStanding)
        XCTAssertEqual(counter.telemetry.left.event, .reset(.invalidGeometry))
    }
    #endif

    func testBothLegsCountOneRepetitionWithoutDuplicate() {
        var counter = BilateralLiveCounter()
        var currentTime: TimeInterval = 0
        feed(&counter, clock: &currentTime)
        XCTAssertEqual(counter.repetitions, 1)
        XCTAssertEqual(counter.mergedDuplicates, 1)
        XCTAssertTrue(counter.pendingMovements.isEmpty)
    }

    func testDifferentLegsCanConfirmSeparateRepetitions() {
        var counter = BilateralLiveCounter()
        var currentTime: TimeInterval = 0
        feed(&counter, clock: &currentTime, leftConfidence: 0.49)
        feed(&counter, clock: &currentTime, rightConfidence: 0.49)
        XCTAssertEqual(counter.repetitions, 2)
        XCTAssertEqual(counter.mergedDuplicates, 0)
    }

    func testSingleMissingPoseDuringLoweredPhasePreservesRepetition() {
        var counter = BilateralLiveCounter()
        var currentTime: TimeInterval = 0
        let standingPose = SquatPoseFixture.pose(leftAngle: 170, rightAngle: 170)
        let loweredPose = SquatPoseFixture.pose(leftAngle: 90, rightAngle: 90)

        for (pose, frameCount) in [(standingPose, 20), (loweredPose, 20)] {
            for _ in 0..<frameCount {
                currentTime += 0.08
                _ = counter.process(pose, at: currentTime)
            }
        }
        currentTime += 0.08
        _ = counter.process(nil, at: currentTime)
        for _ in 0..<20 {
            currentTime += 0.08
            _ = counter.process(standingPose, at: currentTime)
        }

        XCTAssertEqual(counter.repetitions, 1)
        XCTAssertEqual(counter.mergedDuplicates, 1)
    }

    func testTwoMissingPosesInterruptLoweredPhaseWithoutLateCount() {
        var counter = BilateralLiveCounter()
        var currentTime: TimeInterval = 0
        let standingPose = SquatPoseFixture.pose(leftAngle: 170, rightAngle: 170)
        let loweredPose = SquatPoseFixture.pose(leftAngle: 90, rightAngle: 90)

        for (pose, frameCount) in [(standingPose, 20), (loweredPose, 20)] {
            for _ in 0..<frameCount {
                currentTime += 0.08
                _ = counter.process(pose, at: currentTime)
            }
        }
        for _ in 0..<2 {
            currentTime += 0.08
            _ = counter.process(nil, at: currentTime)
        }
        for _ in 0..<20 {
            currentTime += 0.08
            _ = counter.process(standingPose, at: currentTime)
        }

        XCTAssertEqual(counter.repetitions, 0)
        XCTAssertEqual(counter.mergedDuplicates, 0)
    }

    func testSingleLowConfidenceFrameIsIgnoredWithoutLosingLoweredPhase() {
        var counter = BilateralLiveCounter()
        var currentTime: TimeInterval = 0
        let standingPose = SquatPoseFixture.pose(
            leftAngle: 170, rightAngle: 170,
            leftConfidence: 0.49, rightConfidence: 0.93
        )
        let loweredPose = SquatPoseFixture.pose(
            leftAngle: 90, rightAngle: 90,
            leftConfidence: 0.49, rightConfidence: 0.93
        )
        let unreliablePose = SquatPoseFixture.pose(
            leftAngle: 90, rightAngle: 90,
            leftConfidence: 0.49, rightConfidence: 0.49
        )
        for (pose, frameCount) in [(standingPose, 20), (loweredPose, 20)] {
            for _ in 0..<frameCount {
                currentTime += 0.08
                _ = counter.process(pose, at: currentTime)
            }
        }
        currentTime += 0.08
        _ = counter.process(unreliablePose, at: currentTime)
        for _ in 0..<20 {
            currentTime += 0.08
            _ = counter.process(standingPose, at: currentTime)
        }

        XCTAssertEqual(counter.repetitions, 1)
        XCTAssertEqual(counter.mergedDuplicates, 0)
    }

    func testInvalidPoseGeometryImmediatelyAbortsLoweredMovement() {
        var counter = BilateralLiveCounter()
        var currentTime: TimeInterval = 0
        let standingPose = SquatPoseFixture.pose(leftAngle: 170, rightAngle: 170)
        let loweredPose = SquatPoseFixture.pose(leftAngle: 90, rightAngle: 90)

        for (pose, frameCount) in [(standingPose, 20), (loweredPose, 20)] {
            for _ in 0..<frameCount {
                currentTime += 0.08
                _ = counter.process(pose, at: currentTime)
            }
        }
        let invalidPose = BodyPose(
            joints: loweredPose.joints,
            aspectRatio: .nan
        )
        currentTime += 0.08
        _ = counter.process(invalidPose, at: currentTime)
        for _ in 0..<20 {
            currentTime += 0.08
            _ = counter.process(standingPose, at: currentTime)
        }

        XCTAssertEqual(counter.repetitions, 0)
        XCTAssertEqual(counter.mergedDuplicates, 0)
    }

    func testShorterAnalysisIntervalsStillCountFullButRejectPartialSquats() {
        var counter = BilateralLiveCounter()
        var currentTime: TimeInterval = 0
        for (angle, frameCount) in [
            (170.0, 20), (90.0, 20), (170.0, 20),
            (120.0, 20), (170.0, 20)
        ] {
            let pose = SquatPoseFixture.pose(leftAngle: angle, rightAngle: angle)
            for _ in 0..<frameCount {
                currentTime += 0.06
                _ = counter.process(pose, at: currentTime)
            }
        }

        XCTAssertEqual(counter.repetitions, 1)
        XCTAssertEqual(counter.mergedDuplicates, 1)
    }

    func testPartialMovementsCannotCount() {
        var counter = BilateralLiveCounter()
        var currentTime: TimeInterval = 0
        feed(&counter, clock: &currentTime, partial: true)
        XCTAssertEqual(counter.repetitions, 0)
    }

    func testGapAbortsLoweredMovementWithoutLateCount() {
        var counter = BilateralLiveCounter()
        var currentTime: TimeInterval = 0
        for (angle, frames) in [(170.0, 20), (90.0, 20)] {
            let pose = SquatPoseFixture.pose(leftAngle: angle, rightAngle: angle)
            for _ in 0..<frames {
                currentTime += 0.08
                _ = counter.process(pose, at: currentTime)
            }
        }
        currentTime += 0.40
        _ = counter.process(nil, at: currentTime)
        let standing = SquatPoseFixture.pose(leftAngle: 170, rightAngle: 170)
        for _ in 0..<20 {
            currentTime += 0.08
            _ = counter.process(standing, at: currentTime)
        }
        XCTAssertEqual(counter.repetitions, 0)
    }

    func testPendingCountIsCommittedOnceOnPause() {
        var counter = BilateralLiveCounter()
        var currentTime: TimeInterval = 0
        let standing = SquatPoseFixture.pose(
            leftAngle: 170, rightAngle: 170,
            leftConfidence: 0.49, rightConfidence: 0.94
        )
        let lowered = SquatPoseFixture.pose(
            leftAngle: 90, rightAngle: 90,
            leftConfidence: 0.49, rightConfidence: 0.94
        )
        for (pose, frames) in [(standing, 20), (lowered, 20), (standing, 6)] {
            for _ in 0..<frames {
                currentTime += 0.08
                _ = counter.process(pose, at: currentTime)
            }
        }
        XCTAssertEqual(counter.repetitions, 0)
        XCTAssertEqual(counter.pendingMovements.count, 1)
        counter.resetMovement()
        XCTAssertEqual(counter.finishPending(), 1)
        XCTAssertEqual(counter.finishPending(), 0)
        XCTAssertEqual(counter.repetitions, 1)
    }

    @MainActor
    func testDebugSwitchCanOnlyBeEnabledBeforeWorkoutAndLegacyRemainsDefault() {
        let store = BilateralTestStore()
        let clock = BilateralTestClock()
        let experimental = WorkoutViewModel(
            persistence: store, timeSource: clock,
            cameraReady: false, startsAutomatically: false
        )
        XCTAssertFalse(experimental.usesBilateralCounting)
        XCTAssertTrue(experimental.setBilateralCountingEnabled(true))
        experimental.setCameraReady(true)
        experimental.resume()
        XCTAssertFalse(experimental.setBilateralCountingEnabled(false))
        var state: WorkoutViewState?
        experimental.onChange = { state = $0 }
        for (angle, frames) in [(170.0, 20), (90.0, 20), (170.0, 20)] {
            let pose = SquatPoseFixture.pose(leftAngle: angle, rightAngle: angle)
            for _ in 0..<frames {
                clock.currentTime += 0.08
                experimental.process(pose)
            }
        }
        XCTAssertEqual(state?.totalRepetitions, 1)
        experimental.finish()
        XCTAssertEqual(experimental.finishedSummary?.repetitions, 1)

        let legacy = WorkoutViewModel(persistence: store, timeSource: BilateralTestClock())
        XCTAssertFalse(legacy.usesBilateralCounting)
        legacy.finish()
    }
    @MainActor
    func testDefaultReleaseModeUsesLegacyCounter() {
        let store = BilateralTestStore()
        let clock = BilateralTestClock()
        let viewModel = WorkoutViewModel(persistence: store, timeSource: clock)
        XCTAssertFalse(viewModel.usesBilateralCounting)
        var lastState: WorkoutViewState?
        viewModel.onChange = { lastState = $0 }
        for (angle, frames) in [(170.0, 20), (90.0, 20), (170.0, 20)] {
            let pose = SquatPoseFixture.pose(leftAngle: angle, rightAngle: angle)
            for _ in 0..<frames {
                clock.currentTime += 0.08
                viewModel.process(pose)
            }
        }
        XCTAssertEqual(lastState?.totalRepetitions, 1)
        viewModel.finish()
        XCTAssertEqual(viewModel.finishedSummary?.repetitions, 1)
        XCTAssertEqual(try? store.history().first?.repetitions, 1)
    }

    @MainActor
    func testBilateralPauseResumeAndHistorySaveExactlyTwoRepetitions() {
        let store = BilateralTestStore()
        let clock = BilateralTestClock()
        let viewModel = WorkoutViewModel(
            persistence: store, timeSource: clock,
            cameraReady: false, startsAutomatically: false
        )
        XCTAssertTrue(viewModel.setBilateralCountingEnabled(true))
        viewModel.setCameraReady(true)
        viewModel.resume()
        var lastState: WorkoutViewState?
        viewModel.onChange = { lastState = $0 }
        for (angle, frames) in [(170.0, 20), (90.0, 20), (170.0, 6)] {
            let pose = SquatPoseFixture.pose(leftAngle: angle, rightAngle: angle)
            for _ in 0..<frames {
                clock.currentTime += 0.08
                viewModel.process(pose)
            }
        }
        viewModel.pause()
        XCTAssertEqual(lastState?.totalRepetitions, 1)
        clock.currentTime += 2
        viewModel.resume()
        for (angle, frames) in [(170.0, 20), (90.0, 20), (170.0, 20)] {
            let pose = SquatPoseFixture.pose(leftAngle: angle, rightAngle: angle)
            for _ in 0..<frames {
                clock.currentTime += 0.08
                viewModel.process(pose)
            }
        }
        viewModel.finish()
        XCTAssertEqual(viewModel.finishedSummary?.repetitions, 2)
        XCTAssertEqual(try? store.history().first?.repetitions, 2)
    }

    @MainActor
    func testFinishingWhileEventPendingSavesOneRepetition() {
        let store = BilateralTestStore()
        let clock = BilateralTestClock()
        let viewModel = WorkoutViewModel(
            persistence: store, timeSource: clock,
            cameraReady: false, startsAutomatically: false
        )
        XCTAssertTrue(viewModel.setBilateralCountingEnabled(true))
        viewModel.setCameraReady(true)
        viewModel.resume()
        for (angle, frames) in [(170.0, 20), (90.0, 20), (170.0, 6)] {
            let pose = SquatPoseFixture.pose(
                leftAngle: angle, rightAngle: angle,
                leftConfidence: 0.49, rightConfidence: 0.94
            )
            for _ in 0..<frames {
                clock.currentTime += 0.08
                viewModel.process(pose)
            }
        }
        viewModel.finish()
        viewModel.finish()
        XCTAssertEqual(viewModel.finishedSummary?.repetitions, 1)
        XCTAssertEqual(try? store.history().count, 1)
        XCTAssertEqual(try? store.history().first?.repetitions, 1)
    }

    @MainActor
    func testBilateralCanBeDisabledBeforeStartAndCannotChangeMidWorkout() {
        let store = BilateralTestStore()
        let clock = BilateralTestClock()
        let viewModel = WorkoutViewModel(
            persistence: store, timeSource: clock,
            cameraReady: false, startsAutomatically: false
        )
        XCTAssertTrue(viewModel.setBilateralCountingEnabled(true))
        XCTAssertTrue(viewModel.setBilateralCountingEnabled(false))
        XCTAssertFalse(viewModel.usesBilateralCounting)
        viewModel.setCameraReady(true)
        viewModel.resume()
        XCTAssertFalse(viewModel.setBilateralCountingEnabled(true))
        XCTAssertFalse(viewModel.usesBilateralCounting)
        viewModel.finish()
        XCTAssertFalse(viewModel.setBilateralCountingEnabled(true))
    }

}

@MainActor
private final class BilateralTestClock: WorkoutTimeSource {
    var currentTime: TimeInterval = 0
    var date: Date { Date(timeIntervalSince1970: 0) }
}

@MainActor
private final class BilateralTestStore: WorkoutStoring {
    private var summaries: [WorkoutSummary] = []
    func save(_ summary: WorkoutSummary) throws { summaries.append(summary) }
    func history() throws -> [WorkoutSummary] { summaries }
}
