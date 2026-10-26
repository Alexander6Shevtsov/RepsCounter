//
//  SceneDelegate.swift
//  RepsCounter
//
//  Maintainer: Alexander Shevtsov
//  Copyright © 2026 Alexander Shevtsov.

import UIKit

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        guard let windowScene = scene as? UIWindowScene else { return }

        let applicationWindow = UIWindow(windowScene: windowScene)
        let persistence = WorkoutPersistence()
        let camera = CameraService()
        let viewModel = WorkoutViewModel(persistence: persistence, cameraReady: false)
        let controller = WorkoutViewController(viewModel: viewModel, camera: camera, persistence: persistence)
        applicationWindow.rootViewController = controller
        applicationWindow.overrideUserInterfaceStyle = .dark
        window = applicationWindow
        applicationWindow.makeKeyAndVisible()
    }

    func sceneDidEnterBackground(_ scene: UIScene) {
        (window?.rootViewController as? WorkoutViewController)?.cameraCoordinator.sceneDidEnterBackground()
    }

    func sceneDidBecomeActive(_ scene: UIScene) {
        (window?.rootViewController as? WorkoutViewController)?.cameraCoordinator.sceneDidBecomeActive()
    }

    func sceneDidDisconnect(_ scene: UIScene) {
        (window?.rootViewController as? WorkoutViewController)?.cameraCoordinator.disconnect()
    }
}
