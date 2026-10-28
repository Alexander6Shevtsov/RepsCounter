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
        #endif
    }

    @MainActor
    private func descendants(_ view: UIView) -> [UIView] {
        [view] + view.subviews.flatMap { descendants($0) }
    }

    #if DEBUG
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
        let label = try XCTUnwrap(contents.first { $0.accessibilityIdentifier == "poseComparisonText" } as? UILabel)
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
