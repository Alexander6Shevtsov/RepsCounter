import CoreGraphics
import XCTest
@testable import RepsCounter

final class WorkoutViewModelTests: XCTestCase {
    @MainActor
    func testFinishSavesOneWorkoutAndPublishesSuccessAfterCommit() throws {
        let persistence = WorkoutStoreMock()
        let viewModel = WorkoutViewModel(persistence: persistence)
        var states: [WorkoutViewState] = []
        var stateDuringSave: WorkoutViewState?
        viewModel.onChange = { states.append($0) }
        persistence.beforeSave = { stateDuringSave = states.last }
        processRepetition(using: viewModel)

        viewModel.finish()

        let summary = try XCTUnwrap(viewModel.finishedSummary)
        XCTAssertEqual(persistence.attempts, [summary])
        XCTAssertEqual(try persistence.history(), [summary])
        XCTAssertEqual(summary.repetitions, 1)
        XCTAssertEqual(summary.sets, 1)
        XCTAssertEqual(stateDuringSave?.saveState, .saving)
        XCTAssertEqual(stateDuringSave?.isFinished, true)
        XCTAssertEqual(states.last?.saveState, .saved)
        XCTAssertEqual(states.suffix(2).map(\.saveState), [.saving, .saved])
    }

    @MainActor
    func testFailedSaveRetainsFinishedSummaryForRetry() throws {
        let persistence = WorkoutStoreMock(failureCount: 1)
        let viewModel = WorkoutViewModel(persistence: persistence)
        var latestState: WorkoutViewState?
        viewModel.onChange = { latestState = $0 }
        processRepetition(using: viewModel)

        viewModel.finish()

        let summary = try XCTUnwrap(viewModel.finishedSummary)
        let state = try XCTUnwrap(latestState)
        XCTAssertEqual(persistence.attempts, [summary])
        XCTAssertTrue(try persistence.history().isEmpty)
        XCTAssertTrue(state.isFinished)
        XCTAssertEqual(summary.repetitions, 1)
        XCTAssertEqual(state.elapsedSeconds, summary.duration)
        guard case .failed(let message) = state.saveState else {
            XCTFail("A failed save must publish a retryable error")
            return
        }
        XCTAssertFalse(message.isEmpty)
    }

    @MainActor
    func testRetrySavesTheExactSummaryRetainedAfterFailure() throws {
        let persistence = WorkoutStoreMock(failureCount: 1)
        let viewModel = WorkoutViewModel(persistence: persistence)
        var states: [WorkoutViewState] = []
        viewModel.onChange = { states.append($0) }
        processRepetition(using: viewModel)
        viewModel.finish()
        let failedSummary = try XCTUnwrap(viewModel.finishedSummary)

        viewModel.retrySave()

        XCTAssertEqual(viewModel.finishedSummary, failedSummary)
        XCTAssertEqual(persistence.attempts, [failedSummary, failedSummary])
        XCTAssertEqual(try persistence.history(), [failedSummary])
        XCTAssertEqual(states.last?.saveState, .saved)
        XCTAssertEqual(states.last?.isFinished, true)
        XCTAssertEqual(states.last?.elapsedSeconds, failedSummary.duration)
        XCTAssertEqual(states.suffix(2).map(\.saveState), [.saving, .saved])
    }

    @MainActor
    func testRepeatedFinishAndRetryAfterSuccessDoNotWriteAgain() throws {
        let persistence = WorkoutStoreMock()
        let viewModel = WorkoutViewModel(persistence: persistence)
        var states: [WorkoutViewState] = []
        viewModel.onChange = { states.append($0) }
        viewModel.finish()
        let summary = try XCTUnwrap(viewModel.finishedSummary)
        let publishedCount = states.count

        for _ in 0..<3 {
            viewModel.finish()
            viewModel.retrySave()
        }

        XCTAssertEqual(persistence.attempts, [summary])
        XCTAssertEqual(try persistence.history(), [summary])
        XCTAssertEqual(viewModel.finishedSummary, summary)
        XCTAssertEqual(states.count, publishedCount)
        XCTAssertEqual(states.last?.saveState, .saved)
    }

    @MainActor
    func testRepeatedFailureWithSameMessageRemainsRetryable() throws {
        let persistence = WorkoutStoreMock(failureCount: 2)
        let viewModel = WorkoutViewModel(persistence: persistence)
        var states: [WorkoutViewState] = []
        viewModel.onChange = { states.append($0) }

        viewModel.finish()
        viewModel.retrySave()
        viewModel.retrySave()

        let summary = try XCTUnwrap(viewModel.finishedSummary)
        let failures = states.compactMap { state -> String? in
            guard case .failed(let message) = state.saveState else { return nil }
            return message
        }
        XCTAssertEqual(failures.count, 2)
        XCTAssertEqual(failures.first, failures.last)
        XCTAssertEqual(persistence.attempts, [summary, summary, summary])
        XCTAssertEqual(try persistence.history(), [summary])
        XCTAssertEqual(states.last?.saveState, .saved)
    }

