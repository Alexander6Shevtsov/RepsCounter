//
//  CameraSwitchingTests.swift
//  RepsCounter
//
//  Maintainer: Alexander Shevtsov
//  Copyright © 2026 Alexander Shevtsov.

import CoreGraphics
import XCTest
import UIKit
@testable import RepsCounter

final class CameraSwitchingTests: XCTestCase {
    @MainActor
    func testInitialStartSelectsFrontCamera() async {
        let fixture = CameraFixture()
        await fixture.camera.start().value
        let snapshot = await fixture.capture.snapshot()
        XCTAssertEqual(fixture.camera.position, .front)
        XCTAssertEqual(snapshot.positions, [.front])
        XCTAssertEqual(snapshot.position, .front)
        await fixture.camera.finish().value
    }

    @MainActor
    func testSwitchesFrontToBackAndReturnsToFront() async {
        let fixture = CameraFixture()
        await fixture.camera.start().value
        await fixture.camera.switchCamera().value
        XCTAssertEqual(fixture.camera.position, .back)
        XCTAssertEqual(fixture.camera.state, .running)
        await fixture.camera.switchCamera().value
        let snapshot = await fixture.capture.snapshot()
        XCTAssertEqual(fixture.camera.position, .front)
        XCTAssertEqual(snapshot.positions, [.front, .back, .front])
        XCTAssertEqual(snapshot.position, .front)
        XCTAssertTrue(snapshot.isRunning)
        await fixture.camera.finish().value
    }

    @MainActor
    func testSwitchCommitsPerCameraRotationAndRejectsMismatchedFrames() async {
        let fixture = CameraFixture()
        await fixture.capture.setRotationAngle(0, for: .front)
        await fixture.capture.setRotationAngle(90, for: .back)
        let camera = fixture.camera
        var observedRotations: [CGFloat] = []
        var receivedRotations: [CGFloat] = []
        camera.onStateChange = { [weak camera] state in
            guard state == .running, let camera else { return }
            observedRotations.append(camera.rotationAngle)
        }
        camera.onPose = { pose in
            if let pose { receivedRotations.append(pose.rotationAngle) }
        }
        await camera.start().value
        XCTAssertFalse(observedRotations.isEmpty)
        XCTAssertTrue(observedRotations.allSatisfy { $0 == 0 })
        XCTAssertEqual(camera.rotationAngle, 0)
        let generation = fixture.capture.currentGeneration
        camera.receive(CameraFrame(
            generation: generation, pose: BodyPose(joints: [:], aspectRatio: 1, rotationAngle: 90),
            capturedAt: fixture.currentFrameTime.advanced(by: .milliseconds(-100)),
            position: .front, rotationAngle: 90
        ))
        camera.receive(CameraFrame(
            generation: generation, pose: BodyPose(joints: [:], aspectRatio: 1, rotationAngle: 0),
            capturedAt: fixture.currentFrameTime.advanced(by: .milliseconds(-50)),
            position: .front, rotationAngle: 0
        ))
        XCTAssertEqual(receivedRotations, [0])
        observedRotations.removeAll()
        await camera.switchCamera().value
        XCTAssertEqual(camera.position, .back)
        XCTAssertEqual(camera.rotationAngle, 90)
        XCTAssertFalse(observedRotations.isEmpty)
        XCTAssertTrue(observedRotations.allSatisfy { $0 == 90 })
        observedRotations.removeAll()
        await camera.switchCamera().value
        XCTAssertEqual(camera.position, .front)
        XCTAssertEqual(camera.rotationAngle, 0)
        XCTAssertFalse(observedRotations.isEmpty)
        XCTAssertTrue(observedRotations.allSatisfy { $0 == 0 })
        let snapshot = await fixture.capture.snapshot()
        XCTAssertEqual(snapshot.positions, [.front, .back, .front])
        XCTAssertEqual(snapshot.rotationAngle, 0)
        await camera.finish().value
    }

