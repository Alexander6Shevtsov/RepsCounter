//
//  WorkoutTimingTests.swift
//  RepsCounter
//
//  Maintainer: Alexander Shevtsov
//  Copyright © 2026 Alexander Shevtsov.

import CoreGraphics
import XCTest
@testable import RepsCounter

final class WorkoutTimingTests: XCTestCase {
    @MainActor
    func testPauseFreezesElapsedTimeAndPreservesFractionalProgress() {
        let fixture = WorkoutTimingFixture()
        defer { fixture.viewModel.finish() }
        fixture.timeSource.advance(by: 1.75)
        fixture.viewModel.refreshTime()
        XCTAssertEqual(fixture.latestState?.elapsedSeconds, 1)

        fixture.viewModel.togglePause()
        fixture.timeSource.advance(by: 100.5)
        fixture.viewModel.refreshTime()
        XCTAssertEqual(fixture.latestState?.elapsedSeconds, 1)
        XCTAssertEqual(fixture.latestState?.isPaused, true)

        fixture.viewModel.togglePause()
        fixture.timeSource.advance(by: 0.5)
        fixture.viewModel.refreshTime()
        XCTAssertEqual(fixture.latestState?.elapsedSeconds, 2)
        XCTAssertEqual(fixture.latestState?.isPaused, false)
    }

    @MainActor
    func testRepeatedFractionalPausesDoNotRoundAwayActiveTime() {
        let fixture = WorkoutTimingFixture()
        defer { fixture.viewModel.finish() }

        for _ in 0..<8 {
            fixture.timeSource.advance(by: 0.25)
            fixture.viewModel.togglePause()
            fixture.timeSource.advance(by: 10)
            fixture.viewModel.togglePause()
        }
        fixture.viewModel.refreshTime()

        XCTAssertEqual(fixture.latestState?.elapsedSeconds, 2)
        XCTAssertEqual(fixture.latestState?.isPaused, false)
    }

    @MainActor
    func testRestCountdownFreezesOnPauseAndDoesNotJumpBackAfterResume() {
        let fixture = WorkoutTimingFixture()
        defer { fixture.viewModel.finish() }
        completeSet(using: fixture)
        XCTAssertEqual(fixture.latestState?.remainingRestSeconds, 60)
        fixture.timeSource.advance(by: 5.25)
        fixture.viewModel.refreshTime()
        XCTAssertEqual(fixture.latestState?.remainingRestSeconds, 55)

        fixture.viewModel.togglePause()
        fixture.timeSource.advance(by: 100.75)
        fixture.viewModel.refreshTime()
        XCTAssertEqual(fixture.latestState?.remainingRestSeconds, 55)
        XCTAssertEqual(fixture.latestState?.isResting, true)
        fixture.viewModel.togglePause()
        fixture.viewModel.refreshTime()
        XCTAssertEqual(fixture.latestState?.remainingRestSeconds, 55)

        fixture.timeSource.advance(by: 0.75)
        fixture.viewModel.refreshTime()
        XCTAssertEqual(fixture.latestState?.remainingRestSeconds, 54)
        fixture.timeSource.advance(by: 0.1)
        fixture.viewModel.refreshTime()
        XCTAssertEqual(fixture.latestState?.remainingRestSeconds, 54)
    }

    @MainActor
    func testRestExpiresAtItsActiveTimeDeadlineAndAdvancesTheSetOnlyOnce() {
        let fixture = WorkoutTimingFixture()
        defer { fixture.viewModel.finish() }
        completeSet(using: fixture)
        fixture.timeSource.advance(by: 59.5)
        fixture.viewModel.refreshTime()
        XCTAssertEqual(fixture.latestState?.currentSet, 1)
        XCTAssertEqual(fixture.latestState?.remainingRestSeconds, 1)
        XCTAssertEqual(fixture.latestState?.isResting, true)

        fixture.timeSource.advance(by: 0.5)
        fixture.viewModel.refreshTime()
        XCTAssertEqual(fixture.latestState?.currentSet, 2)
        XCTAssertEqual(fixture.latestState?.remainingRestSeconds, 0)
        XCTAssertEqual(fixture.latestState?.isResting, false)

        for _ in 0..<10 { fixture.viewModel.refreshTime() }
        fixture.timeSource.advance(by: 120)
        fixture.viewModel.refreshTime()
        XCTAssertEqual(fixture.latestState?.currentSet, 2)
        XCTAssertEqual(fixture.latestState?.isResting, false)
    }

