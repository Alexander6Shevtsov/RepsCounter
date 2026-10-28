//
//  PoseComparisonTests.swift
//  RepsCounter
//
//  Maintainer: Alexander Shevtsov
//  Copyright © 2026 Alexander Shevtsov.

import UIKit
import XCTest
@testable import RepsCounter

final class PoseComparisonTests: XCTestCase {
    @MainActor
    func testExperimentControlsFollowBuildConfiguration() throws {
        let fixture = ExperimentWorkoutFixture(cameraReady: false)
        let camera = CameraService()
        let controller = WorkoutViewController(viewModel: fixture.viewModel, camera: camera, persistence: fixture.store)
        controller.loadViewIfNeeded()
        defer { controller.cameraCoordinator.finish() }
        let contents = descendants(controller.view)
        let diagnostics = contents.first { $0.accessibilityIdentifier == "squatDiagnosticsButton" } as? UIButton
        let comparison = contents.first { $0.accessibilityIdentifier == "poseComparisonButton" } as? UIButton
        let panel = contents.first { $0.accessibilityIdentifier == "poseComparisonPanel" }
        #if DEBUG
        let diagnosticsButton = try XCTUnwrap(diagnostics)
        let comparisonButton = try XCTUnwrap(comparison)
        let comparisonPanel = try XCTUnwrap(panel)
        XCTAssertTrue(comparisonPanel.isHidden)
        diagnosticsButton.sendActions(for: .touchUpInside)
        comparisonButton.sendActions(for: .touchUpInside)
        XCTAssertFalse(comparisonPanel.isHidden)
        let modeControl = try XCTUnwrap(contents.first { $0.accessibilityIdentifier == "poseComparisonModeControl" } as? UISegmentedControl)
        XCTAssertEqual(modeControl.selectedSegmentIndex, 0)
        modeControl.selectedSegmentIndex = 1
        modeControl.sendActions(for: .valueChanged)
        let label = try XCTUnwrap(contents.first { $0.accessibilityIdentifier == "poseComparisonText" } as? UILabel)
        XCTAssertTrue(label.text?.contains("3D: —") == true)
        XCTAssertTrue(label.text?.contains("полный присед не определён") == true)
        diagnosticsButton.sendActions(for: .touchUpInside)
        XCTAssertTrue(comparisonPanel.isHidden)
        XCTAssertEqual(diagnosticsButton.accessibilityValue, "Выключена")
        #else
        XCTAssertNil(diagnostics)
        XCTAssertNil(comparison)
        XCTAssertNil(panel)
        XCTAssertFalse(contents.contains { $0.accessibilityIdentifier?.hasPrefix("poseHUD") == true })
        XCTAssertFalse(contents.contains { $0.accessibilityIdentifier == "poseComparisonModeControl" || $0.accessibilityIdentifier == "poseComparisonModeMenuButton" })
        #endif
    }

    @MainActor
    private func descendants(_ view: UIView) -> [UIView] {
        [view] + view.subviews.flatMap { descendants($0) }
    }

    #if DEBUG
    @MainActor
    func testCompactHUDDefaultsToNoScrollAndDoesNotInventMeasurements() throws {
        let fixture = PoseComparisonFixture()
        defer { fixture.model.setEnabled(false) }
        fixture.model.selectedViewpoint = .diagonal
        let panel = PoseComparisonView()
        panel.render(fixture.model, cameraPosition: .back)
        let contents = descendants(panel)
        XCTAssertEqual(panel.displayMode, .compact)
        XCTAssertEqual(try hudLabel("Summary", inside: panel).text, "Счёт 0 · Задняя · 45°")
        XCTAssertEqual(try hudLabel("Status", inside: panel).text, "3D: нет актуальных данных")
        XCTAssertEqual(try hudLabel("Planar", inside: panel).text, "2D Л — · П —")
        XCTAssertEqual(try hudLabel("Spatial", inside: panel).text, "3D Л — · П —")
        XCTAssertEqual(try hudLabel("Rates", inside: panel).text, "FPS 2D — · 3D —")
        XCTAssertEqual(try hudLabel("Coverage", inside: panel).text, "Coverage — · 3D Δ —")
        let scroll = try XCTUnwrap(contents.first { $0.accessibilityIdentifier == "poseComparisonDetailsScroll" } as? UIScrollView)
        XCTAssertTrue(scroll.isHidden)
        XCTAssertFalse(contents.contains { $0 is UIScrollView && isVisible($0) })
    }

