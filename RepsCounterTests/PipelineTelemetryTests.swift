import Foundation
import XCTest
@testable import RepsCounter

final class PipelineTelemetryTests: XCTestCase {

    func testPTSCadenceAdmitsThirtyDespiteDelegateJitterAndRejectsDuplicates() {
        var cadence = VisionPTSCadence()
        var accepted = 0
        for index in 0..<300 {
            let pts = Double(index) / 30
            if cadence.accepts(pts, rate: 30) { accepted += 1 }
            XCTAssertFalse(cadence.accepts(pts, rate: 30))
        }
        XCTAssertEqual(accepted, 300)
        XCTAssertFalse(cadence.accepts(.nan, rate: 30))
        XCTAssertFalse(cadence.accepts(0, rate: 30))
        var slower = VisionPTSCadence()
        XCTAssertEqual((0..<300).filter { slower.accepts(Double($0) / 30, rate: 15) }.count, 150)
    }

    func testTimeBasedConfirmationRequiresDwellAndRealObservations() {
        var state = TimeBasedPoseProcessor()
        let pose = timingPose(angle: 180)
        for t in [0.0, 0.033, 0.066, 0.099, 0.132, 0.165, 0.198] {
            XCTAssertFalse(state.process(pose, at: t))
            XCTAssertEqual(state.phase, .seekingStanding)
        }
        XCTAssertFalse(state.process(pose, at: 0.231))
        XCTAssertEqual(state.phase, .standing)
        _ = state.process(nil, at: 0.24)
        XCTAssertEqual(state.phase, .seekingStanding)
        _ = state.process(pose, at: 0.25)
        _ = state.process(pose, at: 0.26)
        _ = state.process(pose, at: 0.27)
        XCTAssertEqual(state.phase, .seekingStanding)
        _ = state.process(pose, at: 1.0)
        XCTAssertEqual(state.phase, .seekingStanding)
    }

    private func timingPose(angle: Double, mirror: Bool = false) -> BodyPose {
        let radians = angle * .pi / 180
        let hip = angle <= 105 ? CGPoint(x: 0.2, y: 0.5) : CGPoint(x: 0.5, y: 0.8)
        let ankle = angle <= 105
            ? CGPoint(x: 0.5 - 0.3 * cos(radians), y: 0.5 - 0.3 * sin(radians))
            : CGPoint(x: 0.5 + 0.3 * sin(radians), y: 0.5 + 0.3 * cos(radians))
        let joints: [BodyJoint: JointPoint] = [
            mirror ? .rightHip : .leftHip: .init(location: hip, confidence: 0.9),
            mirror ? .rightKnee : .leftKnee: .init(location: CGPoint(x: 0.5, y: 0.5), confidence: 0.9),
            mirror ? .rightAnkle : .leftAnkle: .init(location: ankle, confidence: 0.9)]
        return BodyPose(joints: joints, aspectRatio: 1)
    }

    func testTimedPathRejectsShallowNoiseDuplicatesAndIsCausal() {
        for mirror in [false, true] {
            var state = TimeBasedPoseProcessor()
            var counts = 0
            for index in 0..<150 {
                let time = Double(index) / 30
                let angle = index < 30 || index >= 90 ? 180.0 : 120.0
                let pose = timingPose(angle: angle, mirror: mirror)
                if state.process(pose, at: time) { counts += 1 }
                XCTAssertFalse(state.process(pose, at: time))
            }
            XCTAssertEqual(counts, 0)
        }
    }

    func testTimedPathCountsFullCycleOnceWithIrregularIntervals() {
        for mirror in [false, true] {
            var state = TimeBasedPoseProcessor()
            var times: [Double] = []
            for index in 0..<120 {
                let t = Double(index) / 30 + (index % 2 == 0 ? 0 : 0.002)
                let pose = timingPose(angle: index >= 30 && index < 70 ? 60 : 180, mirror: mirror)
                if state.process(pose, at: t) { times.append(t) }
            }
            XCTAssertEqual(times.count, 1)
            XCTAssertGreaterThan(times.first ?? 0, 2.33)
        }
    }