    @MainActor
    func testPermissionRevocationBeforeSwitchStopsCaptureAndPreservesWorkout() async {
        let fixture = SwitchingWorkoutFixture()
        await fixture.start()
        fixture.completeRepetition()
        fixture.clock.advance(seconds: 6.75)
        fixture.cameraFixture.permission.status = .denied
        await fixture.switchCamera()
        let denied = await fixture.cameraFixture.capture.snapshot()
        XCTAssertEqual(fixture.cameraFixture.camera.state, .permissionDenied)
        XCTAssertEqual(fixture.cameraFixture.camera.position, .front)
        XCTAssertEqual(denied.positions, [.front])
        XCTAssertFalse(denied.isRunning)
        XCTAssertTrue(fixture.viewModel.isPaused)
        XCTAssertEqual(fixture.state?.totalRepetitions, 1)
        fixture.clock.advance(seconds: 90)
        XCTAssertEqual(fixture.viewModel.elapsedSeconds, 6)
        fixture.cameraFixture.permission.status = .authorized
        fixture.coordinator.sceneDidBecomeActive()
        XCTAssertTrue(fixture.viewModel.isPaused)
        fixture.coordinator.togglePause()
        await fixture.cameraFixture.camera.start().value
        XCTAssertEqual(fixture.cameraFixture.camera.position, .front)
        XCTAssertFalse(fixture.viewModel.isPaused)
        fixture.clock.advance(seconds: 0.25)
        XCTAssertEqual(fixture.viewModel.elapsedSeconds, 7)
        await fixture.close()
    }

    @MainActor
    func testSwitchPreservesRepetitionsAndFractionalActiveTimeUntilReady() async {
        let fixture = SwitchingWorkoutFixture()
        await fixture.start()
        for _ in 0..<3 { fixture.completeRepetition() }
        fixture.clock.advance(seconds: 4.75)
        fixture.viewModel.refreshTime()
        await fixture.cameraFixture.capture.suspendNextStart()
        let operation = fixture.beginSwitch()
        await fixture.cameraFixture.capture.waitForStart()
        XCTAssertEqual(fixture.cameraFixture.camera.state, .switching)
        XCTAssertTrue(fixture.viewModel.isPaused)
        XCTAssertEqual(fixture.state?.repetitions, 3)
        XCTAssertEqual(fixture.state?.totalRepetitions, 3)
        XCTAssertEqual(fixture.state?.currentSet, 1)
        fixture.clock.advance(seconds: 200)
        XCTAssertEqual(fixture.viewModel.elapsedSeconds, 4)
        await fixture.cameraFixture.capture.releaseStart()
        await operation.value
        XCTAssertFalse(fixture.viewModel.isPaused)
        fixture.clock.advance(seconds: 0.25)
        fixture.viewModel.refreshTime()
        XCTAssertEqual(fixture.state?.elapsedSeconds, 5)
        XCTAssertEqual(fixture.state?.totalRepetitions, 3)
        XCTAssertEqual(fixture.cameraFixture.camera.position, .back)
        await fixture.close()
    }

    @MainActor
    func testSwitchDropsUnfinishedSquatAndRequiresNewStandingConfirmation() async {
        let fixture = SwitchingWorkoutFixture()
        await fixture.start()
        fixture.completeRepetition()
        fixture.feed(isStanding: false)
        await fixture.switchCamera()
        fixture.feed(isStanding: true)
        XCTAssertEqual(fixture.state?.totalRepetitions, 1)
        fixture.completeRepetition()
        XCTAssertEqual(fixture.state?.totalRepetitions, 2)
        fixture.feed(isStanding: true)
        XCTAssertEqual(fixture.state?.totalRepetitions, 2)
        await fixture.close()
    }