    @MainActor
    func testDisplayModeSwitchPreservesRecordingAndCollectsEveryDeliveredPair() throws {
        let fixture = PoseComparisonFixture()
        defer { fixture.model.setEnabled(false) }
        let panel = PoseComparisonView()
        panel.onSeries = {
            if fixture.model.isRecording { fixture.model.finishSeries() }
            else { fixture.model.startSeries() }
        }
        panel.onViewpoint = { fixture.model.selectedViewpoint = $0 }
        let model = fixture.model
        model.onChange = { [weak panel, weak model] in
            guard let model else { return }
            panel?.render(model, cameraPosition: .front)
        }
        panel.render(model, cameraPosition: .front)
        let button = try XCTUnwrap(descendants(panel).first { $0.accessibilityIdentifier == "poseComparisonSeriesButton" } as? UIButton)
        button.sendActions(for: .touchUpInside)
        XCTAssertTrue(model.isRecording)
        let epoch = fixture.capture.currentEpoch
        let seriesIdentifier = model.series.last?.id
        model.receive(.paired(fixture.pair(sequence: 1), fixture.counters))
        let control = try modeControl(inside: panel)
        control.selectedSegmentIndex = 1
        control.sendActions(for: .valueChanged)
        XCTAssertEqual(panel.displayMode, .detailed)
        model.receive(.paired(fixture.pair(sequence: 2), fixture.counters))
        control.selectedSegmentIndex = 0
        control.sendActions(for: .valueChanged)
        XCTAssertEqual(panel.displayMode, .compact)
        model.receive(.paired(fixture.pair(sequence: 3), fixture.counters))
        XCTAssertEqual(fixture.capture.currentEpoch, epoch)
        XCTAssertTrue(fixture.capture.isProcessingEnabled)
        XCTAssertTrue(model.isRecording)
        XCTAssertEqual(model.series.last?.id, seriesIdentifier)
        XCTAssertEqual(model.series.last?.pairs.map { $0.source.metadata.identity.sequence }, [1, 2, 3])
        XCTAssertEqual(model.statistics, fixture.counters)
        button.sendActions(for: .touchUpInside)
        XCTAssertFalse(model.isRecording)
        XCTAssertTrue(model.annotate(full: 0, partial: 3, uncertain: 0))
        XCTAssertEqual(model.series.last?.annotation?.partialRepetitions, 3)
    }

    @MainActor
    func testSeriesMenuKeepsViewpointSelectionAndManualAnnotationInBothModes() throws {
        let fixture = PoseComparisonFixture()
        defer { fixture.model.setEnabled(false) }
        let panel = PoseComparisonView()
        panel.onViewpoint = { fixture.model.selectedViewpoint = $0 }
        let model = fixture.model
        model.onChange = { [weak panel, weak model] in
            guard let model else { return }
            panel?.render(model)
        }
        panel.render(model)
        let settings = try XCTUnwrap(descendants(panel).first { $0.accessibilityIdentifier == "poseComparisonSettingsButton" } as? UIButton)
        panel.selectViewpoint(.diagonal)
        XCTAssertEqual(model.selectedViewpoint, .diagonal)
        XCTAssertTrue(try hudLabel("Summary", inside: panel).text?.contains("45°") == true)
        let before = try XCTUnwrap(menuActions(settings.menu).first { $0.identifier.rawValue == "poseComparisonAnnotation" })
        XCTAssertTrue(before.attributes.contains(.disabled))
        model.startSeries()
        panel.selectViewpoint(.side)
        XCTAssertEqual(model.selectedViewpoint, .diagonal)
        XCTAssertEqual(model.series.last?.viewpoint, .diagonal)
        for modeIndex in [1, 0] {
            let control = try modeControl(inside: panel)
            control.selectedSegmentIndex = modeIndex
            control.sendActions(for: .valueChanged)
            let actions = menuActions(settings.menu)
            for title in ["Лицом", "45°", "Боком"] {
                let action = try XCTUnwrap(actions.first { $0.title == title })
                XCTAssertTrue(action.attributes.contains(.disabled))
            }
            XCTAssertTrue(actions.contains { $0.identifier.rawValue == "poseComparisonAnnotation" })
        }
        model.finishSeries()
        let after = try XCTUnwrap(menuActions(settings.menu).first { $0.identifier.rawValue == "poseComparisonAnnotation" })
        XCTAssertFalse(after.attributes.contains(.disabled))
        panel.selectViewpoint(.side)
        XCTAssertEqual(model.selectedViewpoint, .side)
        XCTAssertTrue(model.annotate(full: 0, partial: 4, uncertain: 0))
    }

    @MainActor
    func testCompactHUDKeepsCameraFailureAndPermissionMessagesVisible() throws {
        let fixture = PoseComparisonFixture()
        defer { fixture.model.setEnabled(false) }
        let panel = PoseComparisonView()
        let scenarios: [(CameraState, String)] = [(.permissionDenied, "Нет доступа"), (.interrupted, "Прерывание"),
                                                  (.failed("Controlled camera failure"), "Ошибка камеры"), (.stopped, "Пауза")]
        for scenario in scenarios {
            panel.render(fixture.model, cameraPosition: .back, cameraState: scenario.0)
            XCTAssertEqual(try hudLabel("Status", inside: panel).text, "3D: нет актуальных данных")
            XCTAssertEqual(try hudLabel("Reason", inside: panel).text, "Причина: " + scenario.1)
        }
    }

    @MainActor
    func testCompactHUDReportsNativeRejectionsWithoutLongErrors() throws {
        let fixture = PoseComparisonFixture()
        defer { fixture.model.setEnabled(false) }
        let panel = PoseComparisonView()
        let scenarios: [(Pose3DIssue, String)] = [
            (.noBody, "noBody"), (.missingJoint, "missingJoint"),
            (.visionError, "visionError"), (.unsupportedRevision, "unsupportedRevision")
        ]
        for (offset, scenario) in scenarios.enumerated() {
            let pair = displayPair(fixture, sequence: UInt64(offset + 1), issue: scenario.0)
            fixture.model.receive(.paired(pair, fixture.counters))
            panel.render(fixture.model, cameraPosition: .front)
            XCTAssertEqual(try hudLabel("Status", inside: panel).text, "3D: " + scenario.1)
            XCTAssertFalse(try hudLabel("Reason", inside: panel).isHidden)
            XCTAssertFalse(try hudLabel("Reason", inside: panel).text?.contains("Long Vision detail") == true)
            XCTAssertEqual(try hudLabel("Spatial", inside: panel).text, "3D Л — · П —")
        }
        fixture.clock.advance(.milliseconds(751))
        panel.render(fixture.model, cameraPosition: .front)
        XCTAssertEqual(try hudLabel("Status", inside: panel).text, "3D: нет актуальных данных")
        XCTAssertEqual(try hudLabel("Coverage", inside: panel).text, "Coverage 10% · 3D Δ —")
    }

