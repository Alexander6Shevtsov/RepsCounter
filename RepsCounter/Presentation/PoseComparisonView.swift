//
//  PoseComparisonView.swift
//  RepsCounter
//
//  Maintainer: Alexander Shevtsov
//  Copyright © 2026 Alexander Shevtsov.

#if DEBUG
import UIKit

enum PoseComparisonDisplayMode: Int {
    case compact
    case detailed
}

final class PoseComparisonView: UIVisualEffectView {
    private enum DisplayedLeg: CaseIterable, Equatable {
        case automatic
        case left
        case right
    }

    private struct ControlsState: Equatable {
        let recording: Bool
        let hasSeries: Bool
        let viewpoint: ExperimentViewpoint
        let displayedLeg: DisplayedLeg
        let workoutDescription: String
    }

    var onClose: (() -> Void)?
    var onSeries: (() -> Void)?
    var onAnnotate: (() -> Void)?
    var onViewpoint: ((ExperimentViewpoint) -> Void)?
    var onDisplayModeChange: ((PoseComparisonDisplayMode) -> Void)?
    private(set) var displayMode = PoseComparisonDisplayMode.compact
    private let modeControl = UISegmentedControl(items: ["Кратко", "Подробно"])
    private let modeMenuButton = UIButton(type: .system)
    private let compactStack = UIStackView()
    private let textLabel = UILabel()
    private let detailsScroll = UIScrollView()
    private let summaryLabel = UILabel()
    private let statusLabel = UILabel()
    private let planarLabel = UILabel()
    private let spatialLabel = UILabel()
    private let ratesLabel = UILabel()
    private let coverageLabel = UILabel()
    private let reasonLabel = UILabel()
    private let seriesButton = UIButton(type: .system)
    private let settingsButton = UIButton(type: .system)
    private let closeButton = UIButton(type: .system)
    private weak var currentModel: PoseComparisonViewModel?
    private var cameraPosition: CameraPosition?
    private var cameraState: CameraState?
    private var workoutState: WorkoutViewState?
    private var displayedLeg = DisplayedLeg.automatic
    private var controlsState: ControlsState?