    @MainActor
    func testRestDoesNotExpireWhileTheWorkoutIsPausedPastTheWallDeadline() {
        let fixture = WorkoutTimingFixture()
        defer { fixture.viewModel.finish() }
        completeSet(using: fixture)
        fixture.timeSource.advance(by: 40)
        fixture.viewModel.togglePause()

        fixture.timeSource.advance(by: 100)
        fixture.viewModel.refreshTime()
        fixture.viewModel.togglePause()
        fixture.viewModel.refreshTime()

        XCTAssertEqual(fixture.latestState?.remainingRestSeconds, 20)
        XCTAssertEqual(fixture.latestState?.currentSet, 1)
        XCTAssertEqual(fixture.latestState?.isResting, true)
        fixture.timeSource.advance(by: 20)
        fixture.viewModel.refreshTime()
        XCTAssertEqual(fixture.latestState?.currentSet, 2)
        XCTAssertEqual(fixture.latestState?.isResting, false)
    }

    @MainActor
    func testPausingAfterAnExpiredRestAdvancesTheSetBeforeFreezing() {
        let fixture = WorkoutTimingFixture()
        defer { fixture.viewModel.finish() }
        completeSet(using: fixture)
        fixture.timeSource.advance(by: 61)

        fixture.viewModel.togglePause()

        XCTAssertEqual(fixture.latestState?.currentSet, 2)
        XCTAssertEqual(fixture.latestState?.isResting, false)
        XCTAssertEqual(fixture.latestState?.remainingRestSeconds, 0)
        XCTAssertEqual(fixture.latestState?.elapsedSeconds, 61)
        fixture.timeSource.advance(by: 100)
        fixture.viewModel.togglePause()
        fixture.viewModel.refreshTime()
        XCTAssertEqual(fixture.latestState?.currentSet, 2)
        XCTAssertEqual(fixture.latestState?.elapsedSeconds, 61)
    }

    @MainActor
    func testPauseDiscardsLoweredMovementAndPreservesCountedRepetitions() {
        let fixture = WorkoutTimingFixture()
        defer { fixture.viewModel.finish() }
        processRepetition(using: fixture.viewModel)
        feedPose(isStanding: false, frames: 20, using: fixture.viewModel)
        fixture.viewModel.togglePause()
        fixture.timeSource.advance(by: 100)
        feedPose(isStanding: true, frames: 20, using: fixture.viewModel)
        fixture.viewModel.togglePause()

        feedPose(isStanding: false, frames: 20, using: fixture.viewModel)
        feedPose(isStanding: true, frames: 20, using: fixture.viewModel)
        XCTAssertEqual(fixture.latestState?.repetitions, 1)
        XCTAssertEqual(fixture.latestState?.totalRepetitions, 1)

        processRepetition(using: fixture.viewModel)
        XCTAssertEqual(fixture.latestState?.repetitions, 2)
        XCTAssertEqual(fixture.latestState?.totalRepetitions, 2)
    }

    @MainActor
    func testStandingFramesBeforeAndAfterPauseDoNotFormOneStableSequence() {
        let fixture = WorkoutTimingFixture()
        defer { fixture.viewModel.finish() }
        feedPose(isStanding: true, frames: 2, using: fixture.viewModel)
        fixture.viewModel.togglePause()
        fixture.viewModel.togglePause()

        feedPose(isStanding: true, frames: 1, using: fixture.viewModel)
        feedPose(isStanding: false, frames: 20, using: fixture.viewModel)
        feedPose(isStanding: true, frames: 20, using: fixture.viewModel)
        XCTAssertEqual(fixture.latestState?.totalRepetitions, 0)

        processRepetition(using: fixture.viewModel)
        XCTAssertEqual(fixture.latestState?.totalRepetitions, 1)
    }

    @MainActor
    func testResumeClearsSmoothingBeforeReacquiringThreeStandingFrames() {
        let fixture = WorkoutTimingFixture()
        defer { fixture.viewModel.finish() }
        feedPose(isStanding: true, frames: 20, using: fixture.viewModel)
        feedPose(isStanding: false, frames: 20, using: fixture.viewModel)
        fixture.viewModel.togglePause()
        fixture.viewModel.togglePause()

        feedPose(isStanding: true, frames: 3, using: fixture.viewModel)
        feedPose(isStanding: false, frames: 20, using: fixture.viewModel)
        feedPose(isStanding: true, frames: 20, using: fixture.viewModel)

        XCTAssertEqual(fixture.latestState?.repetitions, 1)
        XCTAssertEqual(fixture.latestState?.totalRepetitions, 1)
    }