    @MainActor
    func testCompactHUDUsesFresh2DWithoutSubstitutingAnother3DFrame() throws {
        let fixture = PoseComparisonFixture()
        defer { fixture.model.setEnabled(false) }
        fixture.model.receive(.paired(fixture.pair(sequence: 1), fixture.counters))
        fixture.clock.advance(.milliseconds(751))
        fixture.model.receive(.planar(fixture.pair(sequence: 2).source, fixture.counters))
        let panel = PoseComparisonView()
        panel.render(fixture.model, cameraPosition: .front)
        XCTAssertEqual(try hudLabel("Planar", inside: panel).text, "2D Л 170.0° · П 168.0°")
        XCTAssertEqual(try hudLabel("Spatial", inside: panel).text, "3D Л — · П —")
        XCTAssertEqual(try hudLabel("Status", inside: panel).text, "3D: нет актуальных данных")
    }

    @MainActor
    func testCompactMetricsAndDisplayedLegComeFromExistingDataOnly() throws {
        let fixture = PoseComparisonFixture()
        defer { fixture.model.setEnabled(false) }
        fixture.model.startSeries()
        let initial = fixture.pair(sequence: 1)
        fixture.clock.advance(.milliseconds(100))
        let pair = PoseComparisonPair(source: initial.source, detection: initial.detection, spatial: initial.spatial,
                                      latency: 0.06, completedAt: fixture.clock.current)
        fixture.model.receive(.paired(pair, fixture.counters))
        let epoch = fixture.capture.currentEpoch
        let panel = PoseComparisonView()
        panel.render(fixture.model, cameraPosition: .front)
        XCTAssertEqual(try hudLabel("Rates", inside: panel).text, "FPS 2D 100.0 · 3D 10.0")
        XCTAssertEqual(try hudLabel("Coverage", inside: panel).text, "Coverage 10% · 3D Δ 100 мс")
        XCTAssertEqual(try hudLabel("Status", inside: panel).text, "3D: распознаётся")
        XCTAssertTrue(try hudLabel("Reason", inside: panel).isHidden)
        panel.selectHUDLeg(.right)
        XCTAssertEqual(try hudLabel("Planar", inside: panel).text, "2D П 168.0°")
        XCTAssertEqual(fixture.capture.currentEpoch, epoch)
        XCTAssertEqual(fixture.model.series.last?.pairs.count, 1)
        XCTAssertEqual(fixture.model.latestPair?.source.metadata.identity.sequence, 1)
    }

    @MainActor
    func testDetailedModeKeepsFullDiagnosticsAndScrollsInsideFixedControls() throws {
        let fixture = PoseComparisonFixture()
        defer { fixture.model.setEnabled(false) }
        fixture.model.startSeries()
        fixture.model.receive(.paired(fixture.pair(sequence: 1), fixture.counters))
        let panel = PoseComparisonView()
        panel.isHidden = false
        panel.frame = CGRect(x: 0, y: 0, width: 349, height: 500)
        panel.render(fixture.model, cameraPosition: .front)
        let control = try modeControl(inside: panel)
        control.selectedSegmentIndex = 1
        control.sendActions(for: .valueChanged)
        panel.layoutIfNeeded()
        let contents = descendants(panel)
        let label = try XCTUnwrap(contents.first { $0.accessibilityIdentifier == "poseComparisonText" } as? UILabel)
        let text = try XCTUnwrap(label.text)
        for token in ["Кадры:", "Пропуски:", "Устарели", "Кадр 1:1", "PTS", "EXIF", "2D: standing", "3D: measuring", "ΔY", "Depth data", "Оценка роста", "3D: —"] {
            XCTAssertTrue(text.contains(token), token)
        }
        let scroll = try XCTUnwrap(contents.first { $0.accessibilityIdentifier == "poseComparisonDetailsScroll" } as? UIScrollView)
        XCTAssertFalse(scroll.isHidden)
        XCTAssertGreaterThan(scroll.contentSize.height, scroll.bounds.height)
        let seriesButton = try XCTUnwrap(contents.first { $0.accessibilityIdentifier == "poseComparisonSeriesButton" })
        let originalFrame = seriesButton.convert(seriesButton.bounds, to: panel)
        scroll.contentOffset.y = max(0, scroll.contentSize.height - scroll.bounds.height)
        XCTAssertEqual(seriesButton.convert(seriesButton.bounds, to: panel), originalFrame)
        XCTAssertFalse(originalFrame.intersects(scroll.convert(scroll.bounds, to: panel)))
    }

