import AVFoundation
import UIKit

final class WorkoutViewController: UIViewController {
    private let viewModel: WorkoutViewModel
    private let camera: CameraService
    private let persistence: WorkoutPersistence
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
    private var lastPose: BodyPose?
    private var cameraStarted = false

    init(viewModel: WorkoutViewModel, camera: CameraService, persistence: WorkoutPersistence) {
        self.viewModel = viewModel
        self.camera = camera
        self.persistence = persistence
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        cameraView.previewLayer.session = camera.captureSession
        cameraView.previewLayer.videoGravity = .resizeAspectFill
        configureLayout()
        bindState()
        camera.onPose = { [weak self] pose in
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.lastPose = pose
                self.overlayView.render(pose, previewLayer: self.cameraView.previewLayer)
                self.viewModel.process(pose)
            }
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !cameraStarted else { return }
        cameraStarted = true
        Task { [weak self] in
            guard let self else { return }
            do {
                try await camera.start()
                if let connection = cameraView.previewLayer.connection,
                   connection.isVideoRotationAngleSupported(90) {
                    connection.videoRotationAngle = 90
                }
            } catch {
                cameraStarted = false
                presentMessage(title: "Камера недоступна", message: error.localizedDescription)
            }
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        overlayView.render(lastPose, previewLayer: cameraView.previewLayer)
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
            button.configuration = nil
            button.semanticContentAttribute = .forceLeftToRight
            button.imageEdgeInsets.right = 12
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
    }

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
            countLabel.text = "\(state.repetitions)"
            setLabel.text = "Подход \(state.currentSet) из \(state.targetSets)"
            timeLabel.text = String(format: "Время %02d:%02d", state.elapsedSeconds / 60, state.elapsedSeconds % 60)
            restLabel.text = state.isResting ? "Отдых \(state.remainingRestSeconds) сек" : "Цель \(state.targetRepetitions) повторений"
            pauseButton.setTitle(state.isPaused ? "Продолжить" : "Пауза", for: .normal)
            pauseButton.setImage(UIImage(systemName: state.isPaused ? "play.fill" : "pause.fill"), for: .normal)
            guidanceLabel.isHidden = state.poseDetected
            pauseButton.isEnabled = !state.isFinished
            finishButton.isEnabled = !state.isFinished
            if state.isFinished { camera.stop() }
        }
        viewModel.onFailure = { [weak self] message in
            self?.presentMessage(title: "Сохранение", message: message)
        }
    }

    private func presentMessage(title: String, message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "ОК", style: .default))
        present(alert, animated: true)
    }

    @objc private func openHistory() {
        let controller = WorkoutHistoryViewController(persistence: persistence)
        present(UINavigationController(rootViewController: controller), animated: true)
    }

    @objc private func togglePause() { viewModel.togglePause() }

    @objc private func finishWorkout() {
        viewModel.finish()
        presentMessage(title: "Тренировка завершена", message: "Результат сохранён в истории, если хранилище доступно.")
    }
}
