//
//  WorkoutViewController.swift
//  RepsCounter
//
//  Maintainer: Alexander Shevtsov
//  Copyright © 2026 Alexander Shevtsov.

import AVFoundation
import UIKit

final class WorkoutViewController: UIViewController, UIAdaptivePresentationControllerDelegate {
    private let viewModel: WorkoutViewModel
    private let camera: CameraService
    let cameraCoordinator: WorkoutCameraCoordinator
    private let persistence: any WorkoutStoring
    private let cameraView = CameraPreviewView()
    private let overlayView = PoseOverlayView()
    private let backdropView = WorkoutBackdropView()
    private let dashboard = WorkoutDashboardView()
    #if DEBUG
    private let diagnosticsButton = UIButton(type: .system)
    private let diagnosticsView = SquatDiagnosticsView()
    #endif
    private var lastPose: BodyPose?
    private var lastState: WorkoutViewState?
    private var pendingSaveState: WorkoutSaveState?
    private var isMessageDismissalInProgress = false

    init(viewModel: WorkoutViewModel, camera: CameraService, persistence: any WorkoutStoring) {
        self.viewModel = viewModel
        self.camera = camera
        cameraCoordinator = WorkoutCameraCoordinator(viewModel: viewModel, camera: camera)
        self.persistence = persistence
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        view.tintColor = WorkoutAppearance.accent
        camera.previewSource?.connect(to: cameraView.previewLayer)
        cameraView.previewLayer.videoGravity = .resizeAspectFill
        configureLayout()
        bindState()
        #if DEBUG
        viewModel.onDiagnosticsChange = { [weak self] diagnostics in
            guard let self, !self.diagnosticsView.isHidden else { return }
            self.diagnosticsView.render(diagnostics)
        }
        #endif
        cameraCoordinator.onPose = { [weak self] pose in
            guard let self else { return }
            self.lastPose = pose
            self.overlayView.render(pose, previewLayer: self.cameraView.previewLayer)
        }
        cameraCoordinator.onCameraStateChange = { [weak self] state in
            guard let self else { return }
            if state == .running { self.configurePreview() }
            self.updateCameraMessage()
        }
        viewModel.setCameraReady(false)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        presentPendingSaveMessage()
        cameraCoordinator.startInitially()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if camera.state == .running { configurePreview() }
        overlayView.render(lastPose, previewLayer: cameraView.previewLayer)
    }

    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        presentPendingSaveMessage()
    }

    private func configurePreview() {
        guard let connection = cameraView.previewLayer.connection else { return }
        if connection.isVideoRotationAngleSupported(camera.rotationAngle) {
            connection.videoRotationAngle = camera.rotationAngle
        }
        connection.automaticallyAdjustsVideoMirroring = false
        if connection.isVideoMirroringSupported {
            connection.isVideoMirrored = camera.position == .front
        }
    }

    private func configureLayout() {
        cameraView.translatesAutoresizingMaskIntoConstraints = false
        overlayView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(cameraView)
        backdropView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(backdropView)
        view.addSubview(overlayView)
        NSLayoutConstraint.activate([
            cameraView.topAnchor.constraint(equalTo: view.topAnchor),
            cameraView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            cameraView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            cameraView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            backdropView.topAnchor.constraint(equalTo: cameraView.topAnchor),
            backdropView.bottomAnchor.constraint(equalTo: cameraView.bottomAnchor),
            backdropView.leadingAnchor.constraint(equalTo: cameraView.leadingAnchor),
            backdropView.trailingAnchor.constraint(equalTo: cameraView.trailingAnchor),
            overlayView.topAnchor.constraint(equalTo: cameraView.topAnchor),
            overlayView.leadingAnchor.constraint(equalTo: cameraView.leadingAnchor),
            overlayView.trailingAnchor.constraint(equalTo: cameraView.trailingAnchor),
            overlayView.bottomAnchor.constraint(equalTo: cameraView.bottomAnchor)
        ])

        dashboard.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(dashboard)
        NSLayoutConstraint.activate([
            dashboard.topAnchor.constraint(equalTo: view.topAnchor),
            dashboard.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            dashboard.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            dashboard.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])
        dashboard.onHistory = { [weak self] in self?.openHistory() }
        dashboard.onSwitch = { [weak self] in self?.switchCamera() }
        dashboard.onPause = { [weak self] in self?.togglePause() }
        dashboard.onFinish = { [weak self] in self?.finishWorkout() }
        #if DEBUG
        configureDiagnostics()
        #endif
    }

    #if DEBUG
    private func configureDiagnostics() {
        diagnosticsButton.setImage(UIImage(systemName: "waveform.path.ecg"), for: .normal)
        diagnosticsButton.setPreferredSymbolConfiguration(UIImage.SymbolConfiguration(pointSize: 20, weight: .semibold), forImageIn: .normal)
        diagnosticsButton.tintColor = .white
        diagnosticsButton.backgroundColor = WorkoutAppearance.surface
        diagnosticsButton.layer.cornerRadius = 16
        diagnosticsButton.accessibilityIdentifier = "squatDiagnosticsButton"
        diagnosticsButton.accessibilityLabel = "Диагностика приседаний"
        diagnosticsButton.accessibilityValue = "Выключена"
        diagnosticsButton.addTarget(self, action: #selector(toggleDiagnostics), for: .touchUpInside)
        diagnosticsButton.widthAnchor.constraint(equalToConstant: 44).isActive = true
        diagnosticsButton.heightAnchor.constraint(equalToConstant: 48).isActive = true
        dashboard.toolbar.insertArrangedSubview(diagnosticsButton, at: 1)
        diagnosticsView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(diagnosticsView)
        NSLayoutConstraint.activate([
            diagnosticsView.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 20),
            diagnosticsView.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -20),
            diagnosticsView.topAnchor.constraint(equalTo: dashboard.toolbar.bottomAnchor, constant: 14),
            diagnosticsView.bottomAnchor.constraint(equalTo: dashboard.controls.topAnchor, constant: -14)
        ])
    }

    @objc private func toggleDiagnostics() {
        diagnosticsView.isHidden.toggle()
        dashboard.setDiagnosticsVisible(!diagnosticsView.isHidden)
        diagnosticsButton.accessibilityValue = diagnosticsView.isHidden ? "Выключена" : "Включена"
        if !diagnosticsView.isHidden, let diagnostics = viewModel.latestDiagnostics {
            diagnosticsView.render(diagnostics)
        }
    }
    #endif

    private func bindState() {
        viewModel.onChange = { [weak self] state in
            guard let self else { return }
            let previousSaveState = lastState?.saveState
            lastState = state
            updateCameraMessage()
            if state.isFinished { cameraCoordinator.stopAfterFinish() }
            if previousSaveState != state.saveState {
                switch state.saveState {
                case .saved, .failed:
                    pendingSaveState = state.saveState
                case .notSaved, .saving:
                    pendingSaveState = nil
                }
            }
            presentPendingSaveMessage()
        }
    }

    private func updateCameraMessage() {
        if let lastState { dashboard.render(lastState, cameraState: camera.state) }
        dashboard.updateCameraControl(canSwitch: cameraCoordinator.canSwitchCamera, position: camera.position)
    }

    private func presentPendingSaveMessage() {
        guard let pendingSaveState,
              viewIfLoaded?.window != nil,
              presentedViewController == nil,
              !isMessageDismissalInProgress else { return }

        let alert: UIAlertController
        switch pendingSaveState {
        case .saved:
            alert = UIAlertController(
                title: "Тренировка завершена",
                message: "Результат сохранён в истории.",
                preferredStyle: .alert
            )
            alert.addAction(UIAlertAction(title: "ОК", style: .default) { [weak self] _ in
                self?.dismissMessage()
            })
        case .failed(let message):
            alert = UIAlertController(title: "Сохранение", message: message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "Повторить", style: .default) { [weak self] _ in
                self?.dismissMessage(retrySave: true)
            })
            alert.addAction(UIAlertAction(title: "Позже", style: .cancel) { [weak self] _ in
                self?.dismissMessage()
            })
        case .notSaved, .saving:
            return
        }
        self.pendingSaveState = nil
        present(alert, animated: true)
    }

    private func dismissMessage(retrySave: Bool = false) {
        isMessageDismissalInProgress = true
        dismiss(animated: true) { [weak self] in
            guard let self else { return }
            self.isMessageDismissalInProgress = false
            if retrySave { self.viewModel.retrySave() }
            self.presentPendingSaveMessage()
        }
    }

    @objc private func openHistory() {
        guard presentedViewController == nil, !isMessageDismissalInProgress else { return }
        let controller = WorkoutHistoryViewController(persistence: persistence)
        controller.onDismiss = { [weak self] in
            self?.presentPendingSaveMessage()
        }
        let navigationController = UINavigationController(rootViewController: controller)
        present(navigationController, animated: true)
        navigationController.presentationController?.delegate = self
    }

    @objc private func switchCamera() { cameraCoordinator.switchCamera() }

    @objc private func togglePause() { cameraCoordinator.togglePause() }

    @objc private func finishWorkout() {
        if lastState?.isFinished == true {
            viewModel.retrySave()
        } else {
            cameraCoordinator.finish()
        }
    }
}
