//
//  CameraLifecycleTests.swift
//  RepsCounter
//
//  Maintainer: Alexander Shevtsov
//  Copyright © 2026 Alexander Shevtsov.

import AVFoundation
import CoreGraphics
import XCTest
import os
@testable import RepsCounter

final class CameraLifecycleTests: XCTestCase {
    @MainActor
    func testAuthorizedStartMakesCameraReadyExactlyOnce() async {
        let fixture = CameraFixture()
        await fixture.camera.start().value
        let snapshot = await fixture.capture.snapshot()
        XCTAssertEqual(fixture.camera.state, .running)
        XCTAssertEqual(snapshot.starts, [1])
        XCTAssertTrue(snapshot.isRunning)
        await fixture.camera.finish().value
    }

    @MainActor
    func testFirstPermissionRequestStartsOnlyAfterGrant() async {
        let fixture = CameraFixture(authorization: .notDetermined)
        let operation = fixture.camera.start()
        await fixture.permission.waitForRequest()
        XCTAssertEqual(fixture.camera.state, .requestingPermission)
        let beforeGrant = await fixture.capture.snapshot()
        XCTAssertTrue(beforeGrant.starts.isEmpty)
        fixture.permission.resolve(granted: true)
        await operation.value
        XCTAssertEqual(fixture.camera.state, .running)
        XCTAssertEqual(fixture.permission.requestCount, 1)
        await fixture.camera.finish().value
    }

    @MainActor
    func testDeniedPermissionDoesNotStartCapture() async {
        let fixture = CameraFixture(authorization: .denied)
        await fixture.camera.start().value
        let snapshot = await fixture.capture.snapshot()
        XCTAssertEqual(fixture.camera.state, .permissionDenied)
        XCTAssertTrue(snapshot.starts.isEmpty)
        XCTAssertEqual(fixture.permission.requestCount, 0)
        await fixture.camera.finish().value
    }

    @MainActor
    func testPermissionRequestDenialDoesNotStartCapture() async {
        let fixture = CameraFixture(authorization: .notDetermined)
        let operation = fixture.camera.start()
        await fixture.permission.waitForRequest()
        fixture.permission.resolve(granted: false)
        await operation.value
        let snapshot = await fixture.capture.snapshot()
        XCTAssertEqual(fixture.camera.state, .permissionDenied)
        XCTAssertTrue(snapshot.starts.isEmpty)
        await fixture.camera.finish().value
    }

    @MainActor
    func testSettingsGrantRequiresExplicitStart() async {
        let fixture = CameraFixture(authorization: .denied)
        await fixture.camera.start().value
        fixture.permission.status = .authorized
        fixture.camera.refreshAuthorization()
        XCTAssertEqual(fixture.camera.state, .stopped)
        let beforeRetry = await fixture.capture.snapshot()
        XCTAssertTrue(beforeRetry.starts.isEmpty)
        await fixture.camera.start().value
        XCTAssertEqual(fixture.camera.state, .running)
        await fixture.camera.finish().value
    }

    @MainActor
    func testRepeatedStartWhileWaitingAndRunningIsCoalesced() async {
        let fixture = CameraFixture(authorization: .notDetermined)
        let firstStart = fixture.camera.start()
        let repeatedStart = fixture.camera.start()
        await fixture.permission.waitForRequest()
        fixture.permission.resolve(granted: true)
        await firstStart.value
        await repeatedStart.value
        await fixture.camera.start().value
        let snapshot = await fixture.capture.snapshot()
        XCTAssertEqual(snapshot.starts, [1])
        XCTAssertEqual(fixture.permission.requestCount, 1)
        await fixture.camera.finish().value
    }

    @MainActor
    func testStopDuringPermissionRequestPreventsLateStart() async {
        let fixture = CameraFixture(authorization: .notDetermined)
        let operation = fixture.camera.start()
        await fixture.permission.waitForRequest()
        await fixture.camera.stop().value
        fixture.permission.resolve(granted: true)
        await operation.value
        let snapshot = await fixture.capture.snapshot()
        XCTAssertEqual(fixture.camera.state, .stopped)
        XCTAssertTrue(snapshot.starts.isEmpty)
        await fixture.camera.finish().value
    }