    func testFullVisionTraceRoundTripsCoordinatesBeforeLiveAdmission() throws {
        let recorder = PipelineTelemetry(capacity: 32)
        let pose = timingPose(angle: 180)
        recorder.record(.timeBasedReset, reason: "lifecycleBeforeCapture")
        for index in 0..<9 {
            let frame = recorder.frame(generation: 1, camera: "front", pts: nil,
                captureHostSeconds: Double(index) / 30)
            recorder.record(.fullPoseInput, frame: frame.identity, visionPose: .init(pose))
        }
        let snapshot = try JSONDecoder().decode(PipelineTelemetry.Snapshot.self,
            from: JSONEncoder().encode(recorder.snapshot()))
        let session = try snapshot.fullPoseSession()
        XCTAssertEqual(session.events.count, 10)
        XCTAssertEqual(session.events[0].kind, .reset)
        XCTAssertEqual(session.events[1].pose?.points.count, 3)
        let result = try TimeBasedPoseProcessor.compare(session)
        XCTAssertTrue(result.legacy.isEmpty)
        XCTAssertTrue(result.timed.isEmpty)
    }


    func testTimedReplayPrefixesCannotUseFutureFramesAndLossCancelsDepth() throws {
        let events = (0..<120).map { index in
            PoseReplayEvent(seconds: Double(index) / 30, kind: .pose,
                pose: .init(from: timingPose(angle: index >= 30 && index < 70 ? 60 : 180)))
        }
        let session = PoseReplaySession(schemaVersion: 1, events: events, annotations: [])
        let full = try TimeBasedPoseProcessor.compare(session)
        XCTAssertEqual(full.timed.count, 1)
        for end in stride(from: 1, through: events.count, by: 7) {
            let prefix = PoseReplaySession(schemaVersion: 1, events: Array(events.prefix(end)), annotations: [])
            XCTAssertEqual(try TimeBasedPoseProcessor.compare(prefix).timed,
                full.timed.filter { $0 <= events[end - 1].seconds })
        }
        var lost = events
        lost[69] = PoseReplayEvent(seconds: events[69].seconds, kind: .pose, pose: nil)
        XCTAssertTrue(try TimeBasedPoseProcessor.compare(
            PoseReplaySession(schemaVersion: 1, events: lost, annotations: [])).timed.isEmpty)
        var weak = events
        for index in 30..<70 {
            var pose = timingPose(angle: 60)
            var joints = pose.joints
            joints[.leftHip] = JointPoint(location: joints[.leftHip]!.location, confidence: 0.49)
            pose = BodyPose(joints: joints, aspectRatio: 1)
            weak[index] = PoseReplayEvent(seconds: events[index].seconds, kind: .pose, pose: .init(from: pose))
        }
        XCTAssertTrue(try TimeBasedPoseProcessor.compare(
            PoseReplaySession(schemaVersion: 1, events: weak, annotations: [])).timed.isEmpty)
    }

    func testQualitySelectionUsesValueSnapshotsAndCanRestoreBaseline() {
        let previous = CameraQualitySelection.current
        defer { CameraQualitySelection.current = previous }
        CameraQualitySelection.current = .baseline
        let baseline = CameraQualitySelection.current
        CameraQualitySelection.current = CameraQualityConfiguration(resolution: .hd1080, visionRate: .hz30)
        XCTAssertEqual(baseline, .baseline)
        XCTAssertEqual(CameraQualitySelection.current.resolution, .hd1080)
        XCTAssertEqual(CameraQualitySelection.current.visionRate, .hz30)
        CameraQualitySelection.current = .baseline
        XCTAssertEqual(CameraQualitySelection.current, baseline)
    }

