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

    init(viewModel: WorkoutViewModel, camera: CameraService) {
        self.viewModel = viewModel
        self.camera = camera
        camera.onStateChange = { [weak self] state in self?.cameraStateChanged(state) }
        camera.onPose = { [weak self] pose in
            guard let self, self.isForeground else { return }
            self.viewModel.process(pose)
            if self.viewModel.finishedSummary != nil { self.camera.finish() }
            else { self.onPose?(pose) }
        }
    }

    func startInitially() {
        guard !hasStarted, isForeground, viewModel.finishedSummary == nil else { return }
        hasStarted = true
        requestResume()
    }

    func togglePause() {
        guard viewModel.finishedSummary == nil else { return }
        if viewModel.isPaused {
            requestResume()
        } else {
            shouldResumeWhenReady = false
            viewModel.pause()
            camera.stop()
        }
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

    func disconnect() {
        shouldResumeWhenReady = false
        viewModel.setCameraReady(false)
        camera.finish()
        onPose = nil
        onCameraStateChange = nil
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
            if state != .starting, state != .requestingPermission { shouldResumeWhenReady = false }
            onPose?(nil)
        }
        onCameraStateChange?(state)
    }
}
