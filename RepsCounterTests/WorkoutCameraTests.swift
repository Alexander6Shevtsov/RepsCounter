import CoreGraphics
import XCTest
import UIKit
@testable import RepsCounter

final class WorkoutCameraTests: XCTestCase {
    @MainActor
    func testActiveTimeWaitsForCameraReadiness() async {
        let fixture = WorkoutCameraFixture(authorization: .notDetermined)
        fixture.coordinator.startInitially()
        await fixture.cameraFixture.permission.waitForRequest()
        fixture.clock.advance(by: 120)
        XCTAssertEqual(fixture.viewModel.elapsedSeconds, 0)
        XCTAssertTrue(fixture.viewModel.isPaused)
        fixture.cameraFixture.permission.resolve(granted: true)
        await fixture.cameraFixture.camera.start().value
        fixture.clock.advance(by: 5.5)
        fixture.viewModel.refreshTime()
        XCTAssertEqual(fixture.state?.elapsedSeconds, 5)
        XCTAssertEqual(fixture.state?.isPaused, false)
        fixture.coordinator.finish()
    }

    @MainActor
    func testFinishBeforePermissionResponsePreventsLateCameraStart() async {
        let fixture = WorkoutCameraFixture(authorization: .notDetermined)
        fixture.coordinator.startInitially()
        let operation = fixture.cameraFixture.camera.start()
        await fixture.cameraFixture.permission.waitForRequest()
        fixture.clock.advance(by: 100)
        fixture.coordinator.finish()
        fixture.cameraFixture.permission.resolve(granted: true)
        await operation.value
        let snapshot = await fixture.cameraFixture.capture.snapshot()
        XCTAssertTrue(snapshot.starts.isEmpty)
        XCTAssertEqual(fixture.cameraFixture.camera.state, .finished)
        XCTAssertEqual(fixture.viewModel.finishedSummary?.duration, 0)
        XCTAssertEqual(fixture.state?.saveState, .saved)
    }

    @MainActor
    func testBackgroundFreezesTimeAndForegroundRequiresUserResume() async {
        let fixture = WorkoutCameraFixture()
        await fixture.start()
        fixture.clock.advance(by: 7.75)
        fixture.coordinator.sceneDidEnterBackground()
        fixture.clock.advance(by: 100)
        fixture.coordinator.sceneDidBecomeActive()
        XCTAssertEqual(fixture.viewModel.elapsedSeconds, 7)
        XCTAssertTrue(fixture.viewModel.isPaused)
        XCTAssertEqual(fixture.cameraFixture.camera.state, .stopped)
        fixture.coordinator.togglePause()
        await fixture.cameraFixture.camera.start().value
        fixture.clock.advance(by: 0.5)
        fixture.viewModel.refreshTime()
        XCTAssertEqual(fixture.state?.elapsedSeconds, 8)
        XCTAssertEqual(fixture.state?.isPaused, false)
        fixture.coordinator.finish()
    }

    @MainActor
    func testBackgroundDuringPermissionPreventsAutomaticStartAfterGrant() async {
        let fixture = WorkoutCameraFixture(authorization: .notDetermined)
        fixture.coordinator.startInitially()
        let operation = fixture.cameraFixture.camera.start()
        await fixture.cameraFixture.permission.waitForRequest()
        fixture.coordinator.sceneDidEnterBackground()
        fixture.cameraFixture.permission.resolve(granted: true)
        await operation.value
        fixture.coordinator.sceneDidBecomeActive()
        let snapshot = await fixture.cameraFixture.capture.snapshot()
        XCTAssertTrue(snapshot.starts.isEmpty)
        XCTAssertTrue(fixture.viewModel.isPaused)
        XCTAssertEqual(fixture.viewModel.elapsedSeconds, 0)
        fixture.coordinator.finish()
    }

    @MainActor
    func testSettingsPermissionChangeDoesNotAutomaticallyResumeWorkout() async {
        let fixture = WorkoutCameraFixture(authorization: .denied)
        await fixture.start()
        fixture.coordinator.sceneDidEnterBackground()
        fixture.cameraFixture.permission.status = .authorized
        fixture.coordinator.sceneDidBecomeActive()
        XCTAssertTrue(fixture.viewModel.isPaused)
        XCTAssertEqual(fixture.viewModel.elapsedSeconds, 0)
        fixture.coordinator.togglePause()
        await fixture.cameraFixture.camera.start().value
        XCTAssertFalse(fixture.viewModel.isPaused)
        fixture.coordinator.finish()
    }

