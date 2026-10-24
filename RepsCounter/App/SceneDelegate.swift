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
        let viewModel = WorkoutViewModel(persistence: persistence)
        let controller = WorkoutViewController(viewModel: viewModel, camera: camera, persistence: persistence)
        applicationWindow.rootViewController = controller
        applicationWindow.overrideUserInterfaceStyle = .dark
        window = applicationWindow
        applicationWindow.makeKeyAndVisible()
    }
}
