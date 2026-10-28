//
//  PoseExperimentCaptureTests.swift
//  RepsCounter
//
//  Maintainer: Alexander Shevtsov
//  Copyright © 2026 Alexander Shevtsov.

#if DEBUG
import CoreMedia
import CoreVideo
import ImageIO
import Vision
import XCTest
import os
@testable import RepsCounter

final class PoseExperimentCaptureTests: XCTestCase {
    func testDisabledExperimentNeverInvokes3D() throws {
        let fixture = ExperimentCaptureFixture()
        try fixture.submit(sequence: 1)
        fixture.drain()
        XCTAssertEqual(fixture.detector.calls, 0)
        XCTAssertEqual(fixture.capture.statistics.analyzed2D, 0)
    }

    func testSameSourceBufferTimestampAndOrientationProduceOnePair() async throws {
        let fixture = ExperimentCaptureFixture()
        fixture.enable()
        var updates = fixture.capture.updates.makeAsyncIterator()
        let sample = try fixture.submit(sequence: 7)
        fixture.drain()
        guard case .planar(let planar, _) = await updates.next(),
              case .paired(let pair, _) = await updates.next() else {
            return XCTFail("Expected planar observation followed by its exact pair")
        }
        XCTAssertEqual(pair.source.metadata.identity, planar.metadata.identity)
        XCTAssertEqual(pair.source.metadata.identity.sequence, 7)
        XCTAssertEqual(pair.source.metadata.timestamp, CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample)))
        XCTAssertEqual(fixture.detector.timestamp, pair.source.metadata.timestamp)
        XCTAssertEqual(fixture.detector.orientation, PoseGeometry.visionOrientation.rawValue)
        XCTAssertEqual(fixture.detector.imageIdentity, ExperimentCaptureFixture.imageIdentity(sample))
        XCTAssertEqual(pair.source.latency, 0.012)
        XCTAssertEqual(pair.detection.pose?.heightEstimation, .reference)
        XCTAssertFalse(pair.source.metadata.depthDataProvided)
        XCTAssertFalse(pair.source.metadata.inputMirrored)
        XCTAssertEqual(fixture.capture.statistics.completed3D, 1)
        XCTAssertFalse(pair.isComparable)
        XCTAssertEqual(fixture.capture.statistics.coverage, 0)
    }

    func testBusy3DDoesNotQueueBuffersOrBlockPlanarObservations() throws {
        let fixture = ExperimentCaptureFixture(blocked: true)
        fixture.enable()
        try fixture.submit(sequence: 1)
        XCTAssertEqual(XCTWaiter.wait(for: [fixture.detector.started], timeout: 3), .completed)
        for sequence in 2...12 {
            fixture.clock.advance(.milliseconds(80))
            try fixture.submit(sequence: UInt64(sequence))
        }
        XCTAssertEqual(fixture.capture.statistics.analyzed2D, 12)
        XCTAssertEqual(fixture.capture.statistics.admitted3D, 1)
        XCTAssertEqual(fixture.capture.statistics.busyDropped, 11)
        XCTAssertEqual(fixture.detector.calls, 1)
        fixture.detector.release()
        fixture.drain()
    }

    func testControlledFrequencySkipsFramesWithoutInventingPairs() throws {
        let fixture = ExperimentCaptureFixture()
        fixture.enable()
        try fixture.submit(sequence: 1, pose: SquatPoseFixture.pose(leftAngle: 170))
        fixture.drain()
        fixture.clock.advance(.milliseconds(499))
        try fixture.submit(sequence: 2, pose: SquatPoseFixture.pose(leftAngle: 170))
        fixture.drain()
        XCTAssertEqual(fixture.detector.calls, 1)
        XCTAssertEqual(fixture.capture.statistics.rateLimited, 1)
        fixture.clock.advance(.milliseconds(1))
        try fixture.submit(sequence: 3, pose: SquatPoseFixture.pose(leftAngle: 170))
        fixture.drain()
        XCTAssertEqual(fixture.detector.calls, 2)
        XCTAssertEqual(fixture.capture.statistics.completed3D, 2)
        XCTAssertEqual(fixture.capture.statistics.coverage, 2.0 / 3.0, accuracy: 0.000001)
    }

    func testDisableBeforeQueuedWorkPreventsNativeRequest() throws {
        let fixture = ExperimentCaptureFixture()
        let gate = DispatchSemaphore(value: 0)
        fixture.queue.async { gate.wait() }
        fixture.enable()
        try fixture.submit(sequence: 1)
        fixture.capture.setEnabled(false)
        gate.signal()
        fixture.drain()
        XCTAssertEqual(fixture.detector.calls, 0)
        XCTAssertEqual(fixture.capture.statistics.cancelled, 1)
        XCTAssertEqual(fixture.capture.statistics.completed3D, 0)
    }

    func testStoppingCancelsInFlightWorkAndDiscardsItsResult() throws {
        let fixture = ExperimentCaptureFixture(blocked: true)
        fixture.enable()
        try fixture.submit(sequence: 1)
        XCTAssertEqual(XCTWaiter.wait(for: [fixture.detector.started], timeout: 3), .completed)
        fixture.capture.suspend()
        XCTAssertGreaterThan(fixture.detector.cancellations, 0)
        fixture.detector.release()
        fixture.drain()
        XCTAssertEqual(fixture.capture.statistics.completed3D, 0)
        XCTAssertEqual(fixture.capture.statistics.cancelled, 1)
    }

    func testCameraSwitchInvalidatesGenerationBeforeOld3DCompletes() throws {
        let fixture = ExperimentCaptureFixture(blocked: true)
        fixture.enable()
        try fixture.submit(sequence: 1)
        XCTAssertEqual(XCTWaiter.wait(for: [fixture.detector.started], timeout: 3), .completed)
        let oldEpoch = fixture.capture.currentEpoch
        fixture.capture.configure(generation: 2, position: .back)
        XCTAssertNotEqual(fixture.capture.currentEpoch, oldEpoch)
        fixture.detector.release()
        fixture.drain()
        XCTAssertEqual(fixture.capture.statistics.completed3D, 0)
        fixture.clock.advance(.milliseconds(500))
        try fixture.submit(sequence: 2, generation: 1)
        XCTAssertEqual(fixture.capture.statistics.analyzed2D, 1)
        try fixture.submit(sequence: 3, generation: 2, position: .back)
        fixture.drain()
        XCTAssertEqual(fixture.capture.statistics.completed3D, 1)
    }

    func testExpiredOperationIsCancelledWithoutRealWaiting() throws {
        let fixture = ExperimentCaptureFixture(blocked: true)
        fixture.enable()
        try fixture.submit(sequence: 1)
        XCTAssertEqual(XCTWaiter.wait(for: [fixture.detector.started], timeout: 3), .completed)
        fixture.clock.advance(.milliseconds(751))
        fixture.capture.cancelExpiredWork()
        XCTAssertGreaterThan(fixture.detector.cancellations, 0)
        fixture.capture.cancelExpiredWork()
        XCTAssertEqual(fixture.capture.statistics.timeouts, 1)
        fixture.detector.release()
        fixture.drain()
        XCTAssertEqual(fixture.capture.statistics.staleDropped, 1)
        XCTAssertEqual(fixture.capture.statistics.completed3D, 0)
    }

    func testVisionFailureIsReportedAsFailureWithout2DFallback() async throws {
        let fixture = ExperimentCaptureFixture(detection: Pose3DDetection(pose: nil, issue: .visionError, detail: "Controlled error"))
        fixture.enable()
        var updates = fixture.capture.updates.makeAsyncIterator()
        try fixture.submit(sequence: 1)
        fixture.drain()
        _ = await updates.next()
        guard case .paired(let pair, _) = await updates.next() else { return XCTFail("Missing failed pair") }
        XCTAssertEqual(pair.detection.issue, .visionError)
        XCTAssertEqual(pair.detection.detail, "Controlled error")
        XCTAssertEqual(pair.spatial.phase, .unavailable)
        XCTAssertNil(pair.spatial.confirmedRepetitions)
        XCTAssertEqual(fixture.capture.statistics.usable3D, 0)
    }

    func testTimestampMismatchAndInvalidMetadataDoNotFormPair() throws {
        let fixture = ExperimentCaptureFixture()
        fixture.enable()
        let sample = try ExperimentCaptureFixture.sample(timestamp: 1)
        fixture.capture.submit(sampleBuffer: sample, pose: nil, metadata: fixture.metadata(sequence: 1, timestamp: 2), planarLatency: 0)
        fixture.drain()
        XCTAssertEqual(fixture.detector.calls, 0)
        XCTAssertEqual(fixture.capture.statistics.analyzed2D, 0)
    }

    func testDuplicateAndOlderSourceFramesCannotAdvanceIndependentCounter() throws {
        let fixture = ExperimentCaptureFixture()
        fixture.enable()
        try fixture.submit(sequence: 2, pose: SquatPoseFixture.pose(leftAngle: 170))
        fixture.drain()
        try fixture.submit(sequence: 2, pose: SquatPoseFixture.pose(leftAngle: 90))
        try fixture.submit(sequence: 1, pose: SquatPoseFixture.pose(leftAngle: 90))
        XCTAssertEqual(fixture.capture.statistics.analyzed2D, 1)
        XCTAssertEqual(fixture.capture.statistics.invalidInput, 2)
        XCTAssertEqual(fixture.capture.latestPlanar?.analysis.repetitions, 0)
    }

    func testTrackingLossResetsIndependentMovementButPreservesCount() throws {
        let fixture = ExperimentCaptureFixture()
        fixture.enable()
        var sequence: UInt64 = 0
        for angle in Array(repeating: 170.0, count: 24) + Array(repeating: 90.0, count: 24) + Array(repeating: 170.0, count: 24) + Array(repeating: 90.0, count: 24) {
            sequence += 1
            fixture.clock.advance(.milliseconds(80))
            try fixture.submit(sequence: sequence, pose: SquatPoseFixture.pose(leftAngle: angle))
            fixture.drain()
        }
        sequence += 1
        fixture.clock.advance(.milliseconds(80))
        try fixture.submit(sequence: sequence, pose: nil)
        fixture.drain()
        for _ in 0..<24 {
            sequence += 1
            fixture.clock.advance(.milliseconds(80))
            try fixture.submit(sequence: sequence, pose: SquatPoseFixture.pose(leftAngle: 170))
            fixture.drain()
        }
        XCTAssertEqual(fixture.capture.latestPlanar?.analysis.repetitions, 1)
    }

    func testRepeatedObservationCannotGenerateAnotherIndependent2DEvent() throws {
        let fixture = ExperimentCaptureFixture()
        fixture.enable()
        var sequence: UInt64 = 0
        for angle in Array(repeating: 170.0, count: 24) + Array(repeating: 90.0, count: 24) + Array(repeating: 170.0, count: 48) {
            sequence += 1
            fixture.clock.advance(.milliseconds(80))
            try fixture.submit(sequence: sequence, pose: SquatPoseFixture.pose(leftAngle: angle))
            fixture.drain()
        }
        let lastState = fixture.capture.statistics
        XCTAssertEqual(lastState.analyzed2D, 96)
        XCTAssertGreaterThan(lastState.deliveryDropped, 0)
        XCTAssertEqual(fixture.capture.latestPlanar?.analysis.repetitions, 1)
    }

    func testAdmissionKeepsOneBusyOperationAcrossDisableAndReenable() {
        var admission = ExperimentAdmission()
        let instant = ContinuousClock.now
        XCTAssertEqual(admission.admit(at: instant), .disabled)
        admission.setEnabled(true)
        let oldEpoch = admission.epoch
        XCTAssertNil(admission.admit(at: instant))
        admission.setEnabled(false)
        admission.setEnabled(true)
        XCTAssertEqual(admission.admit(at: instant.advanced(by: .seconds(1))), .busy)
        XCTAssertFalse(admission.complete(epoch: oldEpoch))
        XCTAssertNil(admission.admit(at: instant.advanced(by: .seconds(1))))
    }

    func testNativeCancellationPrecedesAvailabilityAndNeedsNoPhysicalCamera() throws {
        let detector = Pose3DDetector()
        detector.cancel()
        let detection = detector.detect(sampleBuffer: try ExperimentCaptureFixture.sample(timestamp: 1), orientation: .up)
        XCTAssertEqual(detection.issue, .cancelled)
        XCTAssertNil(detection.pose)
    }

    func testNativeVision3DOnBlankFrameReportsNoBodyOrExplicitRuntimeError() throws {
        let sample = try ExperimentCaptureFixture.sample(timestamp: 1)
        let imageBuffer = try XCTUnwrap(CMSampleBufferGetImageBuffer(sample))
        CVPixelBufferLockBaseAddress(imageBuffer, [])
        if let address = CVPixelBufferGetBaseAddress(imageBuffer) {
            memset(address, 0, CVPixelBufferGetBytesPerRow(imageBuffer) * CVPixelBufferGetHeight(imageBuffer))
        }
        CVPixelBufferUnlockBaseAddress(imageBuffer, [])
        let startedAt = ContinuousClock.now
        let result = Pose3DDetector().detect(sampleBuffer: sample, orientation: .up)
        let elapsed = startedAt.duration(to: .now).experimentSeconds
        print("Vision3D blank-buffer smoke: \(result.issue?.rawValue ?? "pose"), \(elapsed) s; \(result.detail ?? "")")
        XCTAssertNil(result.pose)
        let request = VNDetectHumanBodyPose3DRequest()
        if VNDetectHumanBodyPose3DRequest.supportedRevisions.contains(request.revision) {
            XCTAssertTrue(result.issue == .noBody || result.issue == .visionError)
        } else {
            XCTAssertEqual(result.issue, .unsupportedRevision)
            XCTAssertNotNil(result.detail)
        }
    }

    func testShutdownFinishesStreamAndPreventsReactivation() async throws {
        let fixture = ExperimentCaptureFixture()
        fixture.enable()
        fixture.capture.shutdown()
        fixture.capture.configure(generation: 2)
        fixture.capture.setEnabled(true)
        try fixture.submit(sequence: 1, generation: 2)
        fixture.drain()
        var iterator = fixture.capture.updates.makeAsyncIterator()
        let remaining = await iterator.next()
        XCTAssertNil(remaining)
        XCTAssertEqual(fixture.detector.calls, 0)
    }

    func testReleasingCaptureFinishesNumericStreamAndRetainsNoBufferWork() async {
        var capture: PoseExperimentCapture? = PoseExperimentCapture()
        weak let weakCapture = capture
        let updates = capture?.updates
        capture = nil
        XCTAssertNil(weakCapture)
        var iterator = updates?.makeAsyncIterator()
        let remaining = await iterator?.next()
        XCTAssertNil(remaining)
    }
}