    @MainActor
    func testCompactHUDAllDynamicTypeSizesFitIPhone15ProWithoutClippedMetrics() throws {
        let workout = ExperimentWorkoutFixture(cameraReady: false)
        let camera = CameraService(permission: ControlledCameraPermission(status: .denied), capture: ControlledCameraCapture())
        let controller = WorkoutViewController(viewModel: workout.viewModel, camera: camera, persistence: workout.store)
        controller.loadViewIfNeeded()
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        window.rootViewController = controller
        window.isHidden = false
        window.layoutIfNeeded()
        let systemInsets = controller.view.safeAreaInsets
        controller.additionalSafeAreaInsets = UIEdgeInsets(top: 59 - systemInsets.top, left: -systemInsets.left,
                                                           bottom: 34 - systemInsets.bottom, right: -systemInsets.right)
        defer {
            controller.cameraCoordinator.finish()
            window.isHidden = true
        }
        let contents = descendants(controller.view)
        let toggle = try XCTUnwrap(contents.first { $0.accessibilityIdentifier == "squatDiagnosticsButton" } as? UIButton)
        let openButton = try XCTUnwrap(contents.first { $0.accessibilityIdentifier == "poseComparisonButton" } as? UIButton)
        toggle.sendActions(for: .touchUpInside)
        openButton.sendActions(for: .touchUpInside)
        let panel = try XCTUnwrap(contents.first { $0.accessibilityIdentifier == "poseComparisonPanel" } as? PoseComparisonView)
        let controls = try XCTUnwrap(contents.first { $0.accessibilityIdentifier == "workoutControls" })
        let indicators = try XCTUnwrap(contents.first { $0.accessibilityIdentifier == "workoutIndicators" })
        XCTAssertTrue(indicators.isHidden)
        let fixture = PoseComparisonFixture()
        defer { fixture.model.setEnabled(false) }
        fixture.model.updateWorkout(active: true, repetitions: 48)
        fixture.model.selectedViewpoint = .frontal
        fixture.model.startSeries()
        var sequence: UInt64 = 0
        let categories: [UIContentSizeCategory] = [.extraSmall, .small, .medium, .large, .extraLarge, .extraExtraLarge, .extraExtraExtraLarge,
                                                  .accessibilityMedium, .accessibilityLarge, .accessibilityExtraLarge,
                                                  .accessibilityExtraExtraLarge, .accessibilityExtraExtraExtraLarge]
        for category in categories {
            sequence += 1
            let initialPair = displayPair(fixture, sequence: sequence, issue: .unsupportedRevision)
            fixture.clock.advance(.milliseconds(749))
            let pair = PoseComparisonPair(source: initialPair.source, detection: initialPair.detection, spatial: initialPair.spatial,
                                          latency: initialPair.latency, completedAt: fixture.clock.current)
            fixture.model.receive(.paired(pair, fixture.counters))
            controller.traitOverrides.preferredContentSizeCategory = category
            controller.view.setNeedsLayout()
            controller.view.layoutIfNeeded()
            panel.render(fixture.model, cameraPosition: .front)
            controller.view.layoutIfNeeded()
            XCTAssertEqual(controller.view.bounds.size, CGSize(width: 393, height: 852))
            XCTAssertEqual(controller.view.safeAreaInsets, UIEdgeInsets(top: 59, left: 0, bottom: 34, right: 0))
            XCTAssertEqual(panel.traitCollection.preferredContentSizeCategory, category)
            let expectedFont = UIFont.preferredFont(forTextStyle: .caption2, compatibleWith: UITraitCollection(preferredContentSizeCategory: category))
            XCTAssertEqual(try hudLabel("Status", inside: panel).font.pointSize, expectedFont.pointSize)
            let panelFrame = panel.convert(panel.bounds, to: controller.view)
            let controlsFrame = controls.convert(controls.bounds, to: controller.view)
            assertCompactMetricsFit(panel, container: controller.view, controls: controls, context: category.rawValue)
            if category.isAccessibilityCategory {
                XCTAssertFalse(try hudLabel("Planar", inside: panel).text?.contains("П ") == true)
                XCTAssertTrue(try hudLabel("Planar", inside: panel).text?.contains("Л ") == true)
                let menuButton = try XCTUnwrap(descendants(panel).first { $0.accessibilityIdentifier == "poseComparisonModeMenuButton" } as? UIButton)
                XCTAssertTrue(isVisible(menuButton))
                XCTAssertEqual(menuButton.accessibilityValue, "Кратко")
                XCTAssertEqual(Set(menuActions(menuButton.menu).map(\.title)), Set(["Кратко", "Подробно"]))
                XCTAssertTrue(try modeControl(inside: panel).isHidden)
                if let title = menuButton.titleLabel {
                    let needed = title.sizeThatFits(CGSize(width: title.bounds.width, height: .greatestFiniteMagnitude))
                    XCTAssertGreaterThan(title.bounds.width, 0)
                    XCTAssertGreaterThanOrEqual(title.bounds.height + 0.5, needed.height, "\(category.rawValue) mode menu")
                }
            }
            let seriesButton = try XCTUnwrap(descendants(panel).first { $0.accessibilityIdentifier == "poseComparisonSeriesButton" } as? UIButton)
            if let title = seriesButton.titleLabel {
                let needed = title.sizeThatFits(CGSize(width: title.bounds.width, height: .greatestFiniteMagnitude))
                XCTAssertGreaterThan(title.bounds.width, 0)
                XCTAssertGreaterThanOrEqual(title.bounds.height + 0.5, needed.height, "\(category.rawValue) series button")
            }
            if category == .large { XCTAssertLessThanOrEqual(panelFrame.height, 250) }
            print("HUD layout \(category.rawValue): height=\(panelFrame.height), font=\(try hudLabel("Status", inside: panel).font.pointSize), safe=\(controller.view.safeAreaInsets)")
            if category == .large || category == .accessibilityExtraExtraExtraLarge {
                let image = UIGraphicsImageRenderer(size: controller.view.bounds.size).image { context in
                    controller.view.drawHierarchy(in: controller.view.bounds, afterScreenUpdates: true)
                }
                let attachment = XCTAttachment(image: image)
                attachment.name = "Synthetic compact HUD \(category.rawValue)"
                attachment.lifetime = .keepAlways
                add(attachment)
            }
            for issue: Pose3DIssue? in [.noBody, .missingJoint, .visionError, .invalidGeometry, .cancelled, nil] {
                sequence += 1
                fixture.model.receive(.paired(displayPair(fixture, sequence: sequence, issue: issue), fixture.counters))
                panel.render(fixture.model, cameraPosition: .back)
                controller.view.layoutIfNeeded()
                assertCompactMetricsFit(panel, container: controller.view, controls: controls, context: category.rawValue + " \(String(describing: issue))")
            }
            fixture.clock.advance(.milliseconds(751))
            panel.render(fixture.model, cameraPosition: .back, cameraState: .permissionDenied)
            controller.view.layoutIfNeeded()
            assertCompactMetricsFit(panel, container: controller.view, controls: controls, context: category.rawValue + " stale / denied")
            panel.selectDisplayMode(.detailed)
            controller.view.layoutIfNeeded()
            XCTAssertLessThanOrEqual(panel.convert(panel.bounds, to: controller.view).maxY, controlsFrame.minY - 9)
            panel.selectDisplayMode(.compact)
        }
        toggle.sendActions(for: .touchUpInside)
        XCTAssertFalse(indicators.isHidden)
    }

