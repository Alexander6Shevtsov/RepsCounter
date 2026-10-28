//
//  SquatObservationTests.swift
//  RepsCounter
//
//  Maintainer: Alexander Shevtsov
//  Copyright © 2026 Alexander Shevtsov.

import XCTest
@testable import RepsCounter

final class SquatObservationTests: XCTestCase {
    func testObserved97Point6RawAnd104Point9EMAConfirmThirdRawDepthFrame() {
        var counter = standingCounter()
        XCTAssertFalse(counter.process(measuredAngle: 100, smoothedAngle: 110))
        XCTAssertFalse(counter.process(measuredAngle: 99, smoothedAngle: 108))
        XCTAssertEqual(counter.consecutiveFrames, 2)
        XCTAssertFalse(counter.process(measuredAngle: 97.6, smoothedAngle: 104.9))
        XCTAssertEqual(counter.phase, .lowered)
        XCTAssertEqual(counter.decision, .loweredConfirmed)
        XCTAssertEqual(counter.consecutiveFrames, 3)
        XCTAssertEqual(counter.repetitions, 0)
    }

    func testObserved104RawAnd107Point9EMAStillRequireFilteredThreshold() {
        var counter = standingCounter()
        for _ in 0..<3 { XCTAssertFalse(counter.process(measuredAngle: 104, smoothedAngle: 107.9)) }
        XCTAssertEqual(counter.phase, .standing)
        XCTAssertEqual(counter.consecutiveFrames, 3)
        XCTAssertEqual(counter.decision, .awaitingDepthSmoothing)
        XCTAssertFalse(counter.process(measuredAngle: 104, smoothedAngle: 105.1))
        XCTAssertEqual(counter.phase, .standing)
        XCTAssertFalse(counter.process(measuredAngle: 104, smoothedAngle: 104.9))
        XCTAssertEqual(counter.phase, .lowered)
    }

    func testObserved96Point5AfterLossCannotReplaceStandingReacquisition() {
        var counter = loweredCounter()
        XCTAssertFalse(counter.process(measuredAngle: nil, smoothedAngle: nil))
        for _ in 0..<8 { XCTAssertFalse(counter.process(measuredAngle: 96.5, smoothedAngle: 96.5)) }
        XCTAssertEqual(counter.phase, .seekingStanding)
        XCTAssertEqual(counter.decision, .awaitingStanding)
        for _ in 0..<3 { XCTAssertFalse(counter.process(measuredAngle: 170, smoothedAngle: 170)) }
        XCTAssertEqual(counter.repetitions, 0)
    }

    func testEMABelowThresholdCannotConfirmDepthWithoutThreeRawFrames() {
        for frameCount in [1, 2] {
            var counter = standingCounter()
            for _ in 0..<frameCount { _ = counter.process(measuredAngle: 97.6, smoothedAngle: 104.9) }
            for _ in 0..<8 { _ = counter.process(measuredAngle: 110, smoothedAngle: 104.9) }
            XCTAssertEqual(counter.phase, .standing)
            XCTAssertEqual(counter.consecutiveFrames, 0)
            for _ in 0..<3 { XCTAssertFalse(counter.process(measuredAngle: 170, smoothedAngle: 170)) }
            XCTAssertEqual(counter.repetitions, 0)
        }
    }

    func testRawMustStillMeetDepthWhenEMAEventuallyCrossesThreshold() {
        var counter = standingCounter()
        for _ in 0..<3 { _ = counter.process(measuredAngle: 104, smoothedAngle: 107.9) }
        XCTAssertFalse(counter.process(measuredAngle: 106, smoothedAngle: 104.9))
        XCTAssertEqual(counter.phase, .standing)
        XCTAssertEqual(counter.consecutiveFrames, 0)
        XCTAssertEqual(counter.decision, .awaitingDepth)
    }

    func testAlternatingRawDepthDoesNotAccumulateConfirmation() {
        var counter = standingCounter()
        for _ in 0..<20 {
            _ = counter.process(measuredAngle: 104, smoothedAngle: 104.9)
            _ = counter.process(measuredAngle: 106, smoothedAngle: 104.9)
        }
        XCTAssertEqual(counter.phase, .standing)
        XCTAssertEqual(counter.repetitions, 0)
        XCTAssertEqual(counter.consecutiveFrames, 0)
    }