final class ExperimentTestClock: Sendable {
    private let value = OSAllocatedUnfairLock(initialState: ContinuousClock.now)
    var current: ContinuousClock.Instant { value.withLock { $0 } }
    func advance(_ interval: Duration) { value.withLock { $0 = $0.advanced(by: interval) } }
}

final class Controlled3DDetector: Pose3DDetecting {
    private struct State {
        var calls = 0
        var cancellations = 0
        var timestamp: Double?
        var orientation: UInt32?
        var imageIdentity: UInt?
    }

    let started = XCTestExpectation(description: "Controlled 3D request entered")
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let gate = DispatchSemaphore(value: 0)
    private let blocked: Bool
    private let detection: Pose3DDetection
    var calls: Int { state.withLock { $0.calls } }
    var cancellations: Int { state.withLock { $0.cancellations } }
    var timestamp: Double? { state.withLock { $0.timestamp } }
    var orientation: UInt32? { state.withLock { $0.orientation } }
    var imageIdentity: UInt? { state.withLock { $0.imageIdentity } }

    init(blocked: Bool = false, detection: Pose3DDetection = Pose3DDetection(pose: Pose3DFixture.pose(), issue: nil, detail: nil)) {
        self.blocked = blocked
        self.detection = detection
        started.assertForOverFulfill = false
    }