    @MainActor
    private func assertCompactMetricsFit(_ panel: UIView, container: UIView, controls: UIView, context: String) {
        let panelFrame = panel.convert(panel.bounds, to: container)
        let controlsFrame = controls.convert(controls.bounds, to: container)
        XCTAssertTrue(container.bounds.contains(panelFrame), context)
        XCTAssertLessThanOrEqual(panelFrame.maxY, controlsFrame.minY - 9, context)
        XCTAssertFalse(panelFrame.intersects(controlsFrame), context)
        for label in descendants(panel).compactMap({ $0 as? UILabel }) where label.accessibilityIdentifier?.hasPrefix("poseHUD") == true && isVisible(label) {
            let needed = label.sizeThatFits(CGSize(width: label.bounds.width, height: .greatestFiniteMagnitude))
            XCTAssertGreaterThanOrEqual(label.bounds.height + 0.5, needed.height, "\(context) \(label.accessibilityIdentifier ?? "")")
            XCTAssertTrue(panel.bounds.contains(label.convert(label.bounds, to: panel)), "\(context) \(label.accessibilityIdentifier ?? "")")
        }
    }

    @MainActor
    private func hudLabel(_ identifier: String, inside panel: UIView) throws -> UILabel {
        try XCTUnwrap(descendants(panel).first { $0.accessibilityIdentifier == "poseHUD" + identifier } as? UILabel)
    }

    @MainActor
    private func modeControl(inside panel: UIView) throws -> UISegmentedControl {
        try XCTUnwrap(descendants(panel).first { $0.accessibilityIdentifier == "poseComparisonModeControl" } as? UISegmentedControl)
    }