    @MainActor
    func testFinishAndRetryKeepTheSameDurationDateAndIdentifierAfterPause() throws {
        let fixture = WorkoutTimingFixture(failureCount: 1)
        let initialDate = fixture.timeSource.date
        fixture.timeSource.advance(by: 10.75)
        fixture.viewModel.togglePause()
        fixture.timeSource.advance(by: 100.5)
        fixture.viewModel.togglePause()
        fixture.timeSource.advance(by: 9.5)

        fixture.viewModel.finish()
        let summary = try XCTUnwrap(fixture.viewModel.finishedSummary)
        XCTAssertEqual(summary.duration, 20)
        XCTAssertEqual(summary.date, initialDate)
        fixture.timeSource.advance(by: 500)
        fixture.viewModel.refreshTime()
        fixture.viewModel.retrySave()

        XCTAssertEqual(fixture.viewModel.finishedSummary, summary)
        XCTAssertEqual(fixture.persistence.attempts, [summary, summary])
        XCTAssertEqual(fixture.latestState?.elapsedSeconds, 20)
        XCTAssertEqual(fixture.latestState?.saveState, .saved)
    }

    @MainActor
    func testFinishWhilePausedExcludesThePauseUntilFinish() throws {
        let fixture = WorkoutTimingFixture()
        fixture.timeSource.advance(by: 7.75)
        fixture.viewModel.togglePause()
        fixture.timeSource.advance(by: 200)

        fixture.viewModel.finish()

        XCTAssertEqual(try XCTUnwrap(fixture.viewModel.finishedSummary).duration, 7)
        XCTAssertEqual(fixture.latestState?.elapsedSeconds, 7)
        XCTAssertEqual(fixture.latestState?.isFinished, true)
    }

    @MainActor
    func testRapidPauseResumeAndFinishDoNotAdvanceTimeOrSaveTwice() throws {
        let fixture = WorkoutTimingFixture()
        for _ in 0..<100 {
            fixture.viewModel.togglePause()
            fixture.viewModel.togglePause()
        }
        fixture.viewModel.finish()
        let summary = try XCTUnwrap(fixture.viewModel.finishedSummary)

        fixture.timeSource.advance(by: 100)
        fixture.viewModel.togglePause()
        fixture.viewModel.refreshTime()
        fixture.viewModel.finish()
        fixture.viewModel.retrySave()

        XCTAssertEqual(summary.duration, 0)
        XCTAssertEqual(fixture.latestState?.elapsedSeconds, 0)
        XCTAssertEqual(fixture.persistence.attempts, [summary])
    }

    @MainActor
    func testWallClockChangesDoNotChangeElapsedDuration() throws {
        let fixture = WorkoutTimingFixture()
        let initialDate = fixture.timeSource.date
        fixture.timeSource.advance(by: 2)
        fixture.timeSource.date = initialDate.addingTimeInterval(-86_400)
        fixture.viewModel.refreshTime()
        XCTAssertEqual(fixture.latestState?.elapsedSeconds, 2)
        fixture.timeSource.advance(by: 3)
        fixture.timeSource.date = initialDate.addingTimeInterval(86_400)

        fixture.viewModel.finish()

        let summary = try XCTUnwrap(fixture.viewModel.finishedSummary)
        XCTAssertEqual(summary.date, initialDate)
        XCTAssertEqual(summary.duration, 5)
    }

    @MainActor
    func testFinishingWithoutRepetitionsSavesZeroSets() throws {
        let fixture = WorkoutTimingFixture()

        fixture.viewModel.finish()

        let summary = try XCTUnwrap(fixture.viewModel.finishedSummary)
        XCTAssertEqual(summary.repetitions, 0)
        XCTAssertEqual(summary.sets, 0)
    }

    @MainActor
    func testFinishingPartialFirstSetSavesOneSet() throws {
        let fixture = WorkoutTimingFixture()
        processRepetition(using: fixture.viewModel)
        processRepetition(using: fixture.viewModel)

        fixture.viewModel.finish()

        let summary = try XCTUnwrap(fixture.viewModel.finishedSummary)
        XCTAssertEqual(summary.repetitions, 2)
        XCTAssertEqual(summary.sets, 1)
    }

    @MainActor
    func testFinishingDuringRestSavesOnlyTheCompletedSet() throws {
        let fixture = WorkoutTimingFixture()
        completeSet(using: fixture)
        XCTAssertEqual(fixture.latestState?.isResting, true)

        fixture.viewModel.finish()

        let summary = try XCTUnwrap(fixture.viewModel.finishedSummary)
        XCTAssertEqual(summary.repetitions, 12)
        XCTAssertEqual(summary.sets, 1)
    }

