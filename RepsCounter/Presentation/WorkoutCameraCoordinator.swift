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
    private var shouldResumeWhenReady = false

    var canSwitchCamera: Bool {
        isForeground && viewModel.finishedSummary == nil && camera.canSwitchCamera
    }

    init(viewModel: WorkoutViewModel, camera: CameraService) {
        self.viewModel = viewModel
        self.camera = camera
        camera.onStateChange = { [weak self] state in self?.cameraStateChanged(state) }
        camera.onPose = { [weak self] pose in
            guard let self, self.isForeground else { return }
            if self.viewModel.isPaused { self.viewModel.observePose(pose) }
            else { self.viewModel.process(pose) }
            if self.viewModel.finishedSummary != nil { self.camera.finish() }
            else { self.onPose?(pose) }
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