    @MainActor
    private func menuActions(_ menu: UIMenu?) -> [UIAction] {
        guard let menu else { return [] }
        return menu.children.flatMap { element -> [UIAction] in
            if let action = element as? UIAction { return [action] }
            return menuActions(element as? UIMenu)
        }
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
    private func displayPair(_ fixture: PoseComparisonFixture, sequence: UInt64, issue: Pose3DIssue?) -> PoseComparisonPair {
        let original = fixture.pair(sequence: sequence)
        let pose = issue == nil ? Pose3DFixture.pose() : nil
        return PoseComparisonPair(source: original.source,
                                  detection: Pose3DDetection(pose: pose, issue: issue, detail: "Long Vision detail " + String(repeating: "x", count: 300)),
                                  spatial: ExperimentalDepthAnalysis(pose: pose), latency: original.latency,
                                  completedAt: fixture.clock.current)
    }

    @MainActor
    func testBackgroundDoesNotReactivateExperimentBeforeExplicitResume() async throws {
        let workout = ExperimentWorkoutFixture(cameraReady: false)
        let capture = ExperimentCameraCapture()
        let camera = CameraService(permission: ControlledCameraPermission(status: .authorized), capture: capture)
        let controller = WorkoutViewController(viewModel: workout.viewModel, camera: camera, persistence: workout.store)
        controller.loadViewIfNeeded()
        controller.cameraCoordinator.startInitially()
        await camera.start().value
        let contents = descendants(controller.view)
        let diagnostics = try XCTUnwrap(contents.first { $0.accessibilityIdentifier == "squatDiagnosticsButton" } as? UIButton)
        let comparison = try XCTUnwrap(contents.first { $0.accessibilityIdentifier == "poseComparisonButton" } as? UIButton)
        diagnostics.sendActions(for: .touchUpInside)
        comparison.sendActions(for: .touchUpInside)
        XCTAssertTrue(capture.experiment?.isProcessingEnabled == true)
        controller.cameraCoordinator.sceneDidEnterBackground()
        XCTAssertTrue(capture.experiment?.isProcessingEnabled == false)
        XCTAssertTrue(workout.viewModel.isPaused)
        controller.cameraCoordinator.sceneDidBecomeActive()
        XCTAssertTrue(capture.experiment?.isProcessingEnabled == false)
        controller.cameraCoordinator.togglePause()
        await camera.start().value
        XCTAssertTrue(capture.experiment?.isProcessingEnabled == true)
        controller.cameraCoordinator.finish()
        await camera.finish().value
        XCTAssertTrue(capture.experiment?.isProcessingEnabled == false)
    }

    @MainActor
    func testInterruptionAndRuntimeErrorSuspendExperimentUntilExplicitRetry() async throws {
        let workout = ExperimentWorkoutFixture(cameraReady: false)
        let capture = ExperimentCameraCapture()
        let camera = CameraService(permission: ControlledCameraPermission(status: .authorized), capture: capture)
        let controller = WorkoutViewController(viewModel: workout.viewModel, camera: camera, persistence: workout.store)
        controller.loadViewIfNeeded()
        controller.cameraCoordinator.startInitially()
        await camera.start().value
        let contents = descendants(controller.view)
        let diagnostics = try XCTUnwrap(contents.first { $0.accessibilityIdentifier == "squatDiagnosticsButton" } as? UIButton)
        let comparison = try XCTUnwrap(contents.first { $0.accessibilityIdentifier == "poseComparisonButton" } as? UIButton)
        diagnostics.sendActions(for: .touchUpInside)
        comparison.sendActions(for: .touchUpInside)
        for event in [CameraSessionEvent.interrupted, .runtimeError("Controlled failure")] {
            camera.receive(event)
            XCTAssertTrue(capture.experiment?.isProcessingEnabled == false)
            XCTAssertTrue(workout.viewModel.isPaused)
            camera.receive(.interruptionEnded)
            XCTAssertTrue(capture.experiment?.isProcessingEnabled == false)
            controller.cameraCoordinator.togglePause()
            await camera.start().value
            XCTAssertTrue(capture.experiment?.isProcessingEnabled == true)
        }
        controller.cameraCoordinator.finish()
        await camera.finish().value
    }

    @MainActor
    func testComparisonPanelSupportsDynamicTypeAndKeepsWorkoutControlsClear() throws {
        let workout = ExperimentWorkoutFixture(cameraReady: false)
        let camera = CameraService()
        let controller = WorkoutViewController(viewModel: workout.viewModel, camera: camera, persistence: workout.store)
        controller.loadViewIfNeeded()
        defer { controller.cameraCoordinator.finish() }
        let contents = descendants(controller.view)
        let diagnostics = try XCTUnwrap(contents.first { $0.accessibilityIdentifier == "squatDiagnosticsButton" } as? UIButton)
        let comparison = try XCTUnwrap(contents.first { $0.accessibilityIdentifier == "poseComparisonButton" } as? UIButton)
        let panel = try XCTUnwrap(contents.first { $0.accessibilityIdentifier == "poseComparisonPanel" })
        diagnostics.sendActions(for: .touchUpInside)
        comparison.sendActions(for: .touchUpInside)
        for viewport in [CGSize(width: 375, height: 667), CGSize(width: 393, height: 852)] {
            controller.view.frame = CGRect(origin: .zero, size: viewport)
            controller.view.traitOverrides.preferredContentSizeCategory = .accessibilityExtraExtraExtraLarge
            controller.view.setNeedsLayout()
            controller.view.layoutIfNeeded()
            let panelFrame = panel.convert(panel.bounds, to: controller.view)
            XCTAssertTrue(controller.view.bounds.contains(panelFrame))
            let cameraSwitch = try XCTUnwrap(contents.first { $0.accessibilityIdentifier == "cameraSwitchButton" })
            XCTAssertFalse(panelFrame.intersects(cameraSwitch.convert(cameraSwitch.bounds, to: controller.view)))
            for button in contents.compactMap({ $0 as? UIButton }) where button.currentTitle == "Завершить" || button.currentTitle == "Продолжить" {
                XCTAssertFalse(panelFrame.intersects(button.convert(button.bounds, to: controller.view)))
            }
        }
        let label = try hudLabel("Status", inside: controller.view)
        XCTAssertTrue(label.adjustsFontForContentSizeCategory)
    }

    @MainActor
    func testPairedResultsKeepExactFrameAndIndependentDecisions() {
        let fixture = PoseComparisonFixture()
        defer { fixture.model.setEnabled(false) }
        fixture.model.startSeries()
        let pair = fixture.pair(sequence: 1)
        fixture.model.receive(.paired(pair, fixture.counters))
        XCTAssertEqual(fixture.model.latestPair?.source.metadata.identity, pair.source.metadata.identity)
        XCTAssertEqual(fixture.model.latestPair?.source.metadata.timestamp, pair.source.metadata.timestamp)
        XCTAssertEqual(fixture.model.latestPair?.source.analysis.decision, "repetitionCounted")
        XCTAssertEqual(fixture.model.latestPair?.spatial.decision, .indeterminateDepth)
        XCTAssertNil(fixture.model.latestPair?.spatial.confirmedRepetitions)
        XCTAssertEqual(fixture.model.series.last?.pairs.count, 1)
    }

    @MainActor
    func testDuplicatePairIsNotRecordedTwice() {
        let fixture = PoseComparisonFixture()
        defer { fixture.model.setEnabled(false) }
        fixture.model.startSeries()
        let pair = fixture.pair(sequence: 1)
        fixture.model.receive(.paired(pair, fixture.counters))
        fixture.model.receive(.paired(pair, fixture.counters))
        XCTAssertEqual(fixture.model.series.last?.pairs.count, 1)
        XCTAssertEqual(fixture.model.rejectedResults, 1)
    }

    @MainActor
    func testOlderPairCannotReplaceNewerFrame() {
        let fixture = PoseComparisonFixture()
        defer { fixture.model.setEnabled(false) }
        fixture.model.startSeries()
        fixture.model.receive(.paired(fixture.pair(sequence: 2), fixture.counters))
        fixture.model.receive(.paired(fixture.pair(sequence: 1), fixture.counters))
        XCTAssertEqual(fixture.model.latestPair?.source.metadata.identity.sequence, 2)
        XCTAssertEqual(fixture.model.series.last?.pairs.count, 1)
    }

    @MainActor
    func testExpiredAndFutureResultsAreRejectedWithControlledTime() {
        let fixture = PoseComparisonFixture()
        defer { fixture.model.setEnabled(false) }
        let expired = fixture.pair(sequence: 1)
        fixture.clock.advance(.milliseconds(751))
        fixture.model.receive(.paired(expired, fixture.counters))
        let future = fixture.pair(sequence: 2, receivedAt: fixture.clock.current.advanced(by: .seconds(1)))
        fixture.model.receive(.paired(future, fixture.counters))
        XCTAssertNil(fixture.model.latestPair)
        XCTAssertEqual(fixture.model.rejectedResults, 2)
    }

    @MainActor
    func testFrontBackFrontRejectsPreviousCameraEpochs() {
        let fixture = PoseComparisonFixture()
        defer { fixture.model.setEnabled(false) }
        let front = fixture.pair(sequence: 1)
        fixture.capture.configure(generation: 2, position: .back)
        let back = fixture.pair(sequence: 1, generation: 2, position: .back)
        fixture.model.receive(.paired(front, fixture.counters))
        fixture.model.receive(.paired(back, fixture.counters))
        XCTAssertEqual(fixture.model.latestPair?.source.metadata.position, .back)
        fixture.capture.configure(generation: 3, position: .front)
        fixture.model.receive(.paired(back, fixture.counters))
        fixture.model.receive(.paired(fixture.pair(sequence: 1, generation: 3), fixture.counters))
        XCTAssertEqual(fixture.model.latestPair?.source.metadata.position, .front)
        XCTAssertEqual(fixture.model.latestPair?.source.metadata.identity.generation, 3)
        XCTAssertEqual(fixture.model.rejectedResults, 2)
    }

    @MainActor
    func testPauseAndBackgroundEndSeriesAndDoNotAcceptLateResults() {
        let fixture = PoseComparisonFixture()
        defer { fixture.model.setEnabled(false) }
        fixture.model.startSeries()
        let beforePause = fixture.pair(sequence: 1)
        fixture.model.updateWorkout(active: false, repetitions: 4)
        fixture.model.receive(.paired(beforePause, fixture.counters))
        XCTAssertFalse(fixture.model.isRecording)
        XCTAssertNil(fixture.model.latestPair)
        XCTAssertNotNil(fixture.model.series.last?.endedAt)
        XCTAssertFalse(fixture.model.canStartSeries)
        XCTAssertEqual(fixture.model.productionRepetitions, 4)
        fixture.model.updateWorkout(active: true, repetitions: 4)
        fixture.model.receive(.paired(beforePause, fixture.counters))
        XCTAssertNil(fixture.model.latestPair)
        XCTAssertFalse(fixture.model.isRecording)
    }

    @MainActor
    func testManualAnnotationRequiresExplicitCompletedSeriesAndIndependentCounts() {
        let fixture = PoseComparisonFixture()
        defer { fixture.model.setEnabled(false) }
        XCTAssertFalse(fixture.model.annotate(full: 1, partial: 2, uncertain: 0))
        fixture.model.selectedViewpoint = .diagonal
        fixture.model.startSeries()
        XCTAssertNil(fixture.model.series.last?.annotation)
        fixture.model.receive(.paired(fixture.pair(sequence: 1), fixture.counters))
        XCTAssertFalse(fixture.model.annotate(full: 1, partial: 2, uncertain: 0))
        fixture.model.finishSeries()
        XCTAssertFalse(fixture.model.annotate(full: -1, partial: 2, uncertain: 0))
        XCTAssertTrue(fixture.model.annotate(full: 0, partial: 4, uncertain: 1))
        XCTAssertEqual(fixture.model.series.last?.annotation, ExperimentManualAnnotation(fullRepetitions: 0, partialRepetitions: 4, uncertainRepetitions: 1))
        XCTAssertEqual(fixture.model.series.last?.viewpoint, .diagonal)
        XCTAssertEqual(fixture.model.latestPair?.source.analysis.repetitions, 9)
        XCTAssertNil(fixture.model.latestPair?.spatial.confirmedRepetitions)
    }

    @MainActor
    func testNumericMemoryIsBoundedAndEvictionsRemainVisible() {
        let fixture = PoseComparisonFixture()
        defer { fixture.model.setEnabled(false) }
        fixture.model.startSeries()
        for sequence in 1...610 {
            fixture.model.receive(.paired(fixture.pair(sequence: UInt64(sequence)), fixture.counters))
        }
        XCTAssertEqual(fixture.model.series.last?.pairs.count, 600)
        XCTAssertEqual(fixture.model.series.last?.evictedPairs, 10)
        XCTAssertEqual(fixture.model.series.last?.pairs.first?.source.metadata.identity.sequence, 11)
    }

    @MainActor
    func testExperimentDoesNotMutateWorkoutCounterDurationOrSummary() {
        let workout = ExperimentWorkoutFixture()
        defer { workout.viewModel.finish() }
        workout.completeRepetition()
        let before = workout.state
        let experiment = PoseComparisonFixture()
        defer { experiment.model.setEnabled(false) }
        for sequence in 1...10 {
            experiment.model.receive(.paired(experiment.pair(sequence: UInt64(sequence)), experiment.counters))
        }
        XCTAssertEqual(workout.state?.totalRepetitions, before?.totalRepetitions)
        XCTAssertEqual(workout.state?.currentSet, before?.currentSet)
        XCTAssertEqual(workout.state?.elapsedSeconds, before?.elapsedSeconds)
        XCTAssertNil(workout.viewModel.finishedSummary)
    }

    @MainActor
    func testReleasingViewModelDisablesExperimentAndCancelsSubscription() {
        let capture = PoseExperimentCapture()
        capture.configure(generation: 1)
        var model: PoseComparisonViewModel? = PoseComparisonViewModel(capture: capture)
        model?.setEnabled(true)
        model?.updateWorkout(active: true, repetitions: 0)
        let epoch = capture.currentEpoch
        weak let weakModel = model
        model = nil
        XCTAssertNil(weakModel)
        XCTAssertGreaterThan(capture.currentEpoch, epoch)
    }

    @MainActor
    func testFPSAndLatencyUseMeasuredValuesNotConfiguredFrequency() {
        let fixture = PoseComparisonFixture()
        defer { fixture.model.setEnabled(false) }
        fixture.model.startSeries()
        let pair = fixture.pair(sequence: 1)
        fixture.model.receive(.planar(pair.source, fixture.counters))
        fixture.model.receive(.paired(pair, fixture.counters))
        fixture.clock.advance(.seconds(2))
        XCTAssertEqual(fixture.model.planarFPS, 5, accuracy: 0.000001)
        XCTAssertEqual(fixture.model.spatialFPS, 0.5, accuracy: 0.000001)
        XCTAssertEqual(fixture.model.usableFPS, 0.5, accuracy: 0.000001)
        XCTAssertEqual(fixture.model.latestPair?.latency, 0.06)
        XCTAssertFalse(fixture.model.isLatestPairFresh)
    }
    #endif
}

@MainActor
private final class ExperimentWorkoutFixture {
    let store = ExperimentWorkoutStore()
    let viewModel: WorkoutViewModel
    var state: WorkoutViewState?