    @MainActor
    func testFinishingCompletedAndPartialSetsSavesBothSets() throws {
        let fixture = WorkoutTimingFixture()
        completeSet(using: fixture)
        fixture.timeSource.advance(by: 60)
        fixture.viewModel.refreshTime()
        processRepetition(using: fixture.viewModel)

        fixture.viewModel.finish()

        let summary = try XCTUnwrap(fixture.viewModel.finishedSummary)
        XCTAssertEqual(summary.repetitions, 13)
        XCTAssertEqual(summary.sets, 2)
    }

    @MainActor
    func testCompletingFourSetsFinishesAndSavesExactlyFourSets() throws {
        let fixture = WorkoutTimingFixture()

        for setNumber in 1...4 {
            completeSet(using: fixture)
            if setNumber < 4 {
                fixture.timeSource.advance(by: 60)
                fixture.viewModel.refreshTime()
            }
        }

        let summary = try XCTUnwrap(fixture.viewModel.finishedSummary)
        XCTAssertEqual(summary.repetitions, 48)
        XCTAssertEqual(summary.sets, 4)
        XCTAssertEqual(fixture.latestState?.currentSet, 4)
        XCTAssertEqual(fixture.latestState?.isFinished, true)
        XCTAssertEqual(fixture.latestState?.saveState, .saved)
        XCTAssertEqual(fixture.persistence.attempts, [summary])
    }

    @MainActor
    func testUpdateTaskDoesNotRetainAnAbandonedViewModel() {
        let timeSource = MutableWorkoutTimeSource()
        let persistence = WorkoutTimingStore(failureCount: 0)
        var viewModel: WorkoutViewModel? = WorkoutViewModel(persistence: persistence, timeSource: timeSource)
        let releasedViewModel = { [weak viewModel] in viewModel }

        viewModel = nil

        XCTAssertNil(releasedViewModel())
        XCTAssertTrue(persistence.attempts.isEmpty)
    }

    @MainActor
    private func completeSet(using fixture: WorkoutTimingFixture) {
        for _ in 0..<12 { processRepetition(using: fixture.viewModel) }
    }

    @MainActor
    private func processRepetition(using viewModel: WorkoutViewModel) {
        feedPose(isStanding: true, frames: 20, using: viewModel)
        feedPose(isStanding: false, frames: 20, using: viewModel)
        feedPose(isStanding: true, frames: 20, using: viewModel)
    }

    @MainActor
    private func feedPose(isStanding: Bool, frames: Int, using viewModel: WorkoutViewModel) {
        let hipPoint = isStanding ? CGPoint(x: 0.5, y: 0.8) : CGPoint(x: 0.8, y: 0.5)
        let pose = BodyPose(joints: [
            .leftHip: JointPoint(location: hipPoint, confidence: 1),
            .leftKnee: JointPoint(location: CGPoint(x: 0.5, y: 0.5), confidence: 1),
            .leftAnkle: JointPoint(location: CGPoint(x: 0.5, y: 0.2), confidence: 1)
        ], aspectRatio: 1)
        for _ in 0..<frames { viewModel.process(pose) }
    }
}

@MainActor
private final class WorkoutTimingFixture {
    let timeSource = MutableWorkoutTimeSource()
    let persistence: WorkoutTimingStore
    let viewModel: WorkoutViewModel
    private(set) var latestState: WorkoutViewState?

    init(failureCount: Int = 0) {
        persistence = WorkoutTimingStore(failureCount: failureCount)
        viewModel = WorkoutViewModel(persistence: persistence, timeSource: timeSource)
        viewModel.onChange = { [weak self] state in self?.latestState = state }
        viewModel.refreshTime()
    }
}

@MainActor
private final class MutableWorkoutTimeSource: WorkoutTimeSource {
    var currentTime: TimeInterval = 1_000
    var date = Date(timeIntervalSince1970: 1_700_000_000)

    func advance(by interval: TimeInterval) {
        currentTime += interval
        date = date.addingTimeInterval(interval)
    }
}

@MainActor
private final class WorkoutTimingStore: WorkoutStoring {
    private(set) var attempts: [WorkoutSummary] = []
    private var failureCount: Int
    private var summaries: [UUID: WorkoutSummary] = [:]

    init(failureCount: Int) {
        self.failureCount = failureCount
    }

    func save(_ summary: WorkoutSummary) throws {
        attempts.append(summary)
        if failureCount > 0 {
            failureCount -= 1
            throw WorkoutTimingError.unavailable
        }
        summaries[summary.id] = summary
    }

    func history() throws -> [WorkoutSummary] {
        Array(summaries.values)
    }
}

private enum WorkoutTimingError: Error {
    case unavailable
}