    @MainActor
    func testInterruptionPreservesRepetitionsAndResetsUnfinishedMovement() async {
        let fixture = WorkoutCameraFixture()
        await fixture.start()
        fixture.completeRepetition()
        fixture.feed(isStanding: false)
        fixture.clock.advance(by: 8)
        fixture.cameraFixture.camera.receive(.interrupted)
        XCTAssertTrue(fixture.viewModel.isPaused)
        XCTAssertEqual(fixture.state?.totalRepetitions, 1)
        fixture.clock.advance(by: 100)
        fixture.cameraFixture.camera.receive(.interruptionEnded)
        XCTAssertTrue(fixture.viewModel.isPaused)
        XCTAssertEqual(fixture.viewModel.elapsedSeconds, 8)
        fixture.coordinator.togglePause()
        await fixture.cameraFixture.camera.start().value
        fixture.feed(isStanding: true)
        XCTAssertEqual(fixture.state?.totalRepetitions, 1)
        fixture.completeRepetition()
        XCTAssertEqual(fixture.state?.totalRepetitions, 2)
        fixture.coordinator.finish()
        XCTAssertEqual(fixture.viewModel.finishedSummary?.repetitions, 2)
        XCTAssertEqual(fixture.viewModel.finishedSummary?.sets, 1)
    }

    @MainActor
    func testRuntimeErrorFreezesWorkoutUntilExplicitSuccessfulRetry() async {
        let fixture = WorkoutCameraFixture()
        await fixture.start()
        fixture.clock.advance(by: 4)
        fixture.cameraFixture.camera.receive(.runtimeError("Controlled failure"))
        fixture.clock.advance(by: 30)
        XCTAssertTrue(fixture.viewModel.isPaused)
        XCTAssertEqual(fixture.viewModel.elapsedSeconds, 4)
        fixture.coordinator.togglePause()
        await fixture.cameraFixture.camera.start().value
        fixture.clock.advance(by: 2)
        XCTAssertEqual(fixture.viewModel.elapsedSeconds, 6)
        fixture.coordinator.finish()
    }

    @MainActor
    func testRestFreezesAcrossBackgroundAndCameraRestart() async {
        let fixture = WorkoutCameraFixture()
        await fixture.start()
        for _ in 0..<12 { fixture.completeRepetition() }
        fixture.clock.advance(by: 10)
        fixture.viewModel.refreshTime()
        XCTAssertEqual(fixture.state?.remainingRestSeconds, 50)
        fixture.coordinator.sceneDidEnterBackground()
        fixture.clock.advance(by: 100)
        fixture.coordinator.sceneDidBecomeActive()
        fixture.coordinator.togglePause()
        await fixture.cameraFixture.camera.start().value
        XCTAssertEqual(fixture.state?.remainingRestSeconds, 50)
        XCTAssertEqual(fixture.state?.totalRepetitions, 12)
        fixture.clock.advance(by: 5)
        fixture.viewModel.refreshTime()
        XCTAssertEqual(fixture.state?.remainingRestSeconds, 45)
        fixture.coordinator.finish()
    }

    @MainActor
    func testLatePoseFromPreviousCaptureCannotCompleteMovement() async {
        let fixture = WorkoutCameraFixture()
        await fixture.start()
        fixture.feed(isStanding: true)
        fixture.feed(isStanding: false)
        await fixture.cameraFixture.camera.stop().value
        fixture.coordinator.togglePause()
        await fixture.cameraFixture.camera.start().value
        fixture.feed(isStanding: true, generation: 1)
        XCTAssertEqual(fixture.state?.totalRepetitions, 0)
        fixture.feed(isStanding: true)
        fixture.completeRepetition()
        XCTAssertEqual(fixture.state?.totalRepetitions, 1)
        fixture.coordinator.finish()
    }

    @MainActor
    func testRapidPauseResumeFinishPreservesFrozenRetrySummary() async {
        let fixture = WorkoutCameraFixture()
        await fixture.start()
        fixture.completeRepetition()
        fixture.clock.advance(by: 5.75)
        fixture.coordinator.togglePause()
        fixture.coordinator.togglePause()
        let pendingStart = fixture.cameraFixture.camera.start()
        fixture.store.shouldFail = true
        fixture.coordinator.finish()
        await pendingStart.value
        let summary = fixture.viewModel.finishedSummary
        fixture.clock.advance(by: 100)
        fixture.store.shouldFail = false
        fixture.viewModel.retrySave()
        XCTAssertEqual(fixture.viewModel.finishedSummary, summary)
        XCTAssertEqual(summary?.duration, 5)
        XCTAssertEqual(summary?.repetitions, 1)
        XCTAssertEqual(fixture.store.attempts, [summary, summary].compactMap { $0 })
        XCTAssertEqual(fixture.state?.saveState, .saved)
        XCTAssertEqual(fixture.cameraFixture.camera.state, .finished)
    }