    @MainActor
    func testSwitchPreservesRestAndCurrentSet() async {
        let fixture = SwitchingWorkoutFixture()
        await fixture.start()
        for _ in 0..<12 { fixture.completeRepetition() }
        fixture.clock.advance(seconds: 10)
        fixture.viewModel.refreshTime()
        XCTAssertEqual(fixture.state?.remainingRestSeconds, 50)
        await fixture.cameraFixture.capture.suspendNextStart()
        let operation = fixture.beginSwitch()
        await fixture.cameraFixture.capture.waitForStart()
        fixture.clock.advance(seconds: 120)
        XCTAssertEqual(fixture.state?.remainingRestSeconds, 50)
        await fixture.cameraFixture.capture.releaseStart()
        await operation.value
        XCTAssertEqual(fixture.state?.remainingRestSeconds, 50)
        XCTAssertEqual(fixture.state?.currentSet, 1)
        XCTAssertEqual(fixture.state?.totalRepetitions, 12)
        fixture.clock.advance(seconds: 50)
        fixture.viewModel.refreshTime()
        XCTAssertEqual(fixture.state?.currentSet, 2)
        fixture.completeRepetition()
        await fixture.switchCamera()
        XCTAssertEqual(fixture.state?.currentSet, 2)
        XCTAssertEqual(fixture.state?.repetitions, 1)
        XCTAssertEqual(fixture.state?.totalRepetitions, 13)
        fixture.coordinator.finish()
        XCTAssertEqual(fixture.viewModel.finishedSummary?.sets, 2)
        XCTAssertEqual(fixture.viewModel.finishedSummary?.repetitions, 13)
        await fixture.close()
    }

    @MainActor
    func testPreviousCameraAndWrongPositionFramesCannotReachWorkout() async {
        let fixture = SwitchingWorkoutFixture()
        await fixture.start()
        fixture.feed(isStanding: true)
        fixture.feed(isStanding: false)
        let previousGeneration = fixture.cameraFixture.capture.currentGeneration
        await fixture.switchCamera()
        fixture.feed(isStanding: true, generation: previousGeneration, position: .front)
        fixture.feed(isStanding: false, position: .front)
        fixture.feed(isStanding: true, position: .front)
        XCTAssertEqual(fixture.state?.totalRepetitions, 0)
        fixture.feed(isStanding: true)
        XCTAssertEqual(fixture.state?.totalRepetitions, 0)
        fixture.completeRepetition()
        XCTAssertEqual(fixture.state?.totalRepetitions, 1)
        await fixture.close()
    }

    @MainActor
    func testServiceRejectsWrongCameraEvenWhenGenerationMatches() async {
        let fixture = CameraFixture()
        var receivedPoses = 0
        fixture.camera.onPose = { pose in
            if pose != nil { receivedPoses += 1 }
        }
        await fixture.camera.start().value
        await fixture.camera.switchCamera().value
        let currentGeneration = fixture.capture.currentGeneration
        let pose = BodyPose(joints: [:], aspectRatio: 1)
        fixture.camera.receive(CameraFrame(
            generation: currentGeneration, pose: pose,
            capturedAt: fixture.currentFrameTime.advanced(by: .milliseconds(-100)), position: .front
        ))
        fixture.camera.receive(CameraFrame(
            generation: currentGeneration, pose: pose,
            capturedAt: fixture.currentFrameTime.advanced(by: .milliseconds(-50)), position: .back
        ))
        XCTAssertEqual(receivedPoses, 1)
        await fixture.camera.finish().value
    }

    @MainActor
    func testRapidRepeatedSwitchesDoNotQueueAdditionalStartsOrLoseResumeIntent() async {
        let fixture = SwitchingWorkoutFixture()
        await fixture.start()
        await fixture.cameraFixture.capture.suspendNextStart()
        let operation = fixture.beginSwitch()
        await fixture.cameraFixture.capture.waitForStart()
        XCTAssertFalse(fixture.coordinator.canSwitchCamera)
        for _ in 0..<20 { fixture.coordinator.switchCamera() }
        let whileSwitching = await fixture.cameraFixture.capture.snapshot()
        XCTAssertEqual(whileSwitching.positions, [.front, .back])
        await fixture.cameraFixture.capture.releaseStart()
        await operation.value
        let snapshot = await fixture.cameraFixture.capture.snapshot()
        XCTAssertEqual(snapshot.positions, [.front, .back])
        XCTAssertEqual(fixture.cameraFixture.camera.position, .back)
        XCTAssertFalse(fixture.viewModel.isPaused)
        XCTAssertTrue(fixture.coordinator.canSwitchCamera)
        await fixture.close()
    }

