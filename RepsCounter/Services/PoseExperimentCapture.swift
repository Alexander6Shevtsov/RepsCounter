//
//  PoseExperimentCapture.swift
//  RepsCounter
//
//  Maintainer: Alexander Shevtsov
//  Copyright © 2026 Alexander Shevtsov.

#if DEBUG
import CoreMedia
import ImageIO
import os

final class PoseExperimentCapture: Sendable {
    private struct Work {
        let sampleBuffer: CMSampleBuffer
        let source: ExperimentFrame2D
        let detector: any Pose3DDetecting
    }

    private struct State {
        var admission = ExperimentAdmission(minimumInterval: .milliseconds(500))
        var requestedEnabled = false
        var isShutdown = false
        var generation: UInt64?
        var configuration = CameraConfiguration(position: .front, rotationAngle: 90)
        let planarAnalyzer = PoseAnalyzer()
        var planarCounter = SquatCounter()
        var previousObservation: ContinuousClock.Instant?
        var previousMetadata: ExperimentFrameMetadata?
        var statistics = ExperimentLoadStatistics()
        var pendingWork: Work?
        var currentDetector: (any Pose3DDetecting)?
        var currentSource: ExperimentFrame2D?
        var latestPlanar: ExperimentFrame2D?
        var currentTimedOut = false
    }

    let updates: AsyncStream<PoseExperimentUpdate>
    static let maximumResultAge: Duration = .milliseconds(750)
    private let continuation: AsyncStream<PoseExperimentUpdate>.Continuation
    private let state = OSAllocatedUnfairLock(uncheckedState: State())
    private let worker: DispatchQueue
    private let detectorFactory: @Sendable () -> any Pose3DDetecting
    private let clock: @Sendable () -> ContinuousClock.Instant

    init(
        worker: DispatchQueue = DispatchQueue(label: "repscounter.vision3d", qos: .utility),
        detectorFactory: @escaping @Sendable () -> any Pose3DDetecting = { Pose3DDetector() },
        clock: @escaping @Sendable () -> ContinuousClock.Instant = { .now }
    ) {
        self.worker = worker
        self.detectorFactory = detectorFactory
        self.clock = clock
        let stream = AsyncStream<PoseExperimentUpdate>.makeStream(bufferingPolicy: .bufferingNewest(8))
        updates = stream.stream
        continuation = stream.continuation
    }

    deinit {
        state.withLock { $0.currentDetector }?.cancel()
        continuation.finish()
    }

    var statistics: ExperimentLoadStatistics { state.withLock { $0.statistics } }
    var currentEpoch: UInt64 { state.withLock { $0.admission.epoch } }
    var latestPlanar: ExperimentFrame2D? { state.withLock { $0.latestPlanar } }
    var isProcessingEnabled: Bool { state.withLock { $0.admission.isEnabled } }

    func configure(generation: UInt64, position: CameraPosition = .front, rotationAngle: CGFloat = 90) {
        let detector = state.withLock { current in
            guard !current.isShutdown else { return Optional<any Pose3DDetecting>.none }
            current.generation = generation
            current.configuration = CameraConfiguration(position: position, rotationAngle: rotationAngle)
            current.admission.setEnabled(current.requestedEnabled)
            current.planarAnalyzer.reset()
            current.planarCounter.resetMovement()
            current.previousObservation = nil
            current.previousMetadata = nil
            current.latestPlanar = nil
            return current.currentDetector
        }
        detector?.cancel()
    }

    func suspend() {
        let detector = state.withLock { current in
            current.generation = nil
            current.admission.setEnabled(false)
            current.planarAnalyzer.reset()
            current.planarCounter.resetMovement()
            current.previousObservation = nil
            current.previousMetadata = nil
            current.latestPlanar = nil
            return current.currentDetector
        }
        detector?.cancel()
    }

    func setEnabled(_ enabled: Bool) {
        let detector = state.withLock { current in
            guard !current.isShutdown, current.requestedEnabled != enabled else { return Optional<any Pose3DDetecting>.none }
            current.requestedEnabled = enabled
            current.admission.setEnabled(enabled && current.generation != nil)
            current.planarAnalyzer.reset()
            current.planarCounter.resetMovement()
            current.previousObservation = nil
            current.previousMetadata = nil
            current.latestPlanar = nil
            return current.currentDetector
        }
        detector?.cancel()
    }

    func shutdown() {
        let detector = state.withLock { current in
            current.isShutdown = true
            current.generation = nil
            current.requestedEnabled = false
            current.admission.setEnabled(false)
            current.latestPlanar = nil
            return current.currentDetector
        }
        detector?.cancel()
        continuation.finish()
    }

    func resetSeries() {
        let detector = state.withLock { current in
            current.admission.setEnabled(current.requestedEnabled && current.generation != nil)
            current.planarAnalyzer.reset()
            current.planarCounter = SquatCounter()
            current.previousObservation = nil
            current.previousMetadata = nil
            current.latestPlanar = nil
            current.statistics = ExperimentLoadStatistics()
            return current.currentDetector
        }
        detector?.cancel()
    }

    func isCurrent(_ source: ExperimentFrame2D) -> Bool {
        state.withLock { current in
            current.admission.isEnabled && current.admission.epoch == source.epoch
                && current.generation == source.metadata.identity.generation
                && current.configuration.position == source.metadata.position
                && current.configuration.rotationAngle == source.metadata.rotationAngle
        }
    }

    func noteSourceFrame(dropped: Bool = false) {
        state.withLock { current in
            guard current.admission.isEnabled else { return }
            current.statistics.sourceFrames += 1
            if dropped { current.statistics.captureDropped += 1 }
        }
    }