    @MainActor
    func testStopDuringPendingCaptureStartPreventsLateRunningState() async {
        let fixture = CameraFixture()
        await fixture.capture.suspendNextStart()
        let operation = fixture.camera.start()
        await fixture.capture.waitForStart()
        await fixture.camera.stop().value
        await fixture.capture.releaseStart()
        await operation.value
        let snapshot = await fixture.capture.snapshot()
        XCTAssertEqual(fixture.camera.state, .stopped)
        XCTAssertFalse(snapshot.isRunning)
        await fixture.camera.finish().value
    }

    @MainActor
    func testCancellationOfStartTaskPreventsCaptureAfterPermission() async {
        let fixture = CameraFixture(authorization: .notDetermined)
        let operation = fixture.camera.start()
        await fixture.permission.waitForRequest()
        let stopped = XCTestExpectation(description: "Cancelled start stops before permission response")
        fixture.camera.onStateChange = { state in
            if state == .stopped { stopped.fulfill() }
        }
        operation.cancel()
        let cancellation = await XCTWaiter.fulfillment(of: [stopped], timeout: 3)
        XCTAssertEqual(cancellation, .completed)
        XCTAssertEqual(fixture.camera.state, .stopped)
        let beforeResponse = await fixture.capture.snapshot()
        XCTAssertTrue(beforeResponse.starts.isEmpty)
        fixture.permission.resolve(granted: true)
        await operation.value
        let snapshot = await fixture.capture.snapshot()
        XCTAssertEqual(fixture.camera.state, .stopped)
        XCTAssertTrue(snapshot.starts.isEmpty)
        await fixture.camera.finish().value
    }

    @MainActor
    func testRapidStartStopStartKeepsOnlyNewestGenerationRunning() async {
        let fixture = CameraFixture()
        await fixture.capture.suspendNextStart()
        let obsoleteStart = fixture.camera.start()
        await fixture.capture.waitForStart()
        let stopping = fixture.camera.stop()
        let newestStart = fixture.camera.start()
        await stopping.value
        await newestStart.value
        await fixture.capture.releaseStart()
        await obsoleteStart.value
        let snapshot = await fixture.capture.snapshot()
        XCTAssertEqual(fixture.camera.state, .running)
        XCTAssertEqual(snapshot.generation, 3)
        XCTAssertTrue(snapshot.isRunning)
        await fixture.camera.finish().value
    }

    @MainActor
    func testRapidStopAndStartReusesPendingPermissionRequest() async {
        let fixture = CameraFixture(authorization: .notDetermined)
        let obsoleteStart = fixture.camera.start()
        await fixture.permission.waitForRequest()
        await fixture.camera.stop().value
        let newestStart = fixture.camera.start()
        fixture.permission.resolve(granted: true)
        await obsoleteStart.value
        await newestStart.value
        let snapshot = await fixture.capture.snapshot()
        XCTAssertEqual(fixture.permission.requestCount, 1)
        XCTAssertEqual(snapshot.starts, [3])
        XCTAssertEqual(fixture.camera.state, .running)
        await fixture.camera.finish().value
    }

    @MainActor
    func testImmediateFinishCancelsPermissionRequestBeforeItBegins() async {
        let fixture = CameraFixture(authorization: .notDetermined)
        let operation = fixture.camera.start()
        await fixture.camera.finish().value
        await operation.value
        XCTAssertEqual(fixture.permission.requestCount, 0)
        XCTAssertEqual(fixture.camera.state, .finished)
    }

    @MainActor
    func testFinishDuringPendingCaptureStartRemainsTerminal() async {
        let fixture = CameraFixture()
        await fixture.capture.suspendNextStart()
        let operation = fixture.camera.start()
        await fixture.capture.waitForStart()
        await fixture.camera.finish().value
        await fixture.capture.releaseStart()
        await operation.value
        let snapshot = await fixture.capture.snapshot()
        XCTAssertEqual(fixture.camera.state, .finished)
        XCTAssertFalse(snapshot.isRunning)
        XCTAssertEqual(snapshot.shutdownCount, 1)
    }

    @MainActor
    func testFrameStreamDeliversValueWithoutPassingPixelBuffersToMainActor() async {
        let fixture = CameraFixture()
        await fixture.camera.start().value
        let received = XCTestExpectation(description: "Pose value delivered")
        fixture.camera.onPose = { _ in received.fulfill() }
        fixture.capture.frameContinuation.yield(fixture.frame(generation: 1))
        let result = await XCTWaiter.fulfillment(of: [received], timeout: 3)
        XCTAssertEqual(result, .completed)
        await fixture.camera.finish().value
    }