    init(cameraReady: Bool = true) {
        viewModel = WorkoutViewModel(persistence: store, timeSource: ExperimentWorkoutClock(), cameraReady: cameraReady)
        viewModel.onChange = { [weak self] state in self?.state = state }
    }

    func completeRepetition() {
        for angle in [170.0, 90, 170] {
            for _ in 0..<24 { viewModel.process(SquatPoseFixture.pose(leftAngle: angle)) }
        }
    }
}

@MainActor
private final class ExperimentWorkoutStore: WorkoutStoring {
    func save(_ summary: WorkoutSummary) throws {}
    func history() throws -> [WorkoutSummary] { [] }
}

@MainActor
private struct ExperimentWorkoutClock: WorkoutTimeSource {
    var currentTime: TimeInterval { 0 }
    var date: Date { Date(timeIntervalSince1970: 0) }
}

#if DEBUG
private actor ExperimentCameraCapture: CameraCapturing {
    nonisolated let base = ControlledCameraCapture()
    nonisolated let experiment: PoseExperimentCapture? = PoseExperimentCapture()
    nonisolated var frames: AsyncStream<CameraFrame> { base.frames }
    nonisolated var events: AsyncStream<CameraSessionEvent> { base.events }
    nonisolated var previewSource: CameraPreviewSource? { nil }
    private var latestGeneration: UInt64 = 0
    private var isShutdown = false

    func start(generation: UInt64, position: CameraPosition) async throws -> CameraConfiguration {
        guard !isShutdown, generation >= latestGeneration else { throw CancellationError() }
        latestGeneration = generation
        let configuration = try await base.start(generation: generation, position: position)
        guard !isShutdown, generation == latestGeneration else { throw CancellationError() }
        experiment?.configure(generation: generation, position: position, rotationAngle: configuration.rotationAngle)
        return configuration
    }

    func stop(generation: UInt64) async {
        guard generation >= latestGeneration else { return }
        latestGeneration = generation
        experiment?.suspend()
        await base.stop(generation: generation)
    }

    func shutdown() async {
        isShutdown = true
        experiment?.shutdown()
        await base.shutdown()
    }
}

@MainActor
final class PoseComparisonFixture {
    let capture = PoseExperimentCapture()
    let clock = ExperimentTestClock()
    let model: PoseComparisonViewModel
    var counters: ExperimentLoadStatistics {
        var counters = ExperimentLoadStatistics()
        counters.analyzed2D = 10
        counters.completed3D = 1
        counters.comparablePairs = 1
        counters.usable3D = 1
        return counters
    }