    func submit(
        sampleBuffer: CMSampleBuffer, pose: BodyPose?, metadata: ExperimentFrameMetadata,
        planarLatency: Double
    ) {
        let timestamp = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
        let scheduled = state.withLockUnchecked { current in
            guard current.admission.isEnabled else { return false }
            guard current.generation == metadata.identity.generation,
                  current.configuration.position == metadata.position,
                  current.configuration.rotationAngle == metadata.rotationAngle,
                  metadata.orientation == PoseGeometry.visionOrientation.rawValue, !metadata.inputMirrored,
                  !metadata.depthDataProvided,
                  metadata.timestamp.isFinite, metadata.timestamp >= 0,
                  timestamp.isFinite, abs(timestamp - metadata.timestamp) < 0.000001 else {
                current.statistics.invalidInput += 1
                return false
            }
            if let previous = current.previousMetadata,
               metadata.identity.sequence <= previous.identity.sequence || metadata.timestamp <= previous.timestamp
                || metadata.receivedAt < previous.receivedAt {
                current.statistics.invalidInput += 1
                return false
            }
            current.previousMetadata = metadata
            if let previous = current.previousObservation,
               previous.duration(to: metadata.receivedAt) > .milliseconds(250) {
                current.planarAnalyzer.reset()
                current.planarCounter.resetMovement()
            }
            current.previousObservation = metadata.receivedAt
            let analysis = current.planarAnalyzer.analyze(pose)
            if analysis.requiresMovementReset { current.planarCounter.resetMovement() }
            _ = current.planarCounter.process(measuredAngle: analysis.measuredAngle, smoothedAngle: analysis.smoothedAngle)
            let planar = Experimental2DAnalysis(
                leftAngle: analysis.leftMeasurement.angle, rightAngle: analysis.rightMeasurement.angle,
                leftUsable: analysis.leftMeasurement.isReliable, rightUsable: analysis.rightMeasurement.isReliable,
                phase: String(describing: current.planarCounter.phase),
                decision: String(describing: current.planarCounter.decision), repetitions: current.planarCounter.repetitions
            )
            let source = ExperimentFrame2D(epoch: current.admission.epoch, metadata: metadata, analysis: planar, latency: planarLatency)
            current.latestPlanar = source
            current.statistics.analyzed2D += 1
            if analysis.measuredAngle != nil { current.statistics.usable2D += 1 }
            let rejection = current.admission.admit(at: metadata.receivedAt)
            switch rejection {
            case .busy: current.statistics.busyDropped += 1
            case .rateLimited: current.statistics.rateLimited += 1
            case .disabled: break
            case nil:
                let detector = detectorFactory()
                current.currentDetector = detector
                current.currentSource = source
                current.currentTimedOut = false
                current.pendingWork = Work(sampleBuffer: sampleBuffer, source: source, detector: detector)
                current.statistics.admitted3D += 1
            }
            publish(.planar(source, current.statistics), state: &current)
            return rejection == nil
        }
        if scheduled {
            worker.async { [weak self] in self?.performPendingWork() }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.75) { [weak self] in
                self?.cancelExpiredWork()
            }
        }
    }

    func cancelExpiredWork() {
        let detector = state.withLock { current in
            guard let source = current.currentSource, !current.currentTimedOut,
                  source.metadata.receivedAt.duration(to: clock()) >= Self.maximumResultAge else {
                return Optional<any Pose3DDetecting>.none
            }
            current.currentTimedOut = true
            current.statistics.timeouts += 1
            return current.currentDetector
        }
        detector?.cancel()
    }

    private func performPendingWork() {
        let work = state.withLockUnchecked { current in
            defer { current.pendingWork = nil }
            return current.pendingWork
        }
        guard let work else { return }
        let startedAt = clock()
        let detection: Pose3DDetection
        if !isCurrent(work.source) || work.source.metadata.receivedAt.duration(to: startedAt) >= Self.maximumResultAge {
            work.detector.cancel()
            detection = Pose3DDetection(pose: nil, issue: .cancelled, detail: nil)
        } else if let orientation = CGImagePropertyOrientation(rawValue: work.source.metadata.orientation) {
            detection = work.detector.detect(sampleBuffer: work.sampleBuffer, orientation: orientation)
        } else {
            detection = Pose3DDetection(pose: nil, issue: .invalidGeometry, detail: nil)
        }
        let completedAt = clock()
        let spatial = ExperimentalDepthAnalysis(pose: detection.pose)
        let pair = PoseComparisonPair(
            source: work.source, detection: detection, spatial: spatial,
            latency: startedAt.duration(to: completedAt).experimentSeconds, completedAt: completedAt
        )
        state.withLock { current in
            current.currentDetector = nil
            current.currentSource = nil
            let accepted = current.admission.complete(epoch: pair.source.epoch)
            guard accepted else {
                current.statistics.cancelled += 1
                return
            }
            guard pair.source.metadata.receivedAt.duration(to: completedAt) < Self.maximumResultAge else {
                current.statistics.staleDropped += 1
                return
            }
            if detection.issue == .cancelled {
                current.statistics.cancelled += 1
                return
            }
            current.statistics.completed3D += 1
            if pair.isComparable { current.statistics.comparablePairs += 1 }
            if spatial.leftLeg.isUsable || spatial.rightLeg.isUsable { current.statistics.usable3D += 1 }
            publish(.paired(pair, current.statistics), state: &current)
        }
    }

    private func publish(_ update: PoseExperimentUpdate, state current: inout State) {
        if case .dropped = continuation.yield(update) { current.statistics.deliveryDropped += 1 }
    }
}
#endif