    @MainActor
    func testInterruptionPausesCaptureAndEndingDoesNotRestartIt() async {
        let fixture = CameraFixture()
        await fixture.camera.start().value
        fixture.camera.receive(.interrupted)
        XCTAssertEqual(fixture.camera.state, .interrupted)
        fixture.camera.receive(.interruptionEnded)
        XCTAssertEqual(fixture.camera.state, .stopped)
        await fixture.camera.start().value
        let snapshot = await fixture.capture.snapshot()
        XCTAssertEqual(snapshot.starts.count, 2)
        XCTAssertEqual(fixture.camera.state, .running)
        await fixture.camera.finish().value
    }

    @MainActor
    func testRuntimeErrorAllowsExplicitRetry() async {
        let fixture = CameraFixture()
        await fixture.camera.start().value
        fixture.camera.receive(.runtimeError("Controlled runtime error"))
        XCTAssertEqual(fixture.camera.state, .failed("Controlled runtime error"))
        await fixture.camera.start().value
        XCTAssertEqual(fixture.camera.state, .running)
        await fixture.camera.finish().value
    }

    @MainActor
    func testTemporaryCaptureFailureAllowsExplicitRetry() async {
        let fixture = CameraFixture()
        await fixture.capture.failNextStart()
        await fixture.camera.start().value
        guard case .failed = fixture.camera.state else {
            XCTFail("Expected a recoverable capture failure")
            await fixture.camera.finish().value
            return
        }
        await fixture.camera.start().value
        XCTAssertEqual(fixture.camera.state, .running)
        await fixture.camera.finish().value
    }

    @MainActor
    func testFramesFromStoppedAndPreviousGenerationsAreIgnored() async {
        let fixture = CameraFixture()
        var deliveredFrames = 0
        fixture.camera.onPose = { _ in deliveredFrames += 1 }
        await fixture.camera.start().value
        fixture.camera.receive(fixture.frame(generation: 1))
        XCTAssertEqual(deliveredFrames, 1)
        await fixture.camera.stop().value
        fixture.camera.receive(fixture.frame(generation: 1))
        await fixture.camera.start().value
        fixture.camera.receive(fixture.frame(generation: 1))
        fixture.camera.receive(fixture.frame(generation: 3))
        XCTAssertEqual(deliveredFrames, 2)
        await fixture.camera.finish().value
    }

    @MainActor
    func testStaleOutOfOrderAndFutureFramesAreIgnored() async {
        let fixture = CameraFixture()
        var deliveredFrames = 0
        fixture.camera.onPose = { _ in deliveredFrames += 1 }
        await fixture.camera.start().value
        fixture.camera.receive(fixture.frame(generation: 1, offset: .seconds(-1)))
        fixture.camera.receive(fixture.frame(generation: 1, offset: .seconds(1)))
        fixture.camera.receive(fixture.frame(generation: 1, offset: .milliseconds(-100)))
        fixture.camera.receive(fixture.frame(generation: 1, offset: .milliseconds(-150)))
        fixture.camera.receive(fixture.frame(generation: 1))
        XCTAssertEqual(deliveredFrames, 2)
        await fixture.camera.finish().value
    }

    @MainActor
    func testFinishIsTerminalAndDropsAllFramesAndEvents() async {
        let fixture = CameraFixture()
        var deliveredFrames = 0
        fixture.camera.onPose = { _ in deliveredFrames += 1 }
        await fixture.camera.start().value
        await fixture.camera.finish().value
        await fixture.camera.start().value
        fixture.camera.receive(fixture.frame(generation: 1))
        fixture.camera.receive(.runtimeError("Late error"))
        fixture.camera.receive(.interruptionEnded)
        let snapshot = await fixture.capture.snapshot()
        XCTAssertEqual(fixture.camera.state, .finished)
        XCTAssertEqual(deliveredFrames, 0)
        XCTAssertEqual(snapshot.starts.count, 1)
        XCTAssertEqual(snapshot.shutdownCount, 1)
    }

    @MainActor
    func testStreamsDeliverCaptureEventsOnMainActor() async {
        let fixture = CameraFixture()
        await fixture.camera.start().value
        let interrupted = XCTestExpectation(description: "Camera event delivered")
        fixture.camera.onStateChange = { state in
            if state == .interrupted { interrupted.fulfill() }
        }
        fixture.capture.eventContinuation.yield(.interrupted)
        let result = await XCTWaiter.fulfillment(of: [interrupted], timeout: 3)
        XCTAssertEqual(result, .completed)
        XCTAssertEqual(fixture.camera.state, .interrupted)
        await fixture.camera.finish().value
    }

