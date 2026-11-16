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
        applicationWindow.rootViewController = makeWorkoutController()
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
        let camera = CameraService()
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