    init() {
        super.init(effect: UIBlurEffect(style: .systemThickMaterialDark))
        accessibilityIdentifier = "poseComparisonPanel"
        accessibilityHint = "Статус Vision 3D относится к позе. Критерий полного приседа не определён."
        layer.cornerRadius = 14
        clipsToBounds = true
        isHidden = true
        configureLayout()
        refreshTypography()
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (view: PoseComparisonView, previous: UITraitCollection) in
            view.refreshTypography()
            view.refreshContent()
        }
        updateDisplayMode()
    }

    required init?(coder: NSCoder) { nil }

    func render(_ model: PoseComparisonViewModel, cameraPosition: CameraPosition? = nil, workoutState: WorkoutViewState? = nil,
                cameraState: CameraState? = nil) {
        currentModel = model
        self.cameraPosition = cameraPosition
        self.workoutState = workoutState
        self.cameraState = cameraState
        let seriesTitle: String
        if traitCollection.preferredContentSizeCategory.isAccessibilityCategory {
            seriesTitle = model.isRecording ? "Стоп серии" : "Старт серии"
        } else {
            seriesTitle = model.isRecording ? "Завершить серию" : "Начать серию"
        }
        configureTitle(seriesTitle, for: seriesButton)
        seriesButton.accessibilityLabel = model.isRecording ? "Завершить контрольную серию" : "Начать контрольную серию"
        seriesButton.isEnabled = model.isRecording || model.canStartSeries
        refreshMenu(model)
        if displayMode == .compact { renderCompact(model) }
        else { renderDetails(model) }
    }

    func selectHUDLeg(_ selectedLeg: BodyLeg) {
        displayedLeg = selectedLeg == .left ? .left : .right
        refreshContent()
    }

    func selectViewpoint(_ viewpoint: ExperimentViewpoint) {
        guard currentModel?.isRecording == false else { return }
        onViewpoint?(viewpoint)
        refreshContent()
    }

    func selectDisplayMode(_ nextMode: PoseComparisonDisplayMode) {
        guard displayMode != nextMode else { return }
        displayMode = nextMode
        updateDisplayMode()
        refreshContent()
        onDisplayModeChange?(nextMode)
    }

    private func configureLayout() {
        modeControl.selectedSegmentIndex = displayMode.rawValue
        modeControl.accessibilityIdentifier = "poseComparisonModeControl"
        modeControl.accessibilityLabel = "Режим диагностики"
        modeControl.addTarget(self, action: #selector(changeDisplayMode), for: .valueChanged)
        modeControl.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        modeMenuButton.accessibilityIdentifier = "poseComparisonModeMenuButton"
        modeMenuButton.accessibilityLabel = "Режим диагностики"
        modeMenuButton.showsMenuAsPrimaryAction = true
        closeButton.setImage(UIImage(systemName: "chevron.left"), for: .normal)
        closeButton.accessibilityLabel = "К диагностике 2D"
        closeButton.accessibilityIdentifier = "poseComparisonCloseButton"
        closeButton.addTarget(self, action: #selector(closePanel), for: .touchUpInside)
        closeButton.widthAnchor.constraint(equalToConstant: 44).isActive = true
        seriesButton.accessibilityIdentifier = "poseComparisonSeriesButton"
        seriesButton.addTarget(self, action: #selector(toggleSeries), for: .touchUpInside)
        settingsButton.setImage(UIImage(systemName: "ellipsis.circle"), for: .normal)
        settingsButton.accessibilityIdentifier = "poseComparisonSettingsButton"
        settingsButton.accessibilityLabel = "Ракурс, ручная оценка и параметры HUD"
        settingsButton.showsMenuAsPrimaryAction = true
        settingsButton.widthAnchor.constraint(equalToConstant: 44).isActive = true
        for button in [closeButton, seriesButton, settingsButton, modeMenuButton] {
            button.tintColor = .systemCyan
            button.titleLabel?.adjustsFontForContentSizeCategory = true
            button.titleLabel?.numberOfLines = 0
            button.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        }
        let header = UIStackView(arrangedSubviews: [closeButton, modeControl, modeMenuButton])
        header.spacing = 6
        let actions = UIStackView(arrangedSubviews: [seriesButton, settingsButton])
        actions.spacing = 6
        compactStack.axis = .vertical
        compactStack.spacing = 2
        compactStack.accessibilityIdentifier = "poseComparisonCompactHUD"
        let labels = [summaryLabel, statusLabel, planarLabel, spatialLabel, ratesLabel, coverageLabel, reasonLabel]
        let identifiers = ["Summary", "Status", "Planar", "Spatial", "Rates", "Coverage", "Reason"]
        for (label, identifier) in zip(labels, identifiers) {
            label.textColor = .white
            label.numberOfLines = 0
            label.adjustsFontForContentSizeCategory = true
            label.accessibilityIdentifier = "poseHUD" + identifier
            label.setContentCompressionResistancePriority(.required, for: .vertical)
            compactStack.addArrangedSubview(label)
        }
        statusLabel.lineBreakMode = .byCharWrapping
        textLabel.textColor = .white
        textLabel.numberOfLines = 0
        textLabel.adjustsFontForContentSizeCategory = true
        textLabel.accessibilityIdentifier = "poseComparisonText"
        textLabel.translatesAutoresizingMaskIntoConstraints = false
        detailsScroll.accessibilityIdentifier = "poseComparisonDetailsScroll"
        detailsScroll.addSubview(textLabel)
        NSLayoutConstraint.activate([
            textLabel.topAnchor.constraint(equalTo: detailsScroll.contentLayoutGuide.topAnchor),
            textLabel.bottomAnchor.constraint(equalTo: detailsScroll.contentLayoutGuide.bottomAnchor),
            textLabel.leadingAnchor.constraint(equalTo: detailsScroll.contentLayoutGuide.leadingAnchor),
            textLabel.trailingAnchor.constraint(equalTo: detailsScroll.contentLayoutGuide.trailingAnchor),
            textLabel.widthAnchor.constraint(equalTo: detailsScroll.frameLayoutGuide.widthAnchor)
        ])
        let contents = UIStackView(arrangedSubviews: [header, compactStack, detailsScroll, actions])
        contents.axis = .vertical
        contents.spacing = 6
        contents.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(contents)
        NSLayoutConstraint.activate([
            contents.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 8),
            contents.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -8),
            contents.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 12),
            contents.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -12)
        ])
    }

    private func refreshTypography() {
        let compactFont = UIFont.preferredFont(forTextStyle: .caption2, compatibleWith: traitCollection)
        for label in [summaryLabel, statusLabel, planarLabel, spatialLabel, ratesLabel, coverageLabel, reasonLabel] {
            label.font = compactFont
        }
        textLabel.font = .preferredFont(forTextStyle: .caption1, compatibleWith: traitCollection)
        modeControl.setTitleTextAttributes([.font: compactFont], for: .normal)
        let accessibleSize = traitCollection.preferredContentSizeCategory.isAccessibilityCategory
        modeControl.isHidden = accessibleSize
        modeMenuButton.isHidden = !accessibleSize
        refreshModeMenu()
    }

    private func configureTitle(_ title: String, for button: UIButton) {
        var configuration = UIButton.Configuration.plain()
        configuration.baseForegroundColor = .systemCyan
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 4, bottom: 4, trailing: 4)
        var attributes = AttributeContainer()
        attributes[AttributeScopes.UIKitAttributes.FontAttribute.self] = UIFont.preferredFont(forTextStyle: .caption2, compatibleWith: traitCollection)
        configuration.attributedTitle = AttributedString(title, attributes: attributes)
        button.configuration = configuration
        button.invalidateIntrinsicContentSize()
        button.setNeedsLayout()
    }

    private func refreshModeMenu() {
        let title = displayMode == .compact ? "Кратко" : "Подробно"
        configureTitle(title + " ▾", for: modeMenuButton)
        modeMenuButton.accessibilityValue = title
        modeMenuButton.menu = UIMenu(children: [
            UIAction(title: "Кратко", state: displayMode == .compact ? .on : .off) { [weak self] _ in self?.selectDisplayMode(.compact) },
            UIAction(title: "Подробно", state: displayMode == .detailed ? .on : .off) { [weak self] _ in self?.selectDisplayMode(.detailed) }
        ])
    }

    private func refreshContent() {
        guard let currentModel else { return }
        render(currentModel, cameraPosition: cameraPosition, workoutState: workoutState, cameraState: cameraState)
    }

    private func updateDisplayMode() {
        compactStack.isHidden = displayMode != .compact
        detailsScroll.isHidden = displayMode != .detailed
        modeControl.selectedSegmentIndex = displayMode.rawValue
        accessibilityValue = displayMode == .compact ? "Кратко" : "Подробно"
        refreshModeMenu()
        invalidateIntrinsicContentSize()
        setNeedsLayout()
    }

    private func renderCompact(_ model: PoseComparisonViewModel) {
        let freshPair = model.isLatestPairFresh ? model.latestPair : nil
        let freshPlanar = model.isLatestPlanarFresh ? model.latestPlanar : nil
        let position = cameraPosition ?? freshPair?.source.metadata.position ?? freshPlanar?.metadata.position
        let viewpoint = model.isRecording ? model.series.last?.viewpoint ?? model.selectedViewpoint : model.selectedViewpoint
        let accessibleSize = traitCollection.preferredContentSizeCategory.isAccessibilityCategory
        if accessibleSize {
            let cameraName: String
            switch position {
            case .front: cameraName = "Фр."
            case .back: cameraName = "Зад."
            case nil: cameraName = "—"
            }
            summaryLabel.text = "×\(model.productionRepetitions) \(cameraName) \(viewpointText(viewpoint))"
        } else {
            summaryLabel.text = "Счёт \(model.productionRepetitions) · \(cameraText(position)) · \(viewpointText(viewpoint))"
        }
        summaryLabel.accessibilityLabel = "Рабочий счётчик: \(model.productionRepetitions). Камера: \(cameraText(position)). Ракурс: \(viewpointText(viewpoint))."
        let analysis = freshPair?.source.analysis ?? freshPlanar?.analysis
        let selectedLeg = effectiveLeg
        planarLabel.text = anglesText("2D", left: analysis?.leftUsable == true ? analysis?.leftAngle : nil,
                                      right: analysis?.rightUsable == true ? analysis?.rightAngle : nil, selectedLeg: selectedLeg)
        spatialLabel.text = anglesText("3D", left: freshPair?.spatial.leftLeg.angle, right: freshPair?.spatial.rightLeg.angle, selectedLeg: selectedLeg)
        let status = recognitionStatus(freshPair)
        statusLabel.text = "3D: " + (accessibleSize && status.status == "нет актуальных данных" ? "нет данных" : status.status)
        statusLabel.accessibilityLabel = "Vision 3D: " + status.status
        reasonLabel.text = (accessibleSize ? "" : "Причина: ") + (status.reason ?? "—")
        reasonLabel.isHidden = status.reason == nil
        let counters = model.statistics
        let planarRate = model.hasRateMeasurement && counters.analyzed2D > 0 ? number(model.planarFPS, decimals: 1) : "—"
        let spatialRate = model.hasRateMeasurement && counters.completed3D > 0 ? number(model.spatialFPS, decimals: 1) : "—"
        ratesLabel.text = accessibleSize ? "FPS \(planarRate)/\(spatialRate)" : "FPS 2D \(planarRate) · 3D \(spatialRate)"
        ratesLabel.accessibilityLabel = "Средняя частота обработки 2D: \(planarRate). 3D: \(spatialRate)."
        let coverage = counters.analyzed2D > 0 ? number(counters.coverage * 100, decimals: 0) + "%" : "—"
        let latency = freshPair.map { number($0.totalLatency * 1000, decimals: 0) + " мс" } ?? "—"
        coverageLabel.text = accessibleSize ? "C\(coverage) Δ\(latency)" : "Coverage \(coverage) · 3D Δ \(latency)"
        coverageLabel.accessibilityLabel = "Покрытие сопоставимых измерений: \(coverage). Задержка 3D от получения кадра до результата: \(latency)."
    }

    private var effectiveLeg: DisplayedLeg {
        if displayedLeg == .automatic, traitCollection.preferredContentSizeCategory.isAccessibilityCategory { return .left }
        return displayedLeg
    }

    private func anglesText(_ method: String, left: Double?, right: Double?, selectedLeg: DisplayedLeg) -> String {
        switch selectedLeg {
        case .automatic: return "\(method) Л \(angle(left)) · П \(angle(right))"
        case .left: return "\(method) Л \(angle(left))"
        case .right: return "\(method) П \(angle(right))"
        }
    }

    private func recognitionStatus(_ pair: PoseComparisonPair?) -> (status: String, reason: String?) {
        guard let pair else {
            let reason: String
            if let cameraReason { reason = cameraReason }
            else if let workoutState, workoutState.isResting { reason = "Отдых \(workoutState.remainingRestSeconds) с" }
            else if workoutState?.isFinished == true { reason = "Завершено" }
            else if workoutState?.isPaused == true { reason = "Пауза" }
            else { reason = "Ожидание кадра" }
            return ("нет актуальных данных", reason)
        }
        if let issue = pair.detection.issue { return issueStatus(issue) }
        let measurements = [pair.spatial.leftLeg, pair.spatial.rightLeg]
        if let issue = measurements.compactMap(\.issue).first { return issueStatus(issue) }
        return ("распознаётся", nil)
    }

    private func issueStatus(_ issue: Pose3DIssue) -> (status: String, reason: String?) {
        switch issue {
        case .noBody: return ("noBody", "Тело не найдено")
        case .missingJoint: return ("missingJoint", "Нет суставов")
        case .visionError: return ("visionError", "Ошибка Vision")
        case .unsupportedRevision: return ("unsupportedRevision", "API недоступен")
        case .invalidGeometry: return ("нет актуальных данных", "Ошибка точек")
        case .cancelled: return ("нет актуальных данных", "Запрос отменён")
        }
    }

    private var cameraReason: String? {
        switch cameraState {
        case .permissionDenied: return "Нет доступа"
        case .requestingPermission: return "Запрос доступа"
        case .starting: return "Запуск камеры"
        case .switching: return "Смена камеры"
        case .interrupted: return "Прерывание"
        case .failed: return "Ошибка камеры"
        case .stopped: return "Пауза"
        case .finished: return "Завершено"
        case .idle: return "Ждём камеру"
        case .running, nil: return nil
        }
    }

    private func refreshMenu(_ model: PoseComparisonViewModel) {
        let description: String
        if let workoutState {
            description = String(format: "Подход %d/%d · %02d:%02d", workoutState.currentSet, workoutState.targetSets,
                                 workoutState.elapsedSeconds / 60, workoutState.elapsedSeconds % 60)
        } else { description = "Данные тренировки: —" }
        let nextState = ControlsState(recording: model.isRecording, hasSeries: !model.series.isEmpty,
                                      viewpoint: model.selectedViewpoint, displayedLeg: displayedLeg, workoutDescription: description)
        guard controlsState != nextState else { return }
        controlsState = nextState
        let viewpointActions = [ExperimentViewpoint.frontal, .diagonal, .side].map { viewpoint in
            UIAction(title: viewpointText(viewpoint), attributes: model.isRecording ? .disabled : [],
                     state: model.selectedViewpoint == viewpoint ? .on : .off) { [weak self] _ in
                self?.selectViewpoint(viewpoint)
            }
        }
        let legActions = DisplayedLeg.allCases.map { selectedLeg in
            let title: String
            switch selectedLeg {
            case .automatic: title = "Авто: обе / левая при крупном тексте"
            case .left: title = "Левая нога"
            case .right: title = "Правая нога"
            }
            return UIAction(title: title, state: displayedLeg == selectedLeg ? .on : .off) { [weak self] _ in
                self?.displayedLeg = selectedLeg
                self?.refreshContent()
            }
        }
        let annotation = UIAction(title: "Ручная оценка серии", identifier: UIAction.Identifier("poseComparisonAnnotation"),
                                  attributes: model.isRecording || model.series.isEmpty ? .disabled : []) { [weak self] _ in self?.onAnnotate?() }
        settingsButton.menu = UIMenu(children: [
            UIMenu(title: "Ракурс: " + viewpointText(model.selectedViewpoint), children: viewpointActions),
            UIMenu(title: "Нога в HUD", children: legActions), annotation,
            UIAction(title: description, attributes: .disabled) { _ in }
        ])
    }

    private func cameraText(_ position: CameraPosition?) -> String {
        switch position {
        case .front: return "Фронт."
        case .back: return "Задняя"
        case nil: return "—"
        }
    }

    private func viewpointText(_ viewpoint: ExperimentViewpoint) -> String {
        switch viewpoint {
        case .frontal: return "Лицом"
        case .diagonal: return "45°"
        case .side: return "Боком"
        case .unspecified: return "—"
        }
    }

    private func renderDetails(_ model: PoseComparisonViewModel) {
        let counters = model.statistics
        var lines = [
            "ЭКСПЕРИМЕНТ 2D / 3D · DEBUG",
            "Рабочий 2D: \(model.productionRepetitions)",
            "3D: — · полный присед не определён",
            "2D эксперимента: \(model.latestPlanar?.analysis.repetitions ?? 0) · отдельный счётчик",
            model.isAvailable ? "3D ≤2 Гц · одна операция · предел возраста 750 мс" : "Экспериментальный источник недоступен",
            "Кадры: вход \(counters.sourceFrames), 2D \(counters.analyzed2D), ответов 3D \(counters.completed3D), сопоставимых пар \(counters.comparablePairs)",
            "Пригодны: 2D \(counters.usable2D), 3D \(counters.usable3D) · coverage \(Int(counters.coverage * 100))%",
            String(format: "FPS 2D %.1f · 3D %.1f · пригодных 3D %.1f", model.planarFPS, model.spatialFPS, model.usableFPS),
            "Пропуски: частота \(counters.rateLimited), занят \(counters.busyDropped), захват \(counters.captureDropped)",
            "Устарели \(counters.staleDropped), отменены \(counters.cancelled), тайм-ауты \(counters.timeouts), доставка \(counters.deliveryDropped), вход \(counters.invalidInput), UI-отказ \(model.rejectedResults)"
        ]
        if let cameraReason { lines.append("Камера: " + cameraReason) }
        if case .failed(let message) = cameraState { lines.append(message) }
        if let pair = model.latestPair {
            let metadata = pair.source.metadata
            lines += [
                "ПОСЛЕДНЯЯ ПАРА · \(model.isLatestPairFresh ? "актуальна" : "устарела")",
                pair.isComparable ? "Есть пригодные углы одной и той же ноги обоих методов" : "Нет пригодных углов одной ноги обоих методов; сравнение недоступно",
                "Кадр \(metadata.identity.generation):\(metadata.identity.sequence) · \(metadata.position == .front ? "front" : "back")",
                String(format: "PTS %.3f с · поворот %.0f° · EXIF %u", metadata.timestamp, metadata.rotationAngle, metadata.orientation),
                "2D Л \(angle(pair.source.analysis.leftAngle)) \(pair.source.analysis.leftUsable ? "✓" : "✕") · П \(angle(pair.source.analysis.rightAngle)) \(pair.source.analysis.rightUsable ? "✓" : "✕")",
                "3D Л \(angle(pair.spatial.leftLeg.angle)) · П \(angle(pair.spatial.rightLeg.angle))",
                "2D: \(pair.source.analysis.phase) / \(pair.source.analysis.decision)",
                "3D: \(pair.spatial.phase.rawValue) / \(pair.spatial.decision.rawValue)",
                String(format: "Обработка 2D %.0f мс · 3D %.0f мс", pair.source.latency * 1000, pair.latency * 1000),
                String(format: "Получение → готовность 3D: %.0f мс", pair.totalLatency * 1000),
                "3D отказ: \(pair.detection.issue?.rawValue ?? "нет") · Л \(pair.spatial.leftLeg.issue?.rawValue ?? "нет") · П \(pair.spatial.rightLeg.issue?.rawValue ?? "нет")",
                "ΔY hip−knee (model): Л \(number(pair.spatial.leftLeg.hipMinusKneeModelY)) · П \(number(pair.spatial.rightLeg.hipMinusKneeModelY)) м",
                "ΔY / бедро: Л \(number(pair.spatial.leftLeg.normalizedHipOffset)) · П \(number(pair.spatial.rightLeg.normalizedHipOffset))",
                "Depth data: \(metadata.depthDataProvided ? "переданы" : "приложением не переданы")",
                "Оценка роста: \(pair.detection.pose?.heightEstimation.rawValue ?? "—") · revision \(pair.detection.pose?.requestRevision.description ?? "—")",
                "3D confidence суставов: API не предоставляет",
                "Один кадр ≠ доказательство одного человека. В кадре должен быть один участник."
            ]
            if let detail = pair.detection.detail { lines.append(detail) }
        } else {
            lines.append("Ожидание парного наблюдения; камера и тренировка должны быть активны.")
        }
        if let series = model.series.last {
            lines.append("Серия: \(model.isRecording ? "идёт" : "завершена") · \(series.viewpoint.rawValue) · пар \(series.pairs.count), вытеснено \(series.evictedPairs)")
            if let endCount = series.productionEndCount {
                lines.append("Рабочий 2D за серию: \(endCount - series.productionStartCount)")
            }
            if let annotation = series.annotation {
                lines.append("РУЧНАЯ: полных \(annotation.fullRepetitions), неполных \(annotation.partialRepetitions), спорных \(annotation.uncertainRepetitions)")
            } else {
                lines.append("Ручная оценка не введена. Vision её не заполняет.")
            }
        }
        lines.append("ΔY сустава не равна глубине тазобедренного сгиба. 3D-пороги не валидированы. Видео и изображения не сохраняются; числа только в памяти.")
        textLabel.text = lines.joined(separator: "\n\n")
    }

    private func angle(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "—" }
        return String(format: "%.1f°", value)
    }

    private func number(_ value: Double?, decimals: Int = 3) -> String {
        guard let value, value.isFinite else { return "—" }
        return String(format: "%.*f", decimals, value)
    }

    @objc private func closePanel() { onClose?() }
    @objc private func toggleSeries() { onSeries?() }
    @objc private func changeDisplayMode() {
        guard let nextMode = PoseComparisonDisplayMode(rawValue: modeControl.selectedSegmentIndex) else { return }
        selectDisplayMode(nextMode)
    }
}
#endif
