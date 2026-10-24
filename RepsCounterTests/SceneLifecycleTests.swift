import UIKit
import XCTest
@testable import RepsCounter

final class SceneLifecycleTests: XCTestCase {
    func testBuiltApplicationRegistersProgrammaticScene() throws {
        let applicationBundle = Bundle(for: AppDelegate.self)
        let sceneManifest = try XCTUnwrap(
            applicationBundle.object(forInfoDictionaryKey: "UIApplicationSceneManifest") as? [String: Any]
        )
        let configurations = try XCTUnwrap(sceneManifest["UISceneConfigurations"] as? [String: Any])
        let applicationConfigurations = try XCTUnwrap(
            configurations[UISceneSession.Role.windowApplication.rawValue] as? [[String: Any]]
        )
        let configuration = try XCTUnwrap(applicationConfigurations.first)

        XCTAssertEqual(sceneManifest["UIApplicationSupportsMultipleScenes"] as? Bool, false)
        XCTAssertEqual(configuration["UISceneClassName"] as? String, NSStringFromClass(UIWindowScene.self))
        XCTAssertEqual(configuration["UISceneDelegateClassName"] as? String, NSStringFromClass(SceneDelegate.self))
        XCTAssertNil(configuration["UISceneStoryboardFile"])
        XCTAssertNil(applicationBundle.object(forInfoDictionaryKey: "UIMainStoryboardFile"))
        XCTAssertEqual(
            applicationBundle.object(forInfoDictionaryKey: "UISupportedInterfaceOrientations") as? [String],
            ["UIInterfaceOrientationPortrait"]
        )
    }

    @MainActor
    func testHostConnectsWorkoutWindow() async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        var connectedScene: UIWindowScene?

        repeat {
            connectedScene = UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .first { scene in
                    scene.session.role == .windowApplication
                        && (scene.delegate as? SceneDelegate)?.window != nil
                }
            if connectedScene != nil { break }
            try await Task.sleep(for: .milliseconds(50))
        } while clock.now < deadline

        let windowScene = try XCTUnwrap(connectedScene, "UIKit did not connect the workout scene")
        let sceneDelegate = try XCTUnwrap(windowScene.delegate as? SceneDelegate)
        let applicationWindow = try XCTUnwrap(sceneDelegate.window)

        XCTAssertTrue(applicationWindow.windowScene === windowScene)
        XCTAssertFalse(applicationWindow.isHidden)
        XCTAssertTrue(applicationWindow.rootViewController is WorkoutViewController)
        XCTAssertEqual(applicationWindow.overrideUserInterfaceStyle, .dark)
    }
}
