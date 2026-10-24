import UIKit

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        let applicationWindow = UIWindow(frame: UIScreen.main.bounds)
        let persistence = WorkoutPersistence()
        let camera = CameraService()
        let viewModel = WorkoutViewModel(persistence: persistence)
        let controller = WorkoutViewController(viewModel: viewModel, camera: camera, persistence: persistence)
        applicationWindow.rootViewController = controller
        applicationWindow.overrideUserInterfaceStyle = .dark
        applicationWindow.makeKeyAndVisible()
        window = applicationWindow
        return true
    }

    func application(
        _ application: UIApplication,
        supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        .portrait
    }
}
