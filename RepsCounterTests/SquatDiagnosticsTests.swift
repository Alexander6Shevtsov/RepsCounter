//
//  SquatDiagnosticsTests.swift
//  RepsCounter
//
//  Maintainer: Alexander Shevtsov
//  Copyright © 2026 Alexander Shevtsov.

import UIKit
import XCTest
@testable import RepsCounter

final class SquatDiagnosticsTests: XCTestCase {
    @MainActor
    func testLegChangeCannotCompletePreviousLoweredMovement() {
        let fixture = SquatTrackingFixture()
        defer { fixture.viewModel.finish() }
        fixture.feed(SquatPoseFixture.pose(leftAngle: 170, rightAngle: 170, rightConfidence: 0.8))
        fixture.feed(SquatPoseFixture.pose(leftAngle: 90, rightAngle: 90, rightConfidence: 0.8))
        fixture.feed(SquatPoseFixture.pose(leftAngle: 170, rightAngle: 170, leftConfidence: 0.4, rightConfidence: 0.8))
        XCTAssertEqual(fixture.state?.totalRepetitions, 0)
        fixture.feed(SquatPoseFixture.pose(leftAngle: 90, rightAngle: 90, leftConfidence: 0.4, rightConfidence: 0.8))
        fixture.feed(SquatPoseFixture.pose(leftAngle: 170, rightAngle: 170, leftConfidence: 0.4, rightConfidence: 0.8))
        XCTAssertEqual(fixture.state?.totalRepetitions, 1)
    }

    @MainActor
    func testSingleJointLossPreservesCompletedCountAndRequiresNewStanding() {
        let fixture = SquatTrackingFixture()
        defer { fixture.viewModel.finish() }
        fixture.completeRepetition()
        fixture.feed(SquatPoseFixture.pose(leftAngle: 90))
        var joints = SquatPoseFixture.pose(leftAngle: 90).joints
        joints.removeValue(forKey: .leftAnkle)
        fixture.viewModel.process(BodyPose(joints: joints, aspectRatio: 1))
        fixture.feed(SquatPoseFixture.pose(leftAngle: 170))
        XCTAssertEqual(fixture.state?.totalRepetitions, 1)
        fixture.completeRepetition()
        XCTAssertEqual(fixture.state?.totalRepetitions, 2)
    }

    @MainActor
    func testBriefLowConfidenceCannotBridgeLoweredMovement() {
        let fixture = SquatTrackingFixture()
        defer { fixture.viewModel.finish() }
        fixture.feed(SquatPoseFixture.pose(leftAngle: 170))
        fixture.feed(SquatPoseFixture.pose(leftAngle: 90))
        fixture.viewModel.process(SquatPoseFixture.pose(leftAngle: 90, leftConfidence: 0.49))
        fixture.feed(SquatPoseFixture.pose(leftAngle: 170))
        XCTAssertEqual(fixture.state?.totalRepetitions, 0)
    }

    @MainActor
    func testFrontProjectionDoesNotInventDepthAndSideCycleCountsOnce() {
        for yawAngle in [0.0, 90] {
            let fixture = SquatTrackingFixture()
            fixture.feed(SquatPoseFixture.projectedPose(kneeAngle: 170, cameraYaw: yawAngle))
            fixture.feed(SquatPoseFixture.projectedPose(kneeAngle: 100, cameraYaw: yawAngle))
            fixture.feed(SquatPoseFixture.projectedPose(kneeAngle: 170, cameraYaw: yawAngle))
            XCTAssertEqual(fixture.state?.totalRepetitions, yawAngle == 90 ? 1 : 0)
            fixture.viewModel.finish()
        }
    }

    @MainActor
    func testIncompleteSmoothedMovementDoesNotCountOrDuplicate() {
        let fixture = SquatTrackingFixture()
        defer { fixture.viewModel.finish() }
        fixture.feed(SquatPoseFixture.pose(leftAngle: 170))
        fixture.feed(SquatPoseFixture.pose(leftAngle: 130))
        fixture.feed(SquatPoseFixture.pose(leftAngle: 170))
        XCTAssertEqual(fixture.state?.totalRepetitions, 0)
        fixture.completeRepetition()
        fixture.feed(SquatPoseFixture.pose(leftAngle: 170), frames: 60)
        XCTAssertEqual(fixture.state?.totalRepetitions, 1)
    }