    func testQualityConfigurationsKeepBaselineAndBoundCounterCadence() {
        XCTAssertEqual(CameraQualityConfiguration.baseline.resolution, .hd720)
        XCTAssertEqual(CameraQualityConfiguration.baseline.visionRate, .hz10)
        XCTAssertFalse(CameraQualityConfiguration.baseline.limitsCounterCadence)
        for resolution in CameraQualityConfiguration.Resolution.allCases {
            for rate in CameraQualityConfiguration.VisionRate.allCases {
                let value = CameraQualityConfiguration(resolution: resolution, visionRate: rate)
                XCTAssertTrue(value.supported(by: [720, 1080]))
                XCTAssertFalse(value.supported(by: []))
                XCTAssertFalse(value.accepts(elapsed: value.analysisInterval - 0.000001))
                XCTAssertTrue(value.accepts(elapsed: value.analysisInterval))
                XCTAssertFalse(value.accepts(elapsed: .nan))
                XCTAssertFalse(value.accepts(elapsed: -1))
                XCTAssertGreaterThanOrEqual(CameraQualityConfiguration.counterInterval, .milliseconds(80))
            }
        }
        XCTAssertFalse(CameraQualityConfiguration(resolution: .hd1080).supported(by: [720]))
    }

    func testQualityAdmissionAtThirtyCameraFramesPerSecond() {
        for (rate, expected) in [(CameraQualityConfiguration.VisionRate.hz10, 10), (.hz15, 15), (.hz30, 30)] {
            let value = CameraQualityConfiguration(visionRate: rate)
            var last: Double? = nil
            var admitted = 0
            for index in 0..<30 {
                let time = Double(index) / 30
                if last.map({ value.accepts(elapsed: time - $0) }) ?? true {
                    last = time
                    admitted += 1
                }
            }
            XCTAssertEqual(admitted, expected)
        }
    }

    func testHighRateCounterAdmissionCannotShortenStableConfirmation() {
        for step in [33, 66] {
            var counter = SquatCounter()
            var last: Int?
            var confirmedAt: Int?
            for time in stride(from: 0, through: 300, by: step) {
                if last.map({ CameraQualityConfiguration.acceptsCounter(elapsed: .milliseconds(time - $0)) }) ?? true {
                    last = time
                    _ = counter.process(angle: 180)
                    if confirmedAt == nil && counter.phase == .standing { confirmedAt = time }
                }
            }
            XCTAssertNotNil(confirmedAt)
            XCTAssertGreaterThanOrEqual(confirmedAt ?? 0, 160)
        }
        XCTAssertFalse(CameraQualityConfiguration.acceptsCounter(elapsed: .milliseconds(79)))
        XCTAssertTrue(CameraQualityConfiguration.acceptsCounter(elapsed: .milliseconds(80)))
        XCTAssertFalse(CameraQualityConfiguration.acceptsCounter(elapsed: .milliseconds(-1)))
    }