    @MainActor
    func testSwitchWhileInitialStartIsPendingIsIgnored() async {
        let fixture = SwitchingWorkoutFixture()
        await fixture.cameraFixture.capture.suspendNextStart()
        fixture.coordinator.startInitially()
        let operation = fixture.cameraFixture.camera.start()
        await fixture.cameraFixture.capture.waitForStart()
        XCTAssertFalse(fixture.coordinator.canSwitchCamera)
        fixture.coordinator.switchCamera()
        await fixture.cameraFixture.capture.releaseStart()
        await operation.value
        let snapshot = await fixture.cameraFixture.capture.snapshot()
        XCTAssertEqual(snapshot.positions, [.front])
        XCTAssertEqual(fixture.cameraFixture.camera.position, .front)
        XCTAssertFalse(fixture.viewModel.isPaused)
        await fixture.close()
    }

    @MainActor
    func testSwitchOnUserPauseKeepsWorkoutPausedAfterCameraIsReady() async {
        let fixture = SwitchingWorkoutFixture()
        await fixture.start()
        fixture.completeRepetition()
        fixture.clock.advance(seconds: 3.5)
        fixture.coordinator.togglePause()
        XCTAssertTrue(fixture.viewModel.isPaused)
        await fixture.switchCamera()
        fixture.clock.advance(seconds: 90)
        XCTAssertEqual(fixture.cameraFixture.camera.position, .back)
        XCTAssertEqual(fixture.cameraFixture.camera.state, .running)
        XCTAssertTrue(fixture.viewModel.isPaused)
        XCTAssertEqual(fixture.viewModel.elapsedSeconds, 3)
        fixture.feed(isStanding: true)
        fixture.completeRepetition()
        XCTAssertEqual(fixture.state?.totalRepetitions, 1)
        fixture.coordinator.togglePause()
        XCTAssertFalse(fixture.viewModel.isPaused)
        fixture.clock.advance(seconds: 0.5)
        XCTAssertEqual(fixture.viewModel.elapsedSeconds, 4)
        await fixture.close()
    }

    @MainActor
    func testFailedSwitchKeepsCommittedPositionAndRequiresExplicitRetry() async {
        let fixture = SwitchingWorkoutFixture()
        await fixture.start()
        fixture.completeRepetition()
        fixture.clock.advance(seconds: 6)
        await fixture.cameraFixture.capture.failNextStart()
        await fixture.switchCamera()
        guard case .failed = fixture.cameraFixture.camera.state else {
            XCTFail("Expected a failed switch")
            await fixture.close()
            return
        }
        XCTAssertEqual(fixture.cameraFixture.camera.position, .front)
        XCTAssertTrue(fixture.viewModel.isPaused)
        XCTAssertEqual(fixture.state?.totalRepetitions, 1)
        fixture.clock.advance(seconds: 100)
        XCTAssertEqual(fixture.viewModel.elapsedSeconds, 6)
        fixture.coordinator.togglePause()
        await fixture.cameraFixture.camera.start().value
        XCTAssertEqual(fixture.cameraFixture.camera.position, .front)
        XCTAssertFalse(fixture.viewModel.isPaused)
        let snapshot = await fixture.cameraFixture.capture.snapshot()
        XCTAssertEqual(snapshot.positions, [.front, .back, .front])
        await fixture.close()
    }

    @MainActor
    func testUnavailableOppositeCameraCanBeRetriedWithoutChangingSelectedPosition() async {
        let fixture = CameraFixture()
        await fixture.camera.start().value
        await fixture.capture.failNextStart()
        await fixture.camera.switchCamera().value
        XCTAssertEqual(fixture.camera.position, .front)
        await fixture.camera.switchCamera().value
        let snapshot = await fixture.capture.snapshot()
        XCTAssertEqual(snapshot.positions, [.front, .back, .back])
        XCTAssertEqual(fixture.camera.position, .back)
        XCTAssertEqual(fixture.camera.state, .running)
        await fixture.camera.finish().value
    }

