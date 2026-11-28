//
//  WorkoutViewController.swift
//  RepsCounter
//
//  Maintainer: Alexander Shevtsov
//  Copyright © 2026 Alexander Shevtsov.

import AVFoundation
import UIKit
#if DEBUG
import UniformTypeIdentifiers
#endif

final class WorkoutViewController: UIViewController, UIAdaptivePresentationControllerDelegate {
    var onNewWorkout: (() -> Void)?
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
    private let poseReplayButton = UIButton(type: .system)
    #endif
    private var isExportingTrace = false
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
        if let telemetry = PipelineTelemetry.active {
            dashboard.historyButton.menu = UIMenu(children: [
                UIAction(title: "Сохранить трассу обработки", image: UIImage(systemName: "square.and.arrow.up")) { [weak self] _ in
                    self?.exportTrace(telemetry)
                }
            ])
        }
        #if DEBUG
        configureDiagnostics()
        configurePoseReplayCapture()
        #endif
    }

    private func exportTrace(_ telemetry: PipelineTelemetry) {
        guard !isExportingTrace else { return }
        isExportingTrace = true
        Task {
            defer { isExportingTrace = false }
            do {
                let url = try await telemetry.export()
                guard viewIfLoaded?.window != nil, presentedViewController == nil else {
                    try? FileManager.default.removeItem(at: url)
                    return
                }
                let share = UIActivityViewController(activityItems: [url], applicationActivities: nil)
                share.popoverPresentationController?.sourceView = dashboard.historyButton
                share.popoverPresentationController?.sourceRect = dashboard.historyButton.bounds
                share.completionWithItemsHandler = { _, _, _, _ in try? FileManager.default.removeItem(at: url) }
                present(share, animated: true)
            } catch {
                let alert = UIAlertController(title: "Не удалось сохранить трассу",
                                              message: error.localizedDescription, preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: "ОК", style: .default))
                present(alert, animated: true)
            }
        }
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
            diagnosticsView.leadingAnchor.constraint(greaterThanOrEqualTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 12),
            diagnosticsView.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -12),
            diagnosticsView.topAnchor.constraint(equalTo: dashboard.toolbar.bottomAnchor, constant: 8),
            diagnosticsView.bottomAnchor.constraint(lessThanOrEqualTo: dashboard.controls.topAnchor, constant: -12),
            diagnosticsView.widthAnchor.constraint(equalToConstant: 250),
            diagnosticsView.heightAnchor.constraint(equalToConstant: 170)
        ])
    }

    private func configurePoseReplayCapture() {
        poseReplayButton.titleLabel?.font = .systemFont(ofSize: 12, weight: .bold)
        poseReplayButton.backgroundColor = WorkoutAppearance.surface
        poseReplayButton.layer.cornerRadius = 16
        poseReplayButton.accessibilityIdentifier = "poseReplayCaptureButton"
        poseReplayButton.widthAnchor.constraint(equalToConstant: 44).isActive = true
        poseReplayButton.heightAnchor.constraint(equalToConstant: 48).isActive = true
        poseReplayButton.addTarget(
            self,
            action: #selector(togglePoseReplayCapture),
            for: .touchUpInside
        )
        poseReplayButton.menu = UIMenu(children: [
            UIAction(
                title: "Открыть Replay JSON",
                image: UIImage(systemName: "doc.text.magnifyingglass")
            ) { [weak self] _ in
                self?.openPoseReplayDocument()
            }
        ])
        dashboard.toolbar.insertArrangedSubview(poseReplayButton, at: 2)
        updatePoseReplayCaptureButton()
    }

    private func updatePoseReplayCaptureButton() {
        let isRecording = viewModel.isPoseReplayRecording
        poseReplayButton.setTitle(isRecording ? "STOP" : "REC", for: .normal)
        poseReplayButton.setTitleColor(isRecording ? .systemRed : .white, for: .normal)
        poseReplayButton.accessibilityLabel = isRecording
            ? "Остановить запись позы и экспортировать JSON"
            : "Начать запись числовых данных позы"
    }

    @objc private func togglePoseReplayCapture() {
        if viewModel.isPoseReplayRecording {
            if let archive = viewModel.stopDiagnosticRecording() {
                updatePoseReplayCaptureButton()
                Task { @MainActor [weak self] in
                    do {
                        let saved = try await archive.finished()
                        guard let self else { return }
                        guard saved.status.complete else {
                            self.showPoseReplayMessage("Запись неполная: \(saved.status.error ?? "ошибка записи"). Отклонено событий: \(saved.status.rejectedEvents). Файлы сохранены в контейнере приложения.")
                            return
                        }
                        let controller = UIActivityViewController(activityItems: [saved.pipelineURL, saved.replayURL], applicationActivities: nil)
                        controller.popoverPresentationController?.sourceView = self.poseReplayButton
                        controller.popoverPresentationController?.sourceRect = self.poseReplayButton.bounds
                        self.present(controller, animated: true)
                    } catch { self?.showPoseReplayMessage("Ошибка завершения диагностики: \(error.localizedDescription)") }
                }
                return
            }
            do {
                guard let data = try viewModel.stopPoseReplayRecording() else { return }
                updatePoseReplayCaptureButton()
                try sharePoseReplay(data)
            } catch {
                updatePoseReplayCaptureButton()
                showPoseReplayMessage("Не удалось экспортировать запись: \(error.localizedDescription)")
            }
            return
        }
        guard PipelineTelemetry.active != nil else {
            showPoseReplayMessage("Для полной записи включите REPS_PIPELINE_TRACE=1 в схеме Xcode и перезапустите приложение.")
            return
        }
        guard PipelineTelemetry.active?.lastRecordingArchive?.isClosed ?? true else {
            showPoseReplayMessage("Предыдущая запись ещё завершается. Дождитесь экспорта и повторите REC.")
            return
        }
        let consent = UIAlertController(
            title: "Запись данных позы",
            message: "Будут записаны координаты всех суставов, время камеры, диагностика обработки и вход счётчика. Это данные о движениях тела. Видео не сохраняется, JSON экспортируется только вручную. Записывайте после нажатия «Старт».",
            preferredStyle: .alert
        )
        consent.addAction(UIAlertAction(title: "Отмена", style: .cancel))
        consent.addAction(UIAlertAction(title: "Начать запись", style: .default) { [weak self] _ in
            guard let self else { return }
            if self.viewModel.startPoseReplayRecording() {
                self.updatePoseReplayCaptureButton()
            } else {
                self.showPoseReplayMessage("Сначала запустите тренировку кнопкой «Старт».")
            }
        })
        present(consent, animated: true)
    }

    private func openPoseReplayDocument() {
        guard !viewModel.isPoseReplayRecording else {
            showPoseReplayMessage("Сначала остановите запись кнопкой STOP.")
            return
        }
        let documentPicker = UIDocumentPickerViewController(
            forOpeningContentTypes: [.json],
            asCopy: true
        )
        documentPicker.delegate = self
        documentPicker.allowsMultipleSelection = false
        present(documentPicker, animated: true)
    }

    fileprivate func analyzePoseReplay(at url: URL) {
        let hasPermission = url.startAccessingSecurityScopedResource()
        defer {
            if hasPermission {
                url.stopAccessingSecurityScopedResource()
            }
        }
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            if let fileSize = attributes[.size] as? Int,
               fileSize > 10_000_000 {
                showPoseReplayMessage("JSON превышает максимальный размер 10 МБ.")
                return
            }
            let data = try Data(contentsOf: url)
            guard data.count <= 10_000_000 else {
                showPoseReplayMessage("JSON превышает максимальный размер 10 МБ.")
                return
            }
            if let trace = try? JSONDecoder().decode(PipelineTelemetry.Snapshot.self, from: data) {
                guard trace.events.contains(where: { $0.stage == .fullPoseInput }) else {
                    showPoseReplayMessage("В этой трассе нет полного потока координат до Live. Нужна новая запись эксперимента 54.")
                    return
                }
                let compared = try TimeBasedPoseProcessor.compare(trace.fullPoseSession())
                let scope = trace.archiveStatus?.complete == true
                    ? "Полный журнал REC. " : "Снимок кольца, вытеснено событий: \(trace.overwritten). "
                showPoseReplayMessage(scope + "Один сохранённый поток: Legacy \(compared.legacy.count), Time-based \(compared.timed.count). Без ручной разметки это числа событий, не точность.")
                return
            }
            let session = try JSONDecoder().decode(PoseReplaySession.self, from: data)
            let compared = try TimeBasedPoseProcessor.compare(session)
            let result = try PoseReplayBilateralRunner.replay(session, telemetry: PipelineTelemetry.active)
            let adaptive = try PoseReplayAdaptiveDepthAudit.replay(session)
            let graceful = try PoseReplayAdaptiveDepthAudit.replayWithGrace(session)
            let asymmetric = try PoseReplayAsymmetricDepthAudit.replay(session)
            let recovery = try PoseReplayOcclusionRecovery.replay(session)
            let recoveredTimes = recovery.supplementalAtSeconds.map { String(format: "%.2f", $0) }
            var summary = """
            Time-based (с первой стойки): \(compared.timed.count)
            Обычный 2D: \(result.baselineCountedAtSeconds.count)
            Левая нога: \(result.leftCountedAtSeconds.count)
            Правая нога: \(result.rightCountedAtSeconds.count)
            Объединено: \(result.combinedEvents.count)
            Убрано дублей: \(result.mergedDuplicateEvents)
            Адаптивный 2D (тень): \(adaptive.countedAtSeconds.count)
            Доп. кадров глубины: \(adaptive.assistedDepthFrames)
            Grace 2D (тень): \(graceful.countedAtSeconds.count)
            Удержано кадров ноги: \(graceful.heldLegFrames)
            Асимметрия 2D (тень): \(asymmetric.countedAtSeconds.count)
            Доп. кандидатов: \(asymmetric.supplementalAtSeconds.count)
            Восстановление при перекрытии: \(recovery.countedAtSeconds.count)
            """
            if !recoveredTimes.isEmpty {
                summary += "\nДобавлено на возврате (с от REC): " + recoveredTimes.joined(separator: ", ")
            }
            if session.initialState == nil {
                summary += "\nНачальная фаза до REC неизвестна (JSON v1)."
            } else if session.initialState?.selectedLeg != nil {
                summary += "\nОбычный 2D продолжает состояние на момент REC. Восстановление сохраняет базовые повторы. Для добавления нужна стойка после REC. Остальные теневые счётчики начинают с первой позы."
            }
            if session.annotations.isEmpty {
                summary += "\nНет ручной разметки: точность пока неизвестна."
            } else {
                let original = PoseReplayResult(
                    countedAtSeconds: result.baselineCountedAtSeconds,
                    depthSamples: []
                )
                let bilateral = PoseReplayResult(
                    countedAtSeconds: result.countedAtSeconds,
                    depthSamples: []
                )
                let adaptiveReplay = PoseReplayResult(
                    countedAtSeconds: adaptive.countedAtSeconds,
                    depthSamples: []
                )
                let graceReplay = PoseReplayResult(
                    countedAtSeconds: graceful.countedAtSeconds,
                    depthSamples: []
                )
                let asymmetricReplay = PoseReplayResult(
                    countedAtSeconds: asymmetric.countedAtSeconds,
                    depthSamples: []
                )
                let originalScore = try PoseReplayRunner.score(
                    original, against: session.annotations
                )
                let bilateralScore = try PoseReplayRunner.score(
                    bilateral, against: session.annotations
                )
                let adaptiveScore = try PoseReplayRunner.score(
                    adaptiveReplay, against: session.annotations
                )
                let graceScore = try PoseReplayRunner.score(
                    graceReplay, against: session.annotations
                )
                let asymmetricScore = try PoseReplayRunner.score(
                    asymmetricReplay, against: session.annotations
                )
                summary += "\nОбычный TP/FP/FN: \(originalScore.truePositives)/\(originalScore.falsePositives)/\(originalScore.falseNegatives)"
                summary += "\nДве ноги TP/FP/FN: \(bilateralScore.truePositives)/\(bilateralScore.falsePositives)/\(bilateralScore.falseNegatives)"
                summary += "\nАдаптивный TP/FP/FN: \(adaptiveScore.truePositives)/\(adaptiveScore.falsePositives)/\(adaptiveScore.falseNegatives)"
                summary += "\nGrace TP/FP/FN: \(graceScore.truePositives)/\(graceScore.falsePositives)/\(graceScore.falseNegatives)"
                summary += "\nАсимметрия TP/FP/FN: \(asymmetricScore.truePositives)/\(asymmetricScore.falsePositives)/\(asymmetricScore.falseNegatives)"
                let recoveryScore = try PoseReplayRunner.score(
                    PoseReplayResult(countedAtSeconds: recovery.countedAtSeconds, depthSamples: []),
                    against: session.annotations
                )
                summary += "\nВосстановление TP/FP/FN: \(recoveryScore.truePositives)/\(recoveryScore.falsePositives)/\(recoveryScore.falseNegatives)"
                let depthReport = try PoseReplayDepthAudit.evaluate(session)
                let angleOnly = depthReport.score(for: .kneeOnly)
                let projected = depthReport.score(for: .legacyProjected)
                let strictHeight = depthReport.score(for: .hipCenterBelowKnee)
                summary += "\nНиз по углу: полн. \(angleOnly.fullSatisfied), ложн. \(angleOnly.partialAccepted)"
                summary += "\nНиз по ТК 0,35: полн. \(projected.fullSatisfied), ложн. \(projected.partialAccepted)"
                summary += "\nНиз по высоте: полн. \(strictHeight.fullSatisfied), ложн. \(strictHeight.partialAccepted)"
                summary += "\nЭто проверка нижней фазы, не итоговые повторы."
            }
            summary += "\nВсе альтернативы только для Replay: счётчик тренировки не меняется."
            showPoseReplayMessage(summary)
        } catch {
            showPoseReplayMessage("Не удалось прочитать Replay JSON: \(error.localizedDescription)")
        }
    }

    private func sharePoseReplay(_ data: Data) throws {
        let exportURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("RepsCounter-PoseReplay-\(UUID().uuidString).json")
        try data.write(to: exportURL, options: .atomic)
        let share = UIActivityViewController(activityItems: [exportURL], applicationActivities: nil)
        share.popoverPresentationController?.sourceView = poseReplayButton
        share.popoverPresentationController?.sourceRect = poseReplayButton.bounds
        share.completionWithItemsHandler = { _, _, _, _ in
            try? FileManager.default.removeItem(at: exportURL)
        }
        present(share, animated: true)
    }

    private func showPoseReplayMessage(_ message: String) {
        let alert = UIAlertController(
            title: "Pose Replay",
            message: message,
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "ОК", style: .default))
        present(alert, animated: true)
    }

    @objc private func toggleDiagnostics() {
        diagnosticsView.isHidden.toggle()
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
        if lastState?.saveState == .saved {
            onNewWorkout?()
        } else if lastState?.isFinished == true {
            viewModel.retrySave()
        } else {
            cameraCoordinator.finish()
        }
    }
}

#if DEBUG
extension WorkoutViewController: UIDocumentPickerDelegate {
    func documentPicker(
        _ controller: UIDocumentPickerViewController,
        didPickDocumentsAt urls: [URL]
    ) {
        guard let selectedURL = urls.first else { return }
        analyzePoseReplay(at: selectedURL)
    }
}
#endif