    func testQualityTraceRoundTripAndLegacyTraceImport() throws {
        let telemetry = PipelineTelemetry(capacity: 16)
        let quality = PipelineTelemetry.CameraQuality(width: 1080, height: 1920,
            requestedResolution: 1080, targetVisionHz: 30, rotationAngle: 90,
            mirrored: false, orientation: "up", confidences: ["leftHip": 0.7, "rightShoulder": 0.8],
            buildSHA: "test", sourceState: "dirty", patchSHA: "patch")
        telemetry.record(.cameraQuality, cameraQuality: quality)
        let data = try JSONEncoder().encode(telemetry.snapshot())
        let decoded = try JSONDecoder().decode(PipelineTelemetry.Snapshot.self, from: data)
        XCTAssertEqual(decoded.events.first?.cameraQuality?.width, 1080)
        XCTAssertEqual(decoded.events.first?.cameraQuality?.confidences.count, 2)
        var legacy = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        legacy["traceVersion"] = 1
        var events = legacy["events"] as! [[String: Any]]
        events[0].removeValue(forKey: "cameraQuality")
        events[0]["stage"] = "cameraInput"
        legacy["events"] = events
        let old = try JSONDecoder().decode(PipelineTelemetry.Snapshot.self,
            from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertNil(old.events.first?.cameraQuality)
    }

    func testLatencyRateAndPTSUseSeparateClocks() throws {
        let clock = TelemetryTestClock()
        let recorder = PipelineTelemetry(capacity: 512, clock: { clock.now })
        let pts = PipelineTelemetry.PTS(value: 123456789, timescale: 60000, epoch: 7, flags: 1)
        for i in 1...100 {
            clock.now = Double(i)
            let frame = recorder.frame(generation: 8, camera: "back", pts: pts, captureHostSeconds: clock.now - 0.25)
            let span = frame.begin("Test Vision", .visionStart)
            clock.now += Double(i) / 1024
            frame.end(span, .visionEnd)
        }
        let snapshot = recorder.snapshot()
        let measurement = try XCTUnwrap(snapshot.elapsedMS["visionEnd"])
        XCTAssertEqual(measurement.samples, 100)
        XCTAssertEqual(measurement.p50, 50 * 1000.0 / 1024)
        XCTAssertEqual(measurement.p95, 95 * 1000.0 / 1024)
        XCTAssertEqual(measurement.p99, 99 * 1000.0 / 1024)
        XCTAssertEqual(snapshot.hz["visionStart"], 1)
        XCTAssertEqual(snapshot.ageFromPTS_MS["cameraInput"]?.p95, 250)
        XCTAssertEqual(snapshot.events.last?.frame?.pts?.value, pts.value)
        XCTAssertEqual(snapshot.events.last?.frame?.pts?.epoch, 7)
        XCTAssertEqual(snapshot.events.first?.frame?.id, 1)
        XCTAssertEqual(snapshot.events.last?.frame?.id, 100)
        XCTAssertEqual(snapshot.events.map(\.sequence), (0..<300).map(UInt64.init))
    }

    func testCountersSurviveEvictionAndMissingCaptureClock() throws {
        let telemetry = PipelineTelemetry(capacity: 3, clock: { 1 })
        let first = telemetry.frame(generation: 1, camera: "front", pts: nil, captureHostSeconds: nil)
        first.mark(.throttled)
        let dropped = telemetry.frame(generation: 1, camera: "front", pts: nil, captureHostSeconds: 2, stage: .avDropped)
        let next = telemetry.frame(generation: 2, camera: "back", pts: nil, captureHostSeconds: nil)
        next.mark(.noPose)
        let snapshot = telemetry.snapshot()
        XCTAssertEqual(snapshot.overwritten, 2)
        XCTAssertEqual(snapshot.totals["throttled"], 1)
        XCTAssertEqual(snapshot.totals["cameraInput"], 2)
        XCTAssertEqual(snapshot.totals["avDropped"], 1)
        XCTAssertEqual(snapshot.events.map(\.sequence), [2, 3, 4])
        XCTAssertEqual(snapshot.events.map { $0.frame?.id }, [dropped.identity.id, next.identity.id, next.identity.id])
        XCTAssertTrue(snapshot.ageFromPTS_MS.isEmpty)
        XCTAssertTrue(snapshot.hz.isEmpty)
        let decoded = try JSONDecoder().decode(PipelineTelemetry.Snapshot.self, from: JSONEncoder().encode(snapshot))
        XCTAssertEqual(decoded.traceVersion, 3)
        XCTAssertEqual(decoded.traceID, telemetry.traceID)
        XCTAssertEqual(decoded.events.map(\.stage), [.avDropped, .cameraInput, .noPose])
    }

    func testLiveAndReplayHaveSeparateMetricsAndTimedControlEvents() throws {
        let session = PoseReplaySession(schemaVersion: 1, events: [
            .init(seconds: 0.5, kind: .reset, pose: nil),
            .init(seconds: 0.6, kind: .pose, pose: nil)
        ], annotations: [])
        let recorder = PipelineTelemetry(clock: { 10 })
        recorder.record(.reset, reason: "pause")
        _ = try PoseReplayRunner.replay(session, telemetry: recorder)
        let snapshot = recorder.snapshot()
        XCTAssertEqual(snapshot.totals["reset"], 1)
        XCTAssertEqual(snapshot.totals["replay.reset"], 2)
        XCTAssertEqual(snapshot.totals["replay.decision"], 1)
        XCTAssertNil(snapshot.totals["decision"])
        XCTAssertEqual(snapshot.events[1].replayControlSeconds, 0.5)
        XCTAssertEqual(snapshot.events.last?.frame?.replaySeconds, 0.6)
        XCTAssertNil(snapshot.events.last?.frame?.pts)
    }

    func testConcurrentProducersKeepOrderedBoundedEventsAndLifetimeTotals() {
        let recorder = PipelineTelemetry(capacity: 32, clock: { 1 })
        DispatchQueue.concurrentPerform(iterations: 256) { i in
            let frame = recorder.frame(generation: UInt64(i % 2), camera: "front", pts: nil, captureHostSeconds: nil)
            frame.mark(.visionStart)
            if i.isMultiple(of: 16) {
                let partial = recorder.snapshot()
                XCTAssertLessThanOrEqual(partial.events.count, 32)
                XCTAssertEqual(partial.events.map(\.sequence), partial.events.map(\.sequence).sorted())
            }
        }
        let result = recorder.snapshot()
        XCTAssertEqual(result.events.map(\.sequence), (480..<512).map(UInt64.init))
        XCTAssertEqual(result.overwritten, 480)
        XCTAssertEqual(result.totals["cameraInput"], 256)
        XCTAssertEqual(result.totals["visionStart"], 256)
    }

    func testLegacyFormatsAndOptionalFrameLinkRoundTrip() throws {
        let v1 = #"{"schemaVersion":1,"events":[{"seconds":0,"kind":"pose"}],"annotations":[]}"#
        let v2 = #"{"schemaVersion":2,"initialState":{"phase":"lowered","pendingFrames":0,"selectedLeg":"left","smoothedAngle":90},"events":[{"seconds":0,"kind":"reset"}],"annotations":[]}"#
        for json in [v1, v2] {
            let session = try JSONDecoder().decode(PoseReplaySession.self, from: Data(json.utf8))
            XCTAssertNil(session.pipelineTraceID)
            XCTAssertNil(session.events.first?.pipelineFrameID)
            XCTAssertNoThrow(try PoseReplayRunner.replay(session))
        }
        var recorder = PoseReplayRecorder()
        let t = PipelineTelemetry()
        let frame = t.frame(generation: 1, camera: "front", pts: nil, captureHostSeconds: nil)
        XCTAssertTrue(recorder.start(at: 42))
        recorder.append(nil, at: 42, trace: frame)
        struct LegacyEvent: Decodable {
            let seconds: Double
            let kind: PoseReplayEventKind
        }
        struct LegacySession: Decodable {
            let schemaVersion: Int
            let events: [LegacyEvent]
        }
        let data = try recorder.encodedSession()
        let legacy = try JSONDecoder().decode(LegacySession.self, from: data)
        XCTAssertEqual(legacy.schemaVersion, 1)
        XCTAssertEqual(legacy.events.first?.kind, .pose)
        let session = try JSONDecoder().decode(PoseReplaySession.self, from: data)
        XCTAssertEqual(session.pipelineTraceID, t.traceID)
        XCTAssertEqual(session.events.first?.pipelineFrameID, frame.identity.id)
        XCTAssertEqual(session.events.first?.seconds, 0)
    }

    @MainActor
    func testLiveDecisionsAndReplayMatchWithAndWithoutTracingAcrossResets() throws {
        let time = TelemetryWorkoutClock()
        let t = PipelineTelemetry()
        let quiet = WorkoutViewModel(persistence: TelemetryStore(), timeSource: time, telemetry: nil)
        let observed = WorkoutViewModel(persistence: TelemetryStore(), timeSource: time, telemetry: t)
        XCTAssertTrue(quiet.startPoseReplayRecording())
        XCTAssertTrue(observed.startPoseReplayRecording())
        var observedFrames: [UInt64] = []
        for index in 0..<30 {
            if index == 23 {
                for model in [quiet, observed] { model.pause(); model.resume() }
            }
            let right = index >= 21
            let low = (5..<13).contains(index)
            let hip = JointPoint(location: low ? CGPoint(x: 0.2, y: 0.5) : CGPoint(x: 0.5, y: 0.8), confidence: 0.875)
            let knee = JointPoint(location: CGPoint(x: 0.5, y: 0.5), confidence: 1)
            let ankle = JointPoint(location: CGPoint(x: 0.5, y: 0.2), confidence: 1)
            let pose = index == 25 ? nil : BodyPose(joints: [right ? .rightHip : .leftHip: hip,
                                                             right ? .rightKnee : .leftKnee: knee,
                                                             right ? .rightAnkle : .leftAnkle: ankle], aspectRatio: 1)
            time.currentTime += index == 27 ? 0.5 : 0.1
            let frame = t.frame(generation: 1, camera: "front", pts: nil, captureHostSeconds: nil)
            observedFrames.append(frame.identity.id)
            quiet.process(pose)
            observed.process(pose, trace: frame)
            XCTAssertEqual(quiet.latestDiagnostics?.phase, observed.latestDiagnostics?.phase)
            XCTAssertEqual(quiet.latestDiagnostics?.decision, observed.latestDiagnostics?.decision)
            XCTAssertEqual(quiet.latestDiagnostics?.analysis?.smoothedAngle, observed.latestDiagnostics?.analysis?.smoothedAngle)
        }
        let events = t.snapshot().events
        XCTAssertEqual(events.filter { $0.stage == .decision }.compactMap { $0.frame?.id }, observedFrames)
        let live = events.compactMap(\.decision)
        XCTAssertEqual(live.filter(\.counted).count, 1)
        XCTAssertEqual(live.first?.left.hip, 0.875)
        XCTAssertNil(live.first?.right.ankle)
        XCTAssertEqual(live[21].previousLeg, "left")
        XCTAssertEqual(live[21].selectedLeg, "right")
        XCTAssertEqual(events.filter { $0.stage == .reset }.compactMap(\.reason),
                       ["legChanged", "pause", "resume", "measurementLost", "observationGap"])
        let firstFrame = events.filter { $0.frame?.id == observedFrames.first }
        XCTAssertEqual(firstFrame.map(\.stage), [.cameraInput, .processedPose, .analyzerStart, .analyzerEnd,
                                                .fsmStart, .decision, .stateUIStart, .stateUIEnd])
        let quietData = try XCTUnwrap(quiet.stopPoseReplayRecording())
        let tracedData = try XCTUnwrap(observed.stopPoseReplayRecording())
        let quietSession = try JSONDecoder().decode(PoseReplaySession.self, from: quietData)
        let session = try JSONDecoder().decode(PoseReplaySession.self, from: tracedData)
        let replayTrace = PipelineTelemetry()
        let replay = try PoseReplayRunner.replay(session, telemetry: replayTrace)
        let reference = try PoseReplayRunner.replay(quietSession)
        XCTAssertEqual(reference.countedAtSeconds, replay.countedAtSeconds)
        XCTAssertEqual(reference.depthSamples.map(\.kneeAngle), replay.depthSamples.map(\.kneeAngle))
        XCTAssertEqual(reference.depthSamples.map(\.phase), replay.depthSamples.map(\.phase))
        XCTAssertEqual(replayTrace.snapshot().events.compactMap(\.decision), live)
        XCTAssertTrue(replayTrace.snapshot().ageFromPTS_MS.isEmpty)
        quiet.finish()
        observed.finish()
    }
}

private final class TelemetryTestClock: @unchecked Sendable {
    // Accessed synchronously by the test and its injected closure.
    var now = 0.0
}

@MainActor private final class TelemetryWorkoutClock: WorkoutTimeSource {
    var currentTime = 1.0
    let date = Date(timeIntervalSince1970: 1)
}

@MainActor private final class TelemetryStore: WorkoutStoring {
    func save(_ summary: WorkoutSummary) throws {}
    func history() throws -> [WorkoutSummary] { [] }
}