    @MainActor
    func testBackgroundDuringSwitchCancelsLateResumeAndKeepsOriginalSelection() async {
        let fixture = SwitchingWorkoutFixture()
        await fixture.start()
        fixture.completeRepetition()
        fixture.clock.advance(seconds: 8)
        await fixture.cameraFixture.capture.suspendNextStart()
        let operation = fixture.beginSwitch()
        await fixture.cameraFixture.capture.waitForStart()
        fixture.coordinator.sceneDidEnterBackground()
        fixture.clock.advance(seconds: 100)
        await fixture.cameraFixture.capture.releaseStart()
        await operation.value
        fixture.coordinator.sceneDidBecomeActive()
        XCTAssertEqual(fixture.cameraFixture.camera.state, .stopped)
        XCTAssertEqual(fixture.cameraFixture.camera.position, .front)
        XCTAssertTrue(fixture.viewModel.isPaused)
        XCTAssertEqual(fixture.viewModel.elapsedSeconds, 8)
        XCTAssertEqual(fixture.state?.totalRepetitions, 1)
        fixture.coordinator.togglePause()
        await fixture.cameraFixture.camera.start().value
        XCTAssertFalse(fixture.viewModel.isPaused)
        XCTAssertEqual(fixture.cameraFixture.camera.position, .front)
        await fixture.close()
    }

    @MainActor
    func testForegroundDoesNotResumeOrResetSuccessfullySelectedBackCamera() async {
        let fixture = SwitchingWorkoutFixture()
        await fixture.start()
        await fixture.switchCamera()
        fixture.clock.advance(seconds: 2.5)
        fixture.coordinator.sceneDidEnterBackground()
        fixture.clock.advance(seconds: 50)
        fixture.coordinator.sceneDidBecomeActive()
        XCTAssertTrue(fixture.viewModel.isPaused)
        XCTAssertEqual(fixture.cameraFixture.camera.position, .back)
        XCTAssertEqual(fixture.viewModel.elapsedSeconds, 2)
        fixture.coordinator.togglePause()
        await fixture.cameraFixture.camera.start().value
        let snapshot = await fixture.cameraFixture.capture.snapshot()
        XCTAssertEqual(snapshot.positions, [.front, .back, .back])
        XCTAssertFalse(fixture.viewModel.isPaused)
        fixture.clock.advance(seconds: 0.5)
        XCTAssertEqual(fixture.viewModel.elapsedSeconds, 3)
        await fixture.close()
    }

    @MainActor
    func testInterruptionDuringSwitchKeepsWorkoutPausedAfterInterruptionEnds() async {
        let fixture = SwitchingWorkoutFixture()
        await fixture.start()
        fixture.completeRepetition()
        await fixture.cameraFixture.capture.suspendNextStart()
        let operation = fixture.beginSwitch()
        await fixture.cameraFixture.capture.waitForStart()
        fixture.cameraFixture.camera.receive(.interrupted)
        XCTAssertEqual(fixture.cameraFixture.camera.state, .interrupted)
        await fixture.cameraFixture.capture.releaseStart()
        await operation.value
        fixture.cameraFixture.camera.receive(.interruptionEnded)
        XCTAssertTrue(fixture.viewModel.isPaused)
        XCTAssertEqual(fixture.state?.totalRepetitions, 1)
        XCTAssertEqual(fixture.cameraFixture.camera.position, .front)
        fixture.coordinator.togglePause()
        await fixture.cameraFixture.camera.start().value
        XCTAssertFalse(fixture.viewModel.isPaused)
        await fixture.close()
    }

    @MainActor
    func testRuntimeErrorDuringSwitchRejectsLateSuccessAndPreservesCounters() async {
        let fixture = SwitchingWorkoutFixture()
        await fixture.start()
        fixture.completeRepetition()
        await fixture.cameraFixture.capture.suspendNextStart()
        let operation = fixture.beginSwitch()
        await fixture.cameraFixture.capture.waitForStart()
        fixture.cameraFixture.camera.receive(.runtimeError("Controlled switch error"))
        await fixture.cameraFixture.capture.releaseStart()
        await operation.value
        XCTAssertEqual(fixture.cameraFixture.camera.state, .failed("Controlled switch error"))
        XCTAssertEqual(fixture.cameraFixture.camera.position, .front)
        XCTAssertEqual(fixture.state?.totalRepetitions, 1)
        XCTAssertTrue(fixture.viewModel.isPaused)
        fixture.coordinator.togglePause()
        await fixture.cameraFixture.camera.start().value
        XCTAssertEqual(fixture.cameraFixture.camera.position, .front)
        XCTAssertFalse(fixture.viewModel.isPaused)
        await fixture.close()
    }