    @MainActor
    func testSilentObservationGapCannotCompletePreviousLoweredMovement() {
        let fixture = SquatTrackingFixture()
        defer { fixture.viewModel.finish() }
        fixture.completeRepetition()
        fixture.feed(SquatPoseFixture.pose(leftAngle: 90))
        fixture.clock.currentTime = 0.3
        fixture.feed(SquatPoseFixture.pose(leftAngle: 170))
        XCTAssertEqual(fixture.state?.totalRepetitions, 1)
        fixture.completeRepetition()
        XCTAssertEqual(fixture.state?.totalRepetitions, 2)
    }

    @MainActor
    func testShortObservationIntervalsDoNotResetValidMovement() {
        let fixture = SquatTrackingFixture()
        defer { fixture.viewModel.finish() }
        for angle in Array(repeating: 170.0, count: 24) + Array(repeating: 90.0, count: 24) + Array(repeating: 170.0, count: 24) {
            fixture.clock.currentTime += 0.2
            fixture.viewModel.process(SquatPoseFixture.pose(leftAngle: angle))
        }
        XCTAssertEqual(fixture.state?.totalRepetitions, 1)
    }

    @MainActor
    func testDiagnosticsControlsFollowBuildConfiguration() throws {
        let fixture = SquatTrackingFixture(cameraReady: false)
        let capture = CameraService()
        let controller = WorkoutViewController(viewModel: fixture.viewModel, camera: capture, persistence: fixture.store)
        controller.loadViewIfNeeded()
        defer { controller.cameraCoordinator.finish() }
        let controls = allSubviews(in: controller.view)
        let toggle = controls.first { $0.accessibilityIdentifier == "squatDiagnosticsButton" } as? UIButton
        let panel = controls.first { $0.accessibilityIdentifier == "squatDiagnosticsPanel" }
        #if DEBUG
        let button = try XCTUnwrap(toggle)
        let diagnosticsPanel = try XCTUnwrap(panel)
        XCTAssertTrue(diagnosticsPanel.isHidden)
        button.sendActions(for: .touchUpInside)
        XCTAssertFalse(diagnosticsPanel.isHidden)
        XCTAssertEqual(button.accessibilityValue, "Включена")
        let label = try XCTUnwrap(controls.first { $0.accessibilityIdentifier == "squatDiagnosticsText" } as? UILabel)
        XCTAssertTrue(label.text?.contains("ожидание камеры") == true)
        button.sendActions(for: .touchUpInside)
        XCTAssertTrue(diagnosticsPanel.isHidden)
        XCTAssertEqual(button.accessibilityValue, "Выключена")
        #else
        XCTAssertNil(toggle)
        XCTAssertNil(panel)
        #endif
    }

    #if DEBUG
    @MainActor
    func testDebugPanelReservesSpaceForMetricsAndControlsAtPhoneSizesAndLargeText() throws {
        let fixture = SquatTrackingFixture(cameraReady: false)
        let camera = CameraService()
        let controller = WorkoutViewController(viewModel: fixture.viewModel, camera: camera, persistence: fixture.store)
        controller.loadViewIfNeeded()
        defer { controller.cameraCoordinator.finish() }
        let contents = allSubviews(in: controller.view)
        let button = try XCTUnwrap(contents.first { $0.accessibilityIdentifier == "squatDiagnosticsButton" } as? UIButton)
        let panel = try XCTUnwrap(contents.first { $0.accessibilityIdentifier == "squatDiagnosticsPanel" })
        XCTAssertEqual(button.accessibilityValue, "Выключена")
        fixture.viewModel.setCameraReady(true)
        fixture.viewModel.resume()
        fixture.feed(SquatPoseFixture.pose(leftAngle: 170, rightAngle: 165, leftConfidence: 0.7, rightConfidence: 0.9))
        button.sendActions(for: .touchUpInside)
        for viewport in [CGSize(width: 375, height: 667), CGSize(width: 393, height: 852)] {
            for category in [UIContentSizeCategory.large, .accessibilityExtraExtraExtraLarge] {
                controller.view.frame = CGRect(origin: .zero, size: viewport)
                controller.view.traitOverrides.preferredContentSizeCategory = category
                controller.view.setNeedsLayout()
                controller.view.layoutIfNeeded()
                let panelFrame = panel.convert(panel.bounds, to: controller.view)
                XCTAssertTrue(controller.view.bounds.contains(panelFrame))
                let labels = contents.compactMap { $0 as? UILabel }.filter { !$0.isDescendant(of: panel) }
                for label in labels {
                    XCTAssertFalse(panelFrame.intersects(label.convert(label.bounds, to: controller.view)), label.text ?? "label")
                }
                for control in contents.compactMap({ $0 as? UIButton }) where !control.isDescendant(of: panel) {
                    XCTAssertFalse(panelFrame.intersects(control.convert(control.bounds, to: controller.view)))
                }
                if viewport.width == 393, category == .large {
                    let image = UIGraphicsImageRenderer(size: viewport).image { context in
                        controller.view.layer.render(in: context.cgContext)
                    }
                    let attachment = XCTAttachment(image: image)
                    attachment.name = "Synthetic Debug diagnostics — iPhone 15 Pro size"
                    attachment.lifetime = .keepAlways
                    add(attachment)
                }
            }
        }
        button.sendActions(for: .touchUpInside)
        controller.view.layoutIfNeeded()
        XCTAssertTrue(panel.isHidden)
    }

