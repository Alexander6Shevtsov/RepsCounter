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
                    if identifier == "workoutHistoryButton" || identifier == "cameraSwitchButton" {
                        XCTAssertLessThanOrEqual(control.convert(control.bounds, to: dashboard).maxY, desiredInsets.top + 72, context)
                    }
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
    func testCompactMetricsLeaveTheRightHalfAvailableAtDefaultTextSize() throws {
        let dashboard = WorkoutDashboardView(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
        dashboard.traitOverrides.preferredContentSizeCategory = .large
        dashboard.render(state(), cameraState: .running)
        dashboard.layoutIfNeeded()
        for identifier in ["workoutSet", "workoutGoal", "workoutStatus"] {
            let card = try metricCard(identifier, in: dashboard)
            let frame = card.convert(card.bounds, to: dashboard)
            XCTAssertLessThanOrEqual(frame.maxX, dashboard.bounds.midX + 0.5, identifier)
            XCTAssertLessThanOrEqual(frame.height, 56, identifier)
            let content = try label(identifier, in: dashboard)
            let needed = content.sizeThatFits(CGSize(width: content.bounds.width, height: .greatestFiniteMagnitude))
            XCTAssertGreaterThanOrEqual(content.bounds.height + 0.5, needed.height, identifier)
        }
        XCTAssertGreaterThanOrEqual(try label("workoutCount", in: dashboard).font.pointSize, 86)
        let count = try label("workoutCount", in: dashboard)
        XCTAssertLessThan(count.convert(count.bounds, to: dashboard).minY, dashboard.bounds.height / 4)
        let summary = try metricCard("workoutTime", in: dashboard)
        XCTAssertGreaterThan(summary.convert(summary.bounds, to: dashboard).minY, dashboard.bounds.height * 0.7)
    }

    @MainActor
    func testBackdropPreservesBrightAndDarkCameraMidtones() throws {
        let size = CGSize(width: 393, height: 852)
        let backdrop = WorkoutBackdropView(frame: CGRect(origin: .zero, size: size))
        backdrop.layoutIfNeeded()
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.preferredRange = .standard
        for brightness in [CGFloat(0.96), CGFloat(0.16)] {
            let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
                UIColor(white: brightness, alpha: 1).setFill()
                context.fill(CGRect(origin: .zero, size: size))
                backdrop.layer.render(in: context.cgContext)
            }
            let source = try XCTUnwrap(image.cgImage)
            let sample = try XCTUnwrap(source.cropping(to: CGRect(x: 330, y: 426, width: 1, height: 1)))
            var bytes = [UInt8](repeating: 0, count: 4)
            let measured = try bytes.withUnsafeMutableBytes { storage -> CGFloat in
                let context = try XCTUnwrap(CGContext(data: storage.baseAddress, width: 1, height: 1, bitsPerComponent: 8,
                                                     bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                                                     bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
                context.draw(sample, in: CGRect(x: 0, y: 0, width: 1, height: 1))
                return CGFloat(storage[0]) / 255
            }
            XCTAssertGreaterThan(measured / brightness, 0.85)
        }
    }

    @MainActor
    func testWorkoutVisualFixtureUsesMatchingGeometryAndStateOnBrightAndDarkBackgrounds() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        let controller = DashboardRenderController()
        let appeared = expectation(description: "Visual fixture appeared")
        controller.onAppear = { appeared.fulfill() }
        let dashboard = WorkoutDashboardView()
        controller.view = dashboard
        let viewport = CGSize(width: 393, height: 852)
        window.frame = CGRect(origin: .zero, size: viewport)
        window.rootViewController = controller
        window.isHidden = false
        defer { window.isHidden = true }
        await fulfillment(of: [appeared], timeout: 3)
        window.layoutIfNeeded()
        let nativeInsets = dashboard.safeAreaInsets
        controller.additionalSafeAreaInsets = UIEdgeInsets(top: 59 - nativeInsets.top, left: -nativeInsets.left,
                                                          bottom: 34 - nativeInsets.bottom, right: -nativeInsets.right)
        let cameraFixture = WorkoutVisualFixtureView(skeleton: false)
        let backdrop = WorkoutBackdropView()
        let skeletonFixture = WorkoutVisualFixtureView(skeleton: true)
        for (index, layer) in [cameraFixture, backdrop, skeletonFixture].enumerated() {
            layer.frame = dashboard.bounds
            layer.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            dashboard.insertSubview(layer, at: index)
        }
        for brightness in [CGFloat(0.96), CGFloat(0.16)] {
            cameraFixture.brightness = brightness
            cameraFixture.setNeedsDisplay()
            controller.traitOverrides.preferredContentSizeCategory = .large
            dashboard.render(state(), cameraState: .running)
            dashboard.updateCameraControl(canSwitch: true, position: .front)
            dashboard.layoutIfNeeded()
            XCTAssertEqual(try label("workoutCount", in: dashboard).text, "7")
            XCTAssertEqual(try label("workoutTotal", in: dashboard).text, "31")
            let name = brightness > 0.5 ? "Bright" : "Dark"
            let image = UIGraphicsImageRenderer(size: viewport).image { _ in
                dashboard.drawHierarchy(in: dashboard.bounds, afterScreenUpdates: true)
            }
            let attachment = XCTAttachment(image: image)
            attachment.name = "\(name) UIKit fixture — synthetic background, body, pose and values"
            attachment.lifetime = .keepAlways
            add(attachment)
            var metrics: [String: [String: CGFloat]] = [:]
            for identifier in ["workoutSet", "workoutGoal", "workoutStatus", "workoutTime", "workoutTotal"] {
                let card = try metricCard(identifier, in: dashboard)
                let frame = card.convert(card.bounds, to: dashboard)
                metrics[identifier] = ["width": frame.width, "height": frame.height, "area": frame.width * frame.height, "top": frame.minY]
            }
            let measurement = XCTAttachment(data: try JSONSerialization.data(withJSONObject: metrics, options: [.sortedKeys]), uniformTypeIdentifier: "public.json")
            measurement.name = "\(name) fixture metric frames"
            measurement.lifetime = .keepAlways
            add(measurement)
        }
    }

    @MainActor
    private func metricCard(_ identifier: String, in container: UIView) throws -> UIVisualEffectView {
        var ancestor = try label(identifier, in: container).superview
        while let current = ancestor {
            if let surface = current as? UIVisualEffectView { return surface }
            ancestor = current.superview
        }
        throw NSError(domain: "Missing metric card", code: 1)
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

private final class WorkoutVisualFixtureView: UIView {
    var brightness: CGFloat = 0.96
    private let skeleton: Bool
    private let joints: [CGPoint] = [CGPoint(x: 278, y: 200), CGPoint(x: 246, y: 244), CGPoint(x: 312, y: 244),
                                    CGPoint(x: 252, y: 374), CGPoint(x: 302, y: 374), CGPoint(x: 226, y: 475),
                                    CGPoint(x: 326, y: 475), CGPoint(x: 244, y: 655), CGPoint(x: 313, y: 655)]
    private let segments = [(0, 1), (0, 2), (1, 2), (1, 3), (2, 4), (3, 4), (3, 5), (4, 6), (5, 7), (6, 8)]

    init(skeleton: Bool) {
        self.skeleton = skeleton
        super.init(frame: .zero)
        backgroundColor = .clear
        isOpaque = false
        isUserInteractionEnabled = false
        isAccessibilityElement = false
    }

    required init?(coder: NSCoder) { nil }

    override func draw(_ rectangle: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        context.saveGState()
        context.scaleBy(x: bounds.width / 393, y: bounds.height / 852)
        if skeleton {
            context.setStrokeColor(UIColor.systemBlue.cgColor)
            context.setLineWidth(2)
            context.setLineCap(.round)
            for segment in segments {
                context.move(to: joints[segment.0])
                context.addLine(to: joints[segment.1])
            }
            context.strokePath()
            context.setFillColor(UIColor.white.cgColor)
            for joint in joints {
                context.fillEllipse(in: CGRect(x: joint.x - 3, y: joint.y - 3, width: 6, height: 6))
            }
        } else {
            context.setFillColor(UIColor(white: brightness, alpha: 1).cgColor)
            context.fill(CGRect(x: 0, y: 0, width: 393, height: 852))
            context.setStrokeColor(UIColor(white: brightness > 0.5 ? 0.82 : 0.26, alpha: 1).cgColor)
            context.setLineWidth(1)
            for offset in stride(from: 0, through: 852, by: 64) {
                context.move(to: CGPoint(x: 0, y: offset))
                context.addLine(to: CGPoint(x: 393, y: offset))
            }
            context.strokePath()
            let bodyColor = UIColor(red: 0.30, green: 0.40, blue: 0.46, alpha: 1).cgColor
            context.setFillColor(bodyColor)
            context.fillEllipse(in: CGRect(x: 252, y: 148, width: 52, height: 60))
            context.fill(CGRect(x: 248, y: 238, width: 60, height: 140))
            context.setStrokeColor(bodyColor)
            context.setLineWidth(30)
            context.setLineCap(.round)
            for segment in segments where segment.0 >= 3 {
                context.move(to: joints[segment.0])
                context.addLine(to: joints[segment.1])
            }
            context.strokePath()
        }
        context.restoreGState()
    }
}

private final class DashboardRenderController: UIViewController {
    var onAppear: (() -> Void)?

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        onAppear?()
    }
}