    @MainActor
    func testCancellingPendingSwitchPausesBeforeBackendResponds() async {
        let fixture = SwitchingWorkoutFixture()
        await fixture.start()
        await fixture.cameraFixture.capture.suspendNextStart()
        let operation = fixture.beginSwitch()
        await fixture.cameraFixture.capture.waitForStart()
        let stopped = XCTestExpectation(description: "Switch cancellation stops camera")
        fixture.coordinator.onCameraStateChange = { state in
            if state == .stopped { stopped.fulfill() }
        }
        operation.cancel()
        let result = await XCTWaiter.fulfillment(of: [stopped], timeout: 3)
        XCTAssertEqual(result, .completed)
        XCTAssertTrue(fixture.viewModel.isPaused)
        XCTAssertEqual(fixture.cameraFixture.camera.position, .front)
        await fixture.cameraFixture.capture.releaseStart()
        await operation.value
        XCTAssertEqual(fixture.cameraFixture.camera.state, .stopped)
        await fixture.close()
    }

    @MainActor
    func testFinishDuringSwitchIsTerminalAndFreezesDuration() async {
        let fixture = SwitchingWorkoutFixture()
        await fixture.start()
        fixture.completeRepetition()
        fixture.clock.advance(seconds: 5.75)
        await fixture.cameraFixture.capture.suspendNextStart()
        let operation = fixture.beginSwitch()
        await fixture.cameraFixture.capture.waitForStart()
        fixture.clock.advance(seconds: 100)
        fixture.coordinator.finish()
        await fixture.cameraFixture.capture.releaseStart()
        await operation.value
        XCTAssertEqual(fixture.cameraFixture.camera.state, .finished)
        XCTAssertEqual(fixture.cameraFixture.camera.position, .front)
        XCTAssertEqual(fixture.viewModel.finishedSummary?.duration, 5)
        XCTAssertEqual(fixture.viewModel.finishedSummary?.repetitions, 1)
        XCTAssertEqual(fixture.state?.saveState, .saved)
        XCTAssertFalse(fixture.coordinator.canSwitchCamera)
        await fixture.close()
    }

    @MainActor
    func testSwitchIsIgnoredInBackgroundAndAfterFinish() async {
        let fixture = SwitchingWorkoutFixture()
        await fixture.start()
        fixture.coordinator.sceneDidEnterBackground()
        XCTAssertFalse(fixture.coordinator.canSwitchCamera)
        fixture.coordinator.switchCamera()
        fixture.coordinator.sceneDidBecomeActive()
        fixture.coordinator.finish()
        fixture.coordinator.switchCamera()
        await fixture.cameraFixture.camera.finish().value
        let snapshot = await fixture.cameraFixture.capture.snapshot()
        XCTAssertEqual(snapshot.positions, [.front])
        XCTAssertEqual(snapshot.shutdownCount, 1)
        XCTAssertEqual(fixture.cameraFixture.camera.state, .finished)
    }

    @MainActor
    func testFinishedSummaryRemainsIdempotentAfterSwitchAndSaveRetry() async throws {
        let fixture = SwitchingWorkoutFixture()
        await fixture.start()
        fixture.completeRepetition()
        fixture.clock.advance(seconds: 1.25)
        await fixture.switchCamera()
        fixture.completeRepetition()
        fixture.clock.advance(seconds: 0.75)
        fixture.store.shouldFail = true
        fixture.coordinator.finish()
        let summary = try XCTUnwrap(fixture.viewModel.finishedSummary)
        XCTAssertEqual(summary.duration, 2)
        XCTAssertEqual(summary.repetitions, 2)
        fixture.clock.advance(seconds: 500)
        fixture.store.shouldFail = false
        fixture.viewModel.retrySave()
        fixture.viewModel.retrySave()
        XCTAssertEqual(fixture.viewModel.finishedSummary, summary)
        XCTAssertEqual(fixture.store.attempts, [summary, summary])
        XCTAssertEqual(try fixture.store.history(), [summary])
        XCTAssertEqual(fixture.state?.saveState, .saved)
        await fixture.close()
    }
    @MainActor
    func testSwitchControlAppearsAtTopRightWithRussianAccessibilityAndCameraImage() async throws {
        let fixture = CameraFixture()
        let store = SwitchingWorkoutStore()
        let viewModel = WorkoutViewModel(persistence: store, cameraReady: false)
        let controller = WorkoutViewController(viewModel: viewModel, camera: fixture.camera, persistence: store)
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        controller.view.layoutIfNeeded()
        let control = try XCTUnwrap(allSubviews(including: controller.view).compactMap { $0 as? UIButton }.first {
            $0.accessibilityIdentifier == "cameraSwitchButton"
        })
        XCTAssertGreaterThan(control.center.x, controller.view.bounds.midX)
        XCTAssertLessThan(control.center.y, controller.view.bounds.height / 4)
        XCTAssertGreaterThanOrEqual(control.bounds.width, 44)
        XCTAssertGreaterThanOrEqual(control.bounds.height, 44)
        XCTAssertTrue(control.accessibilityLabel?.contains("камер") == true)
        XCTAssertNotNil(control.image(for: .normal) ?? control.configuration?.image)
        XCTAssertFalse(control.isEnabled)
        controller.cameraCoordinator.disconnect()
        await fixture.camera.finish().value
    }

