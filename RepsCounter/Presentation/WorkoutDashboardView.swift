//
//  WorkoutDashboardView.swift
//  RepsCounter
//
//  Maintainer: Alexander Shevtsov
//  Copyright © 2026 Alexander Shevtsov.

import UIKit

@MainActor
enum WorkoutAppearance {
    static let accent = UIColor(red: 0.22, green: 0.40, blue: 1, alpha: 1)
    static let surface = UIColor(red: 0.035, green: 0.045, blue: 0.075, alpha: 0.78)
    static let background = UIColor(red: 0.035, green: 0.045, blue: 0.075, alpha: 1)
    static let historySurface = UIColor(red: 0.085, green: 0.105, blue: 0.16, alpha: 1)

    static func label(_ identifier: String, style: UIFont.TextStyle) -> UILabel {
        let label = UILabel()
        label.accessibilityIdentifier = identifier
        label.font = .preferredFont(forTextStyle: style)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = .white
        label.numberOfLines = 0
        label.setContentCompressionResistancePriority(.required, for: .vertical)
        return label
    }

    static func surfaceView() -> UIVisualEffectView {
        let surface = UIVisualEffectView(effect: UIBlurEffect(style: .systemThinMaterialDark))
        surface.contentView.backgroundColor = Self.surface
        surface.layer.cornerRadius = 20
        surface.layer.cornerCurve = .continuous
        surface.layer.borderWidth = 1
        surface.layer.borderColor = UIColor.white.withAlphaComponent(0.14).cgColor
        surface.clipsToBounds = true
        return surface
    }
}

