import XCTest
@testable import RepsCounter

#if DEBUG
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
#endif