    @MainActor
    func testSwitchControlTracksPendingSwitchBackgroundAndFinish() async throws {
        let fixture = CameraFixture()
        let store = SwitchingWorkoutStore()
        let viewModel = WorkoutViewModel(persistence: store, cameraReady: false)
        let controller = WorkoutViewController(viewModel: viewModel, camera: fixture.camera, persistence: store)
        controller.loadViewIfNeeded()
        controller.cameraCoordinator.startInitially()
        await fixture.camera.start().value
        let control = try XCTUnwrap(allSubviews(including: controller.view).compactMap { $0 as? UIButton }.first {
            $0.accessibilityIdentifier == "cameraSwitchButton"
        })
        XCTAssertTrue(control.isEnabled)
        await fixture.capture.suspendNextStart()
        control.sendActions(for: .touchUpInside)
        let operation = fixture.camera.start()
        await fixture.capture.waitForStart()
        XCTAssertFalse(control.isEnabled)
        await fixture.capture.releaseStart()
        await operation.value
        XCTAssertTrue(control.isEnabled)
        XCTAssertEqual(fixture.camera.position, .back)
        controller.cameraCoordinator.sceneDidEnterBackground()
        XCTAssertFalse(control.isEnabled)
        controller.cameraCoordinator.sceneDidBecomeActive()
        XCTAssertTrue(control.isEnabled)
        XCTAssertTrue(viewModel.isPaused)
        controller.cameraCoordinator.finish()
        XCTAssertFalse(control.isEnabled)
        await fixture.camera.finish().value
    }

    @MainActor
    func testSwitchControlReenablesAfterSwitchWhileWorkoutRemainsPaused() async throws {
        let fixture = CameraFixture()
        let store = SwitchingWorkoutStore()
        let viewModel = WorkoutViewModel(persistence: store, cameraReady: false)
        let controller = WorkoutViewController(viewModel: viewModel, camera: fixture.camera, persistence: store)
        controller.loadViewIfNeeded()
        controller.cameraCoordinator.startInitially()
        await fixture.camera.start().value
        controller.cameraCoordinator.togglePause()
        let control = try XCTUnwrap(allSubviews(including: controller.view).compactMap { $0 as? UIButton }.first {
            $0.accessibilityIdentifier == "cameraSwitchButton"
        })
        XCTAssertTrue(control.isEnabled)
        control.sendActions(for: .touchUpInside)
        await fixture.camera.start().value
        XCTAssertEqual(fixture.camera.position, .back)
        XCTAssertTrue(viewModel.isPaused)
        XCTAssertTrue(control.isEnabled)
        controller.cameraCoordinator.disconnect()
        await fixture.camera.finish().value
    }