    func testReturnRequiresRawStandingSeriesAndCurrentEMAStanding() {
        var counter = loweredCounter()
        for _ in 0..<3 { XCTAssertFalse(counter.process(measuredAngle: 170, smoothedAngle: 159.9)) }
        XCTAssertEqual(counter.phase, .lowered)
        XCTAssertEqual(counter.decision, .awaitingReturnSmoothing)
        XCTAssertTrue(counter.process(measuredAngle: 170, smoothedAngle: 160))
        XCTAssertEqual(counter.repetitions, 1)
        for _ in 0..<20 { XCTAssertFalse(counter.process(measuredAngle: 170, smoothedAngle: 170)) }
        XCTAssertEqual(counter.repetitions, 1)
    }

    func testEMAStandingWithoutCurrentRawStandingCannotFinishMovement() {
        var counter = loweredCounter()
        for _ in 0..<2 { _ = counter.process(measuredAngle: 170, smoothedAngle: 170) }
        for _ in 0..<8 { XCTAssertFalse(counter.process(measuredAngle: 159, smoothedAngle: 170)) }
        XCTAssertEqual(counter.phase, .lowered)
        XCTAssertEqual(counter.repetitions, 0)
        XCTAssertEqual(counter.consecutiveFrames, 0)
    }

    func testInitialStandingRequiresBothRawConfirmationAndEMA() {
        var counter = SquatCounter()
        for _ in 0..<3 { _ = counter.process(measuredAngle: 170, smoothedAngle: 159) }
        XCTAssertEqual(counter.phase, .seekingStanding)
        XCTAssertEqual(counter.decision, .awaitingStandingSmoothing)
        _ = counter.process(measuredAngle: 170, smoothedAngle: 160)
        XCTAssertEqual(counter.phase, .standing)
    }

    func testInvalidRawOrEMAResetsPendingConfirmation() {
        let invalidPairs: [(Double?, Double?)] = [(nil, 104), (104, nil), (.nan, 104), (104, .infinity), (-1, 104), (104, 181)]
        for invalidPair in invalidPairs {
            var counter = standingCounter()
            for _ in 0..<3 { _ = counter.process(measuredAngle: 104, smoothedAngle: 107.9) }
            XCTAssertFalse(counter.process(measuredAngle: invalidPair.0, smoothedAngle: invalidPair.1))
            XCTAssertEqual(counter.phase, .seekingStanding)
            XCTAssertEqual(counter.consecutiveFrames, 0)
        }
    }

    @MainActor
    func testContinuous104DegreeDepthCountsAfterFirstEMACrossing() {
        let fixture = ObservationWorkoutFixture()
        defer { fixture.viewModel.finish() }
        fixture.feed(angle: 170, frames: 24)
        fixture.feed(angle: 110, frames: 48)
        fixture.feed(angle: 104)
        #if DEBUG
        XCTAssertEqual(fixture.viewModel.latestDiagnostics?.analysis?.smoothedAngle ?? 0, 107.9, accuracy: 0.001)
        #endif
        fixture.feed(angle: 104, frames: 4)
        #if DEBUG
        XCTAssertEqual(fixture.viewModel.latestDiagnostics?.phase, .lowered)
        #endif
        fixture.feed(angle: 170, frames: 24)
        XCTAssertEqual(fixture.state?.totalRepetitions, 1)
        fixture.feed(angle: 170, frames: 24)
        XCTAssertEqual(fixture.state?.totalRepetitions, 1)
    }

    @MainActor
    func testOnlyTwoDepthSpikesCannotCountViaEMATail() {
        let fixture = ObservationWorkoutFixture()
        defer { fixture.viewModel.finish() }
        fixture.feed(angle: 170, frames: 24)
        fixture.feed(angle: 30, frames: 2)
        fixture.feed(angle: 110, frames: 20)
        fixture.feed(angle: 170, frames: 24)
        XCTAssertEqual(fixture.state?.totalRepetitions, 0)
    }

    @MainActor
    func testObservedHipConfidenceDipsDiscardCycleWithoutGraceOrCountLoss() {
        for confidencePair in [(Float(0.39), Float(0.44)), (Float(0.49), Float(0.48))] {
            let fixture = ObservationWorkoutFixture()
            fixture.completeRepetition()
            fixture.feed(angle: 97.6, frames: 24)
            fixture.feed(angle: 97.6, leftHipConfidence: confidencePair.0, rightHipConfidence: confidencePair.1)
            #if DEBUG
            let diagnostics = fixture.viewModel.latestDiagnostics
            XCTAssertEqual(diagnostics?.analysis?.leftMeasurement.hipConfidence, confidencePair.0)
            XCTAssertEqual(diagnostics?.analysis?.rightMeasurement.hipConfidence, confidencePair.1)
            XCTAssertNil(diagnostics?.analysis?.selectedLeg)
            XCTAssertEqual(diagnostics?.phase, .seekingStanding)
            XCTAssertEqual(diagnostics?.consecutiveFrames, 0)
            #endif
            fixture.feed(angle: 96.5, frames: 24)
            fixture.feed(angle: 170, frames: 24)
            XCTAssertEqual(fixture.state?.totalRepetitions, 1)
            fixture.completeRepetition()
            XCTAssertEqual(fixture.state?.totalRepetitions, 2)
            fixture.viewModel.finish()
        }
    }