    init() {
        let clock = clock
        model = PoseComparisonViewModel(capture: capture, clock: { clock.current })
        capture.configure(generation: 1)
        model.setEnabled(true)
        model.updateWorkout(active: true, repetitions: 0)
    }

    func pair(
        sequence: UInt64, generation: UInt64 = 1, position: CameraPosition = .front,
        receivedAt: ContinuousClock.Instant? = nil
    ) -> PoseComparisonPair {
        let metadata = ExperimentFrameMetadata(
            identity: ExperimentFrameIdentity(generation: generation, sequence: sequence), timestamp: Double(sequence) / 10,
            receivedAt: receivedAt ?? clock.current, position: position, rotationAngle: 90,
            orientation: 1, inputMirrored: false, depthDataProvided: false
        )
        let planar = Experimental2DAnalysis(
            leftAngle: 170, rightAngle: 168, leftUsable: true, rightUsable: true,
            phase: "standing", decision: "repetitionCounted", repetitions: 9
        )
        let source = ExperimentFrame2D(epoch: capture.currentEpoch, metadata: metadata, analysis: planar, latency: 0.012)
        let pose = Pose3DFixture.pose()
        return PoseComparisonPair(
            source: source, detection: Pose3DDetection(pose: pose, issue: nil, detail: nil),
            spatial: ExperimentalDepthAnalysis(pose: pose), latency: 0.06, completedAt: clock.current
        )
    }
}
#endif