    func detect(sampleBuffer: CMSampleBuffer, orientation: CGImagePropertyOrientation) -> Pose3DDetection {
        let timestamp = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
        let imageIdentity = ExperimentCaptureFixture.imageIdentity(sampleBuffer)
        let firstCall = state.withLock { current in
            current.calls += 1
            current.timestamp = timestamp
            current.orientation = orientation.rawValue
            current.imageIdentity = imageIdentity
            return current.calls == 1
        }
        started.fulfill()
        if blocked && firstCall { gate.wait() }
        return detection
    }

    func cancel() { state.withLock { $0.cancellations += 1 } }
    func release() { gate.signal() }
}

final class ExperimentCaptureFixture {
    let queue = DispatchQueue(label: "repscounter.tests.vision3d")
    let clock = ExperimentTestClock()
    let detector: Controlled3DDetector
    let capture: PoseExperimentCapture

    init(blocked: Bool = false, detection: Pose3DDetection = Pose3DDetection(pose: Pose3DFixture.pose(), issue: nil, detail: nil)) {
        let detector = Controlled3DDetector(blocked: blocked, detection: detection)
        self.detector = detector
        let clock = clock
        capture = PoseExperimentCapture(worker: queue, detectorFactory: { detector }, clock: { clock.current })
        capture.configure(generation: 1)
    }

