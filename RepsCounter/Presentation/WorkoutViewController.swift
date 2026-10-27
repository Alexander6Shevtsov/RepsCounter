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
    private let countLabel = UILabel()
    private let exerciseLabel = UILabel()
    private let setLabel = UILabel()
    private let timeLabel = UILabel()
    private let restLabel = UILabel()
    private let guidanceLabel = UILabel()
    private let pauseButton = UIButton(type: .system)
    private let finishButton = UIButton(type: .system)
    private let cameraSwitchButton = UIButton(type: .system)
    #if DEBUG
    private let diagnosticsButton = UIButton(type: .system)
    private let diagnosticsView = SquatDiagnosticsView()
    private var diagnosticsLayoutConstraints: [NSLayoutConstraint] = []
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
        view.addSubview(overlayView)
        NSLayoutConstraint.activate([
            cameraView.topAnchor.constraint(equalTo: view.topAnchor),
            cameraView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            cameraView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            cameraView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            overlayView.topAnchor.constraint(equalTo: cameraView.topAnchor),
            overlayView.leadingAnchor.constraint(equalTo: cameraView.leadingAnchor),
            overlayView.trailingAnchor.constraint(equalTo: cameraView.trailingAnchor),
            overlayView.bottomAnchor.constraint(equalTo: cameraView.bottomAnchor)
        ])

        let historyButton = UIButton(type: .system)
        historyButton.setImage(UIImage(systemName: "clock.arrow.circlepath"), for: .normal)
        historyButton.tintColor = .white
        historyButton.backgroundColor = UIColor.black.withAlphaComponent(0.45)
        historyButton.layer.cornerRadius = 20
        historyButton.addTarget(self, action: #selector(openHistory), for: .touchUpInside)
        historyButton.accessibilityLabel = "История тренировок"
        historyButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(historyButton)

        cameraSwitchButton.setImage(UIImage(systemName: "arrow.triangle.2.circlepath.camera"), for: .normal)
        cameraSwitchButton.tintColor = .white
        cameraSwitchButton.backgroundColor = UIColor.black.withAlphaComponent(0.45)
        cameraSwitchButton.layer.cornerRadius = 20
        cameraSwitchButton.accessibilityIdentifier = "cameraSwitchButton"
        cameraSwitchButton.accessibilityLabel = "Переключить камеру"
        cameraSwitchButton.addTarget(self, action: #selector(switchCamera), for: .touchUpInside)
        cameraSwitchButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(cameraSwitchButton)

        countLabel.font = .monospacedDigitSystemFont(ofSize: 112, weight: .bold)
        countLabel.adjustsFontSizeToFitWidth = true
        countLabel.minimumScaleFactor = 0.6
        countLabel.text = "0"
        countLabel.textColor = .white
        exerciseLabel.font = .preferredFont(forTextStyle: .title2)
        exerciseLabel.text = "Приседания"
        exerciseLabel.textColor = .white
        setLabel.font = .preferredFont(forTextStyle: .headline)
        setLabel.textColor = .white
        timeLabel.font = .preferredFont(forTextStyle: .headline)
        timeLabel.textColor = .white
        restLabel.font = .preferredFont(forTextStyle: .headline)
        restLabel.textColor = .white
        guidanceLabel.font = .preferredFont(forTextStyle: .subheadline)
        guidanceLabel.textColor = .white
        guidanceLabel.numberOfLines = 0
        guidanceLabel.text = "Встаньте боком к камере так, чтобы ноги были видны полностью"

        let headingStack = UIStackView(arrangedSubviews: [countLabel, exerciseLabel])
        headingStack.axis = .vertical
        headingStack.alignment = .leading
        headingStack.spacing = -12
        let indicatorStack = UIStackView(arrangedSubviews: [panel(setLabel), panel(timeLabel), panel(restLabel)])
        indicatorStack.axis = .vertical
        indicatorStack.spacing = 10
        let upperStack = UIStackView(arrangedSubviews: [headingStack, indicatorStack, guidanceLabel])
        upperStack.axis = .vertical
        upperStack.spacing = 20
        upperStack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(upperStack)

        pauseButton.setTitle("Пауза", for: .normal)
        pauseButton.setImage(UIImage(systemName: "pause.fill"), for: .normal)
        pauseButton.tintColor = .white
        pauseButton.backgroundColor = UIColor(red: 0.17, green: 0.36, blue: 0.95, alpha: 0.94)
        pauseButton.layer.cornerRadius = 18
        pauseButton.titleLabel?.font = .preferredFont(forTextStyle: .headline)
        pauseButton.addTarget(self, action: #selector(togglePause), for: .touchUpInside)
        finishButton.setTitle("Завершить", for: .normal)
        finishButton.setImage(UIImage(systemName: "stop.fill"), for: .normal)
        finishButton.tintColor = .white
        finishButton.backgroundColor = UIColor.black.withAlphaComponent(0.6)
        finishButton.layer.cornerRadius = 18
        finishButton.titleLabel?.font = .preferredFont(forTextStyle: .headline)
        finishButton.addTarget(self, action: #selector(finishWorkout), for: .touchUpInside)
        for button in [pauseButton, finishButton] {
            var configuration = UIButton.Configuration.plain()
            configuration.imagePadding = 12
            configuration.baseForegroundColor = .white
            configuration.contentInsets = .zero
            configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
                var updatedAttributes = attributes
                updatedAttributes[AttributeScopes.UIKitAttributes.FontAttribute.self] = UIFont.preferredFont(forTextStyle: .headline)
                return updatedAttributes
            }
            button.configuration = configuration
            button.semanticContentAttribute = .forceLeftToRight
            button.translatesAutoresizingMaskIntoConstraints = false
            button.heightAnchor.constraint(greaterThanOrEqualToConstant: 68).isActive = true
        }
        let controls = UIStackView(arrangedSubviews: [pauseButton, finishButton])
        controls.axis = .horizontal
        controls.distribution = .fillEqually
        controls.spacing = 12
        controls.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(controls)

        NSLayoutConstraint.activate([
            cameraSwitchButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            cameraSwitchButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -22),
            cameraSwitchButton.widthAnchor.constraint(equalToConstant: 54),
            cameraSwitchButton.heightAnchor.constraint(equalToConstant: 54),
            historyButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            historyButton.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 22),
            historyButton.widthAnchor.constraint(equalToConstant: 54),
            historyButton.heightAnchor.constraint(equalToConstant: 54),
            upperStack.topAnchor.constraint(equalTo: historyButton.bottomAnchor, constant: 10),
            upperStack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            upperStack.trailingAnchor.constraint(lessThanOrEqualTo: view.centerXAnchor, constant: 85),
            controls.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 18),
            controls.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -18),
            controls.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -14)
        ])
        #if DEBUG
        configureDiagnostics(above: controls, beside: upperStack)
        #endif
    }

    #if DEBUG
    private func configureDiagnostics(above controls: UIView, beside indicators: UIStackView) {
        diagnosticsButton.setTitle("Диагностика", for: .normal)
        diagnosticsButton.titleLabel?.font = .preferredFont(forTextStyle: .caption1)
        diagnosticsButton.titleLabel?.adjustsFontForContentSizeCategory = true
        diagnosticsButton.titleLabel?.adjustsFontSizeToFitWidth = true
        diagnosticsButton.tintColor = .white
        diagnosticsButton.backgroundColor = UIColor.black.withAlphaComponent(0.6)
        diagnosticsButton.layer.cornerRadius = 14
        diagnosticsButton.accessibilityIdentifier = "squatDiagnosticsButton"
        diagnosticsButton.accessibilityLabel = "Показать диагностику приседаний"
        diagnosticsButton.accessibilityValue = "Выключена"
        diagnosticsButton.addTarget(self, action: #selector(toggleDiagnostics), for: .touchUpInside)
        diagnosticsButton.translatesAutoresizingMaskIntoConstraints = false
        diagnosticsView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(diagnosticsButton)
        view.addSubview(diagnosticsView)
        NSLayoutConstraint.activate([
            diagnosticsButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            diagnosticsButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            diagnosticsButton.widthAnchor.constraint(equalToConstant: 140),
            diagnosticsButton.heightAnchor.constraint(equalToConstant: 54),
            diagnosticsView.leadingAnchor.constraint(equalTo: view.centerXAnchor, constant: 4),
            diagnosticsView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -18),
            diagnosticsView.bottomAnchor.constraint(equalTo: controls.topAnchor, constant: -10),
            diagnosticsView.topAnchor.constraint(equalTo: diagnosticsButton.bottomAnchor, constant: 10)
        ])
        diagnosticsLayoutConstraints = [
            indicators.trailingAnchor.constraint(equalTo: diagnosticsView.leadingAnchor, constant: -8),
            indicators.bottomAnchor.constraint(lessThanOrEqualTo: controls.topAnchor, constant: -10)
        ]
    }

    @objc private func toggleDiagnostics() {
        diagnosticsView.isHidden.toggle()
        if diagnosticsView.isHidden { NSLayoutConstraint.deactivate(diagnosticsLayoutConstraints) }
        else { NSLayoutConstraint.activate(diagnosticsLayoutConstraints) }
        for label in [setLabel, timeLabel, restLabel] {
            label.numberOfLines = diagnosticsView.isHidden ? 1 : 0
        }
        diagnosticsButton.accessibilityLabel = diagnosticsView.isHidden
            ? "Показать диагностику приседаний" : "Скрыть диагностику приседаний"
        diagnosticsButton.accessibilityValue = diagnosticsView.isHidden ? "Выключена" : "Включена"
        if !diagnosticsView.isHidden, let diagnostics = viewModel.latestDiagnostics {
            diagnosticsView.render(diagnostics)
        }
    }
    #endif

    private func panel(_ label: UILabel) -> UIView {
        let container = UIVisualEffectView(effect: UIBlurEffect(style: .systemThinMaterialDark))
        container.layer.cornerRadius = 15
        container.clipsToBounds = true
        label.translatesAutoresizingMaskIntoConstraints = false
        container.contentView.addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: container.contentView.topAnchor, constant: 12),
            label.bottomAnchor.constraint(equalTo: container.contentView.bottomAnchor, constant: -12),
            label.leadingAnchor.constraint(equalTo: container.contentView.leadingAnchor, constant: 14),
            label.trailingAnchor.constraint(equalTo: container.contentView.trailingAnchor, constant: -14)
        ])
        return container
    }

    private func bindState() {
        viewModel.onChange = { [weak self] state in
            guard let self else { return }
            let previousSaveState = lastState?.saveState
            lastState = state
            countLabel.text = "\(state.repetitions)"
            setLabel.text = "Подход \(state.currentSet) из \(state.targetSets)"
            timeLabel.text = String(format: "Время %02d:%02d", state.elapsedSeconds / 60, state.elapsedSeconds % 60)
            restLabel.text = state.isResting ? "Отдых \(state.remainingRestSeconds) сек" : "Цель \(state.targetRepetitions) повторений"
            pauseButton.setTitle(state.isPaused ? "Продолжить" : "Пауза", for: .normal)
            pauseButton.setImage(UIImage(systemName: state.isPaused ? "play.fill" : "pause.fill"), for: .normal)
            updateCameraMessage()
            finishButton.isEnabled = !state.isFinished
            switch state.saveState {
            case .notSaved:
                finishButton.setTitle("Завершить", for: .normal)
            case .saving:
                finishButton.setTitle("Сохранение…", for: .normal)
            case .saved:
                finishButton.setTitle("Завершено", for: .normal)
            case .failed:
                finishButton.setTitle("Повторить", for: .normal)
                finishButton.isEnabled = true
            }
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
        let message: String
        switch camera.state {
        case .idle, .starting:
            message = "Подготовка камеры…"
        case .switching:
            message = "Переключение камеры…"
        case .requestingPermission:
            message = "Разрешите доступ к камере для начала тренировки."
        case .permissionDenied:
            message = "Разрешите доступ к камере в настройках iPhone, вернитесь и нажмите «Продолжить»."
        case .interrupted:
            message = "Камера временно недоступна. Тренировка на паузе."
        case .failed:
            message = "Камера временно недоступна. Нажмите «Продолжить» для повтора."
        case .stopped:
            message = "Тренировка на паузе. Нажмите «Продолжить»."
        case .running, .finished:
            message = "Встаньте боком к камере так, чтобы ноги были видны полностью"
        }
        guidanceLabel.text = message
        guidanceLabel.isHidden = camera.state == .running && lastState?.poseDetected == true
        pauseButton.isEnabled = lastState?.isFinished != true
            && camera.state != .requestingPermission && camera.state != .starting && camera.state != .switching
        cameraSwitchButton.isEnabled = cameraCoordinator.canSwitchCamera
        cameraSwitchButton.accessibilityValue = camera.position == .front ? "Фронтальная камера" : "Задняя камера"
        cameraSwitchButton.accessibilityHint = camera.position == .front ? "Включить заднюю камеру" : "Включить фронтальную камеру"
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