    @MainActor
    func testFinishedResultDoesNotChangeWhileWaitingForRetry() throws {
        let persistence = WorkoutStoreMock(failureCount: 1)
        let viewModel = WorkoutViewModel(persistence: persistence)
        var latestState: WorkoutViewState?
        viewModel.onChange = { latestState = $0 }
        processRepetition(using: viewModel)
        viewModel.finish()
        let summary = try XCTUnwrap(viewModel.finishedSummary)

        processRepetition(using: viewModel)
        viewModel.process(nil)
        viewModel.togglePause()
        viewModel.finish()

        XCTAssertEqual(viewModel.finishedSummary, summary)
        XCTAssertEqual(viewModel.elapsedSeconds, summary.duration)
        XCTAssertEqual(persistence.attempts, [summary])
        XCTAssertEqual(latestState?.totalRepetitions, summary.repetitions)
        XCTAssertEqual(latestState?.isPaused, false)
        XCTAssertEqual(latestState?.isFinished, true)

        viewModel.retrySave()

        XCTAssertEqual(persistence.attempts, [summary, summary])
        XCTAssertEqual(latestState?.saveState, .saved)
    }

    @MainActor
    func testRetryBeforeFinishingDoesNotSaveAnActiveWorkout() {
        let persistence = WorkoutStoreMock()
        let viewModel = WorkoutViewModel(persistence: persistence)

        viewModel.retrySave()

        XCTAssertTrue(persistence.attempts.isEmpty)
        XCTAssertNil(viewModel.finishedSummary)
        viewModel.finish()
    }

    @MainActor
    func testRetryPreservesIdentityAfterAmbiguousStoreFailure() throws {
        let persistence = WorkoutStoreMock(failureCount: 1, commitBeforeFailure: true)
        let viewModel = WorkoutViewModel(persistence: persistence)
        var latestState: WorkoutViewState?
        viewModel.onChange = { latestState = $0 }
        processRepetition(using: viewModel)

        viewModel.finish()
        let summary = try XCTUnwrap(viewModel.finishedSummary)
        XCTAssertEqual(try persistence.history(), [summary])
        viewModel.retrySave()

        XCTAssertEqual(persistence.attempts, [summary, summary])
        XCTAssertEqual(try persistence.history(), [summary])
        XCTAssertEqual(viewModel.finishedSummary?.id, summary.id)
        XCTAssertEqual(latestState?.saveState, .saved)
    }

    @MainActor
    private func processRepetition(using viewModel: WorkoutViewModel) {
        for _ in 0..<20 { viewModel.process(pose(isStanding: true)) }
        for _ in 0..<20 { viewModel.process(pose(isStanding: false)) }
        for _ in 0..<20 { viewModel.process(pose(isStanding: true)) }
    }

    private func pose(isStanding: Bool) -> BodyPose {
        let hipPoint = isStanding ? CGPoint(x: 0.5, y: 0.8) : CGPoint(x: 0.8, y: 0.5)
        return BodyPose(joints: [
            .leftHip: JointPoint(location: hipPoint, confidence: 1),
            .leftKnee: JointPoint(location: CGPoint(x: 0.5, y: 0.5), confidence: 1),
            .leftAnkle: JointPoint(location: CGPoint(x: 0.5, y: 0.2), confidence: 1)
        ], aspectRatio: 1)
    }
}

@MainActor
private final class WorkoutStoreMock: WorkoutStoring {
    var beforeSave: (() -> Void)?
    private(set) var attempts: [WorkoutSummary] = []

    private var failureCount: Int
    private let commitBeforeFailure: Bool
    private var savedSummaries: [UUID: WorkoutSummary] = [:]

    init(failureCount: Int = 0, commitBeforeFailure: Bool = false) {
        self.failureCount = failureCount
        self.commitBeforeFailure = commitBeforeFailure
    }

    func save(_ summary: WorkoutSummary) throws {
        attempts.append(summary)
        beforeSave?()
        if failureCount > 0 {
            failureCount -= 1
            if commitBeforeFailure { savedSummaries[summary.id] = summary }
            throw WorkoutStoreMockError.unavailable
        }
        savedSummaries[summary.id] = summary
    }

    func history() throws -> [WorkoutSummary] {
        savedSummaries.values.sorted { $0.date > $1.date }
    }
}

private enum WorkoutStoreMockError: LocalizedError {
    case unavailable

    var errorDescription: String? {
        "Test workout store is unavailable"
    }
}
