//
//  SceneDelegate.swift
//  RepsCounter
//
//  Maintainer: Alexander Shevtsov
//  Copyright © 2026 Alexander Shevtsov.

import UIKit

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    private let persistence = WorkoutPersistence()
    private weak var pendingNewWorkoutController: WorkoutViewController?
    private var isSceneActive = false

    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        guard let windowScene = scene as? UIWindowScene else { return }

        let applicationWindow = UIWindow(windowScene: windowScene)
        #if DEBUG
        let settings = CameraQualityViewController()
        settings.onStart = { [weak self] in
            guard let self else { return }
            self.window?.rootViewController = self.makeWorkoutController()
        }
        applicationWindow.rootViewController = settings
        #else
        applicationWindow.rootViewController = makeWorkoutController()
        #endif
        applicationWindow.overrideUserInterfaceStyle = .dark
        window = applicationWindow
        applicationWindow.makeKeyAndVisible()
    }

    func sceneDidEnterBackground(_ scene: UIScene) {
        isSceneActive = false
        (window?.rootViewController as? WorkoutViewController)?.cameraCoordinator.sceneDidEnterBackground()
    }

    func sceneDidBecomeActive(_ scene: UIScene) {
        isSceneActive = true
        if let pendingNewWorkoutController {
            self.pendingNewWorkoutController = nil
            replaceWorkoutController(replacing: pendingNewWorkoutController)
        } else {
            (window?.rootViewController as? WorkoutViewController)?.cameraCoordinator.sceneDidBecomeActive()
        }
    }

    func sceneDidDisconnect(_ scene: UIScene) {
        isSceneActive = false
        (window?.rootViewController as? WorkoutViewController)?.cameraCoordinator.disconnect()
    }

    private func makeWorkoutController() -> WorkoutViewController {
        #if DEBUG
        let quality = CameraQualitySelection.current
        let camera = CameraService(capture: CameraCapture(
            resolution: quality.resolution.rawValue, analysisInterval: quality.analysisDuration))
        #else
        let camera = CameraService()
        #endif
        let viewModel = WorkoutViewModel(persistence: persistence, cameraReady: false, startsAutomatically: false)
        let controller = WorkoutViewController(viewModel: viewModel, camera: camera, persistence: persistence)
        controller.onNewWorkout = { [weak self, weak controller] in
            guard let self, let controller, self.window?.rootViewController === controller else { return }
            let shutdownTask = controller.cameraCoordinator.disconnect()
            Task { @MainActor [weak self, weak controller] in
                await shutdownTask.value
                guard let self, let controller, self.window?.rootViewController === controller else { return }
                if self.isSceneActive {
                    self.replaceWorkoutController(replacing: controller)
                } else {
                    self.pendingNewWorkoutController = controller
                }
            }
        }
        return controller
    }

    private func replaceWorkoutController(replacing controller: WorkoutViewController) {
        guard window?.rootViewController === controller else { return }
        window?.rootViewController = makeWorkoutController()
    }
}

#if DEBUG
final class CameraQualityViewController: UIViewController {
    var onStart: (() -> Void)?
    private let resolution = UISegmentedControl(items: ["720p", "1080p"])
    private let rate = UISegmentedControl(items: ["10 Гц", "15 Гц", "30 Гц"])
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        resolution.selectedSegmentIndex = 0
        rate.selectedSegmentIndex = 0
        let title = UILabel()
        title.text = "Debug: Camera & Vision Quality"
        title.numberOfLines = 0
        let identity = CameraQualitySelection.build
        let build = UILabel()
        build.numberOfLines = 0
        build.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        build.text = "SHA: \(identity.sha)\n\(identity.state)"
        let note = UILabel()
        note.numberOfLines = 0
        note.text = "Камеру можно сменить штатной кнопкой до запуска подхода. Live сохраняет ограничение входа 80 мс. Для экспорта трассы включите REPS_PIPELINE_TRACE=1 в схеме Xcode."
        let start = UIButton(type: .system)
        start.setTitle("Открыть тренировку", for: .normal)
        start.addTarget(self, action: #selector(openWorkout), for: .touchUpInside)
        let stack = UIStackView(arrangedSubviews: [title, resolution, rate, build, note, start])
        stack.axis = .vertical
        stack.spacing = 24
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -24),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        ])
    }
    @objc private func openWorkout() {
        CameraQualitySelection.current = CameraQualityConfiguration(
            resolution: resolution.selectedSegmentIndex == 0 ? .hd720 : .hd1080,
            visionRate: CameraQualityConfiguration.VisionRate.allCases[rate.selectedSegmentIndex])
        onStart?()
    }
}
#endif
