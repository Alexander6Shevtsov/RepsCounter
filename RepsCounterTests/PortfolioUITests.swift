//
//  PortfolioUITests.swift
//  RepsCounter
//
//  Maintainer: Alexander Shevtsov
//  Copyright © 2026 Alexander Shevtsov.

import UIKit
import XCTest
@testable import RepsCounter

final class PortfolioUITests: XCTestCase {
    @MainActor
    func testDashboardUsesDeliveredWorkoutValuesInsteadOfConceptExamples() throws {
        let dashboard = WorkoutDashboardView()
        dashboard.render(state(), cameraState: .running)
        XCTAssertEqual(try label("workoutCount", in: dashboard).text, "7")
        XCTAssertEqual(try label("workoutExercise", in: dashboard).text, "Приседания")
        let setText = try XCTUnwrap(label("workoutSet", in: dashboard).text)
        XCTAssertTrue(setText.contains("3"))
        XCTAssertTrue(setText.contains("4"))
        XCTAssertTrue(try label("workoutTime", in: dashboard).text?.contains("02:05") == true)
        XCTAssertTrue(try label("workoutGoal", in: dashboard).text?.contains("12") == true)
        XCTAssertFalse(descendants(dashboard).compactMap { ($0 as? UILabel)?.text }.contains("18:24"))
    }

    @MainActor
    func testDashboardButtonsForwardActionsWithoutChangingWorkoutData() throws {
        let dashboard = WorkoutDashboardView()
        var actions: [String] = []
        dashboard.onPause = { actions.append("pause") }
        dashboard.onFinish = { actions.append("finish") }
        dashboard.onHistory = { actions.append("history") }
        dashboard.onSwitch = { actions.append("switch") }
        dashboard.render(state(), cameraState: .running)
        dashboard.updateCameraControl(canSwitch: true, position: .front)
        XCTAssertTrue(actions.isEmpty)
        for identifier in ["workoutPauseButton", "workoutFinishButton", "workoutHistoryButton", "cameraSwitchButton"] {
            try button(identifier, in: dashboard).sendActions(for: .touchUpInside)
        }
        XCTAssertEqual(actions, ["pause", "finish", "history", "switch"])
        XCTAssertEqual(try label("workoutCount", in: dashboard).text, "7")
    }

    @MainActor
    func testPausedAndRestingPresentationKeepsCounterAndElapsedTime() throws {
        let dashboard = WorkoutDashboardView()
        dashboard.render(state(paused: true), cameraState: .stopped)
        XCTAssertEqual(try button("workoutPauseButton", in: dashboard).currentTitle, "Продолжить")
        XCTAssertEqual(try label("workoutCount", in: dashboard).text, "7")
        XCTAssertTrue(try label("workoutTime", in: dashboard).text?.contains("02:05") == true)
        dashboard.render(state(resting: true), cameraState: .running)
        let text = descendants(dashboard).compactMap { ($0 as? UILabel)?.text }.joined(separator: " ").lowercased()
        XCTAssertTrue(text.contains("отдых"))
        XCTAssertTrue(text.contains("45"))
        XCTAssertEqual(try label("workoutCount", in: dashboard).text, "7")
        XCTAssertEqual(try button("workoutPauseButton", in: dashboard).currentTitle, "Пауза")
    }

    @MainActor
    func testCameraPreparationAndPermissionMessagesRemainActionable() throws {
        let dashboard = WorkoutDashboardView()
        for cameraState in [CameraState.requestingPermission, .starting, .switching] {
            dashboard.render(state(paused: true), cameraState: cameraState)
            XCTAssertFalse(try button("workoutPauseButton", in: dashboard).isEnabled)
            let guidance = try XCTUnwrap(label("workoutGuidance", in: dashboard).text)
            XCTAssertFalse(guidance.isEmpty)
            XCTAssertTrue(guidance.lowercased().contains("камер"))
        }
        dashboard.render(state(paused: true), cameraState: .permissionDenied)
        let guidance = try XCTUnwrap(label("workoutGuidance", in: dashboard).text)
        XCTAssertTrue(guidance.lowercased().contains("настрой"))
        XCTAssertTrue(try button("workoutPauseButton", in: dashboard).isEnabled)
        dashboard.render(state(paused: true), cameraState: .interrupted)
        XCTAssertTrue(try button("workoutPauseButton", in: dashboard).isEnabled)
        XCTAssertEqual(try label("workoutCount", in: dashboard).text, "7")
    }