    @MainActor
    func testDiagnosticsExposeBothLegConfidencesRawAngleAndSmoothedDecision() throws {
        let fixture = SquatTrackingFixture()
        defer { fixture.viewModel.finish() }
        fixture.feed(SquatPoseFixture.pose(leftAngle: 170, rightAngle: 165, leftConfidence: 0.7, rightConfidence: 0.9), frames: 1)
        let diagnostics = try XCTUnwrap(fixture.viewModel.latestDiagnostics)
        XCTAssertEqual(diagnostics.analysis?.selectedLeg, .right)
        XCTAssertEqual(diagnostics.analysis?.leftMeasurement.hipConfidence, 0.7)
        XCTAssertEqual(diagnostics.analysis?.rightMeasurement.ankleConfidence, 0.9)
        XCTAssertEqual(diagnostics.consecutiveFrames, 1)
        XCTAssertEqual(diagnostics.decision, .confirmingStanding)
        XCTAssertEqual(diagnostics.phase, .seekingStanding)
        XCTAssertEqual(diagnostics.standingThreshold, 160)
        XCTAssertEqual(diagnostics.loweredThreshold, 105)
        let panel = SquatDiagnosticsView()
        panel.render(diagnostics)
        let label = try XCTUnwrap(allSubviews(in: panel).first { $0.accessibilityIdentifier == "squatDiagnosticsText" } as? UILabel)
        XCTAssertTrue(label.text?.contains("Правая: 165.0°") == true)
        XCTAssertTrue(label.text?.contains("Нога: правая") == true)
        XCTAssertTrue(label.text?.contains("≥ 160°: да") == true)
        XCTAssertTrue(label.text?.contains("Последовательные кадры: 1/3") == true)
        XCTAssertTrue(label.adjustsFontForContentSizeCategory)
    }

    @MainActor
    func testDiagnosticsExplainMissingLowConfidenceAndSmoothedDepth() throws {
        let fixture = SquatTrackingFixture()
        defer { fixture.viewModel.finish() }
        fixture.feed(SquatPoseFixture.pose(leftAngle: 170))
        fixture.viewModel.process(SquatPoseFixture.pose(leftAngle: 90))
        let filtered = try XCTUnwrap(fixture.viewModel.latestDiagnostics)
        XCTAssertEqual(filtered.analysis?.measuredAngle ?? 0, 90, accuracy: 0.001)
        XCTAssertGreaterThan(filtered.analysis?.smoothedAngle ?? 0, 105)
        XCTAssertEqual(filtered.decision, .awaitingDepth)
        fixture.viewModel.process(SquatPoseFixture.pose(leftAngle: 90, leftConfidence: 0.2))
        let rejected = try XCTUnwrap(fixture.viewModel.latestDiagnostics)
        XCTAssertEqual(rejected.decision, .invalidMeasurement)
        XCTAssertEqual(rejected.phase, .seekingStanding)
        XCTAssertEqual(rejected.analysis?.leftMeasurement.issue, .lowConfidence)
        fixture.viewModel.process(nil)
        XCTAssertEqual(fixture.viewModel.latestDiagnostics?.analysis?.leftMeasurement.issue, .missingJoint)
    }