    @MainActor
    func testConfidenceDipDuringPartialDepthClearsRawConfirmation() {
        let fixture = ObservationWorkoutFixture()
        defer { fixture.viewModel.finish() }
        fixture.feed(angle: 170, frames: 24)
        fixture.feed(angle: 97.6, frames: 2)
        fixture.feed(angle: 97.6, leftHipConfidence: 0.39, rightHipConfidence: 0.44)
        fixture.feed(angle: 97.6, frames: 24)
        fixture.feed(angle: 170, frames: 24)
        XCTAssertEqual(fixture.state?.totalRepetitions, 0)
    }

    @MainActor
    func testSilentGapBeforeStandingCannotCompleteObservedDepth() {
        let fixture = ObservationWorkoutFixture()
        defer { fixture.viewModel.finish() }
        fixture.feed(angle: 170, frames: 24)
        fixture.feed(angle: 97.6, frames: 24)
        fixture.clock.currentTime += 0.3
        fixture.feed(angle: 170, frames: 24)
        XCTAssertEqual(fixture.state?.totalRepetitions, 0)
    }

    @MainActor
    func testShortContinuousIntervalsAndIncompleteCyclesRemainSafe() {
        let fixture = ObservationWorkoutFixture()
        defer { fixture.viewModel.finish() }
        fixture.feed(angle: 170, frames: 24)
        for angle in [120.0, 110, 106, 130] {
            fixture.feed(angle: angle, frames: 24)
            fixture.feed(angle: 170, frames: 24)
        }
        XCTAssertEqual(fixture.state?.totalRepetitions, 0)
        fixture.completeRepetition()
        XCTAssertEqual(fixture.state?.totalRepetitions, 1)
    }

    @MainActor
    func testCameraReadinessResetCannotJoinTwoMovementSegments() {
        let fixture = ObservationWorkoutFixture()
        defer { fixture.viewModel.finish() }
        fixture.feed(angle: 170, frames: 24)
        fixture.feed(angle: 97.6, frames: 24)
        fixture.viewModel.setCameraReady(false)
        fixture.viewModel.setCameraReady(true)
        fixture.viewModel.resume()
        fixture.feed(angle: 170, frames: 24)
        XCTAssertEqual(fixture.state?.totalRepetitions, 0)
        fixture.completeRepetition()
        XCTAssertEqual(fixture.state?.totalRepetitions, 1)
    }

    private func standingCounter() -> SquatCounter {
        var counter = SquatCounter()
        for _ in 0..<3 { _ = counter.process(angle: 170) }
        return counter
    }

    private func loweredCounter() -> SquatCounter {
        var counter = standingCounter()
        for _ in 0..<3 { _ = counter.process(angle: 90) }
        return counter
    }
}

@MainActor
private final class ObservationWorkoutFixture {
    let clock = ObservationClock()
    let store = ObservationStore()
    let viewModel: WorkoutViewModel
    var state: WorkoutViewState?

    init() {
        viewModel = WorkoutViewModel(persistence: store, timeSource: clock)
        viewModel.onChange = { [weak self] state in self?.state = state }
    }

    func feed(angle: Double, frames: Int = 1, leftHipConfidence: Float = 1, rightHipConfidence: Float = 1) {
        var pose = SquatPoseFixture.pose(leftAngle: angle, rightAngle: angle)
        pose = SquatPoseFixture.replacing(pose, joint: .leftHip, confidence: leftHipConfidence)
        pose = SquatPoseFixture.replacing(pose, joint: .rightHip, confidence: rightHipConfidence)
        for _ in 0..<frames {
            clock.currentTime += 0.08
            viewModel.process(pose)
        }
    }

    func completeRepetition() {
        feed(angle: 170, frames: 24)
        feed(angle: 97.6, frames: 24)
        feed(angle: 170, frames: 24)
    }
}

@MainActor
private final class ObservationClock: WorkoutTimeSource {
    var currentTime: TimeInterval = 0
    var date: Date { Date(timeIntervalSince1970: 0) }
}

@MainActor
private final class ObservationStore: WorkoutStoring {
    private var summaries: [WorkoutSummary] = []
    func save(_ summary: WorkoutSummary) throws { summaries.append(summary) }
    func history() throws -> [WorkoutSummary] { summaries }
}