    @MainActor
    func testFinishedSavingFailureRemainsRetryableAndSuccessIsExplicit() throws {
        let dashboard = WorkoutDashboardView()
        dashboard.render(state(finished: true, saveState: .saving), cameraState: .finished)
        XCTAssertEqual(try button("workoutFinishButton", in: dashboard).currentTitle, "Сохранение…")
        XCTAssertFalse(try button("workoutFinishButton", in: dashboard).isEnabled)
        XCTAssertFalse(try button("workoutPauseButton", in: dashboard).isEnabled)
        dashboard.render(state(finished: true, saveState: .failed("Controlled storage failure")), cameraState: .finished)
        XCTAssertEqual(try button("workoutFinishButton", in: dashboard).currentTitle, "Повторить")
        XCTAssertTrue(try button("workoutFinishButton", in: dashboard).isEnabled)
        XCTAssertTrue(try label("workoutGuidance", in: dashboard).text?.contains("Controlled storage failure") == true)
        dashboard.render(state(finished: true, saveState: .saved), cameraState: .finished)
        XCTAssertEqual(try button("workoutFinishButton", in: dashboard).currentTitle, "Завершено")
        XCTAssertFalse(try button("workoutFinishButton", in: dashboard).isEnabled)
        XCTAssertEqual(try label("workoutCount", in: dashboard).text, "7")
        XCTAssertTrue(try label("workoutTime", in: dashboard).text?.contains("02:05") == true)
    }

    @MainActor
    func testCameraSwitchAvailabilityAndAccessibilityFollowSuppliedState() throws {
        let dashboard = WorkoutDashboardView()
        dashboard.render(state(), cameraState: .running)
        let cameraButton = try button("cameraSwitchButton", in: dashboard)
        dashboard.updateCameraControl(canSwitch: false, position: .front)
        XCTAssertFalse(cameraButton.isEnabled)
        XCTAssertTrue(cameraButton.accessibilityValue?.lowercased().contains("фронт") == true)
        dashboard.updateCameraControl(canSwitch: true, position: .back)
        XCTAssertTrue(cameraButton.isEnabled)
        XCTAssertTrue(cameraButton.accessibilityValue?.lowercased().contains("задн") == true)
        XCTAssertEqual(try label("workoutCount", in: dashboard).text, "7")
    }