    func enable() { capture.setEnabled(true) }
    func drain() { queue.sync {} }

    func metadata(sequence: UInt64, timestamp: Double, generation: UInt64 = 1, position: CameraPosition = .front) -> ExperimentFrameMetadata {
        ExperimentFrameMetadata(
            identity: ExperimentFrameIdentity(generation: generation, sequence: sequence), timestamp: timestamp,
            receivedAt: clock.current, position: position, rotationAngle: 90, orientation: 1,
            inputMirrored: false, depthDataProvided: false
        )
    }

    @discardableResult
    func submit(sequence: UInt64, generation: UInt64 = 1, position: CameraPosition = .front, pose: BodyPose? = nil) throws -> CMSampleBuffer {
        let timestamp = Double(sequence) / 10
        let sample = try Self.sample(timestamp: timestamp)
        capture.noteSourceFrame()
        capture.submit(
            sampleBuffer: sample, pose: pose,
            metadata: metadata(sequence: sequence, timestamp: timestamp, generation: generation, position: position),
            planarLatency: 0.012
        )
        return sample
    }

    static func sample(timestamp: Double) throws -> CMSampleBuffer {
        var pixelBuffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 16, 16, kCVPixelFormatType_32BGRA, nil, &pixelBuffer), kCVReturnSuccess)
        let imageBuffer = try XCTUnwrap(pixelBuffer)
        var description: CMVideoFormatDescription?
        XCTAssertEqual(CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: imageBuffer, formatDescriptionOut: &description), noErr)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30), presentationTimeStamp: CMTime(seconds: timestamp, preferredTimescale: 600), decodeTimeStamp: .invalid)
        var sampleBuffer: CMSampleBuffer?
        XCTAssertEqual(CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: imageBuffer, formatDescription: try XCTUnwrap(description), sampleTiming: &timing, sampleBufferOut: &sampleBuffer), noErr)
        return try XCTUnwrap(sampleBuffer)
    }

    static func imageIdentity(_ sample: CMSampleBuffer) -> UInt? {
        guard let imageBuffer = CMSampleBufferGetImageBuffer(sample) else { return nil }
        return UInt(bitPattern: Unmanaged.passUnretained(imageBuffer).toOpaque())
    }
}
#endif