    @MainActor
    func testPauseClearsDiagnosticAnglesWithoutChangingCountOrTime() throws {
        let fixture = SquatTrackingFixture()
        defer { fixture.viewModel.finish() }
        fixture.completeRepetition()
        fixture.clock.currentTime = 7.75
        fixture.viewModel.pause()
        fixture.clock.currentTime = 100
        let diagnostics = try XCTUnwrap(fixture.viewModel.latestDiagnostics)
        XCTAssertEqual(diagnostics.status, .paused)
        XCTAssertNil(diagnostics.analysis)
        XCTAssertEqual(diagnostics.phase, .seekingStanding)
        XCTAssertEqual(fixture.state?.totalRepetitions, 1)
        XCTAssertEqual(fixture.viewModel.elapsedSeconds, 7)
    }

    @MainActor
    func testRefreshExpiresSilentTrackingAndReportsReason() throws {
        let fixture = SquatTrackingFixture()
        defer { fixture.viewModel.finish() }
        fixture.completeRepetition()
        fixture.feed(SquatPoseFixture.pose(leftAngle: 90))
        fixture.clock.currentTime = 0.3
        fixture.viewModel.refreshTime()
        let diagnostics = try XCTUnwrap(fixture.viewModel.latestDiagnostics)
        XCTAssertEqual(diagnostics.phase, .seekingStanding)
        XCTAssertEqual(diagnostics.resetReason, .observationGap)
        XCTAssertNil(diagnostics.analysis)
        XCTAssertEqual(fixture.state?.poseDetected, false)
        XCTAssertEqual(fixture.state?.totalRepetitions, 1)
        fixture.feed(SquatPoseFixture.pose(leftAngle: 170))
        XCTAssertEqual(fixture.state?.totalRepetitions, 1)
    }

    @MainActor
    func testDiagnosticsRestAndFinishDoNotContinueProcessingPoses() {
        let fixture = SquatTrackingFixture()
        for _ in 0..<12 { fixture.completeRepetition() }
        XCTAssertEqual(fixture.viewModel.latestDiagnostics?.status, .resting)
        XCTAssertNil(fixture.viewModel.latestDiagnostics?.analysis)
        fixture.feed(SquatPoseFixture.pose(leftAngle: 90))
        XCTAssertEqual(fixture.state?.totalRepetitions, 12)
        fixture.viewModel.finish()
        XCTAssertEqual(fixture.viewModel.latestDiagnostics?.status, .finished)
        fixture.feed(SquatPoseFixture.pose(leftAngle: 170))
        XCTAssertEqual(fixture.state?.totalRepetitions, 12)
    }
    #endif

    @MainActor
    private func allSubviews(in parent: UIView) -> [UIView] {
        parent.subviews.flatMap { [$0] + allSubviews(in: $0) }
    }
}

@MainActor
private final class SquatTrackingFixture {
    let store = SquatTrackingStore()
    let clock = SquatTrackingClock()
    let viewModel: WorkoutViewModel
    var state: WorkoutViewState?

    init(cameraReady: Bool = true) {
        viewModel = WorkoutViewModel(persistence: store, timeSource: clock, cameraReady: cameraReady)
        viewModel.onChange = { [weak self] state in self?.state = state }
    }

    func feed(_ pose: BodyPose, frames: Int = 24) {
        for _ in 0..<frames { viewModel.process(pose) }
    }

    func completeRepetition() {
        feed(SquatPoseFixture.pose(leftAngle: 170))
        feed(SquatPoseFixture.pose(leftAngle: 90))
        feed(SquatPoseFixture.pose(leftAngle: 170))
    }
}

@MainActor
private final class SquatTrackingStore: WorkoutStoring {
    private var summaries: [WorkoutSummary] = []

    func save(_ summary: WorkoutSummary) throws { summaries.append(summary) }
    func history() throws -> [WorkoutSummary] { summaries }
}

@MainActor
private final class SquatTrackingClock: WorkoutTimeSource {
    var currentTime: TimeInterval = 0
    var date: Date { Date(timeIntervalSince1970: 0) }
}