    @MainActor
    func testUnavailableInitialFrontLeavesSwitchControlEnabledForBackCamera() async throws {
        let fixture = CameraFixture()
        let store = SwitchingWorkoutStore()
        let viewModel = WorkoutViewModel(persistence: store, cameraReady: false)
        let controller = WorkoutViewController(viewModel: viewModel, camera: fixture.camera, persistence: store)
        controller.loadViewIfNeeded()
        await fixture.capture.failNextStart()
        controller.cameraCoordinator.startInitially()
        await fixture.camera.start().value
        let control = try XCTUnwrap(allSubviews(including: controller.view).compactMap { $0 as? UIButton }.first {
            $0.accessibilityIdentifier == "cameraSwitchButton"
        })
        guard case .failed = fixture.camera.state else {
            XCTFail("Expected front-camera unavailability")
            controller.cameraCoordinator.disconnect()
            await fixture.camera.finish().value
            return
        }
        XCTAssertTrue(control.isEnabled)
        control.sendActions(for: .touchUpInside)
        await fixture.camera.start().value
        XCTAssertEqual(fixture.camera.state, .running)
        XCTAssertEqual(fixture.camera.position, .back)
        XCTAssertTrue(control.isEnabled)
        XCTAssertTrue(viewModel.isPaused)
        controller.cameraCoordinator.disconnect()
        await fixture.camera.finish().value
    }

    @MainActor
    private func allSubviews(including rootView: UIView) -> [UIView] {
        [rootView] + rootView.subviews.flatMap { allSubviews(including: $0) }
    }

}

@MainActor
private final class SwitchingWorkoutFixture {
    let cameraFixture = CameraFixture()
    let clock = SwitchingWorkoutClock()
    let store = SwitchingWorkoutStore()
    let viewModel: WorkoutViewModel
    let coordinator: WorkoutCameraCoordinator
    private(set) var state: WorkoutViewState?
    private var frameIndex = 0

    init() {
        viewModel = WorkoutViewModel(persistence: store, timeSource: clock, cameraReady: false)
        coordinator = WorkoutCameraCoordinator(viewModel: viewModel, camera: cameraFixture.camera)
        viewModel.onChange = { [weak self] state in self?.state = state }
    }

    func start() async {
        coordinator.startInitially()
        await cameraFixture.camera.start().value
    }

    func beginSwitch() -> Task<Void, Never> {
        coordinator.switchCamera()
        return cameraFixture.camera.start()
    }

    func switchCamera() async {
        await beginSwitch().value
    }

    func close() async {
        coordinator.disconnect()
        await cameraFixture.camera.finish().value
    }

    func completeRepetition() {
        feed(isStanding: true)
        feed(isStanding: false)
        feed(isStanding: true)
    }

    func feed(isStanding: Bool, generation: UInt64? = nil, position: CameraPosition? = nil) {
        let hipPoint = isStanding ? CGPoint(x: 0.5, y: 0.8) : CGPoint(x: 0.8, y: 0.5)
        let pose = BodyPose(joints: [
            .leftHip: JointPoint(location: hipPoint, confidence: 1),
            .leftKnee: JointPoint(location: CGPoint(x: 0.5, y: 0.5), confidence: 1),
            .leftAnkle: JointPoint(location: CGPoint(x: 0.5, y: 0.2), confidence: 1)
        ], aspectRatio: 1, rotationAngle: cameraFixture.capture.currentRotationAngle)
        for _ in 0..<20 {
            frameIndex += 1
            let capturedAt = cameraFixture.currentFrameTime.advanced(by: .nanoseconds(Int64(frameIndex) - 200_000_000))
            cameraFixture.camera.receive(CameraFrame(
                generation: generation ?? cameraFixture.capture.currentGeneration,
                pose: pose, capturedAt: capturedAt,
                position: position ?? cameraFixture.capture.currentPosition,
                rotationAngle: cameraFixture.capture.currentRotationAngle
            ))
        }
    }
}

@MainActor
private final class SwitchingWorkoutClock: WorkoutTimeSource {
    var currentTime: TimeInterval = 1_000
    var date = Date(timeIntervalSince1970: 1_700_000_000)

    func advance(seconds interval: TimeInterval) {
        currentTime += interval
    }
}

@MainActor
private final class SwitchingWorkoutStore: WorkoutStoring {
    var shouldFail = false
    private(set) var attempts: [WorkoutSummary] = []
    private var summaries: [UUID: WorkoutSummary] = [:]

    func save(_ summary: WorkoutSummary) throws {
        attempts.append(summary)
        if shouldFail { throw SwitchingStoreError.unavailable }
        summaries[summary.id] = summary
    }

    func history() throws -> [WorkoutSummary] {
        Array(summaries.values)
    }
}

private enum SwitchingStoreError: Error {
    case unavailable
}