    @MainActor
    func testDashboardLayoutsKeepControlsAndTextReadableAcrossPhoneSizesAndDynamicType() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        let categories: [UIContentSizeCategory] = [.extraSmall, .small, .medium, .large, .extraLarge, .extraExtraLarge,
                                                 .extraExtraExtraLarge, .accessibilityMedium, .accessibilityLarge,
                                                 .accessibilityExtraLarge, .accessibilityExtraExtraLarge,
                                                 .accessibilityExtraExtraExtraLarge]
        defer { window.isHidden = true }
        for viewport in [CGSize(width: 375, height: 667), CGSize(width: 393, height: 852), CGSize(width: 430, height: 932)] {
            let controller = DashboardRenderController()
            let appeared = expectation(description: "Dashboard appeared at \(viewport)")
            controller.onAppear = { appeared.fulfill() }
            let dashboard = WorkoutDashboardView()
            controller.view = dashboard
            window.frame = CGRect(origin: .zero, size: viewport)
            window.rootViewController = controller
            window.isHidden = false
            await fulfillment(of: [appeared], timeout: 3)
            window.layoutIfNeeded()
            let nativeInsets = dashboard.safeAreaInsets
            let desiredInsets = viewport.height == 667 ? UIEdgeInsets(top: 20, left: 0, bottom: 0, right: 0)
                : UIEdgeInsets(top: 59, left: 0, bottom: 34, right: 0)
            controller.additionalSafeAreaInsets = UIEdgeInsets(top: desiredInsets.top - nativeInsets.top,
                                                               left: -nativeInsets.left,
                                                               bottom: desiredInsets.bottom - nativeInsets.bottom,
                                                               right: -nativeInsets.right)
            for category in categories {
                controller.traitOverrides.preferredContentSizeCategory = category
                dashboard.render(state(pose: false), cameraState: .running)
                dashboard.updateCameraControl(canSwitch: true, position: .front)
                dashboard.setNeedsLayout()
                dashboard.layoutIfNeeded()
                XCTAssertEqual(dashboard.bounds.size, viewport)
                XCTAssertEqual(dashboard.safeAreaInsets, desiredInsets)
                XCTAssertEqual(dashboard.traitCollection.preferredContentSizeCategory, category)
                let context = "\(viewport) \(category.rawValue)"
                let expectedTraits = UITraitCollection(preferredContentSizeCategory: category)
                let guidanceFont = UIFont.preferredFont(forTextStyle: .subheadline, compatibleWith: expectedTraits)
                XCTAssertEqual(try label("workoutGuidance", in: dashboard).font.pointSize, guidanceFont.pointSize, context)
                for identifier in ["workoutSet", "workoutTime", "workoutGoal", "workoutStatus"] {
                    let expectedFont = UIFont.preferredFont(forTextStyle: .headline, compatibleWith: expectedTraits)
                    XCTAssertEqual(try label(identifier, in: dashboard).font.pointSize, expectedFont.pointSize, context + " " + identifier)
                }
                let controls = try XCTUnwrap(descendants(dashboard).first { $0.accessibilityIdentifier == "workoutControls" })
                let scroll = try XCTUnwrap(descendants(dashboard).first { $0.accessibilityIdentifier == "workoutMetricsScroll" } as? UIScrollView)
                XCTAssertTrue(dashboard.bounds.contains(controls.convert(controls.bounds, to: dashboard)), context)
                XCTAssertGreaterThan(scroll.bounds.height, 0, context)
                XCTAssertLessThanOrEqual(scroll.contentSize.width, scroll.bounds.width + 0.5, context)
                XCTAssertFalse(scroll.convert(scroll.bounds, to: dashboard).intersects(controls.convert(controls.bounds, to: dashboard)), context)
                let pause = try button("workoutPauseButton", in: dashboard)
                let finish = try button("workoutFinishButton", in: dashboard)
                XCTAssertFalse(pause.convert(pause.bounds, to: dashboard).intersects(finish.convert(finish.bounds, to: dashboard)), context)
                for identifier in ["workoutPauseButton", "workoutFinishButton", "workoutHistoryButton", "cameraSwitchButton"] {
                    let control = try button(identifier, in: dashboard)
                    XCTAssertGreaterThanOrEqual(control.bounds.width, 44, context + " " + identifier)
                    XCTAssertGreaterThanOrEqual(control.bounds.height, 44, context + " " + identifier)
                    let image = try XCTUnwrap(control.imageView)
                    XCTAssertTrue(control.bounds.contains(image.convert(image.bounds, to: control)), context + " " + identifier)
                }
                for control in [pause, finish] {
                    let title = try XCTUnwrap(control.titleLabel)
                    XCTAssertFalse(control.currentTitle?.isEmpty == true, context)
                    XCTAssertGreaterThan(title.bounds.width, 0, context)
                    XCTAssertGreaterThan(title.bounds.height, 0, context)
                    let needed = title.sizeThatFits(CGSize(width: title.bounds.width, height: .greatestFiniteMagnitude))
                    XCTAssertGreaterThanOrEqual(title.bounds.height + 0.5, needed.height, context + " " + (control.currentTitle ?? ""))
                    XCTAssertTrue(control.bounds.contains(title.convert(title.bounds, to: control)), context)
                }
                for label in descendants(dashboard).compactMap({ $0 as? UILabel }) where isVisible(label) && !isInsideButton(label) {
                    let frame = label.convert(label.bounds, to: dashboard)
                    XCTAssertGreaterThanOrEqual(frame.minX, -0.5, context + " " + (label.text ?? ""))
                    XCTAssertLessThanOrEqual(frame.maxX, viewport.width + 0.5, context + " " + (label.text ?? ""))
                    let needed = label.sizeThatFits(CGSize(width: label.bounds.width, height: .greatestFiniteMagnitude))
                    XCTAssertGreaterThanOrEqual(label.bounds.height + 0.5, needed.height, context + " " + (label.text ?? ""))
                }
                if viewport.width == 393, category == .large || category == .accessibilityExtraExtraExtraLarge {
                    let image = UIGraphicsImageRenderer(size: viewport).image { _ in
                        dashboard.drawHierarchy(in: dashboard.bounds, afterScreenUpdates: true)
                    }
                    let attachment = XCTAttachment(image: image)
                    attachment.name = "Synthetic UIKit workout \(category.rawValue) — iPhone 15 Pro viewport"
                    attachment.lifetime = .keepAlways
                    add(attachment)
                }
            }
        }
    }

    @MainActor
    private func state(repetitions: Int = 7, total: Int = 31, resting: Bool = false, paused: Bool = false,
                       finished: Bool = false, pose: Bool = true, saveState: WorkoutSaveState = .notSaved) -> WorkoutViewState {
        WorkoutViewState(repetitions: repetitions, totalRepetitions: total, currentSet: 3, targetSets: 4,
                         targetRepetitions: 12, elapsedSeconds: 125, remainingRestSeconds: resting ? 45 : 0,
                         isResting: resting, isPaused: paused, isFinished: finished, poseDetected: pose, saveState: saveState)
    }

    @MainActor
    private func label(_ identifier: String, in container: UIView) throws -> UILabel {
        try XCTUnwrap(descendants(container).first { $0.accessibilityIdentifier == identifier } as? UILabel)
    }

    @MainActor
    private func button(_ identifier: String, in container: UIView) throws -> UIButton {
        try XCTUnwrap(descendants(container).first { $0.accessibilityIdentifier == identifier } as? UIButton)
    }

    @MainActor
    private func descendants(_ container: UIView) -> [UIView] {
        [container] + container.subviews.flatMap { descendants($0) }
    }

    @MainActor
    private func isVisible(_ view: UIView) -> Bool {
        var ancestor: UIView? = view
        while let current = ancestor {
            if current.isHidden { return false }
            ancestor = current.superview
        }
        return true
    }

    @MainActor
    private func isInsideButton(_ view: UIView) -> Bool {
        var ancestor = view.superview
        while let current = ancestor {
            if current is UIButton { return true }
            ancestor = current.superview
        }
        return false
    }
}

private final class DashboardRenderController: UIViewController {
    var onAppear: (() -> Void)?

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        onAppear?()
    }
}
