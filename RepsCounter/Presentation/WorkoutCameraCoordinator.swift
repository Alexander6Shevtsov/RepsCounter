//
//  WorkoutCameraCoordinator.swift
//  RepsCounter
//
//  Maintainer: Alexander Shevtsov
//  Copyright © 2026 Alexander Shevtsov.

import Foundation

@MainActor
final class WorkoutCameraCoordinator {
    var onPose: ((BodyPose?) -> Void)?
    var onCameraStateChange: ((CameraState) -> Void)?

    private let viewModel: WorkoutViewModel
    private let camera: CameraService
    private var isForeground = true
    private var hasStarted = false
    #if DEBUG
    private var lastCounterFrame: ContinuousClock.Instant?
    private var timedProcessor = TimeBasedPoseProcessor()
    private let timedOrigin = ContinuousClock.now
    #endif
    private var shouldResumeWhenReady = false

    var canSwitchCamera: Bool {
        isForeground && viewModel.finishedSummary == nil && camera.canSwitchCamera
    }

    init(viewModel: WorkoutViewModel, camera: CameraService) {
        self.viewModel = viewModel
        self.camera = camera
        camera.onStateChange = { [weak self] state in self?.cameraStateChanged(state) }
        camera.onFrame = { [weak self] frame in
            let pose = frame.pose
            guard let self, self.isForeground else {
                frame.trace?.mark(.skipped, reason: "inactiveCoordinator")
                return
            }
            #if DEBUG
            if self.viewModel.isPaused {
                self.timedProcessor.reset()
                frame.trace?.mark(.timeBasedReset, reason: "paused")
            } else {
                frame.trace?.recorder.record(.fullPoseInput, frame: frame.trace?.identity,
                    visionPose: pose.map(PipelineTelemetry.VisionPose.init))
                let duration = self.timedOrigin.duration(to: frame.capturedAt).components
                let seconds = frame.measurementSeconds ?? (Double(duration.seconds) + Double(duration.attoseconds) / 1e18)
                let counted = self.timedProcessor.process(pose, at: seconds)
                frame.trace?.mark(.timeBasedDecision, reason: "phase=\(self.timedProcessor.phase.rawValue) counted=\(counted) ema=\(self.timedProcessor.ema ?? -1)")
            }
            let restrictCounter = CameraQualitySelection.current.limitsCounterCadence
            let admitted = !restrictCounter || (self.lastCounterFrame.map {
                CameraQualityConfiguration.acceptsCounter(elapsed: $0.duration(to: frame.capturedAt))
            } ?? true)
            if admitted { self.lastCounterFrame = frame.capturedAt }
            if !admitted { frame.trace?.mark(.counterSampleSkipped, reason: "baseline80msCounterAdmission") }
            #else
            let admitted = true
            #endif
            if admitted {
                if self.viewModel.isPaused {
                    frame.trace?.mark(.skipped, reason: "paused")
                    self.viewModel.observePose(pose, trace: frame.trace)
                } else {
                    self.viewModel.process(pose, trace: frame.trace)
                }
            }
            if self.viewModel.finishedSummary != nil { self.camera.finish() }
            else if let onPose = self.onPose {
                let start = frame.trace?.begin("Overlay UI submit", .overlayStart)
                onPose(pose)
                frame.trace?.end(start, .overlayEnd)
            }
        }
    }

    func startInitially() {
        guard !hasStarted, isForeground, viewModel.finishedSummary == nil else { return }
        hasStarted = true
        if viewModel.startsAutomatically { requestResume() }
        else { camera.start() }
    }

    func togglePause() {
        guard viewModel.finishedSummary == nil else { return }
        if viewModel.isPaused {
            requestResume()
        } else {
            shouldResumeWhenReady = false
            viewModel.pause()
        }
    }

    func switchCamera() {
        guard canSwitchCamera else { return }
        shouldResumeWhenReady = !viewModel.isPaused && camera.state == .running
        viewModel.setCameraReady(false)
        camera.switchCamera()
    }

    func sceneDidEnterBackground() {
        isForeground = false
        shouldResumeWhenReady = false
        viewModel.setCameraReady(false)
        camera.stop()
    }

    func sceneDidBecomeActive() {
        isForeground = true
        camera.refreshAuthorization()
        if hasStarted, viewModel.finishedSummary == nil { camera.start() }
        onCameraStateChange?(camera.state)
    }

    func finish() {
        shouldResumeWhenReady = false
        camera.finish()
        viewModel.finish()
    }

    func stopAfterFinish() {
        shouldResumeWhenReady = false
        camera.finish()
    }

    @discardableResult
    func disconnect() -> Task<Void, Never> {
        shouldResumeWhenReady = false
        viewModel.setCameraReady(false)
        let shutdownTask = camera.finish()
        #if DEBUG
        _ = viewModel.stopDiagnosticRecording()
        #endif
        onPose = nil
        onCameraStateChange = nil
        return shutdownTask
    }

    private func requestResume() {
        guard isForeground, viewModel.finishedSummary == nil else { return }
        shouldResumeWhenReady = true
        if camera.state == .running {
            viewModel.setCameraReady(true)
            viewModel.resume()
            shouldResumeWhenReady = false
        } else {
            camera.start()
        }
    }

    private func cameraStateChanged(_ state: CameraState) {
        #if DEBUG
        lastCounterFrame = nil
        timedProcessor.reset()
        PipelineTelemetry.active?.record(.timeBasedReset, reason: "cameraLifecycle")
        #endif
        if state == .running, isForeground {
            viewModel.setCameraReady(true)
            if shouldResumeWhenReady { viewModel.resume() }
            shouldResumeWhenReady = false
        } else {
            viewModel.setCameraReady(false)
            if state != .starting, state != .switching, state != .requestingPermission { shouldResumeWhenReady = false }
            onPose?(nil)
        }
        onCameraStateChange?(state)
    }
}