    @MainActor
    func testReleasingCameraCancelsPendingTaskAndShutsDownCapture() async {
        let permission = ControlledCameraPermission(status: .notDetermined)
        let capture = ControlledCameraCapture()
        var camera: CameraService? = CameraService(permission: permission, capture: capture)
        let releasedCamera = { [weak camera] in camera }
        let operation = camera?.start()
        await permission.waitForRequest()
        camera = nil
        XCTAssertNil(releasedCamera())
        await capture.waitForShutdown()
        permission.resolve(granted: true)
        await operation?.value
        let snapshot = await capture.snapshot()
        XCTAssertTrue(snapshot.starts.isEmpty)
        XCTAssertEqual(snapshot.shutdownCount, 1)
    }

    func testNativeNotificationsAreMappedAndRemovedOnStop() async {
        let session = AVCaptureSession()
        let center = NotificationCenter()
        let stream = AsyncStream<CameraSessionEvent>.makeStream()
        let notifications = CameraSessionNotifications(session: session, center: center, continuation: stream.continuation)
        var iterator = stream.stream.makeAsyncIterator()
        center.post(name: AVCaptureSession.wasInterruptedNotification, object: session)
        let interrupted = await iterator.next()
        XCTAssertEqual(interrupted, .interrupted)
        center.post(name: AVCaptureSession.interruptionEndedNotification, object: session)
        let ended = await iterator.next()
        XCTAssertEqual(ended, .interruptionEnded)
        let failure = NSError(domain: "CameraTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "Controlled error"])
        center.post(name: AVCaptureSession.runtimeErrorNotification, object: session, userInfo: [AVCaptureSessionErrorKey: failure])
        let runtimeError = await iterator.next()
        XCTAssertEqual(runtimeError, .runtimeError("Controlled error"))
        notifications.stop()
        center.post(name: AVCaptureSession.wasInterruptedNotification, object: session)
        stream.continuation.finish()
        let afterStop = await iterator.next()
        XCTAssertNil(afterStop)
    }

    func testReleasingNativeNotificationsRemovesObservers() async {
        let session = AVCaptureSession()
        let center = NotificationCenter()
        let stream = AsyncStream<CameraSessionEvent>.makeStream()
        var notifications: CameraSessionNotifications? = CameraSessionNotifications(
            session: session, center: center, continuation: stream.continuation
        )
        let releasedNotifications = { [weak notifications] in notifications }
        notifications = nil
        XCTAssertNil(releasedNotifications())
        center.post(name: AVCaptureSession.wasInterruptedNotification, object: session)
        stream.continuation.finish()
        var iterator = stream.stream.makeAsyncIterator()
        let remainingEvent = await iterator.next()
        XCTAssertNil(remainingEvent)
    }
}

@MainActor
final class CameraFixture {
    let permission: ControlledCameraPermission
    let capture = ControlledCameraCapture()
    let camera: CameraService
    let currentFrameTime = ContinuousClock.now

    init(authorization: CameraAuthorization = .authorized) {
        permission = ControlledCameraPermission(status: authorization)
        let frameTime = currentFrameTime
        camera = CameraService(permission: permission, capture: capture, frameTime: { frameTime })
    }

    func frame(generation: UInt64, offset: Duration = .zero, pose: BodyPose? = nil, position: CameraPosition = .front, rotationAngle: CGFloat = 90) -> CameraFrame {
        CameraFrame(generation: generation, pose: pose, capturedAt: currentFrameTime.advanced(by: offset), position: position, rotationAngle: rotationAngle)
    }
}

@MainActor
final class ControlledCameraPermission: CameraAuthorizing {
    var status: CameraAuthorization
    private(set) var requestCount = 0
    private var response: CheckedContinuation<Bool, Never>?
    private var requested: CheckedContinuation<Void, Never>?

    init(status: CameraAuthorization) {
        self.status = status
    }

    func requestAccess() async -> Bool {
        requestCount += 1
        return await withCheckedContinuation { continuation in
            response = continuation
            requested?.resume()
            requested = nil
        }
    }

    func waitForRequest() async {
        if response != nil { return }
        await withCheckedContinuation { requested = $0 }
    }