    @MainActor
    func testCameraFailureShowsRussianMessageAndEnablesExplicitRetry() async throws {
        let fixture = CameraFixture()
        let store = CameraWorkoutStore()
        let viewModel = WorkoutViewModel(persistence: store, cameraReady: false)
        let controller = WorkoutViewController(viewModel: viewModel, camera: fixture.camera, persistence: store)
        controller.loadViewIfNeeded()
        controller.cameraCoordinator.startInitially()
        await fixture.camera.start().value
        let nativeMessage = "English runtime failure"
        fixture.camera.receive(.runtimeError(nativeMessage))
        let subviews = allSubviews(including: controller.view)
        let visibleLabels = subviews.compactMap { $0 as? UILabel }.filter { !$0.isHidden }
        XCTAssertFalse(visibleLabels.contains { $0.text?.contains(nativeMessage) == true })
        XCTAssertTrue(visibleLabels.contains { $0.text?.contains("Камера временно недоступна") == true })
        let resumeButton = try XCTUnwrap(subviews.compactMap { $0 as? UIButton }.first { $0.currentTitle == "Продолжить" })
        XCTAssertTrue(resumeButton.isEnabled)
        XCTAssertTrue(viewModel.isPaused)
        controller.cameraCoordinator.disconnect()
        await fixture.camera.finish().value
    }

    @MainActor
    private func allSubviews(including rootView: UIView) -> [UIView] {
        [rootView] + rootView.subviews.flatMap { allSubviews(including: $0) }
    }

    @MainActor
    func testDisconnectCancelsCaptureAndReleasesCoordinatorAndModel() async {
        let cameraFixture = CameraFixture()
        let clock = CameraWorkoutClock()
        let store = CameraWorkoutStore()
        var viewModel: WorkoutViewModel? = WorkoutViewModel(persistence: store, timeSource: clock, cameraReady: false)
        let releasedModel = { [weak viewModel] in viewModel }
        var coordinator = viewModel.map { WorkoutCameraCoordinator(viewModel: $0, camera: cameraFixture.camera) }
        let releasedCoordinator = { [weak coordinator] in coordinator }
        coordinator?.startInitially()
        await cameraFixture.camera.start().value
        clock.advance(by: 3)
        coordinator?.disconnect()
        XCTAssertEqual(viewModel?.isPaused, true)
        XCTAssertEqual(viewModel?.elapsedSeconds, 3)
        await cameraFixture.capture.waitForShutdown()
        coordinator = nil
        viewModel = nil
        XCTAssertNil(releasedCoordinator())
        XCTAssertNil(releasedModel())
        XCTAssertTrue(store.attempts.isEmpty)
    }
}

@MainActor
private final class WorkoutCameraFixture {
    let cameraFixture: CameraFixture
    let clock = CameraWorkoutClock()
    let store = CameraWorkoutStore()
    let viewModel: WorkoutViewModel
    let coordinator: WorkoutCameraCoordinator
    private(set) var state: WorkoutViewState?
    private var frameIndex = 0

    init(authorization: CameraAuthorization = .authorized) {
        cameraFixture = CameraFixture(authorization: authorization)
        viewModel = WorkoutViewModel(persistence: store, timeSource: clock, cameraReady: false)
        coordinator = WorkoutCameraCoordinator(viewModel: viewModel, camera: cameraFixture.camera)
        viewModel.onChange = { [weak self] state in self?.state = state }
    }

    func start() async {
        coordinator.startInitially()
        await cameraFixture.camera.start().value
    }

    func completeRepetition() {
        feed(isStanding: true)
        feed(isStanding: false)
        feed(isStanding: true)
    }

    func feed(isStanding: Bool, generation: UInt64? = nil) {
        let hipPoint = isStanding ? CGPoint(x: 0.5, y: 0.8) : CGPoint(x: 0.8, y: 0.5)
        let pose = BodyPose(joints: [
            .leftHip: JointPoint(location: hipPoint, confidence: 1),
            .leftKnee: JointPoint(location: CGPoint(x: 0.5, y: 0.5), confidence: 1),
            .leftAnkle: JointPoint(location: CGPoint(x: 0.5, y: 0.2), confidence: 1)
        ], aspectRatio: 1)
        for _ in 0..<20 {
            frameIndex += 1
            let capturedAt = cameraFixture.currentFrameTime.advanced(by: .nanoseconds(Int64(frameIndex) - 200_000_000))
            cameraFixture.camera.receive(CameraFrame(
                generation: generation ?? cameraFixture.capture.currentGeneration,
                pose: pose, capturedAt: capturedAt
            ))
        }
    }

}

@MainActor
private final class CameraWorkoutClock: WorkoutTimeSource {
    var currentTime: TimeInterval = 1_000
    var date = Date(timeIntervalSince1970: 1_700_000_000)

    func advance(by interval: TimeInterval) { currentTime += interval }
}

@MainActor
private final class CameraWorkoutStore: WorkoutStoring {
    var shouldFail = false
    private(set) var attempts: [WorkoutSummary] = []
    private var summaries: [UUID: WorkoutSummary] = [:]

    func save(_ summary: WorkoutSummary) throws {
        attempts.append(summary)
        if shouldFail { throw CameraService.CameraError.cameraUnavailable }
        summaries[summary.id] = summary
    }

    func history() throws -> [WorkoutSummary] { Array(summaries.values) }
}