final class WorkoutDashboardView: UIView {
    var onPause: (() -> Void)?
    var onFinish: (() -> Void)?
    var onHistory: (() -> Void)?
    var onSwitch: (() -> Void)?
    let controls = UIStackView()
    let toolbar = UIStackView()
    private let scrollView = UIScrollView()
    private let contentStack = UIStackView()
    private let cardsStack = UIStackView()
    private let summaryStack = UIStackView()
    private let countLabel = WorkoutAppearance.label("workoutCount", style: .largeTitle)
    private let exerciseLabel = WorkoutAppearance.label("workoutExercise", style: .title2)
    private let setLabel = WorkoutAppearance.label("workoutSet", style: .headline)
    private let timeLabel = WorkoutAppearance.label("workoutTime", style: .headline)
    private let goalLabel = WorkoutAppearance.label("workoutGoal", style: .headline)
    private let totalLabel = WorkoutAppearance.label("workoutTotal", style: .headline)
    private let statusLabel = WorkoutAppearance.label("workoutStatus", style: .headline)
    private let titleLabel = WorkoutAppearance.label("workoutTitle", style: .headline)
    private let restLabel = WorkoutAppearance.label("workoutRest", style: .headline)
    private var restCard: UIView?
    private let guidanceCard = WorkoutAppearance.surfaceView()
    private let guidanceLabel = WorkoutAppearance.label("workoutGuidance", style: .subheadline)
    private let pauseButton = UIButton(type: .system)
    private let finishButton = UIButton(type: .system)
    private let historyButton = UIButton(type: .system)
    private let switchButton = UIButton(type: .system)
    private var narrowCards: NSLayoutConstraint?
    private var wideCards: NSLayoutConstraint?
    private var renderedState: WorkoutViewState?
    private var renderedCamera = CameraState.idle
    override init(frame: CGRect) {
        super.init(frame: frame)
        configureLayout()
        updateTypography()
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (view: WorkoutDashboardView, previous: UITraitCollection) in
            view.updateTypography()
            if let state = view.renderedState { view.render(state, cameraState: view.renderedCamera) }
        }
    }

    required init?(coder: NSCoder) { nil }

    func render(_ state: WorkoutViewState, cameraState: CameraState) {
        renderedState = state
        renderedCamera = cameraState
        countLabel.text = "\(state.repetitions)"
        countLabel.accessibilityLabel = "Повторений в подходе: \(state.repetitions)"
        setLabel.text = "\(state.currentSet) из \(state.targetSets)"
        goalLabel.text = "\(state.targetRepetitions) повторений"
        timeLabel.text = String(format: "%02d:%02d", state.elapsedSeconds / 60, state.elapsedSeconds % 60)
        totalLabel.text = "\(state.totalRepetitions)"
        restLabel.text = String(format: "%02d:%02d", state.remainingRestSeconds / 60, state.remainingRestSeconds % 60)
        restCard?.isHidden = !state.isResting
        let message = presentation(state, cameraState: cameraState)
        statusLabel.text = message.status
        guidanceLabel.text = message.detail
        guidanceCard.isHidden = message.detail.isEmpty
        setButton(pauseButton, title: state.isPaused ? "Продолжить" : "Пауза", symbol: state.isPaused ? "play.fill" : "pause.fill", primary: true)
        pauseButton.isEnabled = !state.isFinished && cameraState != .requestingPermission && cameraState != .starting && cameraState != .switching
        let finishTitle: String
        switch state.saveState {
        case .notSaved: finishTitle = "Завершить"
        case .saving: finishTitle = "Сохранение…"
        case .saved: finishTitle = "Завершено"
        case .failed: finishTitle = "Повторить"
        }
        setButton(finishButton, title: finishTitle, symbol: state.saveState == .saved ? "checkmark" : "stop.fill", primary: false)
        finishButton.isEnabled = !state.isFinished
        if case .failed = state.saveState { finishButton.isEnabled = true }
    }

    func updateCameraControl(canSwitch: Bool, position: CameraPosition) {
        switchButton.isEnabled = canSwitch
        switchButton.accessibilityValue = position == .front ? "Фронтальная камера" : "Задняя камера"
        switchButton.accessibilityHint = position == .front ? "Включить заднюю камеру" : "Включить фронтальную камеру"
    }

    #if DEBUG
    func setDiagnosticsVisible(_ visible: Bool) { scrollView.isHidden = visible }
    #endif

    private func configureLayout() {
        iconButton(historyButton, symbol: "clock.arrow.circlepath", identifier: "workoutHistoryButton", title: "История тренировок", action: #selector(openHistory))
        iconButton(switchButton, symbol: "arrow.triangle.2.circlepath.camera", identifier: "cameraSwitchButton", title: "Переключить камеру", action: #selector(switchCamera))
        let title = titleLabel
        title.text = "Тренировка"
        title.textAlignment = .center
        title.accessibilityTraits = .header
        toolbar.addArrangedSubview(historyButton)
        toolbar.addArrangedSubview(title)
        toolbar.addArrangedSubview(switchButton)
        toolbar.spacing = 12
        toolbar.alignment = .center
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        addSubview(toolbar)
        scrollView.accessibilityIdentifier = "workoutMetricsScroll"
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.alwaysBounceHorizontal = false
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)
        contentStack.axis = .vertical
        contentStack.spacing = 14
        contentStack.alignment = .leading
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(contentStack)
        exerciseLabel.text = "Приседания"
        exerciseLabel.accessibilityTraits = .header
        let caption = WorkoutAppearance.label("workoutCountCaption", style: .subheadline)
        caption.text = "Повторения в подходе"
        let hero = UIStackView(arrangedSubviews: [countLabel, caption, exerciseLabel])
        hero.axis = .vertical
        hero.spacing = 2
        contentStack.addArrangedSubview(hero)
        cardsStack.axis = .vertical
        cardsStack.spacing = 10
        cardsStack.addArrangedSubview(card(title: "Подход", symbol: "dumbbell.fill", value: setLabel))
        cardsStack.addArrangedSubview(card(title: "Цель подхода", symbol: "scope", value: goalLabel))
        cardsStack.addArrangedSubview(card(title: "Статус", symbol: "waveform.path.ecg", value: statusLabel))
        let rest = card(title: "Осталось отдыха", symbol: "timer", value: restLabel)
        restCard = rest
        cardsStack.addArrangedSubview(rest)
        contentStack.addArrangedSubview(cardsStack)
        summaryStack.spacing = 10
        summaryStack.distribution = .fillEqually
        summaryStack.addArrangedSubview(card(title: "Активное время", symbol: "clock", value: timeLabel))
        summaryStack.addArrangedSubview(card(title: "Всего повторений", symbol: "arrow.triangle.2.circlepath", value: totalLabel))
        contentStack.addArrangedSubview(summaryStack)
        let guidance = guidanceCard
        guidance.contentView.addSubview(guidanceLabel)
        guidanceLabel.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            guidanceLabel.topAnchor.constraint(equalTo: guidance.contentView.topAnchor, constant: 12),
            guidanceLabel.bottomAnchor.constraint(equalTo: guidance.contentView.bottomAnchor, constant: -12),
            guidanceLabel.leadingAnchor.constraint(equalTo: guidance.contentView.leadingAnchor, constant: 14),
            guidanceLabel.trailingAnchor.constraint(equalTo: guidance.contentView.trailingAnchor, constant: -14)
        ])
        contentStack.addArrangedSubview(guidance)
        for section in [hero, summaryStack, guidance] { section.widthAnchor.constraint(equalTo: contentStack.widthAnchor).isActive = true }
        narrowCards = cardsStack.widthAnchor.constraint(equalTo: contentStack.widthAnchor, multiplier: 0.64)
        wideCards = cardsStack.widthAnchor.constraint(equalTo: contentStack.widthAnchor)
        controls.accessibilityIdentifier = "workoutControls"
        controls.spacing = 10
        controls.distribution = .fillEqually
        controls.translatesAutoresizingMaskIntoConstraints = false
        pauseButton.accessibilityIdentifier = "workoutPauseButton"
        finishButton.accessibilityIdentifier = "workoutFinishButton"
        pauseButton.addTarget(self, action: #selector(togglePause), for: .touchUpInside)
        finishButton.addTarget(self, action: #selector(finishWorkout), for: .touchUpInside)
        for button in [pauseButton, finishButton] {
            button.heightAnchor.constraint(greaterThanOrEqualToConstant: 60).isActive = true
            button.setContentCompressionResistancePriority(.required, for: .vertical)
            controls.addArrangedSubview(button)
        }
        addSubview(controls)
        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor, constant: 10),
            toolbar.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor, constant: 20),
            toolbar.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor, constant: -20),
            scrollView.topAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: 14),
            scrollView.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor, constant: 20),
            scrollView.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor, constant: -20),
            scrollView.bottomAnchor.constraint(equalTo: controls.topAnchor, constant: -14),
            contentStack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            contentStack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor, constant: -8),
            contentStack.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            contentStack.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            contentStack.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor),
            controls.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor, constant: 20),
            controls.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor, constant: -20),
            controls.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.bottomAnchor, constant: -16)
        ])
    }

    private func card(title: String, symbol: String, value: UILabel) -> UIView {
        let surface = WorkoutAppearance.surfaceView()
        let caption = WorkoutAppearance.label("", style: .caption1)
        caption.text = title
        caption.textColor = UIColor.white.withAlphaComponent(0.8)
        let icon = UIImageView(image: UIImage(systemName: symbol))
        icon.tintColor = WorkoutAppearance.accent
        icon.contentMode = .scaleAspectFit
        icon.widthAnchor.constraint(equalToConstant: 22).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 22).isActive = true
        let texts = UIStackView(arrangedSubviews: [caption, value])
        texts.axis = .vertical
        texts.spacing = 4
        let row = UIStackView(arrangedSubviews: [icon, texts])
        row.alignment = .center
        row.spacing = 10
        row.translatesAutoresizingMaskIntoConstraints = false
        surface.contentView.addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: surface.contentView.topAnchor, constant: 12),
            row.bottomAnchor.constraint(equalTo: surface.contentView.bottomAnchor, constant: -12),
            row.leadingAnchor.constraint(equalTo: surface.contentView.leadingAnchor, constant: 12),
            row.trailingAnchor.constraint(equalTo: surface.contentView.trailingAnchor, constant: -12)
        ])
        return surface
    }

    private func iconButton(_ button: UIButton, symbol: String, identifier: String, title: String, action: Selector) {
        var configuration = UIButton.Configuration.filled()
        configuration.image = UIImage(systemName: symbol)
        configuration.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: 22, weight: .semibold)
        configuration.baseBackgroundColor = WorkoutAppearance.surface
        configuration.baseForegroundColor = .white
        configuration.background.cornerRadius = 16
        button.configuration = configuration
        button.accessibilityIdentifier = identifier
        button.accessibilityLabel = title
        button.widthAnchor.constraint(equalToConstant: 48).isActive = true
        button.heightAnchor.constraint(equalToConstant: 48).isActive = true
        button.addTarget(self, action: action, for: .touchUpInside)
    }

    private func setButton(_ button: UIButton, title: String, symbol: String, primary: Bool) {
        var configuration = UIButton.Configuration.filled()
        configuration.title = title
        configuration.image = UIImage(systemName: symbol)
        configuration.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: 20, weight: .semibold)
        configuration.imagePadding = 8
        configuration.baseForegroundColor = .white
        configuration.baseBackgroundColor = primary ? WorkoutAppearance.accent : WorkoutAppearance.surface
        configuration.background.cornerRadius = 20
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 16, leading: 12, bottom: 16, trailing: 12)
        var attributes = AttributeContainer()
        attributes[AttributeScopes.UIKitAttributes.FontAttribute.self] = UIFont.preferredFont(forTextStyle: .headline, compatibleWith: traitCollection)
        configuration.attributedTitle = AttributedString(title, attributes: attributes)
        configuration.titleLineBreakMode = .byWordWrapping
        button.configuration = configuration
        button.setTitle(title, for: .normal)
        button.accessibilityLabel = title
        button.titleLabel?.numberOfLines = 0
        button.titleLabel?.adjustsFontForContentSizeCategory = true
        button.invalidateIntrinsicContentSize()
        button.setNeedsLayout()
    }

    private func updateTypography() {
        countLabel.font = UIFontMetrics(forTextStyle: .largeTitle).scaledFont(for: .monospacedDigitSystemFont(ofSize: 86, weight: .bold), compatibleWith: traitCollection)
        exerciseLabel.font = .preferredFont(forTextStyle: .title2, compatibleWith: traitCollection)
        for label in [setLabel, timeLabel, goalLabel, totalLabel, statusLabel, restLabel] { label.font = .preferredFont(forTextStyle: .headline, compatibleWith: traitCollection) }
        guidanceLabel.font = .preferredFont(forTextStyle: .subheadline, compatibleWith: traitCollection)
        let largeText = traitCollection.preferredContentSizeCategory.isAccessibilityCategory
        titleLabel.isHidden = largeText
        toolbar.distribution = largeText ? .equalSpacing : .fill
        controls.axis = largeText ? .vertical : .horizontal
        summaryStack.axis = largeText ? .vertical : .horizontal
        narrowCards?.isActive = !largeText
        wideCards?.isActive = largeText
    }

    private func presentation(_ state: WorkoutViewState, cameraState: CameraState) -> (status: String, detail: String) {
        if state.isFinished {
            switch state.saveState {
            case .saved: return ("Сохранено", "Тренировка завершена. Результат сохранён в истории.")
            case .failed(let message): return ("Не сохранено", message + " Нажмите «Повторить».")
            case .saving: return ("Сохранение…", "Сохраняем результат тренировки.")
            case .notSaved: return ("Завершена", "Результат тренировки готов к сохранению.")
            }
        }
        switch cameraState {
        case .requestingPermission: return ("Доступ к камере", "Разрешите доступ к камере для начала тренировки.")
        case .permissionDenied: return ("Нет доступа", "Разрешите доступ к камере в настройках iPhone, вернитесь и нажмите «Продолжить».")
        case .idle, .starting: return ("Подготовка", "Подготовка камеры…")
        case .switching: return ("Смена камеры", "Переключение камеры…")
        case .interrupted: return ("Камера недоступна", "Камера временно недоступна. Тренировка на паузе.")
        case .failed: return ("Ошибка камеры", "Камера временно недоступна. Нажмите «Продолжить» для повтора.")
        case .stopped: return ("Пауза", "Тренировка на паузе. Нажмите «Продолжить».")
        case .running, .finished: break
        }
        if state.isPaused { return ("Пауза", "Подсчёт и активное время приостановлены.") }
        if state.isResting { return (String(format: "Отдых %02d:%02d", state.remainingRestSeconds / 60, state.remainingRestSeconds % 60), "Следующий подход начнётся после отдыха.") }
        return ("Идёт подход", state.poseDetected ? "" : "Встаньте боком к камере так, чтобы ноги были видны полностью")
    }

    @objc private func togglePause() { onPause?() }
    @objc private func finishWorkout() { onFinish?() }
    @objc private func openHistory() { onHistory?() }
    @objc private func switchCamera() { onSwitch?() }
}

final class WorkoutBackdropView: UIView {
    private let gradient = CAGradientLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        gradient.colors = [UIColor.black.withAlphaComponent(0.68).cgColor, UIColor.black.withAlphaComponent(0.52).cgColor,
                           UIColor.black.withAlphaComponent(0.72).cgColor]
        gradient.locations = [0, 0.55, 1]
        layer.addSublayer(gradient)
    }

    required init?(coder: NSCoder) { nil }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        gradient.frame = bounds
        CATransaction.commit()
    }
}