    func resolve(granted: Bool) {
        status = granted ? .authorized : .denied
        response?.resume(returning: granted)
        response = nil
    }
}

actor ControlledCameraCapture: CameraCapturing {
    struct Snapshot: Sendable {
        let starts: [UInt64]
        let positions: [CameraPosition]
        let position: CameraPosition
        let rotationAngle: CGFloat
        let generation: UInt64
        let isRunning: Bool
        let shutdownCount: Int
    }

    nonisolated let frames: AsyncStream<CameraFrame>
    nonisolated let events: AsyncStream<CameraSessionEvent>
    nonisolated let previewSource: CameraPreviewSource? = nil
    nonisolated let frameContinuation: AsyncStream<CameraFrame>.Continuation
    nonisolated let eventContinuation: AsyncStream<CameraSessionEvent>.Continuation
    private nonisolated let generationState = OSAllocatedUnfairLock(initialState: UInt64(0))
    nonisolated var currentGeneration: UInt64 { generationState.withLock { $0 } }
    private nonisolated let positionState = OSAllocatedUnfairLock(initialState: CameraPosition.front)
    nonisolated var currentPosition: CameraPosition { positionState.withLock { $0 } }
    private var starts: [UInt64] = []
    private var positions: [CameraPosition] = []
    private var position: CameraPosition = .front
    private var rotationAngle: CGFloat = 90
    private var frontRotationAngle: CGFloat = 90
    private var backRotationAngle: CGFloat = 90
    private nonisolated let rotationState = OSAllocatedUnfairLock(initialState: CGFloat(90))
    nonisolated var currentRotationAngle: CGFloat { rotationState.withLock { $0 } }
    private var generation: UInt64 = 0
    private var isRunning = false
    private var shutdownCount = 0
    private var shouldSuspend = false
    private var shouldFail = false
    private var pendingStart: CheckedContinuation<Void, Never>?
    private var startRequested: CheckedContinuation<Void, Never>?
    private var shutdownRequested: CheckedContinuation<Void, Never>?

    init() {
        let frameStream = AsyncStream<CameraFrame>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let eventStream = AsyncStream<CameraSessionEvent>.makeStream()
        frames = frameStream.stream
        events = eventStream.stream
        frameContinuation = frameStream.continuation
        eventContinuation = eventStream.continuation
    }

    func start(generation: UInt64, position: CameraPosition) async throws -> CameraConfiguration {
        guard shutdownCount == 0, generation >= self.generation else { throw CancellationError() }
        self.generation = generation
        generationState.withLock { $0 = generation }
        starts.append(generation)
        positions.append(position)
        isRunning = false
        if shouldSuspend {
            shouldSuspend = false
            await withCheckedContinuation { continuation in
                pendingStart = continuation
                startRequested?.resume()
                startRequested = nil
            }
        }
        try Task.checkCancellation()
        guard generation == self.generation, shutdownCount == 0 else { throw CancellationError() }
        if shouldFail {
            shouldFail = false
            throw CameraService.CameraError.cameraUnavailable
        }
        self.position = position
        rotationAngle = position == .front ? frontRotationAngle : backRotationAngle
        positionState.withLock { $0 = position }
        let currentRotation = rotationAngle
        rotationState.withLock { $0 = currentRotation }
        isRunning = true
        return CameraConfiguration(position: position, rotationAngle: rotationAngle)
    }

    func stop(generation: UInt64) {
        guard generation >= self.generation else { return }
        self.generation = generation
        generationState.withLock { $0 = generation }
        isRunning = false
    }

    func shutdown() {
        guard shutdownCount == 0 else { return }
        shutdownCount += 1
        isRunning = false
        frameContinuation.finish()
        eventContinuation.finish()
        shutdownRequested?.resume()
        shutdownRequested = nil
    }

    func setRotationAngle(_ angle: CGFloat, for position: CameraPosition) {
        if position == .front { frontRotationAngle = angle }
        else { backRotationAngle = angle }
    }

    func suspendNextStart() { shouldSuspend = true }
    func failNextStart() { shouldFail = true }

    func waitForStart() async {
        if pendingStart != nil { return }
        await withCheckedContinuation { startRequested = $0 }
    }

    func releaseStart() {
        pendingStart?.resume()
        pendingStart = nil
    }

    func waitForShutdown() async {
        if shutdownCount > 0 { return }
        await withCheckedContinuation { shutdownRequested = $0 }
    }

    func snapshot() -> Snapshot {
        Snapshot(starts: starts, positions: positions, position: position, rotationAngle: rotationAngle, generation: generation, isRunning: isRunning, shutdownCount: shutdownCount)
    }
}
