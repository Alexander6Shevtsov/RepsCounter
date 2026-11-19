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
    func testPoseRateTracksActualFramesAndResetsOnCameraGap() {
        var tracker = PoseFrameRateTracker()
        for frameNumber in 0...20 {
            tracker.record(at: Double(frameNumber) * 0.05)
        }
        XCTAssertEqual(tracker.rate ?? 0, 20, accuracy: 0.1)

        tracker.reset()
        XCTAssertNil(tracker.rate)

        tracker.record(at: 4)
        tracker.record(at: 4)
        XCTAssertNil(tracker.rate)
        tracker.record(at: 4.6)
        XCTAssertEqual(tracker.rate ?? 0, 1.67, accuracy: 0.02)

        tracker.record(at: 2)
        XCTAssertNil(tracker.rate)
    }

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
    func testDebugHUDKeepsMetricsAndControlsVisibleAtPhoneSizesAndLargeText() throws {
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
                XCTAssertEqual(panelFrame.width, 250, accuracy: 0.5)
                XCTAssertEqual(panelFrame.height, 170, accuracy: 0.5)
                XCTAssertLessThan(panelFrame.midY, controller.view.bounds.midY)
                let metrics = try XCTUnwrap(contents.first { $0.accessibilityIdentifier == "workoutMetricsScroll" })
                let count = try XCTUnwrap(contents.first { $0.accessibilityIdentifier == "workoutCount" })
                let controls = try XCTUnwrap(contents.first { $0.accessibilityIdentifier == "workoutControls" })
                XCTAssertFalse(metrics.isHidden)
                XCTAssertFalse(count.isHidden)
                XCTAssertFalse(controls.isHidden)
                XCTAssertFalse(panelFrame.intersects(controls.convert(controls.bounds, to: controller.view)))
                let protectedLabels = contents.compactMap { $0 as? UILabel }.filter { candidate in
                    ["workoutCount", "workoutExercise"].contains(candidate.accessibilityIdentifier ?? "")
                        || ["Повторения в подходе", "Подход"].contains(candidate.text ?? "")
                }
                XCTAssertEqual(protectedLabels.count, 4)
                XCTAssertFalse(protectedLabels.contains(where: { $0.isHidden }))
                let panelScroll = try XCTUnwrap(allSubviews(in: panel).first { $0 is UIScrollView } as? UIScrollView)
                XCTAssertTrue(panelScroll.isScrollEnabled)
                XCTAssertGreaterThan(panelScroll.bounds.height, 0)
                XCTAssertGreaterThan(panelScroll.contentSize.height, 0)
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
        XCTAssertTrue(label.text?.contains("Нога: правая") == true)
        XCTAssertTrue(label.text?.contains("confidence 0.90") == true)
        XCTAssertTrue(label.text?.contains("Обработано поз/с:") == true)
        XCTAssertTrue(label.text?.contains("raw 165.0°") == true)
        XCTAssertTrue(label.text?.contains("EMA 165.0°") == true)
        XCTAssertTrue(label.text?.contains("Таз−колено: +0.97 бедра") == true)
        XCTAssertTrue(label.text?.contains("Фаза: seekingStanding · кадры 1/3") == true)
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
        XCTAssertEqual(filtered.decision, .confirmingDepth)
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
        XCTAssertEqual(diagnostics.lastDepthAttempt?.outcome, .observationGap)
        XCTAssertEqual(diagnostics.lastDepthAttempt?.lastBreak, .observationGap)
        XCTAssertGreaterThanOrEqual(diagnostics.lastDepthAttempt?.maxPoseInterval ?? 0, 0.3)
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
    @MainActor
    func testDebugResetCountersTrackDistinctLossesLegChangesAndGaps() throws {
        let fixture = SquatTrackingFixture()
        defer { fixture.viewModel.finish() }
        let standingPose = SquatPoseFixture.pose(leftAngle: 170)
        fixture.feed(standingPose)
        XCTAssertEqual(fixture.viewModel.latestDiagnostics?.phase, .standing)

        let lowConfidence = SquatPoseFixture.replacing(standingPose, joint: .leftHip, confidence: 0.49)
        fixture.feed(lowConfidence, frames: 3)
        XCTAssertEqual(fixture.viewModel.latestDiagnostics?.measurementLossCount, 1)
        XCTAssertEqual(fixture.viewModel.latestDiagnostics?.latestMeasurementIssue, .lowConfidence)
        XCTAssertEqual(fixture.viewModel.latestDiagnostics?.phase, .seekingStanding)

        fixture.feed(standingPose)
        XCTAssertEqual(fixture.viewModel.latestDiagnostics?.phase, .standing)
        let rightLegPose = SquatPoseFixture.pose(
            leftAngle: 170,
            rightAngle: 170,
            leftConfidence: 0.49,
            rightConfidence: 0.9
        )
        fixture.feed(rightLegPose, frames: 1)
        XCTAssertEqual(fixture.viewModel.latestDiagnostics?.legChangeCount, 1)
        fixture.feed(rightLegPose)
        XCTAssertEqual(fixture.viewModel.latestDiagnostics?.phase, .standing)

        fixture.clock.currentTime += 0.3
        fixture.viewModel.refreshTime()
        let diagnostics = try XCTUnwrap(fixture.viewModel.latestDiagnostics)
        XCTAssertEqual(diagnostics.observationGapCount, 1)
        XCTAssertEqual(diagnostics.measurementLossCount, 1)
        XCTAssertEqual(diagnostics.legChangeCount, 1)
        XCTAssertEqual(diagnostics.resetReason, .observationGap)

        let panel = SquatDiagnosticsView()
        panel.render(diagnostics)
        let label = try XCTUnwrap(allSubviews(in: panel).first {
            $0.accessibilityIdentifier == "squatDiagnosticsText"
        } as? UILabel)
        XCTAssertTrue(label.text?.contains("Сбросы И:1 Н:1 Г:1") == true)
        XCTAssertTrue(label.text?.contains("Последняя потеря: низкая достоверность") == true)
    }

    @MainActor
    func testExperimentalWorkoutCountsDeepAndRejectsNearDepthPoses() {
        let fixture = SquatTrackingFixture()
        defer { fixture.viewModel.finish() }
        let standingPose = syntheticSquatPose(kneeAngle: 170, hipKneeHeightRatio: 0.98)
        let deepPose = syntheticSquatPose(kneeAngle: 70, hipKneeHeightRatio: 0.08)
        let partialPose = syntheticSquatPose(kneeAngle: 99, hipKneeHeightRatio: 0.48)

        for movement in 0..<6 {
            fixture.feed(standingPose)
            fixture.feed(movement < 3 ? deepPose : partialPose)
            if movement >= 3 {
                XCTAssertEqual(fixture.viewModel.latestDiagnostics?.decision, .awaitingHipKneeDepth)
                XCTAssertEqual(fixture.viewModel.latestDiagnostics?.phase, .standing)
            }
            fixture.feed(standingPose)
            XCTAssertEqual(fixture.state?.totalRepetitions, min(movement + 1, 3))
        }
    }

    @MainActor
    func testDiagnosticsSeparateRawConfirmationFromEMADelay() throws {
        let fixture = SquatTrackingFixture()
        defer { fixture.viewModel.finish() }
        fixture.feed(SquatPoseFixture.pose(leftAngle: 170))
        fixture.feed(SquatPoseFixture.pose(leftAngle: 110), frames: 48)
        fixture.feed(SquatPoseFixture.pose(leftAngle: 104), frames: 3)
        let diagnostics = try XCTUnwrap(fixture.viewModel.latestDiagnostics)
        XCTAssertEqual(diagnostics.consecutiveFrames, 3)
        XCTAssertEqual(diagnostics.decision, .awaitingDepthSmoothing)
        let panel = SquatDiagnosticsView()
        panel.render(diagnostics)
        let label = try XCTUnwrap(allSubviews(in: panel).first { $0.accessibilityIdentifier == "squatDiagnosticsText" } as? UILabel)
        XCTAssertTrue(label.text?.contains("raw 104.0°") == true)
        XCTAssertTrue(label.text?.contains("кадры 3/3") == true)
        XCTAssertTrue(label.text?.contains("EMA ещё >105°") == true)
    }
    @MainActor
    func testDepthAttemptRecordsTwoFramesBeforeHeightBreakWithoutCounting() throws {
        let fixture = SquatTrackingFixture()
        defer { fixture.viewModel.finish() }
        let standingPose = syntheticSquatPose(kneeAngle: 170, hipKneeHeightRatio: 0.98)
        let deepPose = syntheticSquatPose(kneeAngle: 70, hipKneeHeightRatio: 0.08)
        let highPose = syntheticSquatPose(kneeAngle: 99, hipKneeHeightRatio: 0.48)

        fixture.feed(standingPose)
        fixture.clock.currentTime = 0.08
        fixture.viewModel.process(deepPose)
        fixture.clock.currentTime = 0.16
        fixture.viewModel.process(deepPose)
        let pending = try XCTUnwrap(fixture.viewModel.latestDiagnostics?.activeDepthAttempt)
        XCTAssertEqual(pending.maxDepthFrames, 2)
        XCTAssertEqual(pending.depthBreakCount, 0)
        XCTAssertFalse(pending.depthConfirmed)

        fixture.clock.currentTime = 0.20
        fixture.viewModel.process(highPose)
        let interrupted = try XCTUnwrap(fixture.viewModel.latestDiagnostics?.activeDepthAttempt)
        XCTAssertEqual(interrupted.maxDepthFrames, 2)
        XCTAssertEqual(interrupted.depthBreakCount, 1)
        XCTAssertEqual(interrupted.lastBreak, .hipHeight)
        XCTAssertEqual(fixture.viewModel.latestDiagnostics?.consecutiveFrames, 0)

        fixture.clock.currentTime = 0.24
        fixture.feed(standingPose)
        let finished = try XCTUnwrap(fixture.viewModel.latestDiagnostics?.lastDepthAttempt)
        XCTAssertEqual(finished.outcome, .returnedWithoutDepth)
        XCTAssertEqual(finished.maxDepthFrames, 2)
        XCTAssertEqual(finished.minRawAngle ?? 0, 70, accuracy: 0.001)
        XCTAssertEqual(finished.minHipKneeHeightRatio ?? 0, 0.08, accuracy: 0.001)
        XCTAssertEqual(finished.maxPoseInterval ?? 0, 0.08, accuracy: 0.001)
        XCTAssertEqual(fixture.viewModel.latestDiagnostics?.recentDepthAttempts.count, 1)
        XCTAssertEqual(fixture.state?.totalRepetitions, 0)

        let panel = SquatDiagnosticsView()
        panel.render(try XCTUnwrap(fixture.viewModel.latestDiagnostics))
        let label = try XCTUnwrap(allSubviews(in: panel).first {
            $0.accessibilityIdentifier == "squatDiagnosticsText"
        } as? UILabel)
        XCTAssertTrue(label.text?.contains("Попытка #1: пик 2/3 · срывы 1") == true)
        XCTAssertTrue(label.text?.contains("Срыв: высота таза") == true)
        XCTAssertTrue(label.text?.contains("Макс интервал: 80 мс") == true)
        XCTAssertTrue(label.text?.contains("возврат без глубины") == true)
    }

    @MainActor
    func testDepthAttemptRecordsCountedMovementAndNoDuplicateEvents() throws {
        let fixture = SquatTrackingFixture()
        defer { fixture.viewModel.finish() }
        let standingPose = syntheticSquatPose(kneeAngle: 170, hipKneeHeightRatio: 0.98)
        let deepPose = syntheticSquatPose(kneeAngle: 70, hipKneeHeightRatio: 0.08)

        fixture.feed(standingPose)
        fixture.feed(deepPose)
        fixture.feed(standingPose)
        let counted = try XCTUnwrap(fixture.viewModel.latestDiagnostics?.lastDepthAttempt)
        XCTAssertEqual(counted.outcome, .counted)
        XCTAssertTrue(counted.depthConfirmed)
        XCTAssertEqual(counted.maxDepthFrames, 3)
        XCTAssertEqual(counted.depthBreakCount, 0)
        XCTAssertEqual(counted.selectedLeg, .left)
        XCTAssertEqual(fixture.state?.totalRepetitions, 1)

        fixture.feed(standingPose)
        XCTAssertEqual(fixture.viewModel.latestDiagnostics?.recentDepthAttempts.count, 1)
        XCTAssertEqual(fixture.state?.totalRepetitions, 1)
    }

    @MainActor
    func testDepthAttemptRecordsMeasurementLossWithoutCompletingMovement() throws {
        let fixture = SquatTrackingFixture()
        defer { fixture.viewModel.finish() }
        let standingPose = syntheticSquatPose(kneeAngle: 170, hipKneeHeightRatio: 0.98)
        let deepPose = syntheticSquatPose(kneeAngle: 70, hipKneeHeightRatio: 0.08)

        fixture.feed(standingPose)
        fixture.viewModel.process(deepPose)
        fixture.viewModel.process(deepPose)
        let lowConfidence = SquatPoseFixture.replacing(deepPose, joint: .leftHip, confidence: 0.49)
        fixture.viewModel.process(lowConfidence)

        let aborted = try XCTUnwrap(fixture.viewModel.latestDiagnostics?.lastDepthAttempt)
        XCTAssertEqual(aborted.outcome, .measurementLost)
        XCTAssertEqual(aborted.lastBreak, .measurementLost)
        XCTAssertEqual(aborted.maxDepthFrames, 2)
        XCTAssertEqual(aborted.depthBreakCount, 1)
        XCTAssertNil(fixture.viewModel.latestDiagnostics?.activeDepthAttempt)
        XCTAssertEqual(fixture.state?.totalRepetitions, 0)

        fixture.feed(standingPose)
        fixture.feed(deepPose)
        fixture.feed(standingPose)
        XCTAssertEqual(fixture.state?.totalRepetitions, 1)
        XCTAssertEqual(fixture.viewModel.latestDiagnostics?.recentDepthAttempts.count, 2)
        XCTAssertEqual(fixture.viewModel.latestDiagnostics?.lastDepthAttempt?.outcome, .counted)
    }

    #endif

    private func syntheticSquatPose(kneeAngle: Double, hipKneeHeightRatio: Double) -> BodyPose {
        let thighLength = 0.2
        let verticalOffset = hipKneeHeightRatio * thighLength
        let horizontalOffset = sqrt(1 - hipKneeHeightRatio * hipKneeHeightRatio) * thighLength
        let thighAngle = atan2(verticalOffset, horizontalOffset)
        let shinAngle = thighAngle - kneeAngle * .pi / 180
        return BodyPose(
            joints: [
                .leftHip: JointPoint(
                    location: CGPoint(x: 0.5 + horizontalOffset, y: 0.5 + verticalOffset),
                    confidence: 1
                ),
                .leftKnee: JointPoint(location: CGPoint(x: 0.5, y: 0.5), confidence: 1),
                .leftAnkle: JointPoint(
                    location: CGPoint(x: 0.5 + thighLength * cos(shinAngle), y: 0.5 + thighLength * sin(shinAngle)),
                    confidence: 1
                )
            ],
            aspectRatio: 1
        )
    }

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
